#!/usr/bin/env python3
"""冒烟测试：在每个平台上真正跑一遍命令行和桌面版。

用法：python tools/smoke.py --cli <wedl 路径> --app <桌面版可执行文件>

- 命令行：X（纯 HTTP）必须能解析并下载；借浏览器解析的平台（Instagram）只报告结果、不算失败，
  因为 CI 机房 IP 常被这些平台限制，但能顺带看出本机浏览器能否被找到并驱动。
- 桌面版：用 WEDOWNLOAD_AUTOTEST 启动，等任务列表里出现已完成的任务、文件确实落盘。
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# Windows 控制台默认 cp1252，打印中文 / emoji 会崩；统一用 UTF-8
for stream in (sys.stdout, sys.stderr):
    try:
        stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

X_URL = "https://x.com/Twitter/status/1600649710662213632"
BROWSER_URL = "https://www.instagram.com/natgeo/reel/DehZj9wggt0/"


def run(cmd, env=None, timeout=180):
    print("$", " ".join(cmd), flush=True)
    r = subprocess.run(cmd, env=env, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout)
    print(r.stdout[-2000:], r.stderr[-2000:], sep="\n", flush=True)
    return r.returncode


def check_cli(cli: str, work: Path) -> bool:
    env = dict(os.environ, WEDL_DATA_DIR=str(work / "cli-data"))
    ok = run([cli, "--info", X_URL], env) == 0
    out = work / "cli-out"
    ok = ok and run([cli, "-o", str(out), X_URL], env) == 0
    files = [p for p in out.glob("*.mp4") if p.stat().st_size > 100_000] if out.exists() else []
    print(f"CLI downloaded: {[p.name for p in files]}")
    ok = ok and len(files) > 0
    soft = run([cli, "--info", BROWSER_URL], env, timeout=240)
    print(f"[soft] browser-backed parse exit code: {soft}")
    return ok


def check_app(app: str, work: Path) -> bool:
    data = work / "app-data"
    data.mkdir(parents=True, exist_ok=True)
    # 下到临时目录，不碰真实的下载文件夹
    (data / "settings.json").write_text(
        json.dumps({"download_dir": str(work / "app-out"), "per_platform_dir": False, "watch_clipboard": False}),
        encoding="utf-8",
    )
    env = dict(os.environ, WEDOWNLOAD_DATA_DIR=str(data), WEDOWNLOAD_AUTOTEST=X_URL)
    print("$ launch", app, flush=True)
    log = open(work / "app.log", "w")
    proc = subprocess.Popen([app], env=env, stdout=log, stderr=subprocess.STDOUT)
    deadline = time.time() + 240
    done = []
    try:
        while time.time() < deadline:
            if proc.poll() is not None:
                print(f"app exited early with {proc.returncode}")
                break
            tasks_file = data / "tasks.json"
            if tasks_file.exists():
                try:
                    tasks = json.loads(tasks_file.read_text(encoding="utf-8"))
                except ValueError:
                    tasks = []
                done = [t for t in tasks if t.get("status") == "done" and Path(t["file_path"]).exists()]
                failed = [t for t in tasks if t.get("status") == "failed"]
                if failed:
                    print("failed tasks:", [t.get("error") for t in failed])
                    break
                if tasks and len(done) == len(tasks):
                    break
            time.sleep(2)
    finally:
        proc.terminate()
        try:
            proc.wait(10)
        except subprocess.TimeoutExpired:
            proc.kill()
        log.close()
    print((work / "app.log").read_text(encoding="utf-8", errors="replace")[-3000:])
    print(f"GUI downloaded: {[Path(t['file_path']).name for t in done]}")
    return len(done) > 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cli", required=True)
    ap.add_argument("--app")
    a = ap.parse_args()
    # 相对路径（如 macOS 的 lipo 产物 "wedl" 在仓库根目录）转成绝对路径，否则子进程按 PATH 找不到
    for attr in ("cli", "app"):
        v = getattr(a, attr)
        if v and os.path.exists(v):
            setattr(a, attr, os.path.abspath(v))
    work = Path(tempfile.mkdtemp(prefix="wd-smoke-"))
    results = {"cli": check_cli(a.cli, work)}
    if a.app:
        results["app"] = check_app(a.app, work)
    print("RESULTS", results, flush=True)
    sys.exit(0 if all(results.values()) else 1)


if __name__ == "__main__":
    main()
