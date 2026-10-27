//! 下载器：服务器支持断点续传且文件较大时分 4 段并行下载，否则单连接流式下载。
//! 先写 `<文件>.part`，完成后改名。主地址失败时依次尝试备用地址。

use std::io::SeekFrom;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

use anyhow::{Result, anyhow, bail};
use futures_util::StreamExt;
use reqwest::header::{CONTENT_RANGE, RANGE};
use tokio::io::{AsyncSeekExt, AsyncWriteExt};

use crate::model::Variant;

const PARALLEL_MIN: u64 = 4 << 20;
const SEGMENTS: u64 = 4;

/// 下载进度（共享计数器，由调用方定时读取）
#[derive(Default)]
pub struct Progress {
    pub downloaded: AtomicU64,
    pub total: AtomicU64,
}

pub fn part_path(dest: &Path) -> PathBuf {
    let mut s = dest.as_os_str().to_owned();
    s.push(".part");
    PathBuf::from(s)
}

pub async fn download(
    client: &reqwest::Client,
    v: &Variant,
    dest: &Path,
    progress: Arc<Progress>,
    cancel: Arc<AtomicBool>,
) -> Result<u64> {
    let mut errors = Vec::new();
    for url in std::iter::once(&v.url).chain(v.backup_urls.iter()) {
        if cancel.load(Ordering::Relaxed) {
            bail!("已取消");
        }
        progress.downloaded.store(0, Ordering::Relaxed);
        match download_url(client, url, &v.headers, dest, &progress, &cancel).await {
            Ok(n) => return Ok(n),
            Err(e) => {
                if cancel.load(Ordering::Relaxed) {
                    bail!("已取消");
                }
                tracing::warn!("download {url} failed: {e:#}");
                errors.push(e);
            }
        }
    }
    let _ = tokio::fs::remove_file(part_path(dest)).await;
    Err(errors.pop().unwrap_or_else(|| anyhow!("没有可用的下载地址")))
}

fn request(client: &reqwest::Client, url: &str, headers: &[(String, String)]) -> reqwest::RequestBuilder {
    let mut r = client.get(url);
    for (k, v) in headers {
        if !v.is_empty() {
            r = r.header(k.as_str(), v.as_str());
        }
    }
    r
}

async fn download_url(
    client: &reqwest::Client,
    url: &str,
    headers: &[(String, String)],
    dest: &Path,
    progress: &Arc<Progress>,
    cancel: &Arc<AtomicBool>,
) -> Result<u64> {
    if let Some(dir) = dest.parent() {
        tokio::fs::create_dir_all(dir).await?;
    }
    let part = part_path(dest);

    // 探测：只要第一个字节，看是否支持分段、总大小多少
    let probe = request(client, url, headers).header(RANGE, "bytes=0-0").send().await?;
    let status = probe.status();
    if !status.is_success() {
        bail!("服务器返回 {status}");
    }
    let total = if status.as_u16() == 206 {
        probe
            .headers()
            .get(CONTENT_RANGE)
            .and_then(|h| h.to_str().ok())
            .and_then(|s| s.rsplit('/').next())
            .and_then(|s| s.parse::<u64>().ok())
    } else {
        None
    };
    drop(probe);

    let size = if let Some(total) = total.filter(|t| *t >= PARALLEL_MIN) {
        progress.total.store(total, Ordering::Relaxed);
        parallel(client, url, headers, &part, total, progress, cancel).await?;
        total
    } else {
        single(client, url, headers, &part, progress, cancel).await?
    };
    if size == 0 {
        bail!("下载到的文件是空的");
    }
    tokio::fs::rename(&part, dest).await?;
    Ok(size)
}

