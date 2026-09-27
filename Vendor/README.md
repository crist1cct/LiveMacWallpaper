# Vendor dependencies

If missing, `yt-dlp_macos` is downloaded by `Tools/package_release.sh` from the
pinned official yt-dlp release and verified against its SHA-256 checksum before
it is embedded. The binary is intentionally not stored in Git.

Pinned version: `2026.08.19`  
SHA-256: `0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202`

`ffmpeg` is a minimal universal helper built from the official FFmpeg 9.0.1
source by `Tools/build_ffmpeg_helper.sh`. It is used only when AVFoundation
cannot decode/transcode an imported format (for example VP9 in MP4).

Source archive SHA-256:
`cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635`

The packaging and helper build scripts share pins in `dependencies.env`. Packaging
also verifies the checked-in FFmpeg binary against `FFMPEG_BINARY_SHA256` before
signing it. A deliberate rebuild can change the bytes: review and commit the rebuilt
binary together with the updated hash. Missing or modified vendor binaries fail the
release instead of silently substituting a different build.

The distributed app includes the matching FFmpeg source archive, build script,
dependency pins and license in `Contents/Resources`. To rebuild that source outside
the repository on a Mac, copy the script and `dependencies.env` into a writable
folder, then run `FFMPEG_OUTPUT_DIR="$PWD/rebuilt" bash build_ffmpeg_helper.sh`.
The script downloads and verifies the pinned source and builds both architectures
on either an Apple Silicon or Intel host. It does not require NASM.
