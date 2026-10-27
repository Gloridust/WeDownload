//! 解析结果的统一模型：一个作品（MediaInfo）包含若干条媒体（MediaItem，视频 / 图片 / 实况图），
//! 每条媒体有若干可选版本（Variant，清晰度、编码不同）。

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Platform {
    Douyin,
    Tiktok,
    Xiaohongshu,
    Instagram,
    X,
    Bilibili,
    Generic,
}

impl Platform {
    pub fn key(self) -> &'static str {
        match self {
            Platform::Douyin => "douyin",
            Platform::Tiktok => "tiktok",
            Platform::Xiaohongshu => "xiaohongshu",
            Platform::Instagram => "instagram",
            Platform::X => "x",
            Platform::Bilibili => "bilibili",
            Platform::Generic => "generic",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Platform::Douyin => "抖音",
            Platform::Tiktok => "TikTok",
            Platform::Xiaohongshu => "小红书",
            Platform::Instagram => "Instagram",
            Platform::X => "X",
            Platform::Bilibili => "哔哩哔哩",
            Platform::Generic => "网页",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MediaKind {
    Video,
    Image,
    /// 实况图里的动态部分，下载为短视频
    LivePhoto,
    Audio,
}

impl MediaKind {
    pub fn default_ext(self) -> &'static str {
        match self {
            MediaKind::Video | MediaKind::LivePhoto => "mp4",
            MediaKind::Image => "jpg",
            MediaKind::Audio => "m4a",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Variant {
    /// 给人看的标签，如 "1080p · H.264"
    pub label: String,
    pub url: String,
    /// 同一资源的备用地址，主地址失败时依次尝试
    #[serde(default)]
    pub backup_urls: Vec<String>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    /// bit/s
    pub bitrate: Option<u64>,
    /// 字节数（接口给出时）
    pub size: Option<u64>,
    pub codec: Option<String>,
    pub ext: String,
    /// 下载时要带的请求头（Referer、Cookie 等）
    #[serde(default)]
    pub headers: Vec<(String, String)>,
}

impl Variant {
    pub fn new(label: impl Into<String>, url: impl Into<String>, ext: impl Into<String>) -> Self {
        Self {
            label: label.into(),
            url: url.into(),
            backup_urls: Vec::new(),
            width: None,
            height: None,
            bitrate: None,
            size: None,
            codec: None,
            ext: ext.into(),
            headers: Vec::new(),
        }
    }

    pub fn dims(mut self, w: Option<u32>, h: Option<u32>) -> Self {
        self.width = w.filter(|v| *v > 0);
        self.height = h.filter(|v| *v > 0);
        self
    }

    /// 短边像素，用来排序和生成 "1080p" 这样的标签
    pub fn short_side(&self) -> u32 {
        match (self.width, self.height) {
            (Some(w), Some(h)) => w.min(h),
            (Some(x), None) | (None, Some(x)) => x,
            _ => 0,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaItem {
    pub kind: MediaKind,
    pub thumbnail: Option<String>,
    /// 按推荐程度排好序，第一个是默认选择
    pub variants: Vec<Variant>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaInfo {
    pub platform: Platform,
    /// 平台内的作品 id
    pub id: String,
    /// 规范化后的作品地址（重试时用它重新解析）
    pub url: String,
    pub title: String,
    pub author: Option<String>,
    pub cover: Option<String>,
    pub duration_ms: Option<u64>,
    pub items: Vec<MediaItem>,
}

/// 按清晰度、码率从高到低排序；同清晰度下 H.264 排在 H.265 前面（兼容性更好）
pub fn sort_variants(v: &mut [Variant]) {
    v.sort_by(|a, b| {
        b.short_side()
            .cmp(&a.short_side())
            .then_with(|| codec_rank(a).cmp(&codec_rank(b)))
            .then_with(|| b.bitrate.unwrap_or(0).cmp(&a.bitrate.unwrap_or(0)))
    });
}

fn codec_rank(v: &Variant) -> u8 {
    match v.codec.as_deref().map(str::to_ascii_lowercase).as_deref() {
        Some(c) if c.contains("264") || c.contains("avc") => 0,
        None => 1,
        _ => 2,
    }
}

/// "1080p · H.265 · 1.4 Mbps"
pub fn quality_label(w: Option<u32>, h: Option<u32>, codec: Option<&str>, bitrate: Option<u64>) -> String {
    let mut parts = Vec::new();
    let side = match (w, h) {
        (Some(w), Some(h)) => Some(w.min(h)),
        (Some(x), None) | (None, Some(x)) => Some(x),
        _ => None,
    };
    if let Some(s) = side.filter(|s| *s > 0) {
        parts.push(format!("{s}p"));
    }
    if let Some(c) = codec {
        let c = c.to_ascii_lowercase();
        let name = if c.contains("265") || c.contains("hev") || c.contains("hvc") {
            "H.265"
        } else if c.contains("264") || c.contains("avc") {
            "H.264"
        } else if c.contains("av1") || c.contains("av01") {
            "AV1"
        } else if c.contains("vp9") || c.contains("vp09") {
            "VP9"
        } else {
            ""
        };
        if !name.is_empty() {
            parts.push(name.to_string());
        }
    }
    if let Some(b) = bitrate.filter(|b| *b > 0) {
        parts.push(format!("{:.1} Mbps", b as f64 / 1_000_000.0));
    }
    if parts.is_empty() { "默认".into() } else { parts.join(" · ") }
}
