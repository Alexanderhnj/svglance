# SVGlance

SVGlance is a free, open-source macOS app that makes SVG files easier to see in Finder and in its built-in viewer.

macOS often previews SVGs on a plain white background. White or light SVGs can become invisible. SVGlance fixes the practical workflow by rendering SVGs on a checkerboard transparency background and by applying visible custom Finder icons to SVG files in folders you approve.

## Features

- SVG viewer with checkerboard background, fit-to-window scaling, zoom, rotation, reset, and transparent PNG export.
- Finder icon treatment for SVGs, including white SVGs that would otherwise disappear.
- Approved folder workflow for Desktop, Downloads, or any folder you choose.
- Local folder watching so new SVGs dropped into approved folders get updated automatically.
- Sandboxed macOS app with user-approved folder access.
- Modern Quick Look preview and thumbnail extensions for systems that route SVGs to SVGlance.

## Install

For a public release, download `SVGlance.dmg` from the GitHub Releases page, open it, and drag `SVGlance.app` to Applications.

On first launch, SVGlance asks you to approve folders it may scan and watch for SVG files. You can approve Desktop, Downloads, or a custom folder. Folder access can be removed from the menu bar app at any time.

## Privacy

SVGlance works locally on your Mac. It does not collect analytics, upload SVG files, or contact a server to render files. See [PRIVACY.md](PRIVACY.md).

## Known Limitations

- macOS may still route some Quick Look previews to Apple's built-in SVG renderer. SVGlance's most reliable user-facing behavior is the dedicated viewer and the custom Finder icon treatment.
- SVGlance can only scan and watch folders you approve through macOS folder permission prompts.
- SVGs with external stylesheet or network dependencies may not render exactly like they do in a browser.

## Development

Requirements:

- macOS 13 or later
- Xcode 15 or later
- Swift 5.9 or later

Build locally:

```sh
xcodebuild -project "SVG Glance.xcodeproj" -scheme SVGlance -configuration Debug build
```

Create a local release app bundle:

```sh
./scripts/build-release.sh
```

Package a DMG:

```sh
./scripts/package-dmg.sh
```

Release artifacts are written to `/private/tmp/svglance-release` by default to avoid Desktop/iCloud Finder metadata on signed app bundles. Set `SVGLANCE_RELEASE_DIR` to use another output folder.

Notarization requires a paid Apple Developer account and Developer ID signing credentials. See [release/README.md](release/README.md).

## Website

The GitHub Pages website lives in [docs](docs). Enable GitHub Pages from the `main` branch and `/docs` folder, then the download button will point to the latest uploaded `SVGlance.dmg` release asset.

## License

MIT License. See [LICENSE](LICENSE).
