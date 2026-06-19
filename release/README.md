# SVGlance Release Checklist

This checklist is for the GitHub + DMG release flow.

## One-Time Manual Setup

1. Enroll in the Apple Developer Program if you want a normal public macOS install experience.
2. In Xcode, create or download a `Developer ID Application` certificate.
3. Configure notarization credentials:
   - preferred: `xcrun notarytool store-credentials`
   - alternative: environment variables used by `scripts/notarize.sh`
4. Create the public GitHub repository.
5. Confirm the app, docs, and website links point to `https://github.com/Alexanderhnj/svglance`.

Without Developer ID signing and notarization, users can still download the app, but macOS Gatekeeper may block or warn heavily on launch.

## Build

```sh
./scripts/build-release.sh
```

Expected output:

- `/private/tmp/svglance-release/SVGlance.xcarchive`
- `/private/tmp/svglance-release/SVGlance.app`

To use a different release output folder:

```sh
SVGLANCE_RELEASE_DIR="/path/to/release-folder" ./scripts/build-release.sh
```

## Package DMG

```sh
./scripts/package-dmg.sh
```

Expected output:

- `/private/tmp/svglance-release/SVGlance.dmg`

The package script uses `release/dmg-background.png` for a branded drag-to-Applications window when Finder automation is available. To force a plain DMG, run:

```sh
SVGLANCE_SKIP_DMG_STYLING=1 ./scripts/package-dmg.sh
```

## Notarize

Using a stored notarytool profile:

```sh
NOTARYTOOL_PROFILE="SVGlance Notary" ./scripts/notarize.sh
```

Using Apple ID credentials:

```sh
APPLE_ID="you@example.com" TEAM_ID="TEAMID1234" APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx" ./scripts/notarize.sh
```

## Verify

```sh
./scripts/verify-release.sh
```

For a fully public release, the verification should pass signing checks and Gatekeeper checks after notarization and stapling.

## GitHub Release

1. Update `CHANGELOG.md` date for `1.0.0`.
2. Commit and tag:

```sh
git tag v1.0.0
```

3. Create a GitHub release named `SVGlance 1.0.0`.
4. Upload `/private/tmp/svglance-release/SVGlance.dmg`.
5. Include the SHA-256 checksum:

```sh
shasum -a 256 /private/tmp/svglance-release/SVGlance.dmg
```

## Homebrew Later

After the GitHub release exists, create a cask with:

- app name: `SVGlance`
- bundle ID: `com.svglance.app`
- URL: GitHub release DMG URL
- SHA-256: checksum from the uploaded DMG
