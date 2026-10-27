//! TikTok：作品页 HTML 里的 `__UNIVERSAL_DATA_FOR_REHYDRATION__` 带完整视频信息。
//! 视频 CDN 要求带上打开作品页时下发的 Cookie（tt_chain_token 等），否则 403，
//! 所以每次解析用一个独立 Cookie 罐，把 Cookie 写进下载请求头。

use std::collections::HashSet;
use std::sync::{Arc, OnceLock};

use anyhow::{Result, anyhow, bail};
use regex::Regex;
use reqwest::cookie::CookieStore;
use serde_json::Value;
use url::Url;

use super::{Ctx, build_client};
use crate::model::*;
use crate::util::*;

const REFERER: &str = "https://www.tiktok.com/";

fn video_id(url: &Url) -> Option<String> {
    static R: OnceLock<Regex> = OnceLock::new();
    let r = R.get_or_init(|| Regex::new(r"/(?:video|photo|v)/(\d{8,})").unwrap());
    r.captures(url.path()).map(|c| c[1].to_string())
}

pub async fn extract(_ctx: &Ctx, url: &Url) -> Result<MediaInfo> {
    let id = video_id(url).ok_or_else(|| anyhow!("没能从链接里找到 TikTok 作品 id：{url}"))?;
    let jar = Arc::new(reqwest::cookie::Jar::default());
    let client = build_client(Some(jar.clone()))?;
    // 用户名部分随便填也会被服务端纠正；保留原链接的路径更稳
    let page = if url.path().contains("/video/") || url.path().contains("/photo/") {
        format!("https://www.tiktok.com{}", url.path())
    } else {
        format!("https://www.tiktok.com/@i/video/{id}")
    };
    let html = client
        .get(&page)
        .header("Accept-Language", "en-US,en;q=0.9")
        .send()
        .await?
        .error_for_status()?
        .text()
        .await?;
    let data = script_by_id(&html, "__UNIVERSAL_DATA_FOR_REHYDRATION__")
        .ok_or_else(|| anyhow!("TikTok 页面结构变了，没找到作品数据"))?;
    // 键名本身带点（"webapp.video-detail"），不能用按点分段的 jget
    let detail = data
        .get("__DEFAULT_SCOPE__")
        .and_then(|d| d.get("webapp.video-detail"))
        .ok_or_else(|| anyhow!("TikTok 没有返回作品数据"))?;
    let status = ju64(detail, "statusCode").unwrap_or(0);
    if status != 0 {
        bail!(
            "TikTok 作品不可用（{}）",
            jstr(detail, "statusMsg").unwrap_or_else(|| status.to_string())
        );
    }
    let it = jget(detail, "itemInfo.itemStruct").ok_or_else(|| anyhow!("TikTok 没有返回作品数据"))?;

    let cookie = jar
        .cookies(&Url::parse("https://www.tiktok.com/").unwrap())
        .and_then(|h| h.to_str().ok().map(str::to_string))
        .unwrap_or_default();
    let headers = vec![("Referer".to_string(), REFERER.to_string()), ("Cookie".to_string(), cookie)];

    let mut items = Vec::new();
    let images = jarr(it, "imagePost.images");
    if !images.is_empty() {
        for img in images {
            let urls = str_list(img, "imageURL.urlList");
            let Some(u) = urls.first().cloned() else { continue };
            let mut v = Variant::new("原图", u.clone(), ext_from_url(&u, "jpg"))
                .dims(ju64(img, "imageWidth").map(|x| x as u32), ju64(img, "imageHeight").map(|x| x as u32));
            v.backup_urls = urls.into_iter().skip(1).collect();
            v.headers = headers.clone();
            items.push(MediaItem {
                kind: MediaKind::Image,
                thumbnail: Some(u),
                variants: vec![v],
            });
        }
    } else {
        let mut variants = Vec::new();
        let mut seen = HashSet::new();
        for b in jarr(it, "video.bitrateInfo") {
            let urls = str_list(b, "PlayAddr.UrlList");
            let Some(u) = urls.first().cloned() else { continue };
            let w = ju64(b, "PlayAddr.Width").map(|x| x as u32);
            let h = ju64(b, "PlayAddr.Height").map(|x| x as u32);
            let codec = jstr(b, "CodecType").unwrap_or_default();
            let h265 = codec.contains("265") || codec.contains("hvc") || codec.contains("hev");
            if !seen.insert((w.unwrap_or(0).min(h.unwrap_or(0)), h265)) {
                continue;
            }
            let br = ju64(b, "Bitrate");
            let mut v = Variant::new(quality_label(w, h, Some(&codec), None), u, "mp4").dims(w, h);
            v.backup_urls = urls.into_iter().skip(1).collect();
            v.bitrate = br;
            v.size = ju64(b, "PlayAddr.DataSize");
            v.codec = Some(if h265 { "h265" } else { "h264" }.into());
            v.headers = headers.clone();
            variants.push(v);
        }
        if variants.is_empty() {
            if let Some(u) = jstr(it, "video.playAddr").or_else(|| jstr(it, "video.downloadAddr")) {
                let w = ju64(it, "video.width").map(|x| x as u32);
                let h = ju64(it, "video.height").map(|x| x as u32);
                let mut v = Variant::new(quality_label(w, h, None, None), u, "mp4").dims(w, h);
                v.headers = headers.clone();
                variants.push(v);
            }
        }
        sort_variants(&mut variants);
        items.push(MediaItem {
            kind: MediaKind::Video,
            thumbnail: jstr(it, "video.cover"),
            variants,
        });
    }
    if let Some(u) = jstr(it, "music.playUrl") {
        items.push(MediaItem {
            kind: MediaKind::Audio,
            thumbnail: jstr(it, "music.coverThumb"),
            variants: vec![{
                let mut v = Variant::new(
                    format!("背景音乐 · {}", jstr(it, "music.title").unwrap_or_default()),
                    u.clone(),
                    ext_from_url(&u, "mp3"),
                );
                v.headers = headers.clone();
                v
            }],
        });
    }

    let desc = jstr(it, "desc").unwrap_or_default();
    let title = short_title(&desc);
    Ok(MediaInfo {
        platform: Platform::Tiktok,
        id: id.clone(),
        url: page,
        title: if title.is_empty() { format!("TikTok {id}") } else { title },
        author: jstr(it, "author.nickname").or_else(|| jstr(it, "author.uniqueId")),
        cover: jstr(it, "video.cover").or_else(|| items.iter().find_map(|i| i.thumbnail.clone())),
        duration_ms: ju64(it, "video.duration").map(|s| s * 1000).filter(|d| *d > 0),
        items,
    })
}

fn script_by_id(html: &str, id: &str) -> Option<Value> {
    let start = html.find(&format!("id=\"{id}\""))?;
    let rest = &html[start..];
    let open = rest.find('>')? + 1;
    let close = rest[open..].find("</script>")?;
    serde_json::from_str(&rest[open..open + close]).ok()
}
