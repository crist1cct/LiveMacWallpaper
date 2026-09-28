# Live Mac Wallpaper (LMW)

Native macOS app that keeps a local library of images and videos and applies them
independently to the **Desktop**, the **Screen Saver** and the **Lock Screen**, per
display. Written in Swift 6 with SwiftUI, AppKit, AVFoundation and ExtensionKit.

| | |
|---|---|
| Version | 1.7.0 (build 170) |
| Bundle identifier | `com.livemacwallpaper.app` |
| Requires | macOS 15 Sequoia or later (Lock Screen video: macOS 26 Tahoe or later) |
| Architectures | Universal: `arm64` and `x86_64` |
| Distribution | Developer ID, Hardened Runtime, notarized DMG (not Mac App Store) |

## Features

- **Media library.** Local import (open panel, drag and drop, `⌘O`) and single-video
  YouTube import. Originals are never modified; the app works on prepared copies,
  deduplicated by SHA-256.
- **Three independent destinations.** Desktop, Screen Saver and Lock Screen each have
  their own selection, display target and audio settings. A destination can also
  follow another one (`Screen Saver → Desktop`, `Lock Screen → Screen Saver`).
- **Per-display targeting.** Each destination runs on all displays or on one display
  identified by a stable UUID that survives reboots and reconnects.
- **Video on the Desktop** with optional audio, paused per display whenever that
  display's desktop is covered by a window, and in Low Power Mode.
- **Screen Saver** module that plays an automatically optimized copy (up to 4K/60,
  hardware decoded) and is always muted.
- **Lock Screen video on macOS 26** through a native wallpaper extension hosted by
  `WallpaperAgent`, with optional audio that plays only while the session is locked.
- **Automatic format compatibility.** AVFoundation first; a bundled LGPL FFmpeg
  helper converts formats AVFoundation can't decode (e.g. VP9 4K in MP4).
- **Launch at login** for the Desktop renderer through `SMAppService`.

## Architecture

The Xcode project is generated from `project.yml` with XcodeGen. Shared logic lives in
the `WallpaperCore` Swift package.

| Target | Type | Role |
|---|---|---|
| `LiveMacWallpaper` | app | UI, library management, import, configuration and apply |
| `WallpaperCore` | Swift package | domain model, media pipeline, persistence, Desktop engines, YouTube import, Lock Screen store inspection |
| `WallpaperRenderer` | login item app | keeps the Desktop video running after login and without the main app |
| `LiveMacWallpaperExtension` | ExtensionKit extension (macOS 26) | Lock Screen / wallpaper provider rendered inside `WallpaperAgent` |
| `LiveMacWallpaperScreenSaver` | `.saver` bundle | `ScreenSaverView` player |
| `LoginWallpaperInstaller` | command-line tool | privileged helper that removes Login Window integrations installed by older versions |

```
Apps/
  LiveMacWallpaper/            SwiftUI app
  WallpaperRenderer/         Desktop login item
  LoginWallpaperInstaller/   privileged cleanup tool
  LoginWallpaperRenderer/    legacy Login Window renderer (not built)
Extensions/
  LiveMacWallpaperExtension/   macOS 26 wallpaper extension (Lock Screen)
  LiveMacWallpaperScreenSaver/
Sources/WallpaperCore/       shared package
Tests/WallpaperCoreTests/    Swift Testing suite
Tools/                       packaging, FFmpeg helper build, icon generation
Vendor/                      pinned third-party helpers and licenses
```

### Desktop

- **Images** are applied with `NSWorkspace.setDesktopImageURL(_:for:options:)` for each
  target `NSScreen`, then read back per screen to confirm the change.
- **Video** uses one borderless, click-through `NSWindow` per display at
  `CGWindowLevelForKey(.desktopIconWindow) - 1` (above the desktop picture, below Finder
  icons), joined to all Spaces, with `AVQueuePlayer` + `AVPlayerLooper` +
  `AVPlayerLayer` for a gapless loop.
- Playback and audio stop on a display whose desktop is fully covered by a window and
  resume when it becomes visible again. Low Power Mode, screen sleep and session
  changes pause playback.
