#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "$script_directory/.." && pwd)"
if [[ -f "$script_directory/dependencies.env" ]]; then
    source "$script_directory/dependencies.env"
else
    source "$project_root/Vendor/dependencies.env"
fi
[[ "$(uname -s)" == Darwin ]] || { echo "FFmpeg builds require macOS." >&2; exit 1; }
# Set FFMPEG_OUTPUT_DIR when rebuilding from the sources included inside the app.
output_directory="${FFMPEG_OUTPUT_DIR:-$project_root/Vendor}"
mkdir -p "$output_directory"
output_directory="$(cd "$output_directory" && pwd)"
version="$FFMPEG_VERSION"
archive_hash="$FFMPEG_SOURCE_SHA256"
work_directory="$(mktemp -d /tmp/WallpaperStudioFFmpeg.XXXXXX)"
trap 'rm -rf "$work_directory"' EXIT

archive="$work_directory/ffmpeg-$version.tar.xz"
curl -fL --retry 3 "https://ffmpeg.org/releases/ffmpeg-$version.tar.xz" -o "$archive"
actual_hash="$(shasum -a 256 "$archive" | awk '{print $1}')"
[[ "$actual_hash" == "$archive_hash" ]] || {
    echo "Checksum mismatch for the FFmpeg source." >&2
    exit 1
}

tar -xf "$archive" -C "$work_directory"
source_directory="$work_directory/ffmpeg-$version"

build_architecture() {
    local architecture="$1"
    local build_directory="$work_directory/build-$architecture"
    local cross_flags=()
    mkdir -p "$build_directory"

    if [[ "$architecture" != "$(uname -m)" ]]; then
        cross_flags+=(--enable-cross-compile)
    fi
    if [[ "$architecture" == "x86_64" ]]; then
        cross_flags+=(--disable-x86asm)
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
    -output "$output_directory/ffmpeg"
chmod 755 "$output_directory/ffmpeg"
ditto "$source_directory/COPYING.LGPLv2.1" "$output_directory/FFmpeg-LGPL-2.1.txt"

file "$output_directory/ffmpeg"
"$output_directory/ffmpeg" -version
shasum -a 256 "$output_directory/ffmpeg"
echo "For a dependency update, review the rebuild and update FFMPEG_BINARY_SHA256 in Vendor/dependencies.env."
