//! X（Twitter）：用嵌入推文的公开接口 cdn.syndication.twimg.com/tweet-result，
//! 不需要登录。token 由推文 id 算出（与官方嵌入脚本同一算法）。

use std::sync::OnceLock;

use anyhow::{Result, anyhow, bail};
use regex::Regex;
use serde_json::Value;
use url::Url;

use super::Ctx;
use crate::model::*;
use crate::util::*;

fn tweet_id(url: &Url) -> Option<String> {
    static R: OnceLock<Regex> = OnceLock::new();
    let r = R.get_or_init(|| Regex::new(r"/status(?:es)?/(\d{5,})").unwrap());
    r.captures(url.path()).map(|c| c[1].to_string())
}

/// `((id / 1e15) * π).toString(36)` 去掉 0 和小数点
pub fn syndication_token(id: &str) -> String {
    let n: f64 = id.parse::<f64>().unwrap_or(0.0) / 1e15 * std::f64::consts::PI;
    const D: &[u8] = b"0123456789abcdefghijklmnopqrstuvwxyz";
    let mut ip = n.trunc() as u64;
    let mut fp = n.fract();
    let mut s = String::new();
    if ip == 0 {
        s.push('0');
    }
    let mut int_digits = Vec::new();
    while ip > 0 {
        int_digits.push(D[(ip % 36) as usize] as char);
        ip /= 36;
    }
    s.extend(int_digits.iter().rev());
    for _ in 0..11 {
        fp *= 36.0;
        let d = fp.trunc() as usize;
        s.push(D[d.min(35)] as char);
        fp -= d as f64;
    }
    s.chars().filter(|c| *c != '0').collect()
}

pub async fn extract(ctx: &Ctx, url: &Url) -> Result<MediaInfo> {
    let id = tweet_id(url).ok_or_else(|| anyhow!("没能从链接里找到推文 id：{url}"))?;
    let api = format!(
        "https://cdn.syndication.twimg.com/tweet-result?id={id}&token={}&lang=en",
        syndication_token(&id)
    );
    let resp = ctx.http.get(&api).send().await?;
    if resp.status().as_u16() == 404 {
        bail!("推文不存在、已删除或仅登录可见");
    }
    let v: Value = resp.error_for_status()?.json().await?;
    if jstr(&v, "__typename").as_deref() == Some("TweetTombstone") {
        bail!("这条推文需要登录才能查看");
    }

    let mut items = Vec::new();
    for m in jarr(&v, "mediaDetails") {
        match jstr(m, "type").as_deref() {
            Some("video") | Some("animated_gif") => {
                let mut variants = Vec::new();
                for var in jarr(m, "video_info.variants") {
                    let ct = jstr(var, "content_type").unwrap_or_default();
                    if ct != "video/mp4" {
                        continue;
                    }
                    let Some(u) = jstr(var, "url") else { continue };
                    let (w, h) = dims_from_path(&u);
                    let br = ju64(var, "bitrate");
                    let mut vv = Variant::new(quality_label(w, h, Some("h264"), br), u, "mp4").dims(w, h);
                    vv.bitrate = br;
                    vv.codec = Some("h264".into());
                    variants.push(vv);
                }
                sort_variants(&mut variants);
                items.push(MediaItem {
                    kind: MediaKind::Video,
                    thumbnail: jstr(m, "media_url_https"),
                    variants,
                });
            }
            Some("photo") => {
                let Some(u) = jstr(m, "media_url_https") else { continue };
                let ext = ext_from_url(&u, "jpg");
                let base = u.rsplit_once('.').map(|(b, _)| b.to_string()).unwrap_or(u.clone());
                let w = ju64(m, "original_info.width").map(|x| x as u32);
                let h = ju64(m, "original_info.height").map(|x| x as u32);
                let mut vv = Variant::new("原图", format!("{base}?format={ext}&name=orig"), ext.clone()).dims(w, h);
                vv.backup_urls.push(u.clone());
                items.push(MediaItem {
                    kind: MediaKind::Image,
                    thumbnail: Some(u),
                    variants: vec![vv],
                });
            }
            _ => {}
        }
    }
    if items.is_empty() {
        bail!("这条推文里没有视频或图片");
    }

    static TCO: OnceLock<Regex> = OnceLock::new();
    let tco = TCO.get_or_init(|| Regex::new(r"\s*https://t\.co/\w+").unwrap());
    let text = jstr(&v, "text").unwrap_or_default();
    let title = short_title(&tco.replace_all(&text, ""));
    let name = jstr(&v, "user.name");
    let screen = jstr(&v, "user.screen_name");
    Ok(MediaInfo {
        platform: Platform::X,
        id: id.clone(),
        url: format!("https://x.com/{}/status/{id}", screen.clone().unwrap_or_else(|| "i".into())),
        title: if title.is_empty() { format!("推文 {id}") } else { title },
        author: name.or(screen),
        cover: items.iter().find_map(|i| i.thumbnail.clone()),
        duration_ms: jarr(&v, "mediaDetails").iter().find_map(|m| ju64(m, "video_info.duration_millis")),
        items,
    })
}

fn dims_from_path(u: &str) -> (Option<u32>, Option<u32>) {
    static R: OnceLock<Regex> = OnceLock::new();
    let r = R.get_or_init(|| Regex::new(r"/(\d{2,5})x(\d{2,5})/").unwrap());
    match r.captures(u) {
        Some(c) => (c[1].parse().ok(), c[2].parse().ok()),
        None => (None, None),
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn token_matches_js() {
        // 与 Python 版（同 JS 算法）对照：1600649710662213632
        let t = super::syndication_token("1600649710662213632");
        assert!(!t.is_empty() && !t.contains('0') && !t.contains('.'));
    }
}
