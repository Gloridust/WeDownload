//! 初始化、解析、下载队列、设置。

use std::path::PathBuf;

use flutter_rust_bridge::frb;

use crate::api::types::*;
use crate::frb_generated::StreamSink;
use crate::state::{self, core, recall, remember, rt, run};

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// 启动内核。`data_dir` 为空时用平台默认目录（Linux: ~/.local/share/wedownload）。
pub async fn bootstrap(data_dir: Option<String>) -> anyhow::Result<()> {
    if state::CORE.get().is_some() {
        return Ok(());
    }
    run(async move {
        let dir = match data_dir {
            Some(d) => PathBuf::from(d),
            None => directories::ProjectDirs::from("io.github", "gloridust", "WeDownload")
                .map(|p| p.data_dir().to_path_buf())
                .ok_or_else(|| anyhow::anyhow!("无法确定数据目录"))?,
        };
        let c = wd_core::Core::new(dir)?;
        let _ = state::CORE.set(c);
        Ok(())
    })
    .await
}

/// 订阅任务与设置变化，整个应用生命周期内调用一次。
pub fn events(sink: StreamSink<UiEvent>) -> anyhow::Result<()> {
    let c = core()?;
    let mut rx = c.subscribe();
    rt().spawn(async move {
        loop {
            let ev = match rx.recv().await {
                Ok(e) => e,
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(_) => break,
            };
            let ui = match ev {
                wd_core::Event::Task(t) => UiEvent::Task((&t).into()),
                wd_core::Event::TasksChanged => UiEvent::TasksChanged,
                wd_core::Event::SettingsChanged => UiEvent::SettingsChanged,
            };
            if sink.add(ui).is_err() {
                break;
            }
        }
    });
    Ok(())
}

/// 文本里是否有链接（剪贴板识别用，不发请求）。返回识别到的第一个链接。
#[frb(sync)]
pub fn find_link(text: String) -> Option<String> {
    wd_core::util::extract_urls(&text).into_iter().next()
}

/// 链接属于哪个平台的显示名（剪贴板识别时提示用）；不是已知平台返回 None
#[frb(sync)]
pub fn platform_of(url: String) -> Option<String> {
    let u = url::Url::parse(&url).ok()?;
    let p = wd_core::extractors::detect(&u);
    (p != wd_core::Platform::Generic).then(|| p.display_name().to_string())
}

/// 解析链接或分享文案
pub async fn extract(input: String) -> anyhow::Result<UiMediaInfo> {
    run(async move {
        let info = core()?.extract(&input).await?;
        let key = remember(info.clone());
        Ok(UiMediaInfo::from_info(key, &info))
    })
    .await
}

/// 下载解析结果里选中的条目，返回新任务 id
pub async fn enqueue(key: u64, picks: Vec<UiPick>) -> anyhow::Result<Vec<u64>> {
    run(async move {
        let info = recall(key).ok_or_else(|| anyhow::anyhow!("解析结果已失效，请重新解析"))?;
        let picks: Vec<wd_core::Selection> = picks
            .iter()
            .map(|p| wd_core::Selection {
                item: p.item as usize,
                variant: p.variant as usize,
            })
            .collect();
        core()?.enqueue(&info, &picks)
    })
    .await
}

#[frb(sync)]
pub fn tasks() -> anyhow::Result<Vec<UiTask>> {
    Ok(core()?.tasks().iter().map(Into::into).collect())
}

pub async fn cancel_task(id: u64) -> anyhow::Result<()> {
    run(async move {
        core()?.cancel(id);
        Ok(())
    })
    .await
}

pub async fn retry_task(id: u64) -> anyhow::Result<()> {
    run(async move {
        core()?.retry(id);
        Ok(())
    })
    .await
}

pub async fn remove_task(id: u64, delete_file: bool) -> anyhow::Result<()> {
    run(async move {
        core()?.remove(id, delete_file);
        Ok(())
    })
    .await
}

pub async fn clear_finished() -> anyhow::Result<()> {
    run(async move {
        core()?.clear_finished();
        Ok(())
    })
    .await
}

#[frb(sync)]
pub fn settings() -> anyhow::Result<UiSettings> {
    Ok(core()?.settings().into())
}

pub async fn update_settings(s: UiSettings) -> anyhow::Result<()> {
    run(async move { core()?.update_settings(s.into()) }).await
}

#[frb(sync)]
pub fn environment() -> anyhow::Result<UiEnv> {
    let c = core()?;
    Ok(UiEnv {
        version: env!("CARGO_PKG_VERSION").into(),
        data_dir: c.data_dir().to_string_lossy().into_owned(),
        browser_path: c.browser_executable().map(|p| p.to_string_lossy().into_owned()),
        ytdlp_path: c.ytdlp_path().map(|p| p.to_string_lossy().into_owned()),
    })
}

/// 用系统默认程序打开文件或目录
pub fn open_path(path: String) -> anyhow::Result<()> {
    let p = PathBuf::from(&path);
    if !p.exists() {
        anyhow::bail!("文件不存在：{path}");
    }
    open(&p, false)
}

/// 在文件管理器里显示文件（支持的系统上会选中它）
pub fn reveal_path(path: String) -> anyhow::Result<()> {
    let p = PathBuf::from(&path);
    if p.is_file() {
        open(&p, true)
    } else if let Some(dir) = p.parent().filter(|d| d.exists()) {
        open(dir, false)
    } else {
        anyhow::bail!("文件不存在：{path}")
    }
}

fn open(p: &std::path::Path, select: bool) -> anyhow::Result<()> {
    use std::process::Command;
    #[cfg(target_os = "windows")]
    {
        if select {
            Command::new("explorer").arg(format!("/select,{}", p.display())).spawn()?;
        } else {
            Command::new("explorer").arg(p).spawn()?;
        }
    }
    #[cfg(target_os = "macos")]
    {
        let mut c = Command::new("open");
        if select {
            c.arg("-R");
        }
        c.arg(p).spawn()?;
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        // 选中文件：优先走文件管理器的 D-Bus 接口（Nautilus、Dolphin 等都支持），失败再打开所在目录
        if select {
            let uri = format!("file://{}", p.display());
            let ok = Command::new("dbus-send")
                .args([
                    "--session",
                    "--dest=org.freedesktop.FileManager1",
                    "--type=method_call",
                    "/org/freedesktop/FileManager1",
                    "org.freedesktop.FileManager1.ShowItems",
                    &format!("array:string:{uri}"),
                    "string:",
                ])
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
            if ok {
                return Ok(());
            }
            let dir = p.parent().unwrap_or(p);
            Command::new("xdg-open").arg(dir).spawn()?;
        } else {
            Command::new("xdg-open").arg(p).spawn()?;
        }
    }
    Ok(())
}

/// 退出前调用：取消下载、关闭解析用的浏览器
pub async fn shutdown() -> anyhow::Result<()> {
    run(async move {
        if let Ok(c) = core() {
            c.shutdown().await;
        }
        Ok(())
    })
    .await
}
