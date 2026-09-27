# Architecture and design principles

This document describes how Wallpaper Studio is structured and the rules the
implementation follows. For the API-level research behind it see
[RESEARCH.md](RESEARCH.md).

## Goals

- One personal library of images and videos, applied independently to the Desktop,
  the Screen Saver and the Lock Screen.
- Lock Screen video is played by a native macOS component behind the authentication
  UI after `⌃⌘Q` or when returning from the Screen Saver. An in-app preview, or a
  window that imitates the Lock Screen, doesn't count.
- No accounts, no analytics. The network is used only when the user starts a YouTube
  import.

## Principles

1. Features built on public Apple APIs are the default and must be stable.
2. Integrations that touch macOS internals are isolated. They verify their result and
   can always be restored.
3. The app never hides, covers or intercepts the macOS authentication UI. There are no
   windows at shielding level and nothing above the login window.
4. Import never modifies the user's original file; the app works only on its own copies.
5. Conversion, thumbnail generation and file I/O run off the main thread.
6. Video pauses or degrades when the display sleeps, the session is inactive, Low Power
   Mode is on or the thermal state is elevated.
7. Nothing is inferred on unknown macOS versions: an unrecognized wallpaper store
   format means no write.

## Components

| Module | Responsibility |
|---|---|
| `MediaLibrary` | catalog actor, folders and metadata, atomic manifest writes |
| `MediaProcessing` / `NativeMediaProcessor` | inspection, copy, transcoding, poster and thumbnail, FFmpeg fallback |
| `YouTubeImportService` | strict URL validation, metadata, single-video download through an isolated helper |
| `DesktopImageService` | static Desktop images through `NSWorkspace` |
| `DesktopVideoEngine` / `DesktopImageOverlayEngine` | per-display AppKit windows at Desktop level |
| `ScreenSaverRuntimeStore` | configuration and media for the `.saver` host |
| `RuntimeConfigurationStore` | versioned JSON profile shared with helper processes |
| `LockScreenStoreInspector` / `LockScreenExperimentalService` | read-only compatibility checks and backup/restore of wallpaper store state |
| `WallpaperBackend` | single facade the app's view model talks to |
| Wallpaper extension | `VideoRenderer`, `PlaybackPolicy`, `ShuffleController`, `LockScreenAudioController` inside `WallpaperAgent` |

The SwiftUI layer talks only to `AppModel`, which calls `WallpaperBackend`. Views never
touch files, helper processes or system stores directly.

## Destination model

Each destination has a `DestinationConfiguration`:

- `selection`: `media(UUID)`, `follow(destination)`, `systemDefault` or `off`;
- `displayTarget`: `all` or `display(UUID)`;
- `scaling` (fill / fit / stretch), `zoom`, normalized horizontal and vertical position;
- `muteVideo`, `volume`, `pauseInLowPowerMode`.

`ProfileValidator` rejects follow cycles and references to deleted media before
anything is applied. Applying one destination merges only that destination into the
active profile. Destinations that follow it are re-applied too.

## Apply pipeline

1. Validate the profile.
2. Write the versioned runtime configuration atomically.
3. Apply each requested destination.
4. Read the result back from the system (renderer display list, Desktop image URL per
   screen, Screen Saver runtime store, Lock Screen provider selection).
5. Report success only if the read-back matches the request; otherwise surface the
   exact error on the affected destination.

## Lock Screen playback

`VideoRenderer` feeds `AVAssetReader` samples into an `AVSampleBufferDisplayLayer`
controlled by a `CMTimebase`:

- **Gapless loop.** The next reader is prepared ahead of time. At the loop boundary
  every sample's DTS and PTS are offset by the previous loop's end (`ptsOffset`), so
  the timebase never resets.
- **Loop clock.** Each loop start is recorded, with a timeline generation that changes
  on a clip switch or error reset. `clockSample()` returns the position inside the
  loop currently on screen, the timebase rate and the generation. It is safe to call
  from any thread.
- **Policy ramps.** Rate eases 0 → 1 over 2 s when the lock screen appears and
  1 → 0 over 6 s when it goes away. Ramps start from the current rate, so a reversal
  mid-ramp stays continuous.
- **Deep pause.** After a paused period the pipeline is torn down. A seamless resume
  restarts the reader at `timebase − current loop start` and keeps the running
  timeline.

`LockScreenAudioController` state machine (serial queue, 30 Hz tick):

| Phase | Behaviour |
|---|---|
| `waiting` | player paused, gain 0, waiting for video rate ≥ 0.97 |
| `preparingSeek` | fading out (120 ms) before a seek |
| `seeking(token)` | exact seek to `loop position + measured seek latency`; stale completions are ignored |
| `playing` | fade in (450 ms, equal-power), smoothed drift → rate trim, clamped to ±3 %, 12 ms dead band |

A new generation, a clip change, or a drift above 350 ms sustained for three ticks
(at most once every 1.5 s) returns the controller to `preparingSeek`. `stopImmediately()`
zeroes the volume synchronously from any thread before the asynchronous teardown.

## Safety rules

- No shell commands built from user-provided names or paths; processes get separate
  argument arrays.
- Foundation APIs for copying, hashing and property lists.
- No automatic download of executables at runtime; bundled helpers are pinned and
  checksum-verified at packaging time.
- YouTube import uses no playlists, browser cookies, sign-in, DRM circumvention or
  helper configuration files, and validates scheme, exact host and path before
  starting a process.
- No passwords are requested or stored. The single administrator prompt is used only to
  remove system-level integrations installed by older versions.
- Logs don't include full paths or personal file names by default.

## Backend-to-UI contract

| Backend signal | UI behaviour |
|---|---|
| `ImportPhase` | phase label; indeterminate progress when no fraction is known |
| `YouTubeHelperStatus` | enables or explains the YouTube import |
| `YouTubeMetadata` | confirmation card shown before any download |
| `MediaItem` | single source for posters, detail pages and destination selections |
| `ProfileValidator` error | blocks the apply and points to the affected destination |
| `RuntimeConfiguration` | source of truth for the active profile and helper processes |
| Lock Screen compatibility report | decides whether Lock Screen video is offered |

## Accessibility and input

- Every action is reachable without drag and drop.
- Posters expose a combined VoiceOver label (title and kind) and a hint; icon-only
  buttons have help tags and accessibility labels. State is never conveyed by color
  alone: live destinations are also named in text.
- Keyboard: `⌘O` import, `⇧⌘U` YouTube, `⌘F` search, `⌘1`–`⌘3` sections, `⇧⌘L`
  lock, `⌘↩` apply profile, `↩`/`Esc` on a wallpaper page.
