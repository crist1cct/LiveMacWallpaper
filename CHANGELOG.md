# Changelog

## 1.8.0

### Lock Screen audio

- New native audio engine. Sound is decoded by the same `AVAssetReader` as the picture
  and played through an `AVSampleBufferAudioRenderer` attached to the same
  `AVSampleBufferRenderSynchronizer` as the video renderer. Picture and sound share one
  hardware clock, so the separate audio player, the drift correction and the re-seeks
  that caused dropouts are gone.
- Audio loops gaplessly with the video; buffers are trimmed at the video track's end.
- One display is audible at a time; sound fades in once the picture reaches normal
  speed and is cut instantly on unlock or sleep.

### Interface

- Fixed pages growing past the window: aspect-fill artwork and video backdrops no
  longer take part in layout (this also fixed the YouTube sheet overflowing after a
  link was checked).
- Responsive layout: margins, title sizes, shelves, grids, the top bar and Settings
  rows adapt to the window width. The window has a minimum size (760 × 540).
- YouTube import is one step: paste a link, confirm the rights, press **Install**. The
  video info appears while it downloads; closing the sheet keeps the download running
  as a toast.

### System integration

- Wallpapers appear in System Settings under **LMW** (extension name, provider group,
  entry descriptions and the Screen Saver's display name).
- The DMG installs a **Live Mac Wallpaper** folder in Applications containing the app
  and the install notes. An older copy at `/Applications/Live Mac Wallpaper.app` is
  moved to the Trash on first launch from the new location.

## 1.7.0

### Rename

- The project is now **Live Mac Wallpaper (LMW)**. Targets, modules, types, bundle
  identifiers (`com.livemacwallpaper.*`), the URL scheme (`livemacwallpaper://`), Darwin
  notification names, environment variables (`LMW_*`) and the DMG name follow the new
  name.
- The existing library, preferences and Screen Saver module are migrated automatically;
  see "Upgrading from Wallpaper Studio" in the README.

### Interface

- New window layout with a hidden title bar and a floating tab bar
  (Home · Library · Settings).
- Home shows a full-width featured item with a muted video preview, what is currently
  applied on the Desktop, Screen Saver and Lock Screen, and horizontal shelves for
  favorites, videos and images.
- Every wallpaper has a full-window page: destination, displays and sound, applied
  with a single button. `Return` applies, `Esc` closes, and a full-window preview hides
  all controls.
- Library grid with filter capsules, search in the top bar (`⌘F`) and `⌘1`–`⌘3`
  navigation.
- Hover focus effect on posters, Liquid Glass on macOS 26 with a material fallback on
  macOS 15, and asynchronous cached artwork loading.
- The whole app, including error messages and the packaging script, is now in English.

### Lock Screen audio

- Fixed audio coming and going "in waves" on the Lock Screen. The previous controller
  compared the audio position with `timebase mod libraryDuration`. It re-seeked
  every time the difference exceeded 120 ms, checking four times per second, while the
  video clock was still easing in from 0 to 1. Every correction was an audible seek.
- `VideoRenderer` now exposes a loop clock (exact loop start times and a timeline
  generation), readable from any thread.
- The audio waits silently until the picture runs at normal speed, re-syncs rarely and
  only behind a fade, and absorbs everyday drift with a ±3 % rate trim that preserves
  pitch.
- The clip duration now comes from the player item instead of the library metadata,
  which could be 0 or differ from the real loop length.

### Playback

- Resuming from deep pause now reads from the position inside the current loop. Before,
  it used the raw timebase position, which overshot the clip after the first loop and
  made playback (and audio) jump back to the start.

## 1.5.4

- The Live Mac Wallpaper provider is registered automatically on first launch
  from `/Applications`, and a stale explicit registration is cleared before applying.

## 1.1

### Lock Screen and Login Window

- Removed the old integration that replaced an Apple Aerial file. On macOS 26 the
  system wallpapers ship on the signed system volume and can be recreated or re-read by
  Apple services, so replacing a cached slot didn't guarantee what appeared at login.
- Added an administrator-approved Login Window renderer (AppKit + AVPlayer) running
  from a LaunchAgent limited to the `Aqua` and `LoginWindow` sessions, placed just below
  the normal window level so the Apple authentication controls stay on top. It stops
  on unlock and on display sleep. The FileVault pre-boot screen remains out of scope.

### Playback and efficiency

- Desktop video and audio stop automatically on a display covered by any normal
  window and continue when the desktop becomes visible again.
- The Screen Saver uses a playback copy created on apply and matched to the display
  (1080p or 4K, at most 60 fps). The library original stays intact and the copy is
  reused.

### Migration

- On first install the new component stops the old Aerial daemon and restores the
  backed-up Apple file when a backup from the previous version is available.

## 1.0

- Desktop, Screen Saver and Lock Screen are fully separated, and the display choice
  persists across restarts.
- Runtime configuration schema 2: `DisplayTarget` is either `all` or
  `display(UUID)`. Schema 1 configurations (`targetDisplayIDs`) are migrated and
  rewritten atomically.
- A disconnected display never causes an apply on a different display. The renderer
  refuses a configuration that can no longer be resolved.
- Every destination is confirmed before success is reported:

  | Destination | Apply | Confirmation |
  |---|---|---|
  | Desktop video | one AppKit window per requested display | the renderer returns the profile and the active display UUIDs |
  | Desktop image | `NSWorkspace` per display | the active URL is read back from macOS for each display |
  | Screen Saver | separate runtime package, selected in the modern macOS registry | module, configuration and display UUIDs are read back after writing |
  | Lock Screen | native lock after configuring the Lock Screen video | video slot and Idle selection are verified before locking |
