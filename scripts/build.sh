#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
mkdir -p .build dist
swift build -c release --product SimpleRecorder --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security"
# Sign outside Documents: file providers may reattach Finder metadata mid-signing.
build_stage=$(mktemp -d "${TMPDIR:-/tmp}/light-recorder-build.XXXXXX")
trap 'rm -rf "$build_stage"' EXIT
app="$build_stage/轻录.app"
packaged="$PWD/.build/packaged/轻录.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/SimpleRecorder "$app/Contents/MacOS/SimpleRecorder.new"
mv -f "$app/Contents/MacOS/SimpleRecorder.new" "$app/Contents/MacOS/SimpleRecorder"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/LightRecorder.icns "$app/Contents/Resources/LightRecorder.icns"
cp Resources/AppIcon.png "$app/Contents/Resources/AppIcon.png"
# Finder/iCloud may add legacy metadata to a local .app; it invalidates resource signing.
# Remove only these generated-bundle metadata fields, preserving any quarantine attributes.
xattr -rd com.apple.FinderInfo "$app" 2>/dev/null || true
xattr -rd com.apple.ResourceFork "$app" 2>/dev/null || true
# A designated requirement keeps this local app's identity stable across ad-hoc builds.
codesign --force --sign - --identifier cn.local.lightrecorder --requirements '=designated => identifier "cn.local.lightrecorder"' "$app"
codesign --verify --strict "$app"
python3 scripts/package.py "$app" "$PWD/dist/轻录-mac.zip"
mkdir -p "$PWD/.build/packaged"
rm -rf "$packaged"
ditto --norsrc --noextattr "$app" "$packaged"
printf '%s\n' "构建完成：$packaged"
printf '%s\n' "安装包：$PWD/dist/轻录-mac.zip"
