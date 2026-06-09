# Agent Notes

## Sync Upstream Code

Use this workflow when pulling useful changes from
`https://github.com/sw33tLie/macshot` into this fork.

Start by checking the local state:

```bash
git status --short --branch
git remote -v
git log --oneline --decorate --graph --max-count=40
```

Fetch upstream into a local reference:

```bash
git fetch https://github.com/sw33tLie/macshot.git main:refs/remotes/upstream/main --tags
```

Compare before applying anything:

```bash
git log --oneline --decorate --left-right --cherry-pick HEAD...upstream/main
git diff --name-status HEAD..upstream/main
```

Prefer cherry-picking selected upstream commits over merging or replacing the
fork. This fork has local behavior that upstream does not have. For the 4.1.2
sync, the intended upstream commits were:

```bash
git cherry-pick --no-commit 214a68d 9edfe66 0f8cc5c f90eaaf f83dfc1
git cherry-pick --no-commit 4283309
```

Resolve the expected `4283309` conflicts by keeping both local and upstream
settings:

- Keep `rightClickColorPaletteEnabled` and its Settings checkbox.
- Add `hideCaptureInstructions` and its Settings checkbox.
- Keep both localization strings when `Localizable.strings` has adjacent-line
  conflicts.

Do not cherry-pick `f6c7c4e` by default. This fork already has a richer
clipboard pin flow: current-selection pinning, Markdown toggling, text identity
caching, and color-card rendering. Only revisit `f6c7c4e` if rich HTML/RTF
clipboard pinning is explicitly needed.

After resolving conflicts:

```bash
rg -n "<<<<<<<|=======|>>>>>>>" macshot
git diff --cached --check
xcodebuild -project macshot.xcodeproj -scheme macshot -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

## Set The Local Package Version

The app version shown in built packages comes from
`macshot.xcodeproj/project.pbxproj`.

For the local 4.1.2 package, both Debug and Release should use:

```text
MARKETING_VERSION = 4.1.2;
CURRENT_PROJECT_VERSION = 79;
```

Check with:

```bash
rg -n "MARKETING_VERSION|CURRENT_PROJECT_VERSION" macshot.xcodeproj/project.pbxproj
```

## Build A Local Signed Release

This machine has no valid Apple code-signing identity. Build without Xcode
signing, then ad-hoc sign the copied app bundle. This is suitable for local use,
not public distribution or notarization.

Pick a timestamp:

```bash
STAMP="$(date +%Y%m%d-%H%M)"
DERIVED="/private/tmp/macshot-local-release-${STAMP}"
OUT="local-builds/macshot-local-signed-${STAMP}"
```

Build Release:

```bash
xcodebuild \
  -project macshot.xcodeproj \
  -scheme macshot \
  -configuration Release \
  -derivedDataPath "${DERIVED}" \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Copy the app and dSYM:

```bash
mkdir -p "${OUT}"
ditto "${DERIVED}/Build/Products/Release/macshot.app" "${OUT}/macshot.app"
ditto "${DERIVED}/Build/Products/Release/macshot.app.dSYM" "${OUT}/macshot.app.dSYM"
```

Ad-hoc sign nested Sparkle components first, then the framework, then the main
app with this project's entitlements:

```bash
codesign --force --sign - "${OUT}/macshot.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
codesign --force --sign - "${OUT}/macshot.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
codesign --force --sign - "${OUT}/macshot.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
codesign --force --sign - "${OUT}/macshot.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
codesign --force --sign - "${OUT}/macshot.app/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - --entitlements macshot/macshot.entitlements "${OUT}/macshot.app"
```

Create the zip:

```bash
(
  cd "${OUT}"
  ditto -c -k --sequesterRsrc --keepParent macshot.app "macshot-local-signed-${STAMP}.zip"
)
```

Verify the package:

```bash
/usr/libexec/PlistBuddy \
  -c "Print :CFBundleShortVersionString" \
  -c "Print :CFBundleVersion" \
  "${OUT}/macshot.app/Contents/Info.plist"

lipo -archs "${OUT}/macshot.app/Contents/MacOS/macshot"

codesign --verify --deep --strict --verbose=2 "${OUT}/macshot.app"

unzip -tq "${OUT}/macshot-local-signed-${STAMP}.zip"
```

Expected local 4.1.2 output:

- `CFBundleShortVersionString`: `4.1.2`
- `CFBundleVersion`: `79`
- architectures: `x86_64 arm64`
- `codesign --verify`: valid on disk and satisfies its designated requirement
