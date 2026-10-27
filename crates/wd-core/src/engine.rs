//! 内核：设置、解析缓存、下载队列与事件。界面层和命令行都只和它打交道。

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Result, anyhow};
use serde::{Deserialize, Serialize};
use tokio::sync::{Semaphore, broadcast};

use crate::browser::BrowserPool;
use crate::download::{self, Progress};
use crate::extractors::{self, Ctx};
use crate::model::*;
use crate::util::sanitize_filename;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub download_dir: String,
    /// 按平台分子文件夹（抖音 / TikTok …）
    pub per_platform_dir: bool,
    pub max_concurrent: u32,
    /// 解析用的浏览器是否无头（关掉可以看到浏览器窗口，遇到验证时手动处理）
    pub browser_headless: bool,
    /// 手动指定的浏览器路径，空则自动查找
    pub browser_path: String,
    /// "system" / "light" / "dark"
    pub theme: String,
    /// 剪贴板里出现支持的链接时自动解析
    pub watch_clipboard: bool,
    pub ui_scale: f64,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            download_dir: default_download_dir().to_string_lossy().into_owned(),
            per_platform_dir: true,
            max_concurrent: 3,
            browser_headless: true,
            browser_path: String::new(),
            theme: "system".into(),
            watch_clipboard: true,
            ui_scale: 1.0,
        }
    }
}

