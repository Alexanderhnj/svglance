# Contributing

Thanks for considering a contribution to SVGlance.

## Local Setup

Requirements:

- macOS 13 or later
- Xcode 15 or later
- Swift 5.9 or later

Build:

```sh
xcodebuild -project "SVG Glance.xcodeproj" -scheme SVGlance -configuration Debug build
```

Release build:

```sh
./scripts/build-release.sh
```

## Guidelines

- Keep the app sandboxed.
- Do not add package dependencies unless they are clearly justified.
- Keep SVG rendering local.
- Be careful with folder access. SVGlance should only scan user-approved folders.
- Document user-facing limitations clearly, especially macOS Quick Look routing behavior.

## Useful Manual Tests

- White SVG on transparent background is visible.
- Colored SVG remains visible and centered.
- SVG without `viewBox` but with `width` and `height` scales correctly.
- Malformed SVG shows a fallback message.
- SVG over 10 MB shows a fallback message.
- New SVGs dropped into approved folders receive Finder icon treatment.
