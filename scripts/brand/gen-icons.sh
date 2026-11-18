#!/usr/bin/env bash
# Regenerates every Ninjy icon from the 1024px RGBA glass rings app icon
# (assets/brand/logos/ninjy-icon-light-gold.png). Preserve its rounded corners
# except where the platform needs an opaque light plate. Outputs are committed; re-running
# rewrites them byte-for-byte (PNG date/time chunks are excluded).
#
#   scripts/brand/gen-icons.sh             regenerate in place
#   scripts/brand/gen-icons.sh --sheet F   also write a contact sheet of every icon to F
#
# Needs ImageMagick 7 and libicns (png2icns); without them on PATH the script
# re-runs itself under `nix shell` (no npm dependencies). The sheet labels use
# DejaVu Sans.
set -euo pipefail

if ! command -v magick >/dev/null || ! command -v png2icns >/dev/null; then
  exec nix shell nixpkgs#imagemagick nixpkgs#libicns nixpkgs#dejavu_fonts -c bash "$0" "$@"
fi

sheet=""
if [[ "${1:-}" == "--sheet" ]]; then sheet="${2:?--sheet needs a path}"; fi

root="$(cd "$(dirname "$0")/../.." && pwd)"
src="$root/assets/brand/logos/ninjy-icon-light-gold.png"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

PLATE='#f7f6f2'
# Status dot colours, one per bridgesvc.Tray_Level.
declare -A DOT=([ok]='#22c55e' [warning]='#f59e0b' [error]='#ef4444')
TRAY_SIZES=(16 22 24 32 44)

# Deterministic PNG output: no timestamps, no ancillary text.
png() { echo "-strip -define png:exclude-chunks=date,time,tEXt,zTXt,iTXt -define png:color-type=6 PNG32:$1"; }

# Opaque masters for platforms that apply their own mask. Keep the rings
# inside the maskable icon's central 80% safe circle without cropping them.
plate() {
  local out="$1" icon_size="$2"
  magick -size 1024x1024 "xc:$PLATE" \
    \( "$src" -filter Lanczos -resize "${icon_size}x${icon_size}" \) \
    -gravity center -compose Over -composite $(png "$out")
}

# dot IN OUT COLOUR: a status dot in the bottom-right corner, ringed in the
# plate colour so it reads against the rings at 16px.
dot() {
  local in="$1" out="$2" colour="$3" c=1024
  local d=$(( c * 46 / 100 )) ring=$(( c * 6 / 100 ))
  local cx=$(( c - d / 2 )) cy=$(( c - d / 2 ))
  magick "$in" -fill "$PLATE" -draw "circle $cx,$cy $cx,$((cy - d / 2))" \
    -fill "$colour" -draw "circle $cx,$cy $cx,$((cy - d / 2 + ring))" $(png "$out")
}

# size IN OUT N
size() { magick "$1" -filter Lanczos -resize "$3x$3" $(png "$2"); }

# ico IN OUT N...
ico() {
  local in="$1" out="$2"; shift 2
  local parts=()
  for n in "$@"; do size "$in" "$tmp/ico-$n.png" "$n"; parts+=("$tmp/ico-$n.png"); done
  magick "${parts[@]}" -strip "ICO:$out"
}

# Masters: keep the source artwork intact; macOS adds its standard 100px inset.
magick "$src" $(png "$tmp/app.png")
magick "$src" -filter Lanczos -resize 824x824 -gravity center -background none \
  -extent 1024x1024 $(png "$tmp/mac.png")
plate "$tmp/maskable.png" 800
plate "$tmp/touch.png" 1024
magick "$src" $(png "$tmp/small.png")

mkdir -p "$root/src/ui/electron" "$root/build" "$root/public" "$root/landing-page" "$root/src/bridge/assets/tray"

# Desktop app.
size "$tmp/app.png" "$root/src/ui/electron/icon.png" 1024
ico  "$tmp/app.png" "$root/src/ui/electron/icon.ico" 16 24 32 48 64 128 256
for n in 16 32 64 128 256 512 1024; do size "$tmp/mac.png" "$tmp/icns_$n.png" "$n"; done
# png2icns picks the icns slot from each PNG's size.
png2icns "$root/build/icon.icns" "$tmp"/icns_{16,32,128,256,512,1024}.png >/dev/null

# Web app and landing page.
size "$tmp/app.png"      "$root/public/icon.png"             512
size "$tmp/maskable.png" "$root/public/icon-maskable.png"    512
size "$tmp/touch.png"    "$root/public/apple-touch-icon.png" 180
size "$tmp/small.png"    "$root/public/favicon-32.png"       32
size "$tmp/small.png"    "$root/landing-page/favicon.png"    64

# Bridge tray: one PNG per size and one .ico per level (src/bridge/assets/tray).
for level in ok warning error; do
  dot "$tmp/small.png" "$tmp/tray-$level.png" "${DOT[$level]}"
  for n in "${TRAY_SIZES[@]}"; do
    size "$tmp/tray-$level.png" "$root/src/bridge/assets/tray/tray-$level-$n.png" "$n"
  done
  ico "$tmp/tray-$level.png" "$root/src/bridge/assets/tray/tray-$level.ico" 16 20 24 32 48
done

if [[ -n "$sheet" ]]; then
  # Every committed icon at its real size, labelled, on a mid-grey tile.
  files=(src/ui/electron/icon.png public/icon.png public/icon-maskable.png public/apple-touch-icon.png
         public/favicon-32.png landing-page/favicon.png)
  for level in ok warning error; do
    for n in "${TRAY_SIZES[@]}"; do files+=("src/bridge/assets/tray/tray-$level-$n.png"); done
  done
  args=()
  for f in "${files[@]}"; do
    args+=(-label "${f##*/} $(magick identify -format '%wx%h' "$root/$f")" "$root/$f")
  done
  icns_x="$tmp/icns-x"; mkdir -p "$icns_x"
  icns2png -x -s 512 -o "$icns_x" "$root/build/icon.icns" >/dev/null
  args+=(-label "icon.icns 512" "$icns_x"/*.png)
  magick montage -font DejaVu-Sans -pointsize 12 -fill '#e5e5e5' -background '#2a2a2a' \
    "${args[@]}" -geometry '256x256>+8+8' -tile 6x "$sheet"
fi
