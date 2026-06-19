#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${SVGLANCE_RELEASE_DIR:-/private/tmp/svglance-release}"
APP_PATH="${1:-$BUILD_DIR/SVGlance.app}"
DMG_PATH="${2:-$BUILD_DIR/SVGlance.dmg}"
STAGE_DIR="$BUILD_DIR/dmg-stage"
RW_DMG_PATH="$BUILD_DIR/SVGlance-rw.dmg"
MOUNT_DIR=""
BACKGROUND_PATH="$ROOT_DIR/release/dmg-background.png"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App not found: $APP_PATH" >&2
  echo "Run ./scripts/build-release.sh first, or pass an app path." >&2
  exit 1
fi

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

ditto "$APP_PATH" "$STAGE_DIR/SVGlance.app"
ln -s /Applications "$STAGE_DIR/Applications"

rm -f "$DMG_PATH" "$RW_DMG_PATH"

hdiutil create \
  -volname "SVGlance" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDRW \
  "$RW_DMG_PATH"

ATTACH_OUTPUT="$(hdiutil attach "$RW_DMG_PATH" -nobrowse -noverify -noautoopen)"
MOUNT_DIR="$(printf '%s\n' "$ATTACH_OUTPUT" | awk '/\/Volumes\// { for (i = 3; i <= NF; i++) { printf "%s%s", $i, (i < NF ? OFS : ORS) } exit }')"

if [[ -z "$MOUNT_DIR" || ! -d "$MOUNT_DIR" ]]; then
  echo "Could not find mounted DMG volume." >&2
  printf '%s\n' "$ATTACH_OUTPUT" >&2
  exit 1
fi

cleanup_mount() {
  if [[ -n "$MOUNT_DIR" ]] && mount | grep -q "$MOUNT_DIR"; then
    hdiutil detach "$MOUNT_DIR" >/dev/null || hdiutil detach "$MOUNT_DIR" -force >/dev/null || true
  fi
}
trap cleanup_mount EXIT

mkdir -p "$MOUNT_DIR/.background"
if [[ -f "$BACKGROUND_PATH" ]]; then
  cp "$BACKGROUND_PATH" "$MOUNT_DIR/.background/dmg-background.png"
fi

if [[ "${SVGLANCE_SKIP_DMG_STYLING:-0}" != "1" && -f "$BACKGROUND_PATH" ]]; then
  STYLE_LOG="$BUILD_DIR/dmg-style.log"
  STYLE_SCRIPT="$BUILD_DIR/dmg-style.applescript"
  cat > "$STYLE_SCRIPT" <<APPLESCRIPT
tell application "Finder"
  tell disk "SVGlance"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {120, 120, 780, 540}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 96
    set background picture of viewOptions to file ".background:dmg-background.png"
    set position of item "SVGlance.app" of container window to {158, 230}
    set position of item "Applications" of container window to {505, 230}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

  osascript "$STYLE_SCRIPT" >"$STYLE_LOG" 2>&1 &
  STYLE_PID=$!
  STYLE_STATUS=0
  STYLE_SECONDS=0
  while kill -0 "$STYLE_PID" >/dev/null 2>&1; do
    if [[ "$STYLE_SECONDS" -ge 12 ]]; then
      kill "$STYLE_PID" >/dev/null 2>&1 || true
      STYLE_STATUS=124
      break
    fi
    sleep 1
    STYLE_SECONDS=$((STYLE_SECONDS + 1))
  done

  if [[ "$STYLE_STATUS" -eq 0 ]]; then
    wait "$STYLE_PID" || STYLE_STATUS=$?
  else
    wait "$STYLE_PID" >/dev/null 2>&1 || true
  fi

  if [[ "$STYLE_STATUS" -ne 0 ]]; then
    echo "Finder styling skipped; DMG contents are still valid."
    if [[ "$STYLE_STATUS" -eq 124 ]]; then
      echo "  Finder styling timed out."
    elif [[ -s "$STYLE_LOG" ]]; then
      sed 's/^/  /' "$STYLE_LOG"
    fi
  fi
fi

sync
cleanup_mount
trap - EXIT

hdiutil convert "$RW_DMG_PATH" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_PATH" >/dev/null

rm -f "$RW_DMG_PATH"

echo "DMG ready:"
echo "  $DMG_PATH"
echo
echo "Notarize before publishing:"
echo "  ./scripts/notarize.sh \"$DMG_PATH\""
