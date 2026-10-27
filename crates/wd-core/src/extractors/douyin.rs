//! 抖音：网页接口要页面端签名（a_bogus + uifid），纯 HTTP 拿不到。
//! 借本机 Chromium 系浏览器打开作品页，取页面自己请求的 `/aweme/v1/web/aweme/detail/` 响应。
//! 详情里的 `play_addr` / `bit_rate[].play_addr` 是无水印地址；CDN 不校验 Cookie。

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

const REFERER: &str = "https://www.douyin.com/";

pub fn aweme_id(url: &Url) -> Option<String> {
    static R: OnceLock<Regex> = OnceLock::new();
    let r = R.get_or_init(|| Regex::new(r"/(?:video|note|slides|share/video|share/note|share/slides)/(\d{8,})").unwrap());
    if let Some(c) = r.captures(url.path()) {
        return Some(c[1].to_string());
    }
    url.query_pairs()
        .find(|(k, _)| k == "modal_id" || k == "vid" || k == "aweme_id")
        .map(|(_, v)| v.to_string())
        .filter(|v| v.chars().all(|c| c.is_ascii_digit()))
}

pub async fn extract(ctx: &Ctx, url: &Url) -> Result<MediaInfo> {
    let id = aweme_id(url).ok_or_else(|| anyhow!("没能从链接里找到抖音作品 id：{url}"))?;
    let page = format!("https://www.douyin.com/video/{id}");
    let mut last_err = None;
    // 新的浏览器档案头几次请求常拿到空包（页面会自己重试，但不一定成功）。
    // 页面已经收到两次空包就提前结束这一轮，重新打开页面，最多三轮。
    for attempt in 0..3 {
        if attempt > 0 {
            // 新档案还没有站点 Cookie（ttwid、UIFID 等），先在首页停留几秒让页面脚本种好再打开作品
            let _ = ctx
                .browser
                .capture(CaptureSpec {
                    url: "https://www.douyin.com/",
                    patterns: vec![],
                    document: false,
                    media: false,
                    done: Box::new(|_| false),
                    timeout: Duration::from_secs(6),
                })
                .await;
        }
        let empties = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counter = empties.clone();
        let caps = ctx
            .browser
            .capture(CaptureSpec {
                url: &page,
                patterns: vec!["/aweme/v1/web/aweme/detail/".into()],
                document: false,
                media: false,
                done: Box::new(move |c| {
                    if c.body.contains("\"aweme_detail\":{") {
                        return true;
                    }
                    counter.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1 >= 2
                }),
                timeout: Duration::from_secs(20),
            })
            .await?;
        for c in caps.iter().rev() {
            let Ok(v) = serde_json::from_str::<Value>(&c.body) else { continue };
            if let Some(a) = v.get("aweme_detail").filter(|a| a.is_object()) {
                return parse_detail(a, &id);
            }
            if let Some(f) = jarr(&v, "filter_detail").first().or(v.get("filter_detail")) {
                let reason = jstr(f, "detail_msg").or_else(|| jstr(f, "filter_reason")).unwrap_or_default();
                return Err(anyhow!("作品不可用：{reason}"));
            }
        }
        tracing::info!(attempt, empties = empties.load(std::sync::atomic::Ordering::Relaxed), "douyin: no detail yet, reloading");
        last_err = Some(anyhow!(
            "抖音没有返回作品数据（可能触发了验证）。可以在设置里打开「显示解析浏览器窗口」后重试，在弹出的浏览器里完成验证"
        ));
    }
    Err(last_err.unwrap())
}

