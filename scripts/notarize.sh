#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DMG_PATH="${1:-${SVGLANCE_RELEASE_DIR:-/private/tmp/svglance-release}/SVGlance.dmg}"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG not found: $DMG_PATH" >&2
  exit 1
fi

if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait
elif [[ -n "${APPLE_ID:-}" && -n "${TEAM_ID:-}" && -n "${APP_SPECIFIC_PASSWORD:-}" ]]; then
  xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_SPECIFIC_PASSWORD" \
    --wait
else
  cat >&2 <<'EOF'
Missing notarization credentials.

Use one of these options:

1. Stored keychain profile:
   xcrun notarytool store-credentials "SVGlance Notary"
   NOTARYTOOL_PROFILE="SVGlance Notary" ./scripts/notarize.sh

2. Environment variables:
   APPLE_ID="you@example.com" TEAM_ID="TEAMID1234" APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx" ./scripts/notarize.sh
EOF
  exit 1
fi

xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

echo "Notarized and stapled:"
echo "  $DMG_PATH"
