#!/bin/zsh
# Musset Reader's composed App Store screenshots: a headline over the device, for the 6.9-inch iPhone
# (1320 × 2868) and the 13-inch iPad (2064 × 2752). From scripts/reader-shots/template.html, over the captures
# of scripts/reader-shots.sh in docs/listing-kit/reader/raw/<device>/, rendered with headless Chrome.
# Writes docs/listing-kit/reader/store/<device>/<n>-<name>.png (no transparency, as the store asks).
#   scripts/reader-store-shots.sh
set -euo pipefail
cd "$(dirname "$0")/.."
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -x "$CHROME" ] || { echo "Chrome not found: set CHROME to a Chromium binary" >&2; exit 1; }
NAMES=(${(f)"$(grep -o 'id: "[a-z]*"' scripts/reader-shots/template.html | cut -d'"' -f2)"})
PROFILE=$(mktemp -d)
for device in iphone ipad; do
  [ $device = iphone ] && size=1320,2868 || size=2064,2752
  out="docs/listing-kit/reader/store/$device"; mkdir -p "$out"
  # On the tablet the lists are mostly empty paper: its set keeps the page, the conversation and the night.
  for n in $([ $device = ipad ] && echo 1 2 4 || seq 1 $#NAMES); do
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files --user-data-dir="$PROFILE" \
      --force-device-scale-factor=1 --window-size=$size --virtual-time-budget=4000 \
      --screenshot="$PWD/$out/$n-$NAMES[$n].png" "file://$PWD/scripts/reader-shots/template.html?device=$device&slide=$n" >/dev/null 2>&1
    echo "$out/$n-$NAMES[$n].png"
  done
done
rm -rf "$PROFILE"