fn parse_detail(a: &Value, id: &str) -> Result<MediaInfo> {
    let desc = jstr(a, "desc").unwrap_or_default();
    let title = short_title(&desc);
    let author = jstr(a, "author.nickname");
    let cover = first_str(a, "video.cover.url_list").or_else(|| first_str(a, "video.origin_cover.url_list"));
    let mut items = Vec::new();

    let images = jarr(a, "images");
    if !images.is_empty() {
        for img in images {
            // 实况图：图片里带一段视频
            if let Some(u) = first_str(img, "video.play_addr.url_list") {
                let mut v = Variant::new("实况", u, "mp4");
                v.backup_urls = str_list(img, "video.play_addr.url_list").into_iter().skip(1).collect();
                v.headers.push(("Referer".into(), REFERER.into()));
                items.push(MediaItem {
                    kind: MediaKind::LivePhoto,
                    thumbnail: first_str(img, "url_list"),
                    variants: vec![v],
                });
            }
            let urls = str_list(img, "url_list");
            // 优先 jpeg，其次任意格式
            let best = urls
                .iter()
                .find(|u| u.contains(".jpeg") || u.contains(".jpg"))
                .or(urls.first())
                .cloned();
            if let Some(u) = best {
                let ext = image_ext(&u);
                let mut v = Variant::new("原图", u.clone(), ext)
                    .dims(ju64(img, "width").map(|x| x as u32), ju64(img, "height").map(|x| x as u32));
                v.label = quality_label(v.width, v.height, None, None).replace("p", "") + " 原图";
                v.backup_urls = urls.into_iter().filter(|x| *x != u).collect();
                v.headers.push(("Referer".into(), REFERER.into()));
                items.push(MediaItem {
                    kind: MediaKind::Image,
                    thumbnail: Some(u),
                    variants: vec![v],
                });
            }
        }
    } else {
        let mut variants = Vec::new();
        let mut seen = HashSet::new();
        for b in jarr(a, "video.bit_rate") {
            let Some(u) = first_str(b, "play_addr.url_list") else { continue };
            let w = ju64(b, "play_addr.width").map(|x| x as u32);
            let h = ju64(b, "play_addr.height").map(|x| x as u32);
            let h265 = ju64(b, "is_h265").unwrap_or(0) == 1;
            let codec = if h265 { "h265" } else { "h264" };
            let short = w.unwrap_or(0).min(h.unwrap_or(0));
            // 同清晰度同编码只留码率最高的一档（接口里按码率降序）
            if !seen.insert((short, h265)) {
                continue;
            }
            let br = ju64(b, "bit_rate");
            let mut v = Variant::new(quality_label(w, h, Some(codec), None), u, "mp4").dims(w, h);
            v.backup_urls = str_list(b, "play_addr.url_list").into_iter().skip(1).collect();
            v.bitrate = br;
            v.size = ju64(b, "play_addr.data_size");
            v.codec = Some(codec.into());
            v.headers.push(("Referer".into(), REFERER.into()));
            variants.push(v);
        }
        if variants.is_empty() {
            if let Some(u) = first_str(a, "video.play_addr.url_list") {
                let w = ju64(a, "video.play_addr.width").map(|x| x as u32);
                let h = ju64(a, "video.play_addr.height").map(|x| x as u32);
                let mut v = Variant::new(quality_label(w, h, None, None), u, "mp4").dims(w, h);
                v.backup_urls = str_list(a, "video.play_addr.url_list").into_iter().skip(1).collect();
                v.headers.push(("Referer".into(), REFERER.into()));
                variants.push(v);
            }
        }
        sort_variants(&mut variants);
        if variants.is_empty() {
            bail!("作品里没有视频地址");
        }
        items.push(MediaItem {
            kind: MediaKind::Video,
            thumbnail: cover.clone(),
            variants,
        });
    }

    // 背景音乐（默认不勾选）
    if let Some(u) = first_str(a, "music.play_url.url_list") {
        let ext = ext_from_url(&u, "mp3");
        items.push(MediaItem {
            kind: MediaKind::Audio,
            thumbnail: first_str(a, "music.cover_thumb.url_list"),
            variants: vec![Variant::new(
                format!("背景音乐 · {}", jstr(a, "music.title").unwrap_or_default()),
                u,
                ext,
            )],
        });
    }

    Ok(MediaInfo {
        platform: Platform::Douyin,
        id: id.to_string(),
        url: format!("https://www.douyin.com/video/{id}"),
        title: if title.is_empty() { format!("抖音作品 {id}") } else { title },
        author,
        cover: cover.or_else(|| items.iter().find_map(|i| i.thumbnail.clone())),
        duration_ms: ju64(a, "video.duration").filter(|d| *d > 0),
        items,
    })
}

fn image_ext(u: &str) -> String {
    let path = u.split('?').next().unwrap_or("");
    for e in ["jpeg", "jpg", "webp", "png", "heic"] {
        if path.ends_with(&format!(".{e}")) {
            return if e == "jpeg" { "jpg".into() } else { e.into() };
        }
    }
    "jpg".into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids() {
        let u = |s: &str| Url::parse(s).unwrap();
        assert_eq!(aweme_id(&u("https://www.douyin.com/video/7697283722604776745")).unwrap(), "7697283722604776745");
        assert_eq!(aweme_id(&u("https://www.iesdouyin.com/share/note/7697283722604776745/?x=1")).unwrap(), "7697283722604776745");
        assert_eq!(aweme_id(&u("https://www.douyin.com/jingxuan?modal_id=7697283722604776745")).unwrap(), "7697283722604776745");
    }

    #[test]
    fn image_post_with_live_photo() {
        let a = serde_json::json!({
            "desc": "秋天的银杏 #风景",
            "author": {"nickname": "某人"},
            "images": [
                {"url_list": ["https://p3/a~tplv:q75.webp?x=1", "https://p9/a~tplv:q75.jpeg?x=1"], "width": 1080, "height": 1440},
                {"url_list": ["https://p3/b.jpeg"], "width": 1080, "height": 1920,
                 "video": {"play_addr": {"url_list": ["https://v/live.mp4", "https://v2/live.mp4"]}}}
            ],
            "video": {"cover": {"url_list": ["https://p3/cover.jpeg"]}, "duration": 0},
            "music": {"title": "bgm", "play_url": {"url_list": ["https://m/bgm.mp3"]}}
        });
        let info = parse_detail(&a, "1").unwrap();
        assert_eq!(info.title, "秋天的银杏");
        let kinds: Vec<_> = info.items.iter().map(|i| i.kind).collect();
        assert_eq!(kinds, [MediaKind::Image, MediaKind::LivePhoto, MediaKind::Image, MediaKind::Audio]);
        // 优先 jpeg 地址，webp 作备用
        assert!(info.items[0].variants[0].url.contains(".jpeg"));
        assert_eq!(info.items[0].variants[0].ext, "jpg");
        assert_eq!(info.items[1].variants[0].backup_urls, ["https://v2/live.mp4"]);
        assert_eq!(info.duration_ms, None);
    }
}
