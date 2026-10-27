//! 浏览器后端：通过 DevTools 协议驱动本机已装的 Chromium 系浏览器（Chrome / Edge / Chromium / Brave）。
//!
//! 有的平台（抖音、Instagram、小红书）的接口要页面脚本现算签名和指纹，纯 HTTP 拿不到数据。
//! 这里让真正的浏览器打开作品页，页面自己完成所有校验，我们只在网络层取它收到的响应原文。
//! Windows 自带 Edge，所以开箱即用；Linux / macOS 上需要装有任意一款 Chromium 系浏览器。
//!
//! 实测：WebKit 系内核（Linux 的 WebKitGTK）打开抖音时详情接口只返回空包，Chromium 内核正常，
//! 所以这里只找 Chromium 系浏览器，不用系统 WebView。

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow, bail};
use base64::Engine;
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::process::{Child, Command};
use tokio::sync::{Mutex, mpsc, oneshot};
use tokio_tungstenite::tungstenite::Message;

/// 一次抓取到的响应
#[derive(Debug, Clone)]
pub struct Captured {
    pub url: String,
    pub status: u16,
    pub mime: String,
    /// "Document" / "XHR" / "Fetch" / "Media" …
    pub resource_type: String,
    pub body: String,
}

/// 抓取规则：哪些响应要取正文、什么时候算拿够了
pub struct CaptureSpec<'a> {
    pub url: &'a str,
    /// 响应地址包含其中任一片段就取正文
    pub patterns: Vec<String>,
    /// 也取主文档（页面 HTML）的正文
    pub document: bool,
    /// 记录页面加载的音视频资源地址（不取正文），通用嗅探用
    pub media: bool,
    /// 拿到满足条件的响应就提前结束
    pub done: Box<dyn Fn(&Captured) -> bool + Send + Sync + 'a>,
    pub timeout: Duration,
}

/// 在常见安装位置里找 Chromium 系浏览器。`WD_BROWSER` 环境变量可以指定。
pub fn find_browser() -> Option<PathBuf> {
    if let Ok(p) = std::env::var("WD_BROWSER") {
        let p = PathBuf::from(p);
        if p.exists() {
            return Some(p);
        }
    }
    candidates().into_iter().find(|p| p.is_file())
}

fn candidates() -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = Vec::new();
    #[cfg(target_os = "windows")]
    {
        for var in ["ProgramFiles", "ProgramFiles(x86)", "LocalAppData"] {
            if let Ok(base) = std::env::var(var) {
                let b = PathBuf::from(base);
                v.push(b.join(r"Google\Chrome\Application\chrome.exe"));
                v.push(b.join(r"Microsoft\Edge\Application\msedge.exe"));
                v.push(b.join(r"BraveSoftware\Brave-Browser\Application\brave.exe"));
                v.push(b.join(r"Chromium\Application\chrome.exe"));
            }
        }
    }
    #[cfg(target_os = "macos")]
    {
        for app in [
            "Google Chrome.app/Contents/MacOS/Google Chrome",
            "Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
            "Chromium.app/Contents/MacOS/Chromium",
            "Brave Browser.app/Contents/MacOS/Brave Browser",
        ] {
            v.push(PathBuf::from("/Applications").join(app));
            if let Ok(h) = std::env::var("HOME") {
                v.push(PathBuf::from(h).join("Applications").join(app));
            }
        }
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        let names = [
            "google-chrome",
            "google-chrome-stable",
            "chromium",
            "chromium-browser",
            "microsoft-edge",
            "microsoft-edge-stable",
            "brave-browser",
        ];
        let path = std::env::var("PATH").unwrap_or_default();
        for dir in path.split(':').filter(|d| !d.is_empty()) {
            for n in names {
                v.push(Path::new(dir).join(n));
            }
        }
        v.push("/snap/bin/chromium".into());
        v.push("/var/lib/flatpak/exports/bin/com.google.Chrome".into());
        v.push("/var/lib/flatpak/exports/bin/org.chromium.Chromium".into());
    }
    v
}

type Pending = Arc<Mutex<HashMap<u64, oneshot::Sender<Result<Value>>>>>;

/// 一个已启动的浏览器进程 + 到它的 DevTools 连接
struct Instance {
    /// 接管已在运行的浏览器时为 None
    child: Option<Child>,
    tx: mpsc::UnboundedSender<Message>,
    pending: Pending,
    /// 按 sessionId 分发的事件订阅
    events: Arc<Mutex<HashMap<String, mpsc::UnboundedSender<Value>>>>,
    next_id: AtomicU64,
    last_used: std::sync::Mutex<Instant>,
}

