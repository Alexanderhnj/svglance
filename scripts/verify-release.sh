#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${SVGLANCE_RELEASE_DIR:-/private/tmp/svglance-release}"
APP_PATH="${1:-$BUILD_DIR/SVGlance.app}"
DMG_PATH="${2:-$BUILD_DIR/SVGlance.dmg}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App not found: $APP_PATH" >&2
  exit 1
fi

echo "Checking bundle identifiers..."
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
QL_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/PlugIns/SVGlanceQuickLook.appex/Contents/Info.plist")"
THUMB_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/PlugIns/SVGlanceThumbnail.appex/Contents/Info.plist")"

[[ "$APP_ID" == "com.svglance.app" ]] || { echo "Unexpected app bundle ID: $APP_ID" >&2; exit 1; }
[[ "$QL_ID" == "com.svglance.app.quicklook" ]] || { echo "Unexpected Quick Look bundle ID: $QL_ID" >&2; exit 1; }
[[ "$THUMB_ID" == "com.svglance.app.thumbnail" ]] || { echo "Unexpected thumbnail bundle ID: $THUMB_ID" >&2; exit 1; }

echo "Checking embedded extensions..."
[[ -d "$APP_PATH/Contents/PlugIns/SVGlanceQuickLook.appex" ]] || { echo "Missing Quick Look extension" >&2; exit 1; }
[[ -d "$APP_PATH/Contents/PlugIns/SVGlanceThumbnail.appex" ]] || { echo "Missing thumbnail extension" >&2; exit 1; }
[[ ! -e "$APP_PATH/Contents/PlugIns/SVGlanceQLGenerator.qlgenerator" ]] || { echo "Legacy generator should not be shipped" >&2; exit 1; }

echo "Checking app icon..."
[[ -f "$APP_PATH/Contents/Resources/AppIcon.icns" ]] || { echo "Missing AppIcon.icns" >&2; exit 1; }

echo "Checking code signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "Checking entitlements..."
codesign -d --entitlements :- "$APP_PATH" >/tmp/svglance-entitlements.plist 2>/dev/null || {
  echo "Could not read app entitlements" >&2
  exit 1
}
grep -q "com.apple.security.app-sandbox" /tmp/svglance-entitlements.plist || {
  echo "App sandbox entitlement not found" >&2
  exit 1
}

if [[ -f "$DMG_PATH" ]]; then
  echo "Checking DMG..."
  hdiutil verify "$DMG_PATH"

  if xcrun stapler validate "$DMG_PATH" >/dev/null 2>&1; then
    echo "DMG staple validation passed."
  else
    echo "DMG is not stapled or notarization is not available yet."
  fi
fi

if spctl -a -vv --type execute "$APP_PATH"; then
  echo "Gatekeeper app check passed."
else
  echo "Gatekeeper app check did not pass. This is expected before Developer ID notarization."
fi

echo "Release verification complete."
