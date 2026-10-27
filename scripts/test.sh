#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift build -c release --product RecorderSelfTest --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security"
mkdir -p artifacts
python3 -m unittest discover -s Tests -p 'TranscriptionWorkerTests.py'
.build/release/RecorderSelfTest --report "$PWD/artifacts/self-test-report.json"
