#!/usr/bin/env bash
# 安装到当前用户目录（不需要 root）：
#   程序 ~/.local/opt/wedownload，命令 ~/.local/bin/wedownload（及 wedl），菜单项与图标
# 用法：在解压后的目录里运行 ./install.sh；卸载：./install.sh --uninstall
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OPT="$HOME/.local/opt/wedownload"
BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"
ICONS="$HOME/.local/share/icons/hicolor"
ID=io.github.gloridust.WeDownload

refresh() {
  update-desktop-database "$APPS" 2>/dev/null || true
  gtk-update-icon-cache -f -t "$ICONS" 2>/dev/null || true
}

if [[ "${1:-}" == "--uninstall" ]]; then
  rm -rf "$OPT" "$BIN/wedownload" "$BIN/wedl" "$APPS/$ID.desktop" \
    "$ICONS/256x256/apps/$ID.png" "$ICONS/scalable/apps/$ID.svg"
  refresh
  echo "已卸载（下载的文件和 ~/.local/share/wedownload 里的设置保留）"
  exit 0
fi

# 找 bundle：发布包里程序在当前目录，源码树里在 build 目录
SRC="$HERE"
[[ -x "$SRC/wedownload" ]] || SRC="$HERE/../../build/linux/x64/release/bundle"
[[ -x "$SRC/wedownload" ]] || { echo "没找到 wedownload 程序"; exit 1; }
DATA="$HERE"
[[ -f "$DATA/$ID.desktop" ]] || DATA="$HERE"

rm -rf "$OPT" && mkdir -p "$OPT" "$BIN" "$APPS" "$ICONS/256x256/apps" "$ICONS/scalable/apps"
cp -a "$SRC"/. "$OPT"/
ln -sf "$OPT/wedownload" "$BIN/wedownload"
[[ -x "$OPT/wedl" ]] && ln -sf "$OPT/wedl" "$BIN/wedl"
cp "$DATA/$ID.desktop" "$APPS/$ID.desktop"
sed -i "s#^Exec=.*#Exec=$OPT/wedownload#" "$APPS/$ID.desktop"
cp "$OPT/data/app_icon.png" "$ICONS/256x256/apps/$ID.png"
[[ -f "$DATA/$ID.svg" ]] && cp "$DATA/$ID.svg" "$ICONS/scalable/apps/$ID.svg"
refresh
echo "已安装：在应用菜单里搜索 WeDownload，或运行 wedownload"