- The renderer reports back the exact list of displays it started on; the app only
  reports success when that list matches the request.

### Screen Saver

- `ScreenSaverView` subclass with an `AVPlayerLayer`, always muted.
- Configuration and media are written to a sandbox-compatible runtime store in
  `/Users/Shared/Live Mac Wallpaper` and verified after writing, because the screen
  saver host can't read the app's container.
- On apply, the app creates a playback copy matched to the target display
  (1080p or 4K, at most 60 fps, HEVC/H.264). The library original is not touched and
  the copy is reused on later applies.

### Lock Screen (macOS 26)

The Lock Screen is served by a wallpaper extension (`WallpaperExtensionKit`) that
`WallpaperAgent` hosts over XPC. The extension renders into a remote `CAContext`, so
authentication UI, Touch ID and the password field remain fully owned by macOS.
Nothing is drawn above the login window.

- **Decoding** uses `AVAssetReader` → `AVSampleBufferDisplayLayer` driven by a
  `CMTimebase`. Loops are gapless: the next reader is preloaded and sample timestamps
  are offset by the previous loop's end, so the timeline never resets.
- **Playback policy** eases the timebase rate in (2 s) when the lock screen appears and
  out (6 s) when it leaves, then drops into a deep pause that releases decoder
  resources. Waking from deep pause resumes at the exact position inside the current
  loop.
- **Power-aware variants** play a reduced frame-rate variant under reduced or minimal
  playback policies.
- **Audio.** The display layer has no audio path, so `LockScreenAudioController` plays
  the same clip in an audio-only `AVQueuePlayer` and slaves it to the video clock:
  - the renderer exposes a thread-safe loop clock (loop start times plus a timeline
    generation), so the audio compares against the exact position inside the
    displayed loop rather than `timebase mod duration`;
  - audio stays silent until the video clock runs at normal speed, then joins with a
    0.45 s equal-power fade;
  - drift is measured at 30 Hz, smoothed, and corrected by trimming the playback rate
    by at most ±3 % with the `.timeDomain` pitch algorithm, so pitch is preserved;
  - a seek happens only on start, on a new clip, or after a sustained jump of more than
    350 ms. It happens behind a 120 ms fade-out and targets the measured seek latency;
  - volume is cut synchronously on unlock, sleep or suspend before teardown, so
    audio can't leak into the unlocked session.
- On macOS 15, Lock Screen video isn't available; everything else works.

### Media pipeline

1. Validate the file type (`UTType`) and the presence of a readable video track or
   image.
2. Copy into a unique staging directory and compute a SHA-256 checksum. Duplicates
   are rejected.
3. Read duration, dimensions, transform, codec and frame rate asynchronously.
4. Prepare a playback file with `AVAssetExportSession` according to the import quality:

   | Quality | Result |
   |---|---|
   | Efficient | up to 1080p |
   | Native (default) | up to 4K |
   | Original | passthrough when already compatible |

5. If AVFoundation can't produce a playable file, fall back to the bundled FFmpeg
   helper (H.264, no audio, scaled to the quality tier).
6. Generate a thumbnail and a poster frame, then move the item atomically into the
   library.

Import phases are reported to the UI as they happen; unknown progress is shown as
indeterminate.

### YouTube import

- Accepts HTTPS URLs for a single video, Short, archived Live or `youtu.be` link.
  Playlists and look-alike domains are rejected locally, before any network access.
- Metadata (title, channel, duration, thumbnail) is read first. Download starts only
  after the user confirms they are authorized to download the content.
- Uses a pinned, checksum-verified `yt-dlp` binary embedded in the app. It runs with
  separate `Process` arguments (no shell), `--ignore-config`, `--no-playlist`, no
  cookies, no sign-in and no DRM circumvention.
- Selects the best available video and audio (`bestvideo*+bestaudio/best`, sorted by
  resolution, frame rate and HDR). The result then goes through the normal media
  pipeline.
- Limits: 2 hours and a maximum file size, both enforced before the item enters the
  library.

### Persistence

Everything lives under `~/Library/Application Support/<bundle-id>/`:

