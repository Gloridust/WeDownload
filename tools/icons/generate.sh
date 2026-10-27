#!/usr/bin/env bash
# 由 logo.svg 生成各平台图标（需要 rsvg-convert 与 ImageMagick）。图形与 app/lib/ui/brand.dart 一致，改动时两处一起改。
set -euo pipefail
cd "$(dirname "$0")"
APP=../../app
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
for s in 16 24 32 48 64 128 256 512 1024; do
  rsvg-convert -w $s -h $s logo.svg -o "$TMP/$s.png"
done
# Windows
convert "$TMP"/{16,24,32,48,64,128,256}.png "$APP/windows/runner/resources/app_icon.ico"
# macOS
MAC="$APP/macos/Runner/Assets.xcassets/AppIcon.appiconset"
for s in 16 32 64 128 256 512 1024; do cp "$TMP/$s.png" "$MAC/app_icon_$s.png"; done
# Linux：窗口图标与 .desktop 用
mkdir -p "$APP/linux/data"
cp "$TMP/256.png" "$APP/linux/data/app_icon.png"
cp logo.svg "$APP/linux/data/io.github.gloridust.WeDownload.svg"
echo "icons generated"
