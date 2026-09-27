#!/bin/zsh
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
version="9.0.1"
archive_hash="cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635"
work_directory="$(mktemp -d /tmp/WallpaperStudioFFmpeg.XXXXXX)"
trap 'rm -rf "$work_directory"' EXIT

archive="$work_directory/ffmpeg-$version.tar.xz"
curl -fL --retry 3 "https://ffmpeg.org/releases/ffmpeg-$version.tar.xz" -o "$archive"
actual_hash="$(shasum -a 256 "$archive" | awk '{print $1}')"
[[ "$actual_hash" == "$archive_hash" ]] || {
    echo "Checksum invalid pentru sursa FFmpeg." >&2
    exit 1
}

tar -xf "$archive" -C "$work_directory"
source_directory="$work_directory/ffmpeg-$version"

build_architecture() {
    local architecture="$1"
    local build_directory="$work_directory/build-$architecture"
    local cross_flags=()
    mkdir -p "$build_directory"

    if [[ "$architecture" == "x86_64" && "$(uname -m)" != "x86_64" ]]; then
        cross_flags+=(--enable-cross-compile --disable-x86asm)
    fi

    cd "$build_directory"
    "$source_directory/configure" \
        --arch="$architecture" \
        --target-os=darwin \
        --cc=/usr/bin/clang \
        --extra-cflags="-arch $architecture -mmacosx-version-min=15.0" \
        --extra-ldflags="-arch $architecture -mmacosx-version-min=15.0" \
        --disable-autodetect \
        --disable-debug \
        --disable-doc \
        --disable-network \
        --disable-shared \
        --enable-static \
        --disable-ffplay \
        --disable-ffprobe \
        --disable-everything \
        --enable-ffmpeg \
        --enable-avcodec \
        --enable-avfilter \
        --enable-avformat \
        --enable-swscale \
        --enable-videotoolbox \
        --enable-protocol=file \
        --enable-demuxer=avi,flv,matroska,mov,mpegps,mpegts \
        --enable-decoder=av1,h264,hevc,mjpeg,mpeg2video,mpeg4,prores,rawvideo,theora,vp8,vp9 \
        --enable-encoder=h264_videotoolbox,mpeg4 \
        --enable-muxer=mov,mp4 \
        --enable-filter=crop,format,pad,scale \
        "${cross_flags[@]}"
    make -j"$(sysctl -n hw.ncpu)" ffmpeg
    strip -x ffmpeg
}

build_architecture arm64
build_architecture x86_64

lipo -create \
    "$work_directory/build-arm64/ffmpeg" \
    "$work_directory/build-x86_64/ffmpeg" \
    -output "$project_root/Vendor/ffmpeg"
chmod 755 "$project_root/Vendor/ffmpeg"
ditto "$source_directory/COPYING.LGPLv2.1" "$project_root/Vendor/FFmpeg-LGPL-2.1.txt"

file "$project_root/Vendor/ffmpeg"
"$project_root/Vendor/ffmpeg" -version | head -1
