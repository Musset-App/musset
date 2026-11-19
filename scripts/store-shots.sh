#!/bin/zsh
# The composed screenshots for directories and stores (2880 × 1800): a headline, the app's window, callouts.
# From scripts/store-shots/template.html and slides.js, over the raw captures of scripts/site-shots.sh
# (build/site-shots/<lang>/), rendered with headless Chrome. Writes build/store-shots/<lang>/<n>-<name>.png
# and a JPEG of each in website/assets/store/<lang>/, published with the site; the English ones also go to
# screenshots/ for the README.
#   scripts/store-shots.sh           English
#   scripts/store-shots.sh en fr     some languages
#   SLIDES="1 6" scripts/store-shots.sh    only these
set -euo pipefail
cd "$(dirname "$0")/.."
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -x "$CHROME" ] || { echo "Chrome not found: set CHROME to a Chromium binary" >&2; exit 1; }
if (( $# )); then LANGS=("$@"); else LANGS=(en); fi
NAMES=(${(f)"$(grep -o 'id: "[a-z]*"' scripts/store-shots/slides.js | cut -d'"' -f2)"})
PROFILE=$(mktemp -d)
for lang in $LANGS; do
  [ -d "build/site-shots/$lang" ] || { echo "no captures for $lang: run scripts/site-shots.sh $lang" >&2; exit 1; }
  out="build/store-shots/$lang"; mkdir -p "$out"
  for n in ${=SLIDES:-$(seq 1 $#NAMES)}; do
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files --user-data-dir="$PROFILE" \
      --force-device-scale-factor=1 --window-size=2880,1800 --virtual-time-budget=4000 \
      --screenshot="$PWD/$out/$n-$NAMES[$n].png" "file://$PWD/scripts/store-shots/template.html?lang=$lang&slide=$n" >/dev/null 2>&1
    # A JPEG beside the site's pictures too, so a directory that takes pictures by address can fetch it:
    # https://musset.app/assets/store/<lang>/<n>-<name>.jpg
    mkdir -p "website/assets/store/$lang"
    sips -s format jpeg -s formatOptions 90 "$out/$n-$NAMES[$n].png" --out "website/assets/store/$lang/$n-$NAMES[$n].jpg" >/dev/null
    # And the English ones at 1920 wide for the README (screenshots/).
    [ "$lang" = en ] && sips --resampleWidth 1920 -s format jpeg -s formatOptions 86 "$out/$n-$NAMES[$n].png" --out "screenshots/$NAMES[$n].jpg" >/dev/null
    echo "$out/$n-$NAMES[$n].png"
  done
done
rm -rf "$PROFILE"
