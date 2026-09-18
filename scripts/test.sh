#!/bin/bash
set -euo pipefail
ZDUO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ZDUO_ROOT"
export CLANG_MODULE_CACHE_PATH="$ZDUO_ROOT/.build/clang-module-cache"
# 独立 Command Line Tools 的 Testing.framework 不在 SwiftPM native 的默认搜索路径中。
ZDUO_DEVELOPER="$(xcode-select -p)"
ZDUO_TEST_FRAMEWORKS="$ZDUO_DEVELOPER/Library/Developer/Frameworks"
if [ ! -d "$ZDUO_TEST_FRAMEWORKS/Testing.framework" ]; then
    ZDUO_TEST_FRAMEWORKS="$ZDUO_DEVELOPER/Platforms/MacOSX.platform/Developer/Library/Frameworks"
fi
swift test --build-system native --disable-sandbox --disable-xctest --enable-swift-testing \
    --cache-path "$ZDUO_ROOT/.build/cache" --config-path "$ZDUO_ROOT/.build/config" --security-path "$ZDUO_ROOT/.build/security" \
    -Xswiftc -F -Xswiftc "$ZDUO_TEST_FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$ZDUO_TEST_FRAMEWORKS"
