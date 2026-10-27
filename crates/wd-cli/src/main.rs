//! 命令行：`wedl <链接或分享文案> [-o 目录] [--info] [--json] [--all]`
//! 默认下载每条媒体的第一个（最佳）版本；--info 只显示解析结果。

use std::path::PathBuf;
use std::time::Duration;

use anyhow::Result;
use wd_core::{Core, Event, Selection, TaskStatus};

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_writer(std::io::stderr)
        .init();
    let mut args = std::env::args().skip(1);
    let mut input = Vec::new();
    let (mut out, mut info_only, mut json, mut all) = (None::<PathBuf>, false, false, false);
    while let Some(a) = args.next() {
        match a.as_str() {
            "-o" | "--output" => out = args.next().map(PathBuf::from),
            "--info" => info_only = true,
            "--json" => json = true,
            "--all" => all = true,
            "-h" | "--help" => {
                println!("用法：wedl <链接或分享文案> [-o 目录] [--info] [--json] [--all]");
                return Ok(());
            }
            _ => input.push(a),
        }
    }
    let input = input.join(" ");
    if input.trim().is_empty() {
        anyhow::bail!("请提供链接，见 wedl --help");
    }
    let data_dir = std::env::var_os("WEDL_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("wedl-cli"));
    let core = Core::new(data_dir)?;
    if let Some(o) = out {
        let mut s = core.settings();
        s.download_dir = o.to_string_lossy().into_owned();
        s.per_platform_dir = false;
        core.update_settings(s)?;
    }
    let t0 = std::time::Instant::now();
    let info = match core.extract(&input).await {
        Ok(i) => i,
        Err(e) => {
            core.shutdown().await;
            return Err(e);
        }
    };
    eprintln!("解析用时 {:.1}s", t0.elapsed().as_secs_f64());
    if json {
        println!("{}", serde_json::to_string_pretty(&info)?);
    } else {
        println!("[{}] {} — {}", info.platform.display_name(), info.title, info.author.as_deref().unwrap_or("?"));
        for (i, it) in info.items.iter().enumerate() {
            println!("  #{} {:?}", i + 1, it.kind);
            for v in &it.variants {
                let size = v.size.map(|s| format!(" {:.1} MB", s as f64 / 1048576.0)).unwrap_or_default();
                println!("     - {}{}  .{}", v.label, size, v.ext);
            }
        }
    }
    if info_only {
        core.shutdown().await;
        return Ok(());
    }
    // 默认不下背景音乐，--all 全下
    let picks: Vec<Selection> = info
        .items
        .iter()
        .enumerate()
        .filter(|(_, it)| all || it.kind != wd_core::MediaKind::Audio)
        .map(|(i, _)| Selection { item: i, variant: 0 })
        .collect();
    let mut rx = core.subscribe();
    let ids = core.enqueue(&info, &picks)?;
    let mut left = ids.len();
    while left > 0 {
        match tokio::time::timeout(Duration::from_secs(120), rx.recv()).await {
            Ok(Ok(Event::Task(t))) if ids.contains(&t.id) => match t.status {
                TaskStatus::Running => eprint!(
                    "\r  {} {:.1}/{:.1} MB  {:.1} MB/s   ",
                    t.id,
                    t.downloaded as f64 / 1048576.0,
                    t.total as f64 / 1048576.0,
                    t.speed as f64 / 1048576.0
                ),
                TaskStatus::Done => {
                    eprintln!("\r  ✓ {}", t.file_path);
                    left -= 1;
                }
                TaskStatus::Failed | TaskStatus::Canceled => {
                    eprintln!("\r  ✗ {}: {}", t.file_path, t.error.unwrap_or_default());
                    left -= 1;
                }
                _ => {}
            },
            Ok(Ok(_)) | Ok(Err(tokio::sync::broadcast::error::RecvError::Lagged(_))) => {}
            _ => break,
        }
    }
    core.shutdown().await;
    Ok(())
}
