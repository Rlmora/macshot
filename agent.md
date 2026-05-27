# Agent Notes

## Local Release Build

Run from the repository root:

```bash
xcodebuild \
  -project macshot.xcodeproj \
  -scheme macshot \
  -configuration Release \
  -derivedDataPath /private/tmp/macshot-local-release \
  -clonedSourcePackagesDirPath /private/tmp/macshot-source-packages \
  -disableAutomaticPackageResolution \
  build
```

The built app is generated at:

```text
/private/tmp/macshot-local-release/Build/Products/Release/macshot.app
```

This command reuses the existing Swift Package cache under
`/private/tmp/macshot-source-packages`. Use this when the network cannot resolve
GitHub or when you want to avoid downloading Sparkle/libwebp/WebP again.

Known notes:

- The app is signed with Xcode's local run signing identity, usually
  `Sign to Run Locally`; this is suitable for local use, not public
  distribution/notarization.
- If `/private/tmp/macshot-source-packages` is missing, Xcode may try to fetch
  packages from GitHub. Restore/populate that cache first, or run with working
  network access.
- Release builds may emit Swift warnings, including Swift 6 concurrency
  warnings and unused-variable warnings. These do not block local app generation
  unless `xcodebuild` exits with a non-zero status.
- Before moving the app into `/Applications`, verify the output path exists:

```bash
ls -la /private/tmp/macshot-local-release/Build/Products/Release/macshot.app
```

Optional verification:

```bash
/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleShortVersionString' \
  -c 'Print :CFBundleVersion' \
  /private/tmp/macshot-local-release/Build/Products/Release/macshot.app/Contents/Info.plist

lipo -archs /private/tmp/macshot-local-release/Build/Products/Release/macshot.app/Contents/MacOS/macshot

codesign --verify --deep --strict --verbose=2 \
  /private/tmp/macshot-local-release/Build/Products/Release/macshot.app
```
