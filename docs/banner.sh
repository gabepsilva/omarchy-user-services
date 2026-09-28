#!/bin/sh
# Render docs/banner.html to preview.png (1600×900) with headless Chromium.
# preview.png sits in the repo root because that is where the Omarchy
# marketplace looks for a plugin's listing image. Drawn at 2× and scaled
# down, so text edges come out smooth.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
chromium --headless=new --disable-gpu --hide-scrollbars --no-first-run \
  --user-data-dir="$tmp/profile" --force-device-scale-factor=2 \
  --window-size=1600,900 --screenshot="$tmp/banner@2x.png" \
  "file://$dir/banner.html" >/dev/null 2>&1
magick "$tmp/banner@2x.png" -filter Lanczos -resize 1600x900 "$dir/../preview.png"
echo "$(cd "$dir/.." && pwd)/preview.png"
