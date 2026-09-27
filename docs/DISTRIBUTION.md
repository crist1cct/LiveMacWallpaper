# Build and distribution

## Artifact

- Format: DMG containing the app and a shortcut to `/Applications`
- Architectures: Apple Silicon (`arm64`) and Intel (`x86_64`)
- Contents: app, Desktop renderer (login item), wallpaper extension (macOS 26),
  Screen Saver module, legacy-integration cleanup tool, YouTube helper and universal
  FFmpeg helper
- Deployment target: macOS 15 (extension: macOS 26)
- Signing for QA builds: Apple Development
- Notarization: requires a `Developer ID Application` certificate and a `notarytool`
  keychain profile

On first launch from `/Applications` the app registers the Wallpaper Studio wallpaper
provider with macOS and clears any stale explicit registration before applying. For
distribution to other people an Apple Development signature is not enough: use
Developer ID and notarization, otherwise `WallpaperAgent` can refuse the extension even
though the main app opens.

## Building the package

```sh
Tools/package_release.sh
```

The script:

1. checks the required tools (`curl`, `xcodegen`, `xcodebuild`, `codesign`, `hdiutil`,
   `lipo`, `shasum`, `osascript`);
2. downloads the pinned `yt-dlp_macos` release if missing and verifies its SHA-256;
3. verifies the FFmpeg source archive checksum and embeds the helper, its license and
   source;
4. generates the Xcode project and builds `arm64` + `x86_64`;
5. assembles and signs every bundle, then verifies the signatures;
6. creates the DMG with its window layout and background, and writes
   `<name>.dmg.sha256`.

## Public distribution

After installing the Developer ID certificate and creating a `notarytool` profile:

```sh
SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
NOTARY_PROFILE="wallpaper-studio-notary" \
Tools/package_release.sh
```

In this mode the script signs with a secure timestamp, submits the DMG to Apple,
staples the notarization ticket and validates it.

## Release checklist

- `swift test` passes (30 tests).
- Debug and universal Release builds succeed for every target in the scheme.
- `codesign --verify --deep --strict` succeeds for the app and all embedded bundles.
- `lipo -archs` reports `arm64 x86_64` for the app, renderer, extension and Screen Saver
  executables.
- The embedded YouTube helper starts and reports the pinned version.
- The Screen Saver bundle loads and exposes its principal class.
- A schema 1 runtime configuration migrates to schema 2.
- The renderer reports exactly the displays it started on; the app rejects the apply
  if the answer differs from the request.
- Desktop playback and audio stop on a covered display and resume when the desktop is
  visible again.
- Lock Screen: after `⌃⌘Q` the video plays under the native authentication UI; with
  audio enabled, sound fades in once the picture reaches normal speed, plays without
  dropouts across several loops, and stops immediately on unlock.
- The DMG passes `hdiutil verify` and its SHA-256 matches the published checksum.
