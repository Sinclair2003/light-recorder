#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
./scripts/build.sh
appdir="$HOME/Applications"
target="$appdir/轻录.app"
stage="$appdir/.LightRecorder-install-$$.app"
mkdir -p "$appdir"
if pgrep -f "$target/Contents/MacOS/SimpleRecorder" >/dev/null; then
  printf '%s\n' '请先退出正在运行的轻录，再运行安装脚本。' >&2
  exit 1
fi
if [[ -e "$target" ]]; then
  identity=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist")
  if [[ "$identity" != "cn.local.lightrecorder" ]]; then
    printf '%s\n' '目标位置已有其他同名应用，未作修改。' >&2
    exit 1
  fi
fi
ditto --norsrc --noextattr "$PWD/.build/packaged/轻录.app" "$stage"
codesign --verify --strict "$stage"
if [[ -e "$target" ]]; then
  mv "$target" "$appdir/.LightRecorder-backup-$(date +%Y%m%d-%H%M%S).app"
fi
mv "$stage" "$target"
codesign --verify --strict "$target"
printf '%s\n' "安装完成：$target"
