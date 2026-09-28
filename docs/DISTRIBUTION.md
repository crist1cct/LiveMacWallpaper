# Build and distribution

## Requirements

Use a Mac with full **Xcode 26 or newer** and its macOS 26 SDK. The package uses
Swift tools 6.2, and the wallpaper extension targets macOS 26. Command Line Tools
alone and Xcode 16 are insufficient. The main app, renderer and Screen Saver still
target macOS 15. Both Apple Silicon and Intel are included in the DMG.

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
brew install xcodegen
xcodebuild -version
xcrun swift --version
```

## Local test DMG

From the repository root:

```sh
swift test
bash Tools/package_release.sh
```

Version and build number come from `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`
in `project.yml`. At 1.7.0 / 170 the results are:

- `build/Live-Mac-Wallpaper-1.7.0.dmg`
- `build/Live-Mac-Wallpaper-1.7.0.dmg.sha256`

This default build is ad-hoc signed, **not notarized**. It is useful for development
and packaging checks. Gatekeeper may block it on another Mac, and `WallpaperAgent`
may reject the wallpaper extension. For public distribution use Developer ID below.

The script verifies every pinned dependency before use, generates the Xcode project,
builds all targets for arm64 and x86_64, verifies their embedded versions and
architectures, signs from the inside out, and verifies the finished app and DMG.
It includes the Desktop login item, Screen Saver, wallpaper extension, cleanup tool,
yt-dlp, FFmpeg and its corresponding source/license/build recipe, plus the Phosphene
license. The disk image contains the app, an Applications shortcut and `INSTALL.txt`.
Temporary files and the mounted image are cleaned up on errors.

Local builds use the existing background and Finder icon layout. For an SSH session
or any environment without Finder, use:

```sh
DMG_LAYOUT=plain bash Tools/package_release.sh
```

Optional version overrides apply consistently to every target and the DMG filename:

```sh
LMW_VERSION=1.7.1 LMW_BUILD=171 bash Tools/package_release.sh
```

For a committed release, update `project.yml` and `CHANGELOG.md` instead of relying
on overrides. Vendor pins live in `Vendor/dependencies.env`. The checked-in FFmpeg
helper must match its hash; see `Vendor/README.md` for deliberate dependency rebuilds.

## GitHub Actions, including from Windows

The **macOS DMG** workflow (`.github/workflows/macos-release.yml`) uses the
`macos-26` runner and Xcode 26.0.1. It runs `swift test`, compiles all targets for
both architectures, packages the DMG, mounts it to verify its contents/signatures,
and runs both embedded media helpers. Build/test logs are retained even on failure.

After merging the workflow into `main`:

1. Open **Actions → macOS DMG → Run workflow**.
2. Choose the branch and leave **notarize** unchecked for a test build.
3. Wait for the workflow to succeed.
4. Under **Artifacts**, download `Live-Mac-Wallpaper-1.7.0-test`. The ZIP contains the
   DMG and its SHA-256 file. Artifacts are retained for 30 days.

Pull requests and pushes to `main` also produce test artifacts automatically.
CI uses the plain layout to avoid Finder automation. No Apple account or signing
secrets are needed for test builds. Building and packaging do not replace interactive
Desktop/Screen Saver/Lock Screen testing on a Mac.

## Signed and notarized local release

Import a **Developer ID Application** certificate with its private key into your Mac's
keychain. Find the exact identity:

```sh
security find-identity -v -p codesigning
```

Store notarization credentials once. The interactive prompts request your Apple ID,
team ID and app-specific password; do not commit credentials to the repository:

```sh
xcrun notarytool store-credentials lmw-notary
```

Build:

```sh
SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
NOTARY_PROFILE="lmw-notary" \
REQUIRE_NOTARIZATION=true \
bash Tools/package_release.sh
```

The script uses Hardened Runtime and secure timestamps, notarizes the assembled app,
staples its ticket, then creates, signs, notarizes and staples the DMG. Both undergo
Gatekeeper assessment. Failure at any stage prevents new final outputs from being
installed into `build/`. An older successful output may remain there after a failed
run; always check the current command's exit status.

If the profile is stored in a separate keychain, set `NOTARY_KEYCHAIN` to that keychain
path. Leave it unset for the usual default keychain.

## Signed release through GitHub

Add these **repository Actions secrets** in Settings → Secrets and variables → Actions:

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE_P12` | Base64-encoded Developer ID Application certificate **and private key** exported as `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | Password used to protect the `.p12` |
| `MACOS_SIGN_IDENTITY` | Full `Developer ID Application: Name (TEAMID)` identity |
| `APPLE_ID` | Apple ID associated with the developer team |
| `APPLE_APP_SPECIFIC_PASSWORD` | An app-specific password for notarization |
| `APPLE_TEAM_ID` | Apple Developer team ID |

On your Mac, encode the exported certificate with `base64 -i certificate.p12 | pbcopy`,
then paste it into the secret. Do not put certificate files or passwords in Git.
The workflow imports the certificate into a temporary keychain and deletes it and the
P12 file at the end of the job, including failures.

Run the workflow with **notarize** checked. The artifact name ends in `-notarized`.
Alternatively, push a tag that exactly matches the version in `project.yml`:

```sh
git tag v1.7.0
git push origin v1.7.0
```

Tag builds require all signing secrets and notarization; they never silently fall
back to an unsigned release. The workflow produces downloadable artifacts and does
**not publish a GitHub Release**. After reviewing and testing the notarized artifact,
create a release for that tag and attach both the DMG and its `.sha256` file.

## Final checks on a Mac

```sh
cd build
shasum -a 256 -c Live-Mac-Wallpaper-1.7.0.dmg.sha256
hdiutil verify Live-Mac-Wallpaper-1.7.0.dmg
```

Install from the mounted DMG into `/Applications`, then verify:

- The app launches, imports local images/videos and imports an authorized YouTube clip.
- Desktop rendering targets the selected displays and pauses/resumes when covered.
- The login item works after signing in again.
- The Screen Saver loads, plays the selected media and stays muted.
- On macOS 26, Lock Screen video and optional audio work through several loops,
  and audio stops immediately on unlock.
- A previous library/configuration survives the upgrade.
- For a public release, Gatekeeper accepts the downloaded app/DMG and both tickets
  pass `xcrun stapler validate`.

The wallpaper provider is registered on first launch from `/Applications`.
An Apple Development signature is insufficient for reliable distribution to other
Macs; use Developer ID and notarization. Lock Screen integration uses macOS-specific
wallpaper host behavior and must be tested on the OS versions you support.