pub fn default_download_dir() -> PathBuf {
    let home = std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    home.join("Downloads").join("WeDownload")
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskStatus {
    Queued,
    Running,
    Done,
    Failed,
    Canceled,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Task {
    pub id: u64,
    pub platform: Platform,
    pub source_url: String,
    pub title: String,
    pub author: Option<String>,
    pub cover: Option<String>,
    pub kind: MediaKind,
    pub item_index: u32,
    pub variant_label: String,
    pub file_path: String,
    pub status: TaskStatus,
    pub downloaded: u64,
    pub total: u64,
    /// 字节/秒（运行中才有意义）
    #[serde(skip)]
    pub speed: u64,
    pub error: Option<String>,
    pub created_at: u64,
    #[serde(skip)]
    variant: Option<Variant>,
}

#[derive(Debug, Clone)]
pub enum Event {
    /// 某个任务的状态或进度变化
    Task(Task),
    /// 任务增删
    TasksChanged,
    SettingsChanged,
}

/// 选中要下载的媒体：第几条、用第几个版本
#[derive(Debug, Clone, Copy)]
pub struct Selection {
    pub item: usize,
    pub variant: usize,
}

struct Running {
    cancel: Arc<AtomicBool>,
}

pub struct Core {
    data_dir: PathBuf,
    ctx: Ctx,
    dl_client: reqwest::Client,
    settings: Mutex<Settings>,
    tasks: Mutex<Vec<Task>>,
    running: Mutex<HashMap<u64, Running>>,
    next_id: AtomicU64,
    slots: Arc<Semaphore>,
    slot_count: Mutex<u32>,
    events: broadcast::Sender<Event>,
}

impl Core {
    /// 需要在 tokio 运行时里调用
    pub fn new(data_dir: PathBuf) -> Result<Arc<Self>> {
        std::fs::create_dir_all(&data_dir)?;
        let settings: Settings = read_json(&data_dir.join("settings.json")).unwrap_or_default();
        let mut tasks: Vec<Task> = read_json(&data_dir.join("tasks.json")).unwrap_or_default();
        // 上次退出时没下完的任务标记为失败，可以重试
        for t in &mut tasks {
            if matches!(t.status, TaskStatus::Queued | TaskStatus::Running) {
                t.status = TaskStatus::Failed;
                t.error = Some("程序退出时未完成".into());
            }
        }
        let next = tasks.iter().map(|t| t.id).max().unwrap_or(0) + 1;
        let browser = BrowserPool::new(data_dir.join("browser-profile"));
        let ctx = Ctx::new(browser.clone())?;
        let dl_client = reqwest::Client::builder()
            .user_agent(crate::util::DESKTOP_UA)
            .connect_timeout(Duration::from_secs(15))
            .read_timeout(Duration::from_secs(30))
            .build()?;
        let n = settings.max_concurrent.clamp(1, 8);
        let core = Arc::new(Self {
            data_dir,
            ctx,
            dl_client,
            settings: Mutex::new(settings),
            tasks: Mutex::new(tasks),
            running: Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(next),
            slots: Arc::new(Semaphore::new(n as usize)),
            slot_count: Mutex::new(n),
            events: broadcast::channel(512).0,
        });
        core.apply_browser_settings();
        Ok(core)
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Event> {
        self.events.subscribe()
    }

    pub fn data_dir(&self) -> &Path {
        &self.data_dir
    }

    // ---------- 设置 ----------

    pub fn settings(&self) -> Settings {
        self.settings.lock().unwrap().clone()
    }

    pub fn update_settings(&self, s: Settings) -> Result<()> {
        let n = s.max_concurrent.clamp(1, 8);
        {
            let mut cur = self.slot_count.lock().unwrap();
            if n > *cur {
                self.slots.add_permits((n - *cur) as usize);
            } else if n < *cur {
                self.slots.forget_permits((*cur - n) as usize);
            }
            *cur = n;
        }
        *self.settings.lock().unwrap() = s.clone();
        write_json(&self.data_dir.join("settings.json"), &s)?;
        self.apply_browser_settings();
        let _ = self.events.send(Event::SettingsChanged);
        Ok(())
    }

    fn apply_browser_settings(&self) {
        let s = self.settings();
        let b = self.ctx.browser.clone();
        b.set_executable((!s.browser_path.trim().is_empty()).then(|| PathBuf::from(s.browser_path.trim())));
        tokio::spawn(async move { b.set_headless(s.browser_headless).await });
    }

    /// 解析用的浏览器路径（找不到为 None）
    pub fn browser_executable(&self) -> Option<PathBuf> {
        self.ctx.browser.executable()
    }

    pub fn ytdlp_path(&self) -> Option<PathBuf> {
        extractors::ytdlp_path()
    }

    // ---------- 解析 ----------

    pub async fn extract(&self, input: &str) -> Result<MediaInfo> {
        extractors::extract(&self.ctx, input).await
    }

    // ---------- 下载 ----------

    pub fn tasks(&self) -> Vec<Task> {
        self.tasks.lock().unwrap().clone()
    }

    fn task(&self, id: u64) -> Option<Task> {
        self.tasks.lock().unwrap().iter().find(|t| t.id == id).cloned()
    }

    fn update_task(&self, id: u64, f: impl FnOnce(&mut Task)) -> Option<Task> {
        let t = {
            let mut g = self.tasks.lock().unwrap();
            let t = g.iter_mut().find(|t| t.id == id)?;
            f(t);
            t.clone()
        };
        let _ = self.events.send(Event::Task(t.clone()));
        Some(t)
    }

    fn save_tasks(&self) {
        let tasks = self.tasks();
        let _ = write_json(&self.data_dir.join("tasks.json"), &tasks);
    }

    /// 把选中的媒体加入下载队列，返回新任务 id
    pub fn enqueue(self: &Arc<Self>, info: &MediaInfo, picks: &[Selection]) -> Result<Vec<u64>> {
        let s = self.settings();
        let mut dir = PathBuf::from(&s.download_dir);
        if s.per_platform_dir {
            dir = dir.join(info.platform.display_name());
        }
        let base = {
            let title = sanitize_filename(&info.title, 80);
            match info.author.as_deref().map(|a| sanitize_filename(a, 30)) {
                Some(a) if !a.is_empty() && a != "untitled" => format!("{a} - {title}"),
                _ => title,
            }
        };
        let multi = picks.len() > 1;
        let mut ids = Vec::new();
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs();
        for (n, p) in picks.iter().enumerate() {
            let item = info.items.get(p.item).ok_or_else(|| anyhow!("没有第 {} 条媒体", p.item + 1))?;
            let v = item.variants.get(p.variant).or(item.variants.first()).ok_or_else(|| anyhow!("没有可下载的版本"))?;
            let suffix = match (multi, item.kind) {
                (true, MediaKind::Audio) => " 背景音乐".to_string(),
                (true, MediaKind::LivePhoto) => format!(" ({}) 实况", n + 1),
                (true, _) => format!(" ({})", n + 1),
                (false, MediaKind::Audio) => " 背景音乐".to_string(),
                _ => String::new(),
            };
            let path = unique_path(&dir.join(format!("{base}{suffix}.{}", v.ext)));
            let id = self.next_id.fetch_add(1, Ordering::Relaxed);
            let task = Task {
                id,
                platform: info.platform,
                source_url: info.url.clone(),
                title: info.title.clone(),
                author: info.author.clone(),
                cover: item.thumbnail.clone().or_else(|| info.cover.clone()),
                kind: item.kind,
                item_index: p.item as u32,
                variant_label: v.label.clone(),
                file_path: path.to_string_lossy().into_owned(),
                status: TaskStatus::Queued,
                downloaded: 0,
                total: v.size.unwrap_or(0),
                speed: 0,
                error: None,
                created_at: now,
                variant: Some(v.clone()),
            };
            self.tasks.lock().unwrap().insert(0, task);
            ids.push(id);
        }
        self.save_tasks();
        let _ = self.events.send(Event::TasksChanged);
        for id in &ids {
            self.clone().spawn_task(*id);
        }
        Ok(ids)
    }

    fn spawn_task(self: Arc<Self>, id: u64) {
        let cancel = Arc::new(AtomicBool::new(false));
        self.running.lock().unwrap().insert(id, Running { cancel: cancel.clone() });
        tokio::spawn(async move {
            let permit = self.slots.clone().acquire_owned().await;
            if cancel.load(Ordering::Relaxed) {
                self.running.lock().unwrap().remove(&id);
                return;
            }
            self.update_task(id, |t| {
                t.status = TaskStatus::Running;
                t.error = None;
            });
            let r = self.run_task(id, cancel.clone()).await;
            drop(permit);
            self.running.lock().unwrap().remove(&id);
            self.update_task(id, |t| {
                t.speed = 0;
                match &r {
                    Ok(n) => {
                        t.status = TaskStatus::Done;
                        t.downloaded = *n;
                        t.total = *n;
                    }
                    Err(_) if cancel.load(Ordering::Relaxed) => t.status = TaskStatus::Canceled,
                    Err(e) => {
                        t.status = TaskStatus::Failed;
                        t.error = Some(format!("{e:#}"));
                    }
                }
            });
            self.save_tasks();
        });
    }

    async fn run_task(&self, id: u64, cancel: Arc<AtomicBool>) -> Result<u64> {
        let task = self.task(id).ok_or_else(|| anyhow!("任务不存在"))?;
        let variant = match task.variant.clone() {
            Some(v) => v,
            // 重试 / 重启后：链接可能已过期，重新解析一次，按条目序号和版本名找回原来的选择
            None => {
                let info = self.extract(&task.source_url).await?;
                let item = info
                    .items
                    .get(task.item_index as usize)
                    .ok_or_else(|| anyhow!("作品内容变了，找不到原来的第 {} 条", task.item_index + 1))?;
                item.variants
                    .iter()
                    .find(|v| v.label == task.variant_label)
                    .or(item.variants.first())
                    .cloned()
                    .ok_or_else(|| anyhow!("没有可下载的版本"))?
            }
        };
        let progress = Arc::new(Progress::default());
        progress.total.store(task.total, Ordering::Relaxed);
        let dest = PathBuf::from(&task.file_path);

        // 定时汇报进度和速度
        let reporter = {
            let progress = progress.clone();
            let events = self.events.clone();
            let tasks = &self.tasks;
            let snapshot = move |down: u64, total: u64, speed: u64| {
                let mut g = tasks.lock().unwrap();
                g.iter_mut().find(|t| t.id == id).map(|t| {
                    t.downloaded = down;
                    t.total = total;
                    t.speed = speed;
                    t.clone()
                })
            };
            async move {
                let mut last = (Instant::now(), 0u64);
                let mut speed = 0f64;
                loop {
                    tokio::time::sleep(Duration::from_millis(300)).await;
                    let down = progress.downloaded.load(Ordering::Relaxed);
                    let total = progress.total.load(Ordering::Relaxed);
                    let dt = last.0.elapsed().as_secs_f64().max(0.001);
                    let inst = down.saturating_sub(last.1) as f64 / dt;
                    speed = if speed == 0.0 { inst } else { speed * 0.6 + inst * 0.4 };
                    last = (Instant::now(), down);
                    if let Some(t) = snapshot(down, total, speed as u64) {
                        let _ = events.send(Event::Task(t));
                    }
                }
            }
        };
        let work = download::download(&self.dl_client, &variant, &dest, progress.clone(), cancel);
        tokio::select! {
            r = work => r,
            _ = reporter => unreachable!(),
        }
    }

    pub fn cancel(&self, id: u64) {
        if let Some(r) = self.running.lock().unwrap().get(&id) {
            r.cancel.store(true, Ordering::Relaxed);
        }
        // 还在排队的任务直接标记
        self.update_task(id, |t| {
            if t.status == TaskStatus::Queued {
                t.status = TaskStatus::Canceled;
            }
        });
    }

    pub fn retry(self: &Arc<Self>, id: u64) {
        let Some(t) = self.task(id) else { return };
        if matches!(t.status, TaskStatus::Queued | TaskStatus::Running) {
            return;
        }
        self.update_task(id, |t| {
            t.status = TaskStatus::Queued;
            t.error = None;
            t.downloaded = 0;
        });
        self.clone().spawn_task(id);
    }

    /// 删除任务记录；`delete_file` 为真时连同已下载的文件一起删
    pub fn remove(&self, id: u64, delete_file: bool) {
        self.cancel(id);
        let removed = {
            let mut g = self.tasks.lock().unwrap();
            let pos = g.iter().position(|t| t.id == id);
            pos.map(|p| g.remove(p))
        };
        if let Some(t) = removed {
            let p = PathBuf::from(&t.file_path);
            let _ = std::fs::remove_file(download::part_path(&p));
            if delete_file {
                let _ = std::fs::remove_file(&p);
            }
        }
        self.save_tasks();
        let _ = self.events.send(Event::TasksChanged);
    }

    /// 清除所有已完成的任务记录（不删文件）
    pub fn clear_finished(&self) {
        self.tasks.lock().unwrap().retain(|t| t.status != TaskStatus::Done);
        self.save_tasks();
        let _ = self.events.send(Event::TasksChanged);
    }

    pub async fn shutdown(&self) {
        for r in self.running.lock().unwrap().values() {
            r.cancel.store(true, Ordering::Relaxed);
        }
        self.ctx.browser.close().await;
        self.save_tasks();
    }
}

/// 已存在同名文件（或正在下载的同名任务）时加 " (2)"、" (3)" …
fn unique_path(p: &Path) -> PathBuf {
    if !p.exists() && !download::part_path(p).exists() {
        return p.to_path_buf();
    }
    let stem = p.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let ext = p.extension().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    for i in 2.. {
        let c = p.with_file_name(format!("{stem} ({i}).{ext}"));
        if !c.exists() && !download::part_path(&c).exists() {
            return c;
        }
    }
    unreachable!()
}

fn read_json<T: for<'de> Deserialize<'de>>(p: &Path) -> Option<T> {
    serde_json::from_slice(&std::fs::read(p).ok()?).ok()
}

fn write_json<T: Serialize>(p: &Path, v: &T) -> Result<()> {
    let tmp = p.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(v)?)?;
    std::fs::rename(tmp, p)?;
    Ok(())
}
