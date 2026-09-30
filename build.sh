#!/usr/bin/env bash
# Builds LiveWallpaper and wraps it into build/LiveWallpaper.app (ad-hoc signed).
#   CONFIG=debug ./build.sh      debug build (default: release)
#   UNIVERSAL=1 ./build.sh       arm64 + x86_64 binary
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP="build/LiveWallpaper.app"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

# The expansion form keeps an empty array safe under `set -u` on macOS's bash 3.2.
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/LiveWallpaper" "$APP/Contents/MacOS/LiveWallpaper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

echo "Built $APP"
echo "Run it with: open $APP"
