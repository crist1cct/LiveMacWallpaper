#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
source "$project_root/Tools/release_metadata.sh"
source "$project_root/Vendor/dependencies.env"
fail() { echo "Error: $*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || fail "DMG builds require macOS and Xcode 26 or newer."
sign_identity="${SIGN_IDENTITY:--}"
notary_profile="${NOTARY_PROFILE:-}"
# Hosted runners do not have an interactive Finder session.
dmg_layout="${DMG_LAYOUT:-$([[ "${CI:-false}" == true ]] && echo plain || echo finder)}"
[[ "$dmg_layout" == plain || "$dmg_layout" == finder ]] || fail "DMG_LAYOUT must be plain or finder."
if [[ -n "$notary_profile" && "$sign_identity" != 'Developer ID Application:'* ]]; then
    fail "Notarization requires SIGN_IDENTITY='Developer ID Application: Name (TEAMID)'."
fi
if [[ "${REQUIRE_NOTARIZATION:-false}" == true && -z "$notary_profile" ]]; then
    fail "This release requires NOTARY_PROFILE and a Developer ID Application identity."
fi
for command_name in curl xcodegen xcodebuild codesign hdiutil lipo shasum ditto xattr xcrun plutil; do
    command -v "$command_name" >/dev/null || fail "Missing tool: $command_name"
done
[[ "$dmg_layout" != finder ]] || command -v osascript >/dev/null || fail "Missing tool: osascript"
xcode_major="$(xcodebuild -version | awk '/^Xcode / {split($2, v, "."); print v[1]}')"
[[ "$xcode_major" =~ ^[0-9]+$ && "$xcode_major" -ge 26 ]] || fail "Select Xcode 26 or newer with xcode-select."
sdk_major="$(xcrun --sdk macosx --show-sdk-version | cut -d. -f1)"
[[ "$sdk_major" -ge 26 ]] || fail "The wallpaper extension requires the macOS 26 SDK."
if [[ "$sign_identity" != '-' ]]; then
    security find-identity -v -p codesigning | grep -F -- "\"$sign_identity\"" >/dev/null || fail "Signing identity is not available in the keychain."
fi

derived_data="$project_root/DerivedData-Release"
products="$derived_data/Build/Products/Release"
output_directory="$project_root/build"
built_application="$products/Live Mac Wallpaper.app"
built_renderer="$products/WallpaperRenderer.app"
built_screen_saver="$products/Live Mac Wallpaper.saver"
built_login_installer="$products/LoginWallpaperInstaller"
built_wallpaper_extension="$built_application/Contents/Extensions/LiveMacWallpaperExtension.appex"
helper="$project_root/Vendor/yt-dlp_macos"
ffmpeg_helper="$project_root/Vendor/ffmpeg"
ffmpeg_license="$project_root/Vendor/FFmpeg-LGPL-2.1.txt"
dmg_background="$project_root/Distribution/dmg-background.png"
work_directory="$(mktemp -d "${TMPDIR:-/tmp}/LiveMacWallpaperRelease.XXXXXX")"
mountpoint="$work_directory/mount"
cleanup() {
    if mount | grep -F -- " on $mountpoint (" >/dev/null; then
        hdiutil detach "$mountpoint" >/dev/null 2>&1 || hdiutil detach -force "$mountpoint" >/dev/null 2>&1 || true
    fi
    rm -rf "$work_directory"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
verify_hash() {
    local actual
    actual="$(shasum -a 256 "$1" | awk '{print $1}')"
    [[ "$actual" == "$2" ]] || fail "Checksum mismatch: $1"
}
if [[ ! -f "$helper" ]]; then
    curl -fL --retry 3 "https://github.com/yt-dlp/yt-dlp/releases/download/$YT_DLP_VERSION/yt-dlp_macos" -o "$work_directory/yt-dlp_macos"
    verify_hash "$work_directory/yt-dlp_macos" "$YT_DLP_SHA256"
    mv "$work_directory/yt-dlp_macos" "$helper"
fi
verify_hash "$helper" "$YT_DLP_SHA256"
[[ -f "$ffmpeg_helper" && -f "$ffmpeg_license" ]] || fail "Missing FFmpeg helper/license; restore Vendor/ from Git."
verify_hash "$ffmpeg_helper" "$FFMPEG_BINARY_SHA256"
chmod 755 "$helper" "$ffmpeg_helper"
lipo "$helper" -verify_arch arm64 x86_64
lipo "$ffmpeg_helper" -verify_arch arm64 x86_64
ffmpeg_source="$work_directory/ffmpeg-$FFMPEG_VERSION.tar.xz"
curl -fL --retry 3 "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" -o "$ffmpeg_source"
verify_hash "$ffmpeg_source" "$FFMPEG_SOURCE_SHA256"

echo "Building Live Mac Wallpaper $version ($build_number), arm64 + x86_64"
xcodegen generate
xcodebuild \
    -project LiveMacWallpaper.xcodeproj \
    -scheme LiveMacWallpaper \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" \
    build
for product in "$built_application" "$built_renderer" "$built_screen_saver" "$built_login_installer" "$built_wallpaper_extension"; do
    [[ -e "$product" ]] || fail "Incomplete build: missing $product"
done
application="$work_directory/Live Mac Wallpaper.app"
ditto --norsrc "$built_application" "$application"
mkdir -p "$application/Contents/Library/LoginItems" "$application/Contents/Resources/Helpers"
ditto --norsrc "$built_renderer" "$application/Contents/Library/LoginItems/WallpaperRenderer.app"
ditto --norsrc "$built_screen_saver" "$application/Contents/Resources/Live Mac Wallpaper.saver"
ditto --norsrc "$helper" "$application/Contents/Resources/Helpers/yt-dlp_macos"
ditto --norsrc "$ffmpeg_helper" "$application/Contents/Resources/Helpers/ffmpeg"
ditto --norsrc "$built_login_installer" "$application/Contents/Resources/Helpers/LoginWallpaperInstaller"
ditto --norsrc "$ffmpeg_license" "$application/Contents/Resources/FFmpeg-LGPL-2.1.txt"
ditto --norsrc "$ffmpeg_source" "$application/Contents/Resources/ffmpeg-$FFMPEG_VERSION.tar.xz"
ditto --norsrc "$project_root/Tools/build_ffmpeg_helper.sh" "$application/Contents/Resources/build_ffmpeg_helper.sh"
ditto --norsrc "$project_root/Vendor/dependencies.env" "$application/Contents/Resources/dependencies.env"
ditto --norsrc "$project_root/Vendor/README.md" "$application/Contents/Resources/FFmpeg-BUILD-INFO.md"
ditto --norsrc "$project_root/Vendor/Phosphene-MIT.txt" "$application/Contents/Resources/Phosphene-MIT.txt"
chmod 755 "$application/Contents/Resources/Helpers/"*
xattr -cr "$application"
verify_bundle() {
    local bundle="$1" executable bundle_version bundle_build
    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Contents/Info.plist")"
    bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle/Contents/Info.plist")"
    bundle_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$bundle/Contents/Info.plist")"
    [[ "$bundle_version" == "$version" && "$bundle_build" == "$build_number" ]] || fail "Incorrect version in $bundle"
    lipo "$bundle/Contents/MacOS/$executable" -verify_arch arm64 x86_64
}
verify_bundle "$application"
verify_bundle "$application/Contents/Library/LoginItems/WallpaperRenderer.app"
verify_bundle "$application/Contents/Resources/Live Mac Wallpaper.saver"
verify_bundle "$application/Contents/Extensions/LiveMacWallpaperExtension.appex"
lipo "$application/Contents/Resources/Helpers/LoginWallpaperInstaller" -verify_arch arm64 x86_64
sign_component() {
    local component="$1"
    shift
    local timestamp=--timestamp
    [[ "$sign_identity" != '-' ]] || timestamp=--timestamp=none
    codesign --force --sign "$sign_identity" --options runtime "$timestamp" "$@" "$component"
}
if [[ "$sign_identity" == '-' ]]; then
    codesign --verify --strict "$application/Contents/Resources/Helpers/yt-dlp_macos"
else
    sign_component "$application/Contents/Resources/Helpers/yt-dlp_macos" --entitlements "$project_root/Tools/yt-dlp.entitlements"
fi
sign_component "$application/Contents/Resources/Helpers/ffmpeg"
sign_component "$application/Contents/Resources/Helpers/LoginWallpaperInstaller"
sign_component "$application/Contents/Resources/Live Mac Wallpaper.saver"
sign_component "$application/Contents/Library/LoginItems/WallpaperRenderer.app"
sign_component "$application/Contents/Extensions/LiveMacWallpaperExtension.appex" --entitlements "$project_root/Extensions/LiveMacWallpaperExtension/LiveMacWallpaperExtension.entitlements"
sign_component "$application"
codesign --verify --deep --strict --verbose=2 "$application"
notarize() {
    local notary_args=(--keychain-profile "$notary_profile")
    if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then
        notary_args+=(--keychain "$NOTARY_KEYCHAIN")
    fi
    xcrun notarytool submit "$1" "${notary_args[@]}" --wait
}
# Staple the app too, so it carries its own ticket after copying out of the DMG.
if [[ -n "$notary_profile" ]]; then
    ditto -c -k --keepParent "$application" "$work_directory/notarization.zip"
    notarize "$work_directory/notarization.zip"
    xcrun stapler staple "$application"
    xcrun stapler validate "$application"
    spctl --assess --type execute --verbose=2 "$application"
fi
staging_directory="$work_directory/staging"
# The app is installed as a folder: /Applications/Live Mac Wallpaper/ holds the app and
# its install notes, and the DMG offers that folder next to an Applications shortcut.
install_folder="$staging_directory/Live Mac Wallpaper"
mkdir -p "$install_folder"
ditto --norsrc "$application" "$install_folder/Live Mac Wallpaper.app"
ditto --norsrc "$project_root/Distribution/INSTALL.txt" "$install_folder/INSTALL.txt"
ln -s /Applications "$staging_directory/Applications"
# Give the folder the app's icon (best effort; purely cosmetic).
app_icon="$install_folder/Live Mac Wallpaper.app/Contents/Resources/AppIcon.icns"
if [[ -f "$app_icon" ]]; then
    osascript -l JavaScript - "$app_icon" "$install_folder" <<'JXA' || echo "Warning: could not set the folder icon." >&2
ObjC.import('AppKit')
function run(argv) {
    const image = $.NSImage.alloc.initWithContentsOfFile(argv[0])
    $.NSWorkspace.sharedWorkspace.setIconForFileOptions(image, argv[1], 0)
}
JXA
fi
read_write_dmg="$work_directory/release-rw.dmg"
if [[ "$dmg_layout" == finder ]]; then
    [[ -f "$dmg_background" ]] || fail "Missing DMG background image."
    mkdir -p "$staging_directory/.background"
    ditto --norsrc "$dmg_background" "$staging_directory/.background/dmg-background.png"
fi
# Calculate capacity from the payload instead of imposing a fixed 160 MB cap.
hdiutil create -fs HFS+ -format UDRW -volname 'Live Mac Wallpaper' -srcfolder "$staging_directory" "$read_write_dmg"
if [[ "$dmg_layout" == finder ]]; then
    mkdir -p "$mountpoint"
    hdiutil attach -nobrowse -readwrite -mountpoint "$mountpoint" "$read_write_dmg"
    if ! osascript - "$mountpoint" <<'APPLESCRIPT'
on run argv
    set volumeFolder to POSIX file (item 1 of argv) as alias
    with timeout of 30 seconds
        tell application "Finder"
            open volumeFolder
            set volumeWindow to container window of volumeFolder
            set current view of volumeWindow to icon view
            set toolbar visible of volumeWindow to false
            set statusbar visible of volumeWindow to false
            set bounds of volumeWindow to {100, 100, 1140, 720}
            set viewOptions to icon view options of volumeWindow
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 96
            set text size of viewOptions to 12
            set background picture of viewOptions to file ".background:dmg-background.png" of volumeFolder
            set position of item "Live Mac Wallpaper" of volumeFolder to {250, 300}
            set position of item "Applications" of volumeFolder to {790, 300}
            update volumeFolder without registering applications
            delay 1
            close volumeWindow
        end tell
    end timeout
end run
APPLESCRIPT
    then
        echo "Warning: Finder layout could not be saved; the DMG remains installable." >&2
    fi
    hdiutil detach "$mountpoint"
fi
mkdir -p "$output_directory"
# Install final outputs only after every verification succeeds.
dmg_name="Live-Mac-Wallpaper-$version.dmg"
dmg_path="$work_directory/$dmg_name"
hdiutil convert "$read_write_dmg" -format UDZO -o "$dmg_path"
if [[ "$sign_identity" != '-' ]]; then
    codesign --force --sign "$sign_identity" --timestamp "$dmg_path"
fi
if [[ -n "$notary_profile" ]]; then
    notarize "$dmg_path"
    xcrun stapler staple "$dmg_path"
    xcrun stapler validate "$dmg_path"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_path"
fi
hdiutil verify "$dmg_path"
checksum="$(shasum -a 256 "$dmg_path" | awk '{print $1}')"
printf '%s  %s\n' "$checksum" "$dmg_name" > "$work_directory/$dmg_name.sha256"
mv -f "$dmg_path" "$output_directory/$dmg_name"
mv -f "$work_directory/$dmg_name.sha256" "$output_directory/$dmg_name.sha256"
echo "Package created: $output_directory/$dmg_name"
if [[ -z "$notary_profile" ]]; then
    echo "TEST BUILD: not notarized. Public distribution requires Developer ID and NOTARY_PROFILE."
fi
