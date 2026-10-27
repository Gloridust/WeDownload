//! 小红书：笔记页 HTML 的 `window.__INITIAL_STATE__.note.noteDetailMap` 带全部数据，
//! 但纯 HTTP 访问会被重定向到登录页，所以用浏览器打开（要带分享链接里的 xsec_token）。
//! 视频取 `video.media.stream.{h264,h265,av1}`；图片的 urlDefault 带水印压缩，
//! 取其中的图片 token 拼出原图地址。

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

const REFERER: &str = "https://www.xiaohongshu.com/";

fn note_id(url: &Url) -> Option<String> {
    static R: OnceLock<Regex> = OnceLock::new();
    let r = R.get_or_init(|| Regex::new(r"/(?:explore|discovery/item|item|user/profile/[0-9a-f]+)/([0-9a-f]{24})").unwrap());
    r.captures(url.path()).map(|c| c[1].to_string())
}

pub async fn extract(ctx: &Ctx, url: &Url) -> Result<MediaInfo> {
    let id = note_id(url).ok_or_else(|| anyhow!("没能从链接里找到小红书笔记 id：{url}"))?;
    let query: Vec<(String, String)> = url
        .query_pairs()
        .filter(|(k, _)| k == "xsec_token" || k == "xsec_source")
        .map(|(k, v)| (k.into_owned(), v.into_owned()))
        .collect();
    if !query.iter().any(|(k, _)| k == "xsec_token") {
        bail!("小红书链接缺少 xsec_token，请使用 App 里「分享 → 复制链接」得到的完整链接");
    }
    let mut page = Url::parse(&format!("https://www.xiaohongshu.com/explore/{id}")).unwrap();
    page.query_pairs_mut().extend_pairs(&query);
    let caps = ctx
        .browser
        .capture(CaptureSpec {
            url: page.as_str(),
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
        .ok_or_else(|| anyhow!("小红书页面没有打开"))?;
    let state = window_json(html, "__INITIAL_STATE__").ok_or_else(|| anyhow!("小红书页面结构变了，没找到笔记数据"))?;
    let note = jget(&state, &format!("note.noteDetailMap.{id}.note"))
        .filter(|n| n.get("noteId").is_some() || n.get("type").is_some())
        .ok_or_else(|| anyhow!("笔记不可见（可能已删除、仅自己可见，或链接里的 xsec_token 已过期）"))?;
    parse_note(note, &id, page.as_str())
}

fn parse_note(n: &Value, id: &str, page: &str) -> Result<MediaInfo> {
    let mut items = Vec::new();
    let images = jarr(n, "imageList");
    let is_video = jstr(n, "type").as_deref() == Some("video");
    if is_video {
        let mut variants = Vec::new();
        for codec in ["h264", "h265", "av1"] {
            for s in jarr(n, &format!("video.media.stream.{codec}")) {
                let Some(u) = jstr(s, "masterUrl") else { continue };
                let w = ju64(s, "width").map(|x| x as u32);
                let h = ju64(s, "height").map(|x| x as u32);
                let br = ju64(s, "avgBitrate").or_else(|| ju64(s, "videoBitrate"));
                let mut v = Variant::new(quality_label(w, h, Some(codec), None), https(&u), "mp4").dims(w, h);
                v.backup_urls = str_list(s, "backupUrls").iter().map(|x| https(x)).collect();
                v.bitrate = br;
                v.size = ju64(s, "size");
                v.codec = Some(codec.into());
                v.headers.push(("Referer".into(), REFERER.into()));
                variants.push(v);
            }
        }
        // 早期笔记只有 originVideoKey
        if variants.is_empty() {
            if let Some(k) = jstr(n, "video.consumer.originVideoKey") {
                let mut v = Variant::new("原画", format!("https://sns-video-bd.xhscdn.com/{k}"), "mp4");
                v.headers.push(("Referer".into(), REFERER.into()));
                variants.push(v);
            }
        }
        sort_variants(&mut variants);
        items.push(MediaItem {
            kind: MediaKind::Video,
            thumbnail: images.first().and_then(|i| jstr(i, "urlDefault")).map(|u| https(&u)),
            variants,
        });
    } else {
        for img in images {
            let default = jstr(img, "urlDefault").or_else(|| jstr(img, "url")).map(|u| https(&u));
            let Some(default) = default else { continue };
            let w = ju64(img, "width").map(|x| x as u32);
            let h = ju64(img, "height").map(|x| x as u32);
            // 实况图
            if img.get("livePhoto").and_then(Value::as_bool).unwrap_or(false) {
                if let Some(u) = jstr(img, "stream.h264.0.masterUrl") {
                    let mut v = Variant::new("实况", https(&u), "mp4");
                    v.headers.push(("Referer".into(), REFERER.into()));
                    items.push(MediaItem {
                        kind: MediaKind::LivePhoto,
                        thumbnail: Some(default.clone()),
                        variants: vec![v],
                    });
                }
            }
            let mut variants = Vec::new();
            if let Some(token) = image_token(&default) {
                let mut v = Variant::new("原图 PNG", format!("https://ci.xiaohongshu.com/{token}?imageView2/format/png"), "png")
                    .dims(w, h);
                v.backup_urls.push(format!("https://sns-img-bd.xhscdn.com/{token}"));
                v.headers.push(("Referer".into(), REFERER.into()));
                variants.push(v);
            }
            let mut v = Variant::new("默认", default.clone(), "webp").dims(w, h);
            v.headers.push(("Referer".into(), REFERER.into()));
            variants.push(v);
            items.push(MediaItem {
                kind: MediaKind::Image,
                thumbnail: Some(default),
                variants,
            });
        }
    }
    let title = jstr(n, "title").filter(|t| !t.trim().is_empty()).unwrap_or_else(|| short_title(&jstr(n, "desc").unwrap_or_default()));
    Ok(MediaInfo {
        platform: Platform::Xiaohongshu,
        id: id.to_string(),
        url: page.to_string(),
        title: if title.is_empty() { format!("小红书笔记 {id}") } else { title },
        author: jstr(n, "user.nickname").or_else(|| jstr(n, "user.nickName")),
        cover: items.iter().find_map(|i| i.thumbnail.clone()),
        duration_ms: ju64(n, "video.capa.duration").map(|s| s * 1000),
        items,
    })
}

fn https(u: &str) -> String {
    u.strip_prefix("http://").map(|r| format!("https://{r}")).unwrap_or_else(|| u.to_string())
}

/// `http://sns-webpic-qc.xhscdn.com/202610280211/<hash>/1040g2sg…np0!nd_dft_wlteh_webp_3` → `1040g2sg…np0`
/// 部分图片 token 带目录（`spectrum/1040g…`），一并保留
fn image_token(u: &str) -> Option<String> {
    let path = Url::parse(u).ok()?.path().to_string();
    let path = path.split('!').next()?;
    let segs: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    // 前两段是时间戳和签名
    let rest = if segs.len() > 2 && segs[0].chars().all(|c| c.is_ascii_digit()) { &segs[2..] } else { &segs[..] };
    let t = rest.join("/");
    if t.is_empty() { None } else { Some(t) }
}

#[cfg(test)]
mod tests {
    #[test]
    fn token() {
        assert_eq!(
            super::image_token("http://sns-webpic-qc.xhscdn.com/202610280211/e88ac7c60b9c09fd507b4cfff52d7a98/1040g2sg3251uijctjui05pd3i2v7v6vm5n89np0!nd_dft_wlteh_webp_3").unwrap(),
            "1040g2sg3251uijctjui05pd3i2v7v6vm5n89np0"
        );
        assert_eq!(
            super::image_token("http://sns-webpic-qc.xhscdn.com/202610280211/abc/spectrum/1040g0k0!nd").unwrap(),
            "spectrum/1040g0k0"
        );
    }
}