async fn single(
    client: &reqwest::Client,
    url: &str,
    headers: &[(String, String)],
    part: &Path,
    progress: &Arc<Progress>,
    cancel: &Arc<AtomicBool>,
) -> Result<u64> {
    let resp = request(client, url, headers).send().await?.error_for_status()?;
    if let Some(len) = resp.content_length() {
        progress.total.store(len, Ordering::Relaxed);
    }
    let mut f = tokio::fs::File::create(part).await?;
    let mut stream = resp.bytes_stream();
    let mut n = 0u64;
    while let Some(chunk) = stream.next().await {
        if cancel.load(Ordering::Relaxed) {
            bail!("已取消");
        }
        let chunk = chunk?;
        f.write_all(&chunk).await?;
        n += chunk.len() as u64;
        progress.downloaded.store(n, Ordering::Relaxed);
    }
    f.flush().await?;
    Ok(n)
}

async fn parallel(
    client: &reqwest::Client,
    url: &str,
    headers: &[(String, String)],
    part: &Path,
    total: u64,
    progress: &Arc<Progress>,
    cancel: &Arc<AtomicBool>,
) -> Result<()> {
    {
        let f = tokio::fs::File::create(part).await?;
        f.set_len(total).await?;
    }
    let seg = total.div_ceil(SEGMENTS);
    let mut tasks = Vec::new();
    for i in 0..SEGMENTS {
        let start = i * seg;
        if start >= total {
            break;
        }
        let end = ((i + 1) * seg).min(total) - 1;
        let client = client.clone();
        let url = url.to_string();
        let headers = headers.to_vec();
        let part = part.to_path_buf();
        let progress = progress.clone();
        let cancel = cancel.clone();
        tasks.push(tokio::spawn(async move {
            let mut pos = start;
            let mut attempt = 0;
            loop {
                match segment(&client, &url, &headers, &part, pos, end, &progress, &cancel).await {
                    Ok(()) => return Ok(()),
                    Err((done_to, e)) => {
                        pos = done_to;
                        attempt += 1;
                        if cancel.load(Ordering::Relaxed) || attempt >= 4 {
                            return Err(e);
                        }
                        tokio::time::sleep(Duration::from_millis(600 * attempt)).await;
                    }
                }
            }
        }));
    }
    for t in tasks {
        t.await.map_err(|e| anyhow!("下载线程异常：{e}"))??;
    }
    Ok(())
}

/// 下载 [pos, end] 写到文件对应位置。失败时返回已写到的位置，便于从断点重试。
#[allow(clippy::too_many_arguments)]
async fn segment(
    client: &reqwest::Client,
    url: &str,
    headers: &[(String, String)],
    part: &Path,
    mut pos: u64,
    end: u64,
    progress: &Arc<Progress>,
    cancel: &Arc<AtomicBool>,
) -> std::result::Result<(), (u64, anyhow::Error)> {
    let fail = |pos: u64, e: anyhow::Error| Err((pos, e));
    let resp = match request(client, url, headers).header(RANGE, format!("bytes={pos}-{end}")).send().await {
        Ok(r) if r.status().as_u16() == 206 => r,
        Ok(r) => return fail(pos, anyhow!("分段请求返回 {}", r.status())),
        Err(e) => return fail(pos, e.into()),
    };
    let mut f = match tokio::fs::OpenOptions::new().write(true).open(part).await {
        Ok(f) => f,
        Err(e) => return fail(pos, e.into()),
    };
    if let Err(e) = f.seek(SeekFrom::Start(pos)).await {
        return fail(pos, e.into());
    }
    let mut stream = resp.bytes_stream();
    while let Some(chunk) = stream.next().await {
        if cancel.load(Ordering::Relaxed) {
            return fail(pos, anyhow!("已取消"));
        }
        let chunk = match chunk {
            Ok(c) => c,
            Err(e) => return fail(pos, e.into()),
        };
        let take = chunk.len().min((end + 1 - pos) as usize);
        if let Err(e) = f.write_all(&chunk[..take]).await {
            return fail(pos, e.into());
        }
        pos += take as u64;
        progress.downloaded.fetch_add(take as u64, Ordering::Relaxed);
        if pos > end {
            break;
        }
    }
    if let Err(e) = f.flush().await {
        return fail(pos, e.into());
    }
    if pos <= end {
        return fail(pos, anyhow!("连接提前断开"));
    }
    Ok(())
}