impl Instance {
    async fn call(&self, session: Option<&str>, method: &str, params: Value) -> Result<Value> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let mut msg = json!({"id": id, "method": method, "params": params});
        if let Some(s) = session {
            msg["sessionId"] = json!(s);
        }
        let (otx, orx) = oneshot::channel();
        self.pending.lock().await.insert(id, otx);
        self.tx
            .send(Message::Text(msg.to_string().into()))
            .map_err(|_| anyhow!("浏览器连接已断开"))?;
        match tokio::time::timeout(Duration::from_secs(20), orx).await {
            Ok(Ok(r)) => r,
            Ok(Err(_)) => bail!("浏览器连接已断开"),
            Err(_) => {
                self.pending.lock().await.remove(&id);
                bail!("浏览器响应超时（{method}）")
            }
        }
    }
}

/// 浏览器管理器：按需启动，空闲一段时间后自动关闭，进程退出时一并结束。
pub struct BrowserPool {
    profile_dir: PathBuf,
    inst: Mutex<Option<Arc<Instance>>>,
    headless: std::sync::atomic::AtomicBool,
    executable: std::sync::Mutex<Option<PathBuf>>,
}

impl BrowserPool {
    pub fn new(profile_dir: PathBuf) -> Arc<Self> {
        let pool = Arc::new(Self {
            profile_dir,
            inst: Mutex::new(None),
            headless: true.into(),
            executable: std::sync::Mutex::new(None),
        });
        // 空闲 3 分钟关掉浏览器，省内存
        let weak = Arc::downgrade(&pool);
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(30)).await;
                let Some(p) = weak.upgrade() else { break };
                let mut g = p.inst.lock().await;
                let idle = g
                    .as_ref()
                    .map(|i| i.last_used.lock().unwrap().elapsed() > Duration::from_secs(180))
                    .unwrap_or(false);
                if idle {
                    if let Some(i) = g.take() {
                        shutdown(i).await;
                    }
                }
            }
        });
        pool
    }

    /// 关掉无头模式时浏览器窗口可见，遇到验证码可以手动处理
    pub async fn set_headless(&self, headless: bool) {
        if self.headless.swap(headless, Ordering::Relaxed) != headless {
            if let Some(i) = self.inst.lock().await.take() {
                shutdown(i).await;
            }
        }
    }

    pub fn set_executable(&self, path: Option<PathBuf>) {
        *self.executable.lock().unwrap() = path;
    }

    pub fn executable(&self) -> Option<PathBuf> {
        self.executable.lock().unwrap().clone().or_else(find_browser)
    }

    async fn instance(&self) -> Result<Arc<Instance>> {
        let mut g = self.inst.lock().await;
        if let Some(i) = g.as_ref() {
            if !i.tx.is_closed() {
                *i.last_used.lock().unwrap() = Instant::now();
                return Ok(i.clone());
            }
        }
        let exe = self.executable().ok_or_else(|| {
            anyhow!("没有找到 Chrome / Edge / Chromium 浏览器。抖音、小红书、Instagram 需要借助本机浏览器解析，请先安装其中一款")
        })?;
        let i = Arc::new(launch(&exe, &self.profile_dir, self.headless.load(Ordering::Relaxed)).await?);
        *g = Some(i.clone());
        Ok(i)
    }

    /// 打开页面并按规则抓取响应。返回所有取到正文的响应（按到达顺序）。
    pub async fn capture(&self, spec: CaptureSpec<'_>) -> Result<Vec<Captured>> {
        let inst = self.instance().await?;
        let r = capture_on(&inst, &spec).await;
        *inst.last_used.lock().unwrap() = Instant::now();
        if r.is_err() && inst.tx.is_closed() {
            self.inst.lock().await.take();
        }
        r
    }

    pub async fn close(&self) {
        if let Some(i) = self.inst.lock().await.take() {
            shutdown(i).await;
        }
    }
}

async fn shutdown(i: Arc<Instance>) {
    let _ = i.call(None, "Browser.close", json!({})).await;
    if let Ok(inst) = Arc::try_unwrap(i) {
        if let Some(mut child) = inst.child {
            let _ = tokio::time::timeout(Duration::from_secs(3), child.wait()).await;
            let _ = child.kill().await;
        }
    }
}

fn read_port_file(profile: &Path) -> Option<String> {
    let s = std::fs::read_to_string(profile.join("DevToolsActivePort")).ok()?;
    let mut lines = s.lines();
    let (port, path) = (lines.next()?, lines.next()?);
    Some(format!("ws://127.0.0.1:{}{}", port.trim(), path.trim()))
}

