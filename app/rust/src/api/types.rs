//! 暴露给 Dart 的数据类型（与内核类型一一对应，字段改成 Dart 友好的形式）。

use wd_core as wd;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UiPlatform {
    Douyin,
    Tiktok,
    Xiaohongshu,
    Instagram,
    X,
    Bilibili,
    Generic,
}

impl From<wd::Platform> for UiPlatform {
    fn from(p: wd::Platform) -> Self {
        match p {
            wd::Platform::Douyin => Self::Douyin,
            wd::Platform::Tiktok => Self::Tiktok,
            wd::Platform::Xiaohongshu => Self::Xiaohongshu,
            wd::Platform::Instagram => Self::Instagram,
            wd::Platform::X => Self::X,
            wd::Platform::Bilibili => Self::Bilibili,
            wd::Platform::Generic => Self::Generic,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UiMediaKind {
    Video,
    Image,
    LivePhoto,
    Audio,
}

impl From<wd::MediaKind> for UiMediaKind {
    fn from(k: wd::MediaKind) -> Self {
        match k {
            wd::MediaKind::Video => Self::Video,
            wd::MediaKind::Image => Self::Image,
            wd::MediaKind::LivePhoto => Self::LivePhoto,
            wd::MediaKind::Audio => Self::Audio,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiVariant {
    pub label: String,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub size: Option<u64>,
    pub ext: String,
}

#[derive(Debug, Clone)]
pub struct UiMediaItem {
    pub kind: UiMediaKind,
    pub thumbnail: Option<String>,
    pub variants: Vec<UiVariant>,
}

#[derive(Debug, Clone)]
pub struct UiMediaInfo {
    /// 解析结果编号，下载时传回来
    pub key: u64,
    pub platform: UiPlatform,
    pub platform_name: String,
    pub id: String,
    pub url: String,
    pub title: String,
    pub author: Option<String>,
    pub cover: Option<String>,
    pub duration_ms: Option<u64>,
    pub items: Vec<UiMediaItem>,
}

impl UiMediaInfo {
    pub(crate) fn from_info(key: u64, i: &wd::MediaInfo) -> Self {
        Self {
            key,
            platform: i.platform.into(),
            platform_name: i.platform.display_name().into(),
            id: i.id.clone(),
            url: i.url.clone(),
            title: i.title.clone(),
            author: i.author.clone(),
            cover: i.cover.clone(),
            duration_ms: i.duration_ms,
            items: i
                .items
                .iter()
                .map(|it| UiMediaItem {
                    kind: it.kind.into(),
                    thumbnail: it.thumbnail.clone(),
                    variants: it
                        .variants
                        .iter()
                        .map(|v| UiVariant {
                            label: v.label.clone(),
                            width: v.width,
                            height: v.height,
                            size: v.size,
                            ext: v.ext.clone(),
                        })
                        .collect(),
                })
                .collect(),
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct UiPick {
    pub item: u32,
    pub variant: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UiTaskStatus {
    Queued,
    Running,
    Done,
    Failed,
    Canceled,
}

impl From<wd::TaskStatus> for UiTaskStatus {
    fn from(s: wd::TaskStatus) -> Self {
        match s {
            wd::TaskStatus::Queued => Self::Queued,
            wd::TaskStatus::Running => Self::Running,
            wd::TaskStatus::Done => Self::Done,
            wd::TaskStatus::Failed => Self::Failed,
            wd::TaskStatus::Canceled => Self::Canceled,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiTask {
    pub id: u64,
    pub platform: UiPlatform,
    pub platform_name: String,
    pub source_url: String,
    pub title: String,
    pub author: Option<String>,
    pub cover: Option<String>,
    pub kind: UiMediaKind,
    pub variant_label: String,
    pub file_path: String,
    pub status: UiTaskStatus,
    pub downloaded: u64,
    pub total: u64,
    pub speed: u64,
    pub error: Option<String>,
    pub created_at: u64,
}

impl From<&wd::Task> for UiTask {
    fn from(t: &wd::Task) -> Self {
        Self {
            id: t.id,
            platform: t.platform.into(),
            platform_name: t.platform.display_name().into(),
            source_url: t.source_url.clone(),
            title: t.title.clone(),
            author: t.author.clone(),
            cover: t.cover.clone(),
            kind: t.kind.into(),
            variant_label: t.variant_label.clone(),
            file_path: t.file_path.clone(),
            status: t.status.into(),
            downloaded: t.downloaded,
            total: t.total,
            speed: t.speed,
            error: t.error.clone(),
            created_at: t.created_at,
        }
    }
}

#[derive(Debug, Clone)]
pub struct UiSettings {
    pub download_dir: String,
    pub per_platform_dir: bool,
    pub max_concurrent: u32,
    pub browser_headless: bool,
    pub browser_path: String,
    pub theme: String,
    pub watch_clipboard: bool,
    pub ui_scale: f64,
}

impl From<wd::Settings> for UiSettings {
    fn from(s: wd::Settings) -> Self {
        Self {
            download_dir: s.download_dir,
            per_platform_dir: s.per_platform_dir,
            max_concurrent: s.max_concurrent,
            browser_headless: s.browser_headless,
            browser_path: s.browser_path,
            theme: s.theme,
            watch_clipboard: s.watch_clipboard,
            ui_scale: s.ui_scale,
        }
    }
}

impl From<UiSettings> for wd::Settings {
    fn from(s: UiSettings) -> Self {
        Self {
            download_dir: s.download_dir,
            per_platform_dir: s.per_platform_dir,
            max_concurrent: s.max_concurrent,
            browser_headless: s.browser_headless,
            browser_path: s.browser_path,
            theme: s.theme,
            watch_clipboard: s.watch_clipboard,
            ui_scale: s.ui_scale,
        }
    }
}

/// 运行环境：解析用的浏览器、yt-dlp 是否可用
#[derive(Debug, Clone)]
pub struct UiEnv {
    pub version: String,
    pub data_dir: String,
    pub browser_path: Option<String>,
    pub ytdlp_path: Option<String>,
}

#[derive(Debug, Clone)]
pub enum UiEvent {
    Task(UiTask),
    TasksChanged,
    SettingsChanged,
}
