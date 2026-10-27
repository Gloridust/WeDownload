//! 哔哩哔哩：公开接口 view（标题、分 P）+ playurl。
//! 用 `platform=html5` 拿音视频合一的 mp4（不需要 ffmpeg 合并），未登录最高 1080p 视频不保证，常见 720p。

use std::sync::OnceLock;

use anyhow::{Result, anyhow, bail};
use regex::Regex;
use serde_json::Value;
use url::Url;

use super::Ctx;
use crate::model::*;
use crate::util::*;

const REFERER: &str = "https://www.bilibili.com/";

fn video_ref(url: &Url) -> Option<(String, String)> {
    static R: OnceLock<Regex> = OnceLock::new();
    let r = R.get_or_init(|| Regex::new(r"/(?:video/)?(BV[0-9A-Za-z]{10}|av\d+)").unwrap());
    let c = r.captures(url.path())?;
    let id = c[1].to_string();
    if let Some(av) = id.strip_prefix("av") {
        Some(("aid".into(), av.into()))
    } else {
        Some(("bvid".into(), id))
    }
}

async fn api(ctx: &Ctx, url: &str, cookie: &str) -> Result<Value> {
    let resp = ctx.http.get(url).header("Referer", REFERER).header("Cookie", cookie).send().await?;
    if resp.status().as_u16() == 412 {
        bail!("B 站拒绝了当前网络（常见于海外代理出口），请让 bilibili.com 走国内直连后重试");
    }
    let v: Value = resp.error_for_status()?.json().await?;
    if ju64(&v, "code").unwrap_or(0) != 0 && v.get("code").and_then(Value::as_i64).unwrap_or(0) != 0 {
        bail!("B 站接口返回错误：{}", jstr(&v, "message").unwrap_or_default());
    }
    Ok(v)
}

pub async fn extract(ctx: &Ctx, url: &Url) -> Result<MediaInfo> {
    let (key, val) = video_ref(url).ok_or_else(|| anyhow!("没能从链接里找到 B 站视频编号（BV / av）：{url}"))?;
    // 匿名访客标识，不带时接口更容易触发风控
    let cookie = match ctx.http.get("https://api.bilibili.com/x/frontend/finger/spi").send().await {
        Ok(r) => match r.json::<Value>().await {
            Ok(v) => format!(
                "buvid3={}; buvid4={}",
                jstr(&v, "data.b_3").unwrap_or_default(),
                jstr(&v, "data.b_4").unwrap_or_default()
            ),
            Err(_) => String::new(),
        },
        Err(_) => String::new(),
    };
    let view = api(ctx, &format!("https://api.bilibili.com/x/web-interface/view?{key}={val}"), &cookie).await?;
    let d = jget(&view, "data").ok_or_else(|| anyhow!("B 站没有返回视频信息"))?;
    let bvid = jstr(d, "bvid").unwrap_or(val.clone());
    let pages = jarr(d, "pages");
    // 链接里的 ?p=N 指定分 P，默认第一 P
    let p: usize = url
        .query_pairs()
        .find(|(k, _)| k == "p")
        .and_then(|(_, v)| v.parse().ok())
        .unwrap_or(1);
    let page = pages.get(p.saturating_sub(1)).or(pages.first()).ok_or_else(|| anyhow!("视频没有分 P 信息"))?;
    let cid = ju64(page, "cid").ok_or_else(|| anyhow!("缺少 cid"))?;

    let mut variants = Vec::new();
    // 依次请求 1080 / 720 / 480，接口会回落到可用的最高清晰度，按返回的 quality 去重
    let mut seen = Vec::new();
    for qn in [80, 64, 32, 16] {
        let pu = api(
            ctx,
            &format!(
                "https://api.bilibili.com/x/player/playurl?bvid={bvid}&cid={cid}&qn={qn}&fnval=1&fnver=0&fourk=0&platform=html5&high_quality=1"
            ),
            &cookie,
        )
        .await?;
        let Some(q) = ju64(&pu, "data.quality") else { continue };
        if seen.contains(&q) {
            continue;
        }
        seen.push(q);
        let Some(u) = jstr(&pu, "data.durl.0.url") else { continue };
        let label = jarr(&pu, "data.accept_quality")
            .iter()
            .position(|x| x.as_u64() == Some(q))
            .and_then(|i| jarr(&pu, "data.accept_description").get(i).and_then(Value::as_str).map(str::to_string))
            .unwrap_or_else(|| format!("{q}"));
        let mut v = Variant::new(label, u, "mp4");
        v.backup_urls = str_list(&pu, "data.durl.0.backup_url");
        v.size = ju64(&pu, "data.durl.0.size");
        v.height = Some(match q {
            80 => 1080,
            64 => 720,
            32 => 480,
            16 => 360,
            _ => 0,
        })
        .filter(|h| *h > 0);
        v.headers.push(("Referer".into(), REFERER.into()));
        if !cookie.is_empty() {
            v.headers.push(("Cookie".into(), cookie.clone()));
        }
        variants.push(v);
    }
    sort_variants(&mut variants);
    let mut title = jstr(d, "title").unwrap_or_default();
    if pages.len() > 1 {
        title = format!("{title} P{} {}", p.max(1), jstr(page, "part").unwrap_or_default());
    }
    let cover = jstr(d, "pic").map(|u| u.replace("http://", "https://"));
    Ok(MediaInfo {
        platform: Platform::Bilibili,
        id: bvid.clone(),
        url: format!("https://www.bilibili.com/video/{bvid}?p={}", p.max(1)),
        title,
        author: jstr(d, "owner.name"),
        cover: cover.clone(),
        duration_ms: ju64(page, "duration").map(|s| s * 1000),
        items: vec![MediaItem {
            kind: MediaKind::Video,
            thumbnail: cover,
            variants,
        }],
    })
}