async fn launch(exe: &Path, profile: &Path, headless: bool) -> Result<Instance> {
    std::fs::create_dir_all(profile).ok();
    // 上次退出（或崩溃）时留下的浏览器还在跑：直接接管
    if let Some(ws) = read_port_file(profile) {
        if let Ok(inst) = connect(&ws, None).await {
            tracing::info!("reusing running browser at {ws}");
            return Ok(inst);
        }
    }
    match spawn_and_wait(exe, profile, headless).await {
        Ok((child, ws)) => connect(&ws, Some(child)).await,
        Err(e) => {
            // 同一档案被一个连不上的旧进程占着（新进程会把请求转交给它然后退出）：结束旧进程再试一次
            if !kill_profile_owner(profile) {
                return Err(e);
            }
            tokio::time::sleep(Duration::from_millis(800)).await;
            let (child, ws) = spawn_and_wait(exe, profile, headless).await?;
            connect(&ws, Some(child)).await
        }
    }
}

/// Linux / macOS：读 SingletonLock（指向 "主机名-进程号"），结束那个进程
fn kill_profile_owner(profile: &Path) -> bool {
    #[cfg(unix)]
    {
        let Ok(target) = std::fs::read_link(profile.join("SingletonLock")) else { return false };
        let Some(pid) = target.to_string_lossy().rsplit('-').next().and_then(|p| p.parse::<i32>().ok()) else {
            return false;
        };
        tracing::warn!("killing stale browser {pid} holding the profile");
        return std::process::Command::new("kill").arg(pid.to_string()).status().map(|s| s.success()).unwrap_or(false);
    }
    #[allow(unreachable_code)]
    {
        let _ = profile;
        false
    }
}

