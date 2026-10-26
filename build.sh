#!/usr/bin/env bash
# Builds build/PaperFlow.app (the UI) with the background service nested inside it at
#   Contents/Library/LoginItems/PaperFlowService.app   (plays wallpapers, menu bar item, Unix socket server;
#                                                           launched by the UI, optionally an SMAppService login item)
# The scene renderer is a static Rust library linked into the service, so nothing else is bundled.
# Everything is signed ad hoc, inner bundles first.
#   CONFIG=debug ./build.sh      debug build (default: release)
#   UNIVERSAL=1 ./build.sh       arm64 + x86_64 binaries
#   VERSION=1.2.3 ./build.sh     writes the version into both Info.plists (digits and dots only; default: as in the plists)
#   BUILD_NUMBER=45 ./build.sh   CFBundleVersion used with VERSION (default: VERSION itself)
set -euo pipefail
cd "$(dirname "$0")"

# On GitHub Actions a failing command becomes a visible annotation (the raw log is not always reachable).
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  trap 'echo "::error::build.sh failed at line $LINENO: $BASH_COMMAND"' ERR
fi

CONFIG="${CONFIG:-release}"
APP="build/PaperFlow.app"
HELPERS="$APP/Contents/Library/LoginItems"
SERVICE="$HELPERS/PaperFlowService.app"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

# Our own scene renderer (SceneRenderer/) has to exist before SwiftPM starts: SceneBridge links
# SceneRenderer/target/release/libscene_renderer.a and compiles the generated Sources/SceneBridge
# bindings. UNIVERSAL=1 builds it for both architectures.
UNIVERSAL="${UNIVERSAL:-0}" scripts/build-scene-renderer.sh

# The expansion form keeps an empty array safe under `set -u` on macOS's bash 3.2.
# Only the two bundled products, so targets that are not bundled never break the bundle build.
for product in PaperFlow PaperFlowService; do
  swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product "$product"
done
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" \
         "$SERVICE/Contents/MacOS" "$SERVICE/Contents/Resources"

cp "$BIN_DIR/PaperFlow" "$APP/Contents/MacOS/PaperFlow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cp "$BIN_DIR/PaperFlowService" "$SERVICE/Contents/MacOS/PaperFlowService"
cp Resources/Service-Info.plist "$SERVICE/Contents/Info.plist"
printf 'APPL????' > "$SERVICE/Contents/PkgInfo"

# Version injection: the same version in both bundles (the UI can compare the running service's version with its own).
if [[ -n "${VERSION:-}" ]]; then
  for plist in "$APP/Contents/Info.plist" "$SERVICE/Contents/Info.plist"; do
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$plist"
    plutil -replace CFBundleVersion -string "${BUILD_NUMBER:-$VERSION}" "$plist"
  done
fi

plutil -lint "$APP/Contents/Info.plist" "$SERVICE/Contents/Info.plist"

# Guards. Executable targets link their library targets statically, so a library is detected by the module name
# that Swift embeds in symbol names ("<length><name>", e.g. 11SceneEngine). The service may use Metal (scenes via
# SceneBridge), so only SwiftUI and the old Swift scene engine are checked.
SERVICE_BIN="$SERVICE/Contents/MacOS/PaperFlowService"
SERVICE_LIBS="$(otool -L "$SERVICE_BIN")"
echo "--- libraries linked by the service ---"
echo "$SERVICE_LIBS"
if grep -q "SwiftUI" <<<"$SERVICE_LIBS"; then
  echo "::error::PaperFlowService links SwiftUI; the service must stay AppKit only."
  exit 1
fi
if grep -Eq "11SceneEngine|11SceneFormat" <<<"$(strings -a "$SERVICE_BIN")"; then
  echo "::error::PaperFlowService contains SceneEngine or SceneFormat code; scenes go through SceneBridge."
  exit 1
fi
SETTINGS_BIN="$APP/Contents/MacOS/PaperFlow"
if grep -q "11SceneEngine" <<<"$(strings -a "$SETTINGS_BIN")"; then
  echo "::error::the Settings app contains SceneEngine code; it may use SceneFormat (parsing) but never the renderer."
  exit 1
fi

# A release that still loads anything from Homebrew only runs on the machine that built it.
if otool -L "$SERVICE_BIN" | grep -Eq '/opt/homebrew|/usr/local/(opt|Cellar)'; then
  echo "::error::PaperFlowService still loads dylibs from Homebrew:"
  otool -L "$SERVICE_BIN" | grep -E '/opt/homebrew|/usr/local/(opt|Cellar)'
  exit 1
fi

# Sign the nested helper, then the outer app. No --deep: each bundle is signed on its own.
codesign --force --sign - "$SERVICE"
codesign --force --sign - "$APP"
codesign --verify --strict --deep "$APP"

echo "Built $APP (with $SERVICE)"
echo "Run it with: open $APP"