| Path | Content |
|---|---|
| `Library.json` | versioned media manifest |
| `Media/<UUID>/` | prepared file, thumbnail and poster per item |
| `Runtime/Current.json` | active profile (runtime schema 2) read by the helper processes |
| `Staging/` | in-flight imports |
| `Backups/` | state needed to restore system wallpaper settings |

All JSON files are written atomically. Schema 1 configurations (`targetDisplayIDs`) are
migrated automatically to schema 2 (`DisplayTarget.all` / `.display(UUID)`). A display
that is no longer connected is never silently replaced by another one.

## App usage

| Action | Shortcut |
|---|---|
| Import files | `⌘O` |
| Import from YouTube | `⇧⌘U` |
| Search | `⌘F` |
| Home / Library / Settings | `⌘1` / `⌘2` / `⌘3` |
| Lock the screen with the configured wallpaper | `⇧⌘L` |
| Apply the whole profile | `⌘↩` |
| On a wallpaper page: apply / close | `↩` / `Esc` |

Clicking any wallpaper opens its page, where you pick the destination, displays and
sound and apply with a single button. Right-click any wallpaper to set it directly on
a destination.

## Building

Requirements: Xcode 26, XcodeGen.

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project LiveMacWallpaper.xcodeproj -scheme LiveMacWallpaper build
```

The wallpaper extension must be run from a signed app in `/Applications`; macOS
registers it on first launch. With an Apple Development certificate `WallpaperAgent`
may refuse the extension ("This wallpaper can't be opened"); use Developer ID for
builds that run on other Macs.

## Testing

```sh
swift test
```

The `WallpaperCoreTests` suite (Swift Testing, 30 tests) covers the media library,
media processing, profile validation, display targeting, runtime configuration
migration, the Screen Saver runtime store, YouTube URL validation and import, and the
Lock Screen store inspector.

## Packaging

```sh
Tools/package_release.sh
```

The script verifies the pinned helper checksums, generates the project, builds both
architectures, assembles and signs the bundles, verifies the signatures, builds the
DMG and writes a SHA-256 checksum next to it.

Signed and notarized build:

```sh
SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
NOTARY_PROFILE="lmw-notary" \
Tools/package_release.sh
```

In this mode the script uses a secure timestamp, submits the DMG with `notarytool`,
staples the ticket and validates it. See [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md).

## Upgrading from Wallpaper Studio

The project was previously called Wallpaper Studio (`com.wallpaperstudio.*`). On first
launch, Live Mac Wallpaper:

- moves the library from `~/Library/Application Support/com.wallpaperstudio.app` to
  `~/Library/Application Support/com.livemacwallpaper.app` when the new location
  doesn't exist yet;
- copies the import quality and Lock Screen signature preferences from the old defaults
  domain;
- removes `~/Library/Screen Savers/Wallpaper Studio.saver` (to the Trash) the next time
  the Screen Saver module is installed.

Because the bundle identifiers changed, macOS treats it as a new app: turn **Launch at
Login** on again and re-apply the Lock Screen once so the new wallpaper extension is
selected. The privileged cleanup tool still recognizes the system paths and launchd
labels installed by older versions.

## Limitations

- Apple has no public API for an independent Lock Screen video. The Lock Screen
  integration relies on the macOS 26 wallpaper extension host and may need updates
  after system updates.
- Before the first login after boot (FileVault pre-boot), macOS owns the screen
  completely and no user process can play video.
- The Screen Saver is always muted by design.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): design principles, safety rules and
  the backend-to-UI contract
- [docs/RESEARCH.md](docs/RESEARCH.md): platform research and the macOS APIs used
- [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md): build, signing and notarization
- [CHANGELOG.md](CHANGELOG.md): release history

## Third-party components

- **Phosphene** (MIT). The wallpaper extension is derived from it; see
  `Vendor/Phosphene-MIT.txt`.
- **FFmpeg 9.0.1** (LGPL 2.1+). Minimal universal helper built from the official
  source by `Tools/build_ffmpeg_helper.sh`, with no GPL components. The DMG ships the
  license, the matching source archive and its checksum.
- **yt-dlp 2026.08.19** (Unlicense). Pinned release, verified by SHA-256; see
  `Vendor/README.md`.
