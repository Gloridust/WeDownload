//! WeDownload 内核：把各平台的分享链接解析成可下载的媒体，并管理下载队列。

pub mod browser;
pub mod download;
pub mod engine;
pub mod extractors;
pub mod model;
pub mod util;

pub use engine::{Core, Event, Selection, Settings, Task, TaskStatus};
pub use model::*;
