#!/usr/bin/env bash
# Checks the layout of an assembled PaperFlow.app: the settings app and its background service, executables,
# ids, matching versions, ad-hoc signatures that verify, the linked scene renderer and no Homebrew load paths.
# Used by build.yml and release.yml.
#   scripts/verify-bundle.sh [path/to/PaperFlow.app] [expected-version]
set -euo pipefail
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  trap 'echo "::error::verify-bundle.sh failed at line $LINENO: $BASH_COMMAND"' ERR
fi
APP="${1:-build/PaperFlow.app}"
EXPECTED_VERSION="${2:-}"
SERVICE="$APP/Contents/Library/LoginItems/PaperFlowService.app"

fail() { echo "::error::$*"; echo "error: $*" >&2; exit 1; }

test -x "$APP/Contents/MacOS/PaperFlow" || fail "missing Settings executable"
test -x "$SERVICE/Contents/MacOS/PaperFlowService" || fail "missing service executable"

plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"; }

[[ "$(plist "$APP" CFBundleIdentifier)" == "com.noob3301.LiveWallpaper" ]] || fail "Settings bundle id"
[[ "$(plist "$SERVICE" CFBundleIdentifier)" == "com.noob3301.LiveWallpaper.service" ]] || fail "service bundle id"
[[ "$(plist "$APP" LWRole)" == "settings" ]] || fail "Settings LWRole"
[[ "$(plist "$SERVICE" LWRole)" == "service" ]] || fail "service LWRole"
[[ -n "$(plist "$APP" NSAudioCaptureUsageDescription 2>/dev/null || true)" ]] || fail "Settings Info.plist is missing NSAudioCaptureUsageDescription"
[[ -n "$(plist "$SERVICE" NSAudioCaptureUsageDescription 2>/dev/null || true)" ]] || fail "service Info.plist is missing NSAudioCaptureUsageDescription"

V_APP="$(plist "$APP" CFBundleShortVersionString)"
[[ "$(plist "$SERVICE" CFBundleShortVersionString)" == "$V_APP" ]] || fail "service version differs from the app"
if [[ -n "$EXPECTED_VERSION" && "$V_APP" != "$EXPECTED_VERSION" ]]; then
  fail "version is $V_APP, expected $EXPECTED_VERSION"
fi

codesign --verify --strict --deep "$APP" || fail "codesign verify (app)"
codesign --verify --strict "$SERVICE" || fail "codesign verify (service)"

# Anything loaded from Homebrew would only run on a Mac that happens to have it.
if otool -L "$SERVICE/Contents/MacOS/PaperFlowService" | grep -Eq '/opt/homebrew|/usr/local/(opt|Cellar)'; then
  otool -L "$SERVICE/Contents/MacOS/PaperFlowService" | grep -E '/opt/homebrew|/usr/local/(opt|Cellar)' >&2
  fail "the service still loads dylibs from Homebrew (not distributable)"
fi

# The scene renderer (SceneRenderer/) is a static library, so it leaves no dylib to check. Its UniFFI
# entry points are prefixed; release builds may strip the symbol table, so fall back to strings.
SERVICE_BIN="$SERVICE/Contents/MacOS/PaperFlowService"
# grep -c reads to the end: with pipefail, grep -q would stop early and fail the pipe with SIGPIPE.
if ! nm "$SERVICE_BIN" 2>/dev/null | grep -c 'uniffi_scene_renderer' >/dev/null; then
  if ! strings -a "$SERVICE_BIN" | grep -c 'uniffi_scene_renderer' >/dev/null; then
    fail "the service does not contain SceneRenderer (no uniffi_scene_renderer symbols)"
  fi
fi
echo "--- SceneRenderer linked into the service ---"

echo "--- version $V_APP ---"
for bin in "$APP/Contents/MacOS/PaperFlow" "$SERVICE/Contents/MacOS/PaperFlowService"; do
  echo "$(basename "$bin"): $(lipo -archs "$bin")  $(du -h "$bin" | cut -f1)"
done
echo "--- libraries linked by the service ---"
otool -L "$SERVICE/Contents/MacOS/PaperFlowService"
echo "bundle layout OK"
