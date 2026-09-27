# Technical research

Last verified: September 5, 2026.

## Summary

The three destinations don't have the same level of support in macOS:

| Destination | Implementation | Stability |
|---|---|---|
| Desktop image | `NSWorkspace.setDesktopImageURL` | public Apple API |
| Desktop video | AppKit window at Desktop level + AVFoundation | public APIs, own compositing |
| Screen Saver | `.saver` bundle with `ScreenSaverView` | Apple framework, external install |
| Independent Lock Screen | wallpaper provider for the `Idle` branch | private integration |

Desktop and Screen Saver playback form the stable base. The independent Lock Screen
is an isolated module with verification and restore.

## What Apple provides publicly

### Desktop image

`NSWorkspace` can read and set the Desktop image for a given `NSScreen`; the call must
be made on the main thread.

Source: https://developer.apple.com/documentation/appkit/nsworkspace/desktopimageurl(for:)

### Video preparation and playback

AVFoundation provides:

- `AVAssetExportSession` for conversion;
- HEVC presets for 1080p, 4K and highest quality;
- `AVQueuePlayer` and `AVPlayerLooper` for looping;
- `AVAssetImageGenerator` for asynchronous thumbnails and posters.

Sources:

- https://developer.apple.com/documentation/avfoundation/avassetexportsession
- https://developer.apple.com/documentation/avfoundation/export-presets
- https://developer.apple.com/documentation/avfoundation/exporting-video-to-alternative-formats
- https://developer.apple.com/documentation/avfoundation/avplayerlooper
- https://developer.apple.com/documentation/avfoundation/avassetimagegenerator/generatecgimageasynchronously(for:completionhandler:)

### Wallpaper window

Core Graphics defines the `desktopWindow` and `desktopIconWindow` levels. AppKit lets
windows join all Spaces and stay stationary in Mission Control. Together they allow a
video above the desktop picture and below the Finder icons.

Sources:

- https://developer.apple.com/documentation/coregraphics/cgwindowlevelkey
- https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct

### Screen Saver

Apple documents `.saver` bundles installed in a `Library/Screen Savers` directory, with
a `ScreenSaverView` subclass. The documentation recommends a universal binary for
`arm64` and `x86_64`.

Source: https://developer.apple.com/documentation/screensaver

### Launch at login

On macOS 13+, `SMAppService` is the recommended API for login items, LaunchAgents and
LaunchDaemons bundled with the app. Registration remains subject to user approval.

Source: https://developer.apple.com/documentation/servicemanagement/smappservice

### User-selected files

Apple recommends `fileImporter` or `NSOpenPanel`. Persistent access in the App Sandbox
needs security-scoped bookmarks. Wallpaper Studio copies media into Application
Support, so it doesn't depend on later access to the original file.

Source: https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox

### Energy and lifecycle

`NSWorkspace` posts notifications for sleep/wake, session changes and Spaces.
`ProcessInfo` exposes Low Power Mode and the thermal state. Instruments provides Time
Profiler, Energy/Power Profiler and File Activity.

Sources:

- https://developer.apple.com/documentation/appkit/nsworkspace
- https://developer.apple.com/documentation/foundation/processinfo
- https://developer.apple.com/documentation/xcode/improving-your-app-s-performance

## The Lock Screen limitation

Apple's public Lock Screen documentation covers security, timeouts, the password,
the message and the clock appearance. It offers no public API to set an independent
Lock Screen video. This conclusion comes from the available documentation. It doesn't
prove that Apple has no internal mechanism.

Source: https://support.apple.com/guide/mac-help/change-lock-screen-settings-on-mac-mh11784/mac

On macOS 26.6 the wallpaper store has separate `Desktop` and `Idle` branches under
`AllSpacesAndDisplays` and `SystemDefault`. The separation therefore exists
internally, but the format is not public API and can change with a macOS update.

macOS 26 also hosts wallpaper providers as ExtensionKit extensions inside
`WallpaperAgent`, which renders them into a remote `CAContext` under the
authentication UI. Wallpaper Studio's Lock Screen video uses this path. The provider
draws only its own layer, and the password field, Touch ID and every security control
stay with the system.

### Locked session vs. cold boot

There are two technically different moments:

1. After `⌃⌘Q` or when returning from the Screen Saver, the user session already
   exists and the native wallpaper provider can play video under the authentication
   controls. This is the Lock Screen video feature.
