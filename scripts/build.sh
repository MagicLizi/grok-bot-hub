#!/usr/bin/env zsh
# 编译并打包成 build/Grok Bot Hub.app（ad-hoc 签名，只在本机使用）。
# 用法：scripts/build.sh [release|debug]   加 --install 会同时复制到 /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    release|debug) CONFIG=$arg ;;
    --install) INSTALL=1 ;;
    *) echo "未知参数：$arg" >&2; exit 1 ;;
  esac
done

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/GrokBotHub"

mkdir -p build
if [[ ! -f build/AppIcon.icns ]]; then
  swift scripts/make-icon.swift build/icon-1024.png
  ICONSET=build/AppIcon.iconset
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
  rm -rf "$ICONSET"
fi

APP="build/Grok Bot Hub.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GrokBotHub"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "已生成：$PWD/$APP"

if [[ $INSTALL == 1 ]]; then
  TARGET="/Applications/Grok Bot Hub.app"
  if pgrep -x GrokBotHub >/dev/null; then
    echo "Grok Bot Hub 正在运行，请先退出再安装" >&2
    exit 1
  fi
  rm -rf "$TARGET"
  ditto "$APP" "$TARGET"
  echo "已安装到：$TARGET"
fi
