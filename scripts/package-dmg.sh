#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${SVGLANCE_RELEASE_DIR:-/private/tmp/svglance-release}"
APP_PATH="${1:-$BUILD_DIR/SVGlance.app}"
DMG_PATH="${2:-$BUILD_DIR/SVGlance.dmg}"
STAGE_DIR="$BUILD_DIR/dmg-stage"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App not found: $APP_PATH" >&2
  echo "Run ./scripts/build-release.sh first, or pass an app path." >&2
  exit 1
fi

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

ditto "$APP_PATH" "$STAGE_DIR/SVGlance.app"
ln -s /Applications "$STAGE_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "SVGlance" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "DMG ready:"
echo "  $DMG_PATH"
echo
echo "Notarize before publishing:"
echo "  ./scripts/notarize.sh \"$DMG_PATH\""
