//! FFI 层的全局状态：自建 tokio 运行时 + 内核实例 + 解析结果缓存。不对 Dart 暴露。

use std::collections::HashMap;
use std::future::Future;
use std::sync::{Arc, Mutex, OnceLock};

use wd_core::{Core, MediaInfo};

pub(crate) fn rt() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(4)
            .thread_name("wd-rt")
            .enable_all()
            .build()
            .expect("tokio runtime")
    })
}

/// 在自建运行时里跑异步任务。frb 的执行器不保证是 tokio，内核又依赖 tokio。
pub(crate) async fn run<T, F>(f: F) -> anyhow::Result<T>
where
    T: Send + 'static,
    F: Future<Output = anyhow::Result<T>> + Send + 'static,
{
    rt().spawn(f).await?
}

pub(crate) static CORE: OnceLock<Arc<Core>> = OnceLock::new();

pub(crate) fn core() -> anyhow::Result<Arc<Core>> {
    CORE.get()
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("core not initialized; call bootstrap() first"))
}

/// 解析结果按 id 暂存，Dart 侧选好要下载的条目后只传 id 和选择
static RESULTS: OnceLock<Mutex<HashMap<u64, MediaInfo>>> = OnceLock::new();

pub(crate) fn remember(info: MediaInfo) -> u64 {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
    let id = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let mut m = RESULTS.get_or_init(Default::default).lock().unwrap();
    // 只留最近的几十个
    if m.len() > 50 {
        let min = *m.keys().min().unwrap();
        m.remove(&min);
    }
    m.insert(id, info);
    id
}

pub(crate) fn recall(id: u64) -> Option<MediaInfo> {
    RESULTS.get_or_init(Default::default).lock().unwrap().get(&id).cloned()
}
