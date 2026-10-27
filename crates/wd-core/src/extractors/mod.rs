//! 各平台解析器。入口 [`extract`] 接受用户粘贴的任意文本：先抠出链接、展开短链，再按域名分发。

mod bilibili;
mod douyin;
mod generic;
pub use generic::ytdlp_path;
mod instagram;
mod tiktok;
mod x;
mod xiaohongshu;

use std::sync::Arc;
use std::time::Duration;

use anyhow::{Result, anyhow, bail};
use url::Url;

use crate::browser::BrowserPool;
use crate::model::{MediaInfo, Platform};
use crate::util::{DESKTOP_UA, extract_urls};

/// 解析时共用的资源
#[derive(Clone)]
pub struct Ctx {
    pub http: reqwest::Client,
    pub browser: Arc<BrowserPool>,
}

impl Ctx {
    pub fn new(browser: Arc<BrowserPool>) -> Result<Self> {
        Ok(Self {
            http: build_client(None)?,
            browser,
        })
    }
}

pub(crate) fn build_client(jar: Option<Arc<reqwest::cookie::Jar>>) -> Result<reqwest::Client> {
    let mut b = reqwest::Client::builder()
        .user_agent(DESKTOP_UA)
        .connect_timeout(Duration::from_secs(15))
        .timeout(Duration::from_secs(30));
    if let Some(j) = jar {
        b = b.cookie_provider(j);
    }
    Ok(b.build()?)
}

/// 识别链接属于哪个平台（不发请求）
pub fn detect(url: &Url) -> Platform {
    let host = url.host_str().unwrap_or("").to_ascii_lowercase();
    let is = |d: &str| host == d || host.ends_with(&format!(".{d}"));
    if is("douyin.com") || is("iesdouyin.com") {
        Platform::Douyin
    } else if is("tiktok.com") {
        Platform::Tiktok
    } else if is("xiaohongshu.com") || is("xhslink.com") {
        Platform::Xiaohongshu
    } else if is("instagram.com") {
        Platform::Instagram
    } else if is("x.com") || is("twitter.com") || is("fxtwitter.com") || is("vxtwitter.com") {
        Platform::X
    } else if is("bilibili.com") || is("b23.tv") {
        Platform::Bilibili
    } else {
        Platform::Generic
    }
}

/// 需要先跟随跳转才能拿到作品地址的短链
fn is_short_link(url: &Url) -> bool {
    let host = url.host_str().unwrap_or("");
    matches!(
        host,
        "v.douyin.com" | "xhslink.com" | "vm.tiktok.com" | "vt.tiktok.com" | "b23.tv" | "t.co"
    ) || (host.ends_with("tiktok.com") && url.path().starts_with("/t/"))
        || host.ends_with(".xhslink.com")
}

/// 跟随短链跳转，返回最终地址（不下载正文）
async fn resolve_short(ctx: &Ctx, url: &Url) -> Result<Url> {
    let client = reqwest::Client::builder()
        .user_agent(if url.host_str() == Some("v.douyin.com") {
            // 手机 UA 让抖音直接 302 到带作品 id 的分享页
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        } else {
            DESKTOP_UA
        })
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(15))
        .build()?;
    let _ = ctx;
    let mut cur = url.clone();
    for _ in 0..8 {
        let resp = client.get(cur.clone()).send().await?;
        if !resp.status().is_redirection() {
            break;
        }
        let Some(loc) = resp.headers().get(reqwest::header::LOCATION).and_then(|v| v.to_str().ok()) else {
            break;
        };
        cur = cur.join(loc)?;
        // 到了作品页就够了，不必再往下跳（有的会继续跳到下载 App 页）
        if !is_short_link(&cur) {
            break;
        }
    }
    Ok(cur)
}

/// 用户输入里的第一个链接，展开短链后的规范地址
pub async fn normalize_input(ctx: &Ctx, input: &str) -> Result<Url> {
    let urls = extract_urls(input);
    let raw = urls.first().ok_or_else(|| anyhow!("没有在输入里找到链接"))?;
    let mut url = Url::parse(raw).map_err(|_| anyhow!("链接格式不对：{raw}"))?;
    if is_short_link(&url) {
        url = resolve_short(ctx, &url).await?;
    }
    Ok(url)
}

/// 微信视频号：内容只在微信客户端内的内嵌浏览器里加载，分享链接在普通浏览器里会跳到
/// 「请在微信客户端打开」。现有能下载它的工具都要在本机装根证书、截获微信客户端自己的加密流量
/// 才能拿到解密密钥——本项目不做这件事，所以这里给出清楚的说明，而不是走通用嗅探报一个看不懂的错。
fn is_wechat_channels(url: &Url) -> bool {
    let host = url.host_str().unwrap_or("").to_ascii_lowercase();
    host == "channels.weixin.qq.com"
        || host == "finder.video.qq.com"
        || host.ends_with(".channels.weixin.qq.com")
        || (host == "support.weixin.qq.com" && url.path().contains("channels"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wechat_channels_detected() {
        let u = |s: &str| Url::parse(s).unwrap();
        assert!(is_wechat_channels(&u("https://channels.weixin.qq.com/web/pages/feed?v=abc")));
        assert!(is_wechat_channels(&u("https://finder.video.qq.com/251/xyz")));
        assert!(!is_wechat_channels(&u("https://www.douyin.com/video/123")));
        assert!(!is_wechat_channels(&u("https://support.weixin.qq.com/update/")));
    }

    #[test]
    fn platform_detection() {
        let u = |s: &str| Url::parse(s).unwrap();
        assert_eq!(detect(&u("https://www.tiktok.com/@a/video/1")), Platform::Tiktok);
        assert_eq!(detect(&u("https://b23.tv/abc")), Platform::Bilibili);
        assert_eq!(detect(&u("https://example.com/v.mp4")), Platform::Generic);
    }
}

/// 解析作品
pub async fn extract(ctx: &Ctx, input: &str) -> Result<MediaInfo> {
    let url = normalize_input(ctx, input).await?;
    if is_wechat_channels(&url) {
        bail!(
            "暂不支持微信视频号。视频号的内容只在微信客户端里加载，分享链接在普通浏览器里打不开，\
             要下载它必须截获微信客户端自己的加密流量来拿解密密钥，本项目不做这件事。\
             可以在微信里用「长按 → 更多 → 下载」保存到相册后再导出"
        );
    }
    let info = match detect(&url) {
        Platform::Douyin => douyin::extract(ctx, &url).await,
        Platform::Tiktok => tiktok::extract(ctx, &url).await,
        Platform::Xiaohongshu => xiaohongshu::extract(ctx, &url).await,
        Platform::Instagram => instagram::extract(ctx, &url).await,
        Platform::X => x::extract(ctx, &url).await,
        Platform::Bilibili => bilibili::extract(ctx, &url).await,
        Platform::Generic => generic::extract(ctx, &url).await,
    }?;
    if info.items.iter().all(|i| i.variants.is_empty()) {
        bail!("没有找到可下载的视频或图片");
    }
    Ok(info)
}
