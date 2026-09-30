#!/usr/bin/env bash
# Builds build/LiveWallpaper.app (the Settings app) with the wallpaper agent nested inside it at
#   Contents/Library/LoginItems/LiveWallpaperAgent.app
# and signs everything ad hoc, inner bundle first.
#   CONFIG=debug ./build.sh      debug build (default: release)
#   UNIVERSAL=1 ./build.sh       arm64 + x86_64 binaries
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP="build/LiveWallpaper.app"
AGENT="$APP/Contents/Library/LoginItems/LiveWallpaperAgent.app"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

# The expansion form keeps an empty array safe under `set -u` on macOS's bash 3.2.
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" \
         "$AGENT/Contents/MacOS" "$AGENT/Contents/Resources"

cp "$BIN_DIR/LiveWallpaper" "$APP/Contents/MacOS/LiveWallpaper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cp "$BIN_DIR/LiveWallpaperAgent" "$AGENT/Contents/MacOS/LiveWallpaperAgent"
cp Resources/Agent-Info.plist "$AGENT/Contents/Info.plist"
printf 'APPL????' > "$AGENT/Contents/PkgInfo"

plutil -lint "$APP/Contents/Info.plist" "$AGENT/Contents/Info.plist"

# RAM plan guard: the agent is AppKit only. SwiftUI in it is a hard error, Combine only a warning.
AGENT_LIBS="$(otool -L "$AGENT/Contents/MacOS/LiveWallpaperAgent")"
if grep -q "SwiftUI" <<<"$AGENT_LIBS"; then
  echo "error: LiveWallpaperAgent links SwiftUI; the agent must stay AppKit only." >&2
  exit 1
fi
if grep -q "Combine" <<<"$AGENT_LIBS"; then
  echo "warning: LiveWallpaperAgent links Combine; something imports it (check Core and the agent files)." >&2
fi

# Sign the nested agent first, then the outer app. No --deep: each bundle is signed on its own.
codesign --force --sign - "$AGENT"
codesign --force --sign - "$APP"
codesign --verify --strict --deep "$APP"

echo "Built $APP (with $AGENT)"
echo "Run it with: open $APP"