2. Right after boot, especially with FileVault, the user session and its agents
   aren't running yet and home-folder files may be unavailable. No user process can
   play video in that phase.

The app never uses its own window above the system shielding level.

## Open-source projects reviewed

### Wallpaper Sync

https://github.com/GonzaloRojas14/Wallpaper-Sync

Validated patterns: Desktop video through `AVPlayer` in a window below the icons,
one-time HEVC conversion, one player per display, pause on lock and sleep, Aerial
configuration and `Idle` branch updates with backup and restore.

Risks observed: runtime dependency on FFmpeg and Homebrew, restarting Apple processes,
editing private wallpaper-store formats, and writing a cold-boot poster to a system
location.

### LivePaper

https://github.com/Raunik2/LivePaper

Validated patterns: `AVQueuePlayer` + `AVPlayerLooper` + `AVPlayerLayer`, per-display
windows, reacting to Spaces, sleep and wake, a static snapshot fallback, and a health
check for the private integration.

Not adopted: a window raised above the Lock Screen shielding level, automatic
installation of downloaded binaries, and Screen Saver preferences changed without a
clear separation between stable and private integrations.

### VideoScreenSaver

https://github.com/GeneralD/VideoScreenSaver

Validated patterns: `ScreenSaverView` with `AVPlayerLayer`, muted aspect-fill playback,
complete cleanup in `stopAnimation`, and a preview/config sheet in the Screen Saver
host.

### Phosphene

The macOS 26 wallpaper extension (sample-buffer renderer, XPC handlers, playback
policy) is derived from Phosphene under the MIT license; see `Vendor/Phosphene-MIT.txt`.

## Distribution

The Mac App Store requires the App Sandbox and forbids installing code into shared
locations, auto-start without consent, and root privileges. The full feature set
therefore targets Developer ID distribution outside the Store. A Developer ID build
needs valid signatures, Hardened Runtime and notarization (`notarytool` and stapling).

Sources:

- https://developer.apple.com/app-store/review/guidelines/
- https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution
- https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution

## Toolchain

- macOS 26.6 on Apple Silicon, Xcode 26.6, macOS SDK 26.5, Swift 6.3.3.
- XcodeGen 2.46.0 generates the multi-target project from `project.yml`. It is a
  development tool and is not shipped.
- `yt-dlp` 2026.8.19, embedded as a pinned helper.
- A minimal universal FFmpeg helper built from the official 9.0.1 source. Users never
  need to install FFmpeg.

## Tool decisions

### XcodeGen

A project with an app, a login item, an extension, a `.saver`, a CLI tool and tests is
hard to maintain by hand in `project.pbxproj`. XcodeGen produces it reproducibly from
a readable `project.yml`.

https://github.com/yonaskolb/XcodeGen

### FFmpeg as a fallback

A real test with a VP9 3840×2160 MP4 showed that AVFoundation can inspect the track,
but it refuses the HEVC/H.264 presets and can't extract a poster. The app therefore
tries the Apple conversion first. Only when that can't produce a playable file does it
call the minimal FFmpeg helper, which transcodes the track to H.264 without audio.

The helper is built universal for `arm64` and `x86_64` with an LGPL 2.1+ configuration
and no GPL components. The DMG ships the license, the matching source archive, its
checksum and the reproducible build script.

https://ffmpeg.org/legal.html

### YouTube import

The YouTube Terms of Service prohibit downloading content except where the service
expressly authorizes it or the required written permissions exist. The YouTube API
policies forbid API clients from downloading, importing, backing up, caching or storing
copies of audiovisual content without prior approval. The feature therefore requires
an explicit confirmation. It doesn't try to bypass authentication or DRM, and it
never uses the YouTube Data API.

- https://www.youtube.com/static?template=terms
- https://developers.google.com/youtube/terms/developer-policies

`yt-dlp` provides JSON metadata (`--dump-single-json`), line-based progress output and
a universal macOS binary. The binary can be isolated inside the app bundle instead of
depending on Homebrew. The backend passes `--ignore-config`, `--no-playlist`, a
unique temporary directory and separate `Process` arguments.

- https://github.com/yt-dlp/yt-dlp/blob/master/README.md
- https://github.com/yt-dlp/yt-dlp/releases

### Tests

Swift Testing for unit and integration tests, with anonymized property-list fixtures
for the Lock Screen store inspector.

- https://developer.apple.com/documentation/testing

### Logging

`Logger` from OSLog, with sensitive values private by default.

https://developer.apple.com/documentation/os/logging/
