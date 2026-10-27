//! Instagram：未登录的公开 GraphQL 现在直接 403。浏览器打开帖子页后，
//! 页面 HTML 里 `<script type="application/json">` 内嵌了帖子数据（`video_versions` / `image_versions2`），
//! 按 shortcode 找到那个对象即可。

use std::collections::HashSet;
use std::sync::OnceLock;
use std::time::Duration;

use anyhow::{Result, anyhow, bail};
use regex::Regex;
use serde_json::Value;
use url::Url;

use super::Ctx;
use crate::browser::CaptureSpec;
use crate::model::*;
use crate::util::*;

const REFERER: &str = "https://www.instagram.com/";

fn shortcode(url: &Url) -> Option<String> {
    static R: OnceLock<Regex> = OnceLock::new();
    let r = R.get_or_init(|| Regex::new(r"/(?:p|reel|reels|tv)/([A-Za-z0-9_-]{5,})").unwrap());
    r.captures(url.path()).map(|c| c[1].to_string())
}

pub async fn extract(ctx: &Ctx, url: &Url) -> Result<MediaInfo> {
    let code = shortcode(url).ok_or_else(|| anyhow!("没能从链接里找到 Instagram 帖子编号：{url}"))?;
    let page = format!("https://www.instagram.com/p/{code}/");
    let caps = ctx
        .browser
        .capture(CaptureSpec {
            url: &page,
            patterns: vec![],
            document: true,
            media: false,
            done: Box::new(|c| c.resource_type == "Document"),
            timeout: Duration::from_secs(25),
        })
        .await?;
    let html = caps
        .iter()
        .find(|c| c.resource_type == "Document")
        .map(|c| c.body.as_str())
        .ok_or_else(|| anyhow!("Instagram 页面没有打开"))?;

    let media = find_media(html, &code).ok_or_else(|| {
        if html.contains("accounts/login") && !html.contains("image_versions2") {
            anyhow!("Instagram 要求登录才能查看这条帖子")
        } else {
            anyhow!("没在 Instagram 页面里找到帖子数据")
        }
    })?;

    let mut items = Vec::new();
    let children = jarr(&media, "carousel_media");
    if children.is_empty() {
        items.extend(item_from(&media));
    } else {
        for c in children {
            items.extend(item_from(c));
        }
    }
    if items.is_empty() {
        bail!("帖子里没有视频或图片");
    }
    let caption = jstr(&media, "caption.text").unwrap_or_default();
    let title = short_title(&caption);
    Ok(MediaInfo {
        platform: Platform::Instagram,
        id: code.clone(),
        url: page,
        title: if title.is_empty() { format!("Instagram {code}") } else { title },
        author: jstr(&media, "user.username").or_else(|| jstr(&media, "owner.username")),
        cover: first_candidate(&media),
        duration_ms: jget(&media, "video_duration").and_then(Value::as_f64).map(|s| (s * 1000.0) as u64),
        items,
    })
}

fn find_media(html: &str, code: &str) -> Option<Value> {
    for block in script_blocks(html) {
        if !block.contains(code) || !(block.contains("video_versions") || block.contains("image_versions2")) {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(block.trim()) else { continue };
        let found = find_object(&v, &|m| {
            m.get("code").and_then(Value::as_str) == Some(code)
                && (m.contains_key("video_versions") || m.contains_key("image_versions2") || m.contains_key("carousel_media"))
        });
        if let Some(f) = found {
            return Some(f.clone());
        }
    }
    None
}

fn first_candidate(m: &Value) -> Option<String> {
    jstr(m, "image_versions2.candidates.0.url")
        .or_else(|| jstr(m, "carousel_media.0.image_versions2.candidates.0.url"))
}

fn item_from(m: &Value) -> Option<MediaItem> {
    let thumb = first_candidate(m);
    let vids = jarr(m, "video_versions");
    if !vids.is_empty() {
        // video_versions 只有 type + url（101 画质最高），尺寸取帖子的原始宽高，其余地址作备用
        let urls: Vec<String> = vids.iter().filter_map(|v| jstr(v, "url")).collect();
        let first = urls.first()?.clone();
        let w = ju64(m, "original_width").or_else(|| ju64(vids.first()?, "width")).map(|x| x as u32);
        let h = ju64(m, "original_height").or_else(|| ju64(vids.first()?, "height")).map(|x| x as u32);
        let mut vv = Variant::new(quality_label(w, h, None, None), first.clone(), "mp4").dims(w, h);
        vv.backup_urls = urls.into_iter().filter(|u| *u != first).collect::<HashSet<_>>().into_iter().collect();
        vv.headers.push(("Referer".into(), REFERER.into()));
        return Some(MediaItem {
            kind: MediaKind::Video,
            thumbnail: thumb,
            variants: vec![vv],
        });
    }
    let c = jarr(m, "image_versions2.candidates").first()?;
    let u = jstr(c, "url")?;
    let mut vv = Variant::new("原图", u.clone(), ext_from_url(&u, "jpg"))
        .dims(ju64(c, "width").map(|x| x as u32), ju64(c, "height").map(|x| x as u32));
    vv.headers.push(("Referer".into(), REFERER.into()));
    Some(MediaItem {
        kind: MediaKind::Image,
        thumbnail: Some(u),
        variants: vec![vv],
    })
}
