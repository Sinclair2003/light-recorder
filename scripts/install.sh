#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ "${LIGHTRECORDER_USE_EXISTING_PACKAGE:-}" != "1" ]]; then
  ./scripts/build.sh
fi
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
if [[ -n "${LIGHTRECORDER_FUNASR_ENGINE:-}" || "${LIGHTRECORDER_USE_EXISTING_PACKAGE:-}" == "1" ]]; then
  extract_stage=$(mktemp -d "${TMPDIR:-/tmp}/light-recorder-unpack.XXXXXX")
  trap 'rm -rf "$extract_stage"' EXIT
  /usr/bin/ditto -x -k "$PWD/dist/轻录-mac.zip" "$extract_stage"
  mv "$extract_stage/轻录.app" "$stage"
else
  ditto --norsrc --noextattr "$PWD/.build/packaged/轻录.app" "$stage"
fi
codesign --verify --strict "$stage"
stage_identity=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$stage/Contents/Info.plist")
if [[ "$stage_identity" != "cn.local.lightrecorder" ]]; then
  printf '%s\n' '安装包中的应用标识不匹配，未作修改。' >&2
  exit 1
fi
if [[ -e "$target" ]]; then
  mv "$target" "$appdir/.LightRecorder-backup-$(date +%Y%m%d-%H%M%S).app"
fi
mv "$stage" "$target"
codesign --verify --strict "$target"
printf '%s\n' "安装完成：$target"
