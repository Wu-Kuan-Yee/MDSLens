#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ICON="$ROOT_DIR/assets/app_icon.svg"
FOREGROUND_ICON="$ROOT_DIR/assets/app_icon_foreground.svg"
MONOCHROME_ICON="$ROOT_DIR/assets/app_icon_monochrome.svg"

for tool in rsvg-convert magick; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing icon generator dependency: $tool" >&2
    exit 1
  fi
done

render() {
  local source="$1"
  local size="$2"
  local output="$3"
  mkdir -p "$(dirname "$output")"
  rsvg-convert --width "$size" --height "$size" --output "$output" "$source"
}

render_opaque() {
  local size="$1"
  local output="$2"
  local temporary_dir temporary
  temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/mdslens-icon.XXXXXX")"
  temporary="$temporary_dir/icon.png"
  render "$SOURCE_ICON" "$size" "$temporary"
  magick "$temporary" -background '#0b1120' -alpha remove -alpha off "$output"
  rm -rf "$temporary_dir"
}

# Flutter/About dialog and Linux desktop/window icon.
render "$SOURCE_ICON" 256 "$ROOT_DIR/assets/app_icon.png"
render "$SOURCE_ICON" 512 "$ROOT_DIR/linux/runner/app_icon.png"

# Browser favicon and installable PWA icons.
render "$SOURCE_ICON" 32 "$ROOT_DIR/web/favicon.png"
render "$SOURCE_ICON" 192 "$ROOT_DIR/web/icons/Icon-192.png"
render "$SOURCE_ICON" 512 "$ROOT_DIR/web/icons/Icon-512.png"
render_opaque 192 "$ROOT_DIR/web/icons/Icon-maskable-192.png"
render_opaque 512 "$ROOT_DIR/web/icons/Icon-maskable-512.png"

# macOS asset catalog.
for size in 16 32 64 128 256 512 1024; do
  render "$SOURCE_ICON" "$size" \
    "$ROOT_DIR/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_${size}.png"
done

# iPhone and iPad icon slots. iOS store icons must not contain transparency.
while read -r name size; do
  render_opaque "$size" \
    "$ROOT_DIR/ios/Runner/Assets.xcassets/AppIcon.appiconset/$name"
done <<'IOS_ICONS'
Icon-App-20x20@1x.png 20
Icon-App-20x20@2x.png 40
Icon-App-20x20@3x.png 60
Icon-App-29x29@1x.png 29
Icon-App-29x29@2x.png 58
Icon-App-29x29@3x.png 87
Icon-App-40x40@1x.png 40
Icon-App-40x40@2x.png 80
Icon-App-40x40@3x.png 120
Icon-App-60x60@2x.png 120
Icon-App-60x60@3x.png 180
Icon-App-76x76@1x.png 76
Icon-App-76x76@2x.png 152
Icon-App-83.5x83.5@2x.png 167
Icon-App-1024x1024@1x.png 1024
IOS_ICONS

# Android legacy launcher icons.
while read -r density legacy_size adaptive_size; do
  render "$SOURCE_ICON" "$legacy_size" \
    "$ROOT_DIR/android/app/src/main/res/mipmap-${density}/ic_launcher.png"
  render "$FOREGROUND_ICON" "$adaptive_size" \
    "$ROOT_DIR/android/app/src/main/res/drawable-${density}/ic_launcher_foreground.png"
  render "$MONOCHROME_ICON" "$adaptive_size" \
    "$ROOT_DIR/android/app/src/main/res/drawable-${density}/ic_launcher_monochrome.png"
done <<'ANDROID_ICONS'
mdpi 48 108
hdpi 72 162
xhdpi 96 216
xxhdpi 144 324
xxxhdpi 192 432
ANDROID_ICONS

# Windows embeds one ICO containing every commonly displayed size.
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/mdslens-ico.XXXXXX")"
ico_inputs=()
for size in 16 24 32 48 64 128 256; do
  icon="$temporary_dir/icon-${size}.png"
  render "$SOURCE_ICON" "$size" "$icon"
  ico_inputs+=("$icon")
done
magick "${ico_inputs[@]}" "$ROOT_DIR/windows/runner/resources/app_icon.ico"
rm -rf "$temporary_dir"

# Windows MSIX manifest resources use exact unqualified scale-100 dimensions.
render "$SOURCE_ICON" 44 \
  "$ROOT_DIR/windows/runner/resources/msix/Square44x44Logo.png"
render "$SOURCE_ICON" 150 \
  "$ROOT_DIR/windows/runner/resources/msix/Square150x150Logo.png"
render "$SOURCE_ICON" 50 \
  "$ROOT_DIR/windows/runner/resources/msix/StoreLogo.png"

echo "MDSLens platform icons regenerated from assets/app_icon.svg"
