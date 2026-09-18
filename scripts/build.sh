#!/bin/bash
set -euo pipefail
ZDUO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ZDUO_ROOT"
export CLANG_MODULE_CACHE_PATH="$ZDUO_ROOT/.build/clang-module-cache"
ZDUO_SWIFT_OPTIONS=(--build-system native --disable-sandbox --cache-path "$ZDUO_ROOT/.build/cache" --config-path "$ZDUO_ROOT/.build/config" --security-path "$ZDUO_ROOT/.build/security")
swift build -c release "${ZDUO_SWIFT_OPTIONS[@]}"
ZDUO_BIN="$(swift build -c release --show-bin-path "${ZDUO_SWIFT_OPTIONS[@]}")"
ZDUO_APP="$ZDUO_ROOT/dist/ZDuo.app"
mkdir -p "$ZDUO_APP/Contents/MacOS" "$ZDUO_APP/Contents/Resources"
cp "$ZDUO_BIN/ZDuo" "$ZDUO_APP/Contents/MacOS/ZDuo"
cp "$ZDUO_ROOT/Support/Info.plist" "$ZDUO_APP/Contents/Info.plist"
# 应用包独立携带 shader，不依赖构建目录中的 SwiftPM 资源路径。
cp "$ZDUO_ROOT/Sources/ZDuo/Resources/Fold.metal" "$ZDUO_APP/Contents/Resources/Fold.metal"
cp "$ZDUO_ROOT/THIRD_PARTY_NOTICES.md" "$ZDUO_APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
codesign --force --sign - --identifier app.zduo.demo "$ZDUO_APP"
codesign --verify --strict "$ZDUO_APP"
printf '\nBuilt: %s\n' "$ZDUO_APP"
if [ "${1:-}" = "--run" ]; then
    open "$ZDUO_APP"
fi
