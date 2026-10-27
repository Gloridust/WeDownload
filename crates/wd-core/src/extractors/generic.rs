//! 通用兜底：
//! 1. 链接本身就是视频 / 图片文件 → 直接下载；
//! 2. 本机装有 yt-dlp → 借它解析上千个站点（只取音视频合一的直链格式）；
//! 3. 否则用浏览器打开网页，嗅探页面加载的视频资源和 og:video。

use std::time::Duration;

use anyhow::{Result, bail};
use serde_json::Value;
use url::Url;

use super::Ctx;
use crate::browser::CaptureSpec;
use crate::model::*;
use crate::util::*;

const MEDIA_EXTS: &[&str] = &["mp4", "mov", "webm", "m4v", "mkv", "flv", "mp3", "m4a", "jpg", "jpeg", "png", "webp", "gif"];

pub async fn extract(ctx: &Ctx, url: &Url) -> Result<MediaInfo> {
    if let Some(info) = direct_file(ctx, url).await {
        return Ok(info);
    }
    if let Some(info) = via_ytdlp(url).await {
        return Ok(info);
    }
    sniff(ctx, url).await
}

fn base_info(url: &Url, title: String) -> MediaInfo {
    MediaInfo {
        platform: Platform::Generic,
        id: url.path().rsplit('/').find(|s| !s.is_empty()).unwrap_or("media").to_string(),
        url: url.to_string(),
        title,
        author: url.host_str().map(str::to_string),
        cover: None,
        duration_ms: None,
        items: Vec::new(),
    }
}

async fn direct_file(ctx: &Ctx, url: &Url) -> Option<MediaInfo> {
    let ext = ext_from_url(url.as_str(), "");
    let by_ext = MEDIA_EXTS.contains(&ext.as_str());
    // 没有扩展名时看响应类型
    let ctype = if by_ext {
        String::new()
    } else {
        let r = ctx.http.head(url.clone()).send().await.ok()?;
        r.headers().get("content-type")?.to_str().ok()?.to_string()
    };
    let kind = if by_ext {
        match ext.as_str() {
            "jpg" | "jpeg" | "png" | "webp" | "gif" => MediaKind::Image,
            "mp3" | "m4a" => MediaKind::Audio,
            _ => MediaKind::Video,
        }
    } else if ctype.starts_with("video/") {
        MediaKind::Video
    } else if ctype.starts_with("image/") {
        MediaKind::Image
    } else if ctype.starts_with("audio/") {
        MediaKind::Audio
    } else {
        return None;
    };
    let ext = if ext.is_empty() {
        ctype.split('/').nth(1).unwrap_or("bin").split(';').next().unwrap_or("bin").to_string()
    } else {
        ext
    };
    let name = url.path().rsplit('/').next().unwrap_or("file").to_string();
    let mut info = base_info(url, name.rsplit_once('.').map(|(a, _)| a.to_string()).unwrap_or(name));
    info.items.push(MediaItem {
        kind,
        thumbnail: (kind == MediaKind::Image).then(|| url.to_string()),
        variants: vec![Variant::new("原文件", url.as_str(), ext)],
    });
    Some(info)
}

pub fn ytdlp_path() -> Option<std::path::PathBuf> {
    let exe = if cfg!(windows) { "yt-dlp.exe" } else { "yt-dlp" };
    let sep = if cfg!(windows) { ';' } else { ':' };
    std::env::var("PATH")
        .ok()?
        .split(sep)
        .map(|d| std::path::Path::new(d).join(exe))
        .find(|p| p.is_file())
}

