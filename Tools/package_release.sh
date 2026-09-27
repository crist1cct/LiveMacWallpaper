#!/bin/zsh
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"

version="${WALLPAPER_STUDIO_VERSION:-1.5.2}"
sign_identity="${SIGN_IDENTITY:--}"
notary_profile="${NOTARY_PROFILE:-}"
derived_data="$project_root/DerivedData-Release"
products="$derived_data/Build/Products/Release"
output_directory="$project_root/build"
built_application="$products/Wallpaper Studio.app"
built_renderer="$products/WallpaperRenderer.app"
built_screen_saver="$products/Wallpaper Studio.saver"
built_login_installer="$products/LoginWallpaperInstaller"
built_wallpaper_extension="$built_application/Contents/Extensions/WallpaperStudioWallpaperExtension.appex"
helper="$project_root/Vendor/yt-dlp_macos"
ffmpeg_helper="$project_root/Vendor/ffmpeg"
ffmpeg_license="$project_root/Vendor/FFmpeg-LGPL-2.1.txt"
expected_helper_hash="0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202"
ffmpeg_version="9.0.1"
ffmpeg_source_hash="cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635"
dmg_background="$project_root/Distribution/dmg-background.png"

for command_name in curl xcodegen xcodebuild codesign hdiutil lipo shasum osascript; do
    command -v "$command_name" >/dev/null || {
        echo "Missing tool: $command_name" >&2
        exit 1
    }
done

[[ -f "$dmg_background" ]] || {
    echo "Missing DMG background image: $dmg_background" >&2
    exit 1
}

if [[ ! -x "$helper" ]]; then
    mkdir -p "$(dirname "$helper")"
    curl \
        -fL \
        --retry 3 \
        "https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/yt-dlp_macos" \
        -o "$helper"
    chmod 755 "$helper"
fi

if [[ ! -x "$ffmpeg_helper" || ! -f "$ffmpeg_license" ]]; then
    "$project_root/Tools/build_ffmpeg_helper.sh"
fi
lipo "$ffmpeg_helper" -verify_arch arm64 x86_64

actual_helper_hash="$(shasum -a 256 "$helper" | awk '{print $1}')"
if [[ "$actual_helper_hash" != "$expected_helper_hash" ]]; then
    echo "Checksum mismatch for yt-dlp_macos." >&2
    exit 1
fi

xcodegen generate
xcodebuild \
    -quiet \
    -project WallpaperStudio.xcodeproj \
    -scheme WallpaperStudio \
    -configuration Release \
    -derivedDataPath "$derived_data" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    MARKETING_VERSION="$version" \
    build

for product in "$built_application" "$built_renderer" "$built_screen_saver" "$built_login_installer" "$built_wallpaper_extension"; do
    [[ -e "$product" ]] || {
        echo "Incomplete build: missing $product" >&2
        exit 1
    }
done

assembly_directory="$(mktemp -d /tmp/WallpaperStudioAssembly.XXXXXX)"
staging_directory=""
read_write_dmg_directory=""
trap 'rm -rf "$assembly_directory"; if [[ -n "$staging_directory" ]]; then rm -rf "$staging_directory"; fi; if [[ -n "$read_write_dmg_directory" ]]; then rm -rf "$read_write_dmg_directory"; fi' EXIT
application="$assembly_directory/Wallpaper Studio.app"
ditto --norsrc "$built_application" "$application"

mkdir -p "$application/Contents/Library/LoginItems"
mkdir -p "$application/Contents/Resources/Helpers"
ditto --norsrc "$built_renderer" "$application/Contents/Library/LoginItems/WallpaperRenderer.app"
ditto --norsrc "$built_screen_saver" "$application/Contents/Resources/Wallpaper Studio.saver"
ditto --norsrc "$helper" "$application/Contents/Resources/Helpers/yt-dlp_macos"
ditto --norsrc "$ffmpeg_helper" "$application/Contents/Resources/Helpers/ffmpeg"
ditto --norsrc "$built_login_installer" "$application/Contents/Resources/Helpers/LoginWallpaperInstaller"
ditto --norsrc "$ffmpeg_license" "$application/Contents/Resources/FFmpeg-LGPL-2.1.txt"
ffmpeg_source="$assembly_directory/ffmpeg-$ffmpeg_version.tar.xz"
curl -fL --retry 3 \
    "https://ffmpeg.org/releases/ffmpeg-$ffmpeg_version.tar.xz" \
    -o "$ffmpeg_source"
actual_ffmpeg_source_hash="$(shasum -a 256 "$ffmpeg_source" | awk '{print $1}')"
[[ "$actual_ffmpeg_source_hash" == "$ffmpeg_source_hash" ]] || {
    echo "Checksum mismatch for the FFmpeg source." >&2
    exit 1
}
ditto --norsrc "$ffmpeg_source" \
    "$application/Contents/Resources/ffmpeg-$ffmpeg_version.tar.xz"
ditto --norsrc "$project_root/Tools/build_ffmpeg_helper.sh" \
    "$application/Contents/Resources/build_ffmpeg_helper.sh"
ditto --norsrc "$project_root/Vendor/README.md" \
    "$application/Contents/Resources/FFmpeg-BUILD-INFO.md"
chmod 755 "$application/Contents/Resources/Helpers/yt-dlp_macos"
chmod 755 "$application/Contents/Resources/Helpers/ffmpeg"
chmod 755 "$application/Contents/Resources/Helpers/LoginWallpaperInstaller"
xattr -cr "$application"

