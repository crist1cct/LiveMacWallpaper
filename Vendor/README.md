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
