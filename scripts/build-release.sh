#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/SVG Glance.xcodeproj"
SCHEME="SVGlance"
BUILD_DIR="${SVGLANCE_RELEASE_DIR:-/private/tmp/svglance-release}"
ARCHIVE_PATH="$BUILD_DIR/SVGlance.xcarchive"
APP_OUTPUT="$BUILD_DIR/SVGlance.app"

mkdir -p "$BUILD_DIR"

echo "Archiving $SCHEME..."
xcodebuild archive \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  SKIP_INSTALL=NO

APP_IN_ARCHIVE="$ARCHIVE_PATH/Products/Applications/SVGlance.app"
if [[ ! -d "$APP_IN_ARCHIVE" ]]; then
  echo "Could not find archived app at: $APP_IN_ARCHIVE" >&2
  exit 1
fi

rm -rf "$APP_OUTPUT"
ditto "$APP_IN_ARCHIVE" "$APP_OUTPUT"
xattr -cr "$APP_OUTPUT"
while IFS= read -r item; do
  xattr -d com.apple.FinderInfo "$item" 2>/dev/null || true
  xattr -d "com.apple.fileprovider.fpfs#P" "$item" 2>/dev/null || true
done < <(find "$APP_OUTPUT" -print)

echo "Release app ready:"
echo "  $APP_OUTPUT"
echo
echo "For public distribution, sign with Developer ID and notarize before publishing."