async fn via_ytdlp(url: &Url) -> Option<MediaInfo> {
    let exe = ytdlp_path()?;
    let mut cmd = tokio::process::Command::new(exe);
    cmd.args(["-J", "--no-playlist", "--no-warnings", url.as_str()]).kill_on_drop(true);
    #[cfg(windows)]
    cmd.creation_flags(0x0800_0000);
    let out = tokio::time::timeout(Duration::from_secs(60), cmd.output()).await.ok()?.ok()?;
    if !out.status.success() {
        return None;
    }
    let v: Value = serde_json::from_slice(&out.stdout).ok()?;
    let mut variants = Vec::new();
    for f in jarr(&v, "formats") {
        let proto = jstr(f, "protocol").unwrap_or_default();
        if !proto.starts_with("http") || proto.contains("dash") {
            continue;
        }
        // 只要音视频合一的格式（单独的视频流需要合并，MVP 不处理）
        let vc = jstr(f, "vcodec").unwrap_or_default();
        let ac = jstr(f, "acodec").unwrap_or_default();
        if vc == "none" || ac == "none" {
            continue;
        }
        let Some(u) = jstr(f, "url") else { continue };
        let w = ju64(f, "width").map(|x| x as u32);
        let h = ju64(f, "height").map(|x| x as u32);
        let br = jget(f, "tbr").and_then(Value::as_f64).map(|k| (k * 1000.0) as u64);
        let mut var = Variant::new(quality_label(w, h, Some(&vc), br), u, jstr(f, "ext").unwrap_or("mp4".into())).dims(w, h);
        var.bitrate = br;
        var.size = ju64(f, "filesize").or_else(|| ju64(f, "filesize_approx"));
        if let Some(h) = jget(f, "http_headers").and_then(Value::as_object) {
            var.headers = h.iter().filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_string()))).collect();
        }
        variants.push(var);
    }
    if variants.is_empty() {
        return None;
    }
    sort_variants(&mut variants);
    let mut info = base_info(url, jstr(&v, "title").unwrap_or_else(|| "video".into()));
    info.id = jstr(&v, "id").unwrap_or(info.id);
    info.author = jstr(&v, "uploader").or(info.author);
    info.cover = jstr(&v, "thumbnail");
    info.duration_ms = jget(&v, "duration").and_then(Value::as_f64).map(|s| (s * 1000.0) as u64);
    info.items.push(MediaItem {
        kind: MediaKind::Video,
        thumbnail: info.cover.clone(),
        variants,
    });
    Some(info)
}

async fn sniff(ctx: &Ctx, url: &Url) -> Result<MediaInfo> {
    let caps = ctx
        .browser
        .capture(CaptureSpec {
            url: url.as_str(),
            patterns: vec![],
            document: true,
            media: true,
            done: Box::new(|_| false),
            timeout: Duration::from_secs(15),
        })
        .await?;
    let html = caps.iter().find(|c| c.resource_type == "Document").map(|c| c.body.clone()).unwrap_or_default();
    let title = meta_content(&html, "og:title")
        .or_else(|| {
            let i = html.find("<title>")? + 7;
            let j = html[i..].find("</title>")?;
            Some(html_unescape(html[i..i + j].trim()))
        })
        .unwrap_or_else(|| url.host_str().unwrap_or("video").to_string());
    let mut info = base_info(url, title);
    info.cover = meta_content(&html, "og:image");
    let referer = format!("{}://{}/", url.scheme(), url.host_str().unwrap_or(""));
    let mut urls: Vec<String> = Vec::new();
    for key in ["og:video:secure_url", "og:video:url", "og:video"] {
        if let Some(u) = meta_content(&html, key) {
            urls.push(u);
        }
    }
    for c in &caps {
        if c.resource_type != "Document" && !c.mime.contains("mpegurl") {
            urls.push(c.url.clone());
        }
    }
    let mut seen = Vec::new();
    for u in urls {
        // 分段请求的同一文件：去掉 range 参数后去重
        let key = u.split(['?', '#']).next().unwrap_or(&u).to_string();
        if seen.contains(&key) || u.starts_with("blob:") {
            continue;
        }
        seen.push(key);
        let mut v = Variant::new("页面视频", u.clone(), ext_from_url(&u, "mp4"));
        v.headers.push(("Referer".into(), referer.clone()));
        info.items.push(MediaItem {
            kind: MediaKind::Video,
            thumbnail: info.cover.clone(),
            variants: vec![v],
        });
    }
    if info.items.is_empty() {
        bail!("暂不支持这个网站，也没有在页面里嗅探到视频");
    }
    Ok(info)
}
