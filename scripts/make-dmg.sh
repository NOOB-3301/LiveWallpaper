#!/usr/bin/env bash
# Packs an assembled PaperFlow.app into a DMG with an Applications shortcut, writes the SHA-256 next to it and
# checks that the DMG mounts and the app inside still verifies. No third-party tools: hdiutil, ditto, shasum.
#   scripts/make-dmg.sh [path/to/PaperFlow.app] [version]     ->  dist/PaperFlow-<version>.dmg (+ .sha256)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/PaperFlow.app}"
VERSION="${2:-dev}"
OUT_DIR="dist"
DMG="$OUT_DIR/PaperFlow-$VERSION.dmg"
test -d "$APP" || { echo "error: $APP not found (run ./build.sh first)" >&2; exit 1; }

STAGE="$(mktemp -d)"
MOUNT=""
cleanup() {
  if [[ -n "$MOUNT" ]]; then hdiutil detach "$MOUNT" -quiet -force || true; fi
  rm -rf "$STAGE"
}
trap cleanup EXIT

mkdir -p "$OUT_DIR"
ditto "$APP" "$STAGE/PaperFlow.app"      # keeps the signatures and extended attributes
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "PaperFlow $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG"

(cd "$OUT_DIR" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

# Mount it read-only and verify the bundle that users will actually get.
MOUNT="$(mktemp -d)"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" -quiet
codesign --verify --strict --deep "$MOUNT/PaperFlow.app"
test -L "$MOUNT/Applications"
hdiutil detach "$MOUNT" -quiet
MOUNT=""

echo "Created $DMG"
cat "$DMG.sha256"