async fn spawn_and_wait(exe: &Path, profile: &Path, headless: bool) -> Result<(Child, String)> {
    let port_file = profile.join("DevToolsActivePort");
    let _ = std::fs::remove_file(&port_file);

    let mut cmd = Command::new(exe);
    cmd.arg(format!("--user-data-dir={}", profile.display()))
        .arg("--remote-debugging-port=0")
        .arg("--no-first-run")
        .arg("--no-default-browser-check")
        .arg("--disable-background-networking")
        .arg("--disable-sync")
        .arg("--mute-audio")
        .arg("--autoplay-policy=user-gesture-required")
        .arg("--window-size=1280,860");
    if headless {
        cmd.arg("--headless=new");
    }
    cmd.arg("about:blank")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true);
    #[cfg(windows)]
    {
        // 不弹控制台窗口
        cmd.creation_flags(0x0800_0000);
    }
    #[cfg(target_os = "linux")]
    unsafe {
        // 主程序意外退出时浏览器跟着退出，不留下占着档案的孤儿进程
        cmd.pre_exec(|| {
            libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM);
            Ok(())
        });
    }
    let child = cmd.spawn().with_context(|| format!("启动浏览器失败：{}", exe.display()))?;

    // 浏览器启动后把调试端口写进 DevToolsActivePort（第一行端口，第二行 ws 路径）
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        if let Some(ws) = read_port_file(profile) {
            return Ok((child, ws));
        }
        if Instant::now() > deadline {
            bail!("浏览器没有在 15 秒内就绪（{}）", exe.display());
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

async fn connect(ws_url: &str, child: Option<Child>) -> Result<Instance> {
    let (ws, _) = tokio::time::timeout(Duration::from_secs(5), tokio_tungstenite::connect_async(ws_url))
        .await
        .map_err(|_| anyhow!("连接浏览器调试端口超时"))?
        .context("连接浏览器调试端口失败")?;
    let (mut sink, mut stream) = ws.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<Message>();
    tokio::spawn(async move {
        while let Some(m) = rx.recv().await {
            if sink.send(m).await.is_err() {
                break;
            }
        }
    });
    let pending: Pending = Arc::default();
    let events: Arc<Mutex<HashMap<String, mpsc::UnboundedSender<Value>>>> = Arc::default();
    {
        let pending = pending.clone();
        let events = events.clone();
        tokio::spawn(async move {
            while let Some(Ok(m)) = stream.next().await {
                let Message::Text(t) = m else { continue };
                let Ok(v) = serde_json::from_str::<Value>(&t) else { continue };
                if let Some(id) = v.get("id").and_then(Value::as_u64) {
                    if let Some(s) = pending.lock().await.remove(&id) {
                        let r = match v.get("error") {
                            Some(e) => Err(anyhow!("{}", e.get("message").and_then(Value::as_str).unwrap_or("CDP error"))),
                            None => Ok(v.get("result").cloned().unwrap_or(Value::Null)),
                        };
                        let _ = s.send(r);
                    }
                } else if let Some(sid) = v.get("sessionId").and_then(Value::as_str) {
                    if let Some(s) = events.lock().await.get(sid) {
                        let _ = s.send(v);
                    }
                }
            }
            // 连接断了：让所有等待中的调用失败
            for (_, s) in pending.lock().await.drain() {
                let _ = s.send(Err(anyhow!("浏览器连接已断开")));
            }
        });
    }
    Ok(Instance {
        child,
        tx,
        pending,
        events,
        next_id: AtomicU64::new(1),
        last_used: std::sync::Mutex::new(Instant::now()),
    })
}

async fn capture_on(inst: &Instance, spec: &CaptureSpec<'_>) -> Result<Vec<Captured>> {
    let target = inst.call(None, "Target.createTarget", json!({"url": "about:blank"})).await?;
    let target_id = target["targetId"].as_str().unwrap_or_default().to_string();
    let attach = inst
        .call(None, "Target.attachToTarget", json!({"targetId": target_id, "flatten": true}))
        .await?;
    let sid = attach["sessionId"].as_str().unwrap_or_default().to_string();
    let (etx, mut erx) = mpsc::unbounded_channel();
    inst.events.lock().await.insert(sid.clone(), etx);

    let result = async {
        inst.call(Some(&sid), "Network.enable", json!({"maxResourceBufferSize": 32 << 20}))
            .await?;
        inst.call(Some(&sid), "Page.enable", json!({})).await?;
        inst.call(Some(&sid), "Page.navigate", json!({"url": spec.url})).await?;

        // requestId -> (url, status, mime, type)
        let mut wanted: HashMap<String, (String, u16, String, String)> = HashMap::new();
        let mut out = Vec::new();
        let deadline = Instant::now() + spec.timeout;
        let mut main_doc_seen = false;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break;
            }
            let Ok(Some(ev)) = tokio::time::timeout(left, erx.recv()).await else { break };
            let method = ev["method"].as_str().unwrap_or_default();
            let p = &ev["params"];
            match method {
                "Network.responseReceived" => {
                    let rtype = p["type"].as_str().unwrap_or_default().to_string();
                    let url = p["response"]["url"].as_str().unwrap_or_default().to_string();
                    let mime = p["response"]["mimeType"].as_str().unwrap_or_default();
                    if spec.media
                        && (rtype == "Media" || mime.starts_with("video/") || mime == "application/vnd.apple.mpegurl")
                        && url.starts_with("http")
                    {
                        out.push(Captured {
                            url: url.clone(),
                            status: p["response"]["status"].as_u64().unwrap_or(0) as u16,
                            mime: mime.to_string(),
                            resource_type: rtype.clone(),
                            body: String::new(),
                        });
                        continue;
                    }
                    let is_doc = spec.document && rtype == "Document" && !main_doc_seen;
                    if is_doc {
                        main_doc_seen = true;
                    }
                    if is_doc || spec.patterns.iter().any(|pat| url.contains(pat.as_str())) {
                        wanted.insert(
                            p["requestId"].as_str().unwrap_or_default().to_string(),
                            (
                                url,
                                p["response"]["status"].as_u64().unwrap_or(0) as u16,
                                p["response"]["mimeType"].as_str().unwrap_or_default().to_string(),
                                rtype,
                            ),
                        );
                    }
                }
                "Network.loadingFinished" => {
                    let rid = p["requestId"].as_str().unwrap_or_default();
                    if let Some((url, status, mime, rtype)) = wanted.remove(rid) {
                        let body = match inst
                            .call(Some(&sid), "Network.getResponseBody", json!({"requestId": rid}))
                            .await
                        {
                            Ok(b) => {
                                let raw = b["body"].as_str().unwrap_or_default();
                                if b["base64Encoded"].as_bool().unwrap_or(false) {
                                    base64::engine::general_purpose::STANDARD
                                        .decode(raw)
                                        .map(|d| String::from_utf8_lossy(&d).into_owned())
                                        .unwrap_or_default()
                                } else {
                                    raw.to_string()
                                }
                            }
                            Err(_) => String::new(),
                        };
                        let c = Captured {
                            url,
                            status,
                            mime,
                            resource_type: rtype,
                            body,
                        };
                        let finished = (spec.done)(&c);
                        out.push(c);
                        if finished {
                            break;
                        }
                    }
                }
                _ => {}
            }
        }
        Ok::<_, anyhow::Error>(out)
    }
    .await;

    inst.events.lock().await.remove(&sid);
    let _ = inst.call(None, "Target.closeTarget", json!({"targetId": target_id})).await;
    result
}