sign_component() {
    local component="$1"
    if [[ "$sign_identity" == "-" ]]; then
        codesign --force --sign - --options runtime --timestamp=none "$component"
    else
        codesign --force --sign "$sign_identity" --options runtime --timestamp "$component"
    fi
}

sign_wallpaper_extension() {
    local component="$1"
    local entitlements="$project_root/Extensions/WallpaperStudioWallpaper/WallpaperStudioWallpaperExtension.entitlements"
    if [[ "$sign_identity" == "-" ]]; then
        codesign --force --sign - --options runtime --timestamp=none --entitlements "$entitlements" "$component"
    else
        codesign --force --sign "$sign_identity" --options runtime --timestamp --entitlements "$entitlements" "$component"
    fi
}

if [[ "$sign_identity" == "-" ]]; then
    codesign --verify --strict "$application/Contents/Resources/Helpers/yt-dlp_macos"
else
    codesign \
        --force \
        --sign "$sign_identity" \
        --options runtime \
        --entitlements "$project_root/Tools/yt-dlp.entitlements" \
        --timestamp \
        "$application/Contents/Resources/Helpers/yt-dlp_macos"
fi
sign_component "$application/Contents/Resources/Helpers/ffmpeg"
sign_component "$application/Contents/Resources/Helpers/LoginWallpaperInstaller"
sign_component "$application/Contents/Resources/Wallpaper Studio.saver"
sign_component "$application/Contents/Library/LoginItems/WallpaperRenderer.app"
sign_wallpaper_extension "$application/Contents/Extensions/WallpaperStudioWallpaperExtension.appex"
sign_component "$application"

codesign --verify --deep --strict --verbose=2 "$application"

mkdir -p "$output_directory"
staging_directory="$(mktemp -d /tmp/WallpaperStudioDMG.XXXXXX)"
ditto --norsrc "$application" "$staging_directory/Wallpaper Studio.app"
ln -s /Applications "$staging_directory/Applications"
mkdir -p "$staging_directory/.background"
ditto --norsrc "$dmg_background" "$staging_directory/.background/dmg-background.png"

if ! osascript - "$staging_directory" <<'APPLESCRIPT'
on run argv
    set stagingPath to item 1 of argv
    set backgroundPath to stagingPath & "/.background/dmg-background.png"
    tell application "Finder"
        set stagingFolder to POSIX file stagingPath as alias
        set backgroundFile to POSIX file backgroundPath as alias
        open stagingFolder
        delay 0.4
        set stagingWindow to container window of stagingFolder
        set current view of stagingWindow to icon view
        set iconOptions to icon view options of stagingWindow
        set arrangement of iconOptions to not arranged
        set icon size of iconOptions to 96
        set text size of iconOptions to 12
        set label position of iconOptions to bottom
        set background picture of iconOptions to backgroundFile
        set position of item "Wallpaper Studio.app" of stagingFolder to {250, 300}
        set position of item "Applications" of stagingFolder to {790, 300}
        close stagingWindow saving yes
    end tell
end run
APPLESCRIPT
then
    echo "Warning: Finder could not prepare the DMG source layout."
fi

dmg_path="$output_directory/Wallpaper-Studio-$version.dmg"
read_write_dmg_directory="$(mktemp -d /tmp/WallpaperStudioRW.XXXXXX)"
read_write_dmg="$read_write_dmg_directory/Wallpaper-Studio-$version-rw.dmg"
hdiutil create \
    -size 160m \
    -fs HFS+ \
    -volname "Wallpaper Studio" \
    -srcfolder "$staging_directory" \
    -ov \
    "$read_write_dmg" >/dev/null

device=""
if device="$(hdiutil attach -nobrowse -readwrite "$read_write_dmg" 2>/dev/null | awk '/Apple_HFS/ {print $1; exit}')"; then
    if [[ -z "$device" ]]; then
        echo "Warning: the temporary image could not be mounted; continuing without Finder positioning."
    fi
fi
if [[ -n "$device" ]]; then
    if ! osascript <<'APPLESCRIPT'
tell application "Finder"
    tell disk "Wallpaper Studio"
        open
        set icon view options of container window to {icon size: 96, text size: 12, arrangement: not arranged, label position: bottom, background picture: file ".background:dmg-background.png"}
        set position of item "Wallpaper Studio.app" to {250, 300}
        set position of item "Applications" to {790, 300}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
    then
        echo "Warning: Finder could not save the DMG window layout; continuing with the bundled background."
    fi
    hdiutil detach "$device" >/dev/null
fi

hdiutil convert "$read_write_dmg" \
    -format UDZO \
    -ov \
    -o "$dmg_path" >/dev/null

if [[ "$sign_identity" != "-" ]]; then
    codesign --force --sign "$sign_identity" --timestamp "$dmg_path"
fi

if [[ -n "$notary_profile" ]]; then
    if [[ "$sign_identity" == "-" ]]; then
        echo "Notarization requires SIGN_IDENTITY=Developer ID Application…" >&2
        exit 1
    fi
    xcrun notarytool submit "$dmg_path" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$dmg_path"
    xcrun stapler validate "$dmg_path"
fi

checksum="$(shasum -a 256 "$dmg_path" | awk '{print $1}')"
printf '%s  %s\n' "$checksum" "$(basename "$dmg_path")" > "$dmg_path.sha256"
echo "Package created: $dmg_path"
