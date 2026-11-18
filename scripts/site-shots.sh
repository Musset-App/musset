#!/bin/zsh
# The website's screenshots, in each of its languages: the app in that language on the demo book written in it
# (MussetTests/SiteDemo/<lang>.json: chapters, notes, chat, versions, Bible, board, history), its typeset pages and
# its country's manuscript. Writes website/assets/<lang>/:
#   whole windows, 1920 × 1200 (a 1440 × 900-point window captured at 2×):
#     editor         the chapter being written
#     reading        the chapter beside its typeset page
#     versions       two versions of a chapter side by side
#     panes          a chapter and the planning board in two panes
#     bible          a character's sheet: the author's notes and what the book says
#     cast           the characters in columns, by how much they are in the book
#     scenes         a chapter as scene cards
#     overview       the whole book: its numbers and each chapter's opening and close
#     history        the book's history: sittings, a milestone, a track
#     board          the planning board in a window of its own
#     board-dark     the same at night
#     ultra-focus    Ultra Focus: the whole screen, only the text
#     second-screen  a window of its own with a sheet and the board, for a second monitor
#   panels cut out at full size:
#     notes, corrections (the top of the inspector), chat (the whole AI Reader panel), command-bar
#   pages: book-left, book-right, manuscript
#   scripts/site-shots.sh            all six
#   scripts/site-shots.sh fr de      some
#   REUSE=1 scripts/site-shots.sh    crop again from the last captures, without running the app
# Runs the tests under another bundle id and derived data, so a Musset open on this Mac keeps its settings.
set -euo pipefail
cd "$(dirname "$0")/.."
if (( $# )); then LANGS=("$@"); else LANGS=(en fr de es it pt); fi
RAW="build/site-shots"
DERIVED="build/shots"

xcodegen generate >/dev/null
xcodebuild build-for-testing -project Musset.xcodeproj -scheme Musset -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" PRODUCT_BUNDLE_IDENTIFIER=dev.scratch.musset.tests | grep -E "error:|\*\* TEST BUILD" || true

for L in $LANGS; do
  echo "→ $L"
  if [ -z "${REUSE:-}" ]; then
  rm -rf "$RAW/$L"; mkdir -p "$RAW/$L"
  TEST_RUNNER_MUSSET_SITE_SHOTS="$PWD/$RAW/$L" TEST_RUNNER_MUSSET_SITE_LANG="$L" \
    xcodebuild test-without-building -project Musset.xcodeproj -scheme Musset -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED" PRODUCT_BUNDLE_IDENTIFIER=dev.scratch.musset.tests -only-testing:MussetTests/SiteShots \
    > "$RAW/$L.log" 2>&1 || { grep -E "error:|failed" "$RAW/$L.log" | head -5; echo "$L failed (log: $RAW/$L.log)"; exit 1; }
  fi

  OUT="website/assets/$L"; rm -rf "$OUT"; mkdir -p "$OUT"
  S="$RAW/$L"
  jpg() { sips -s format jpeg -s formatOptions "${3:-84}" "$1" --out "$OUT/$2.jpg" >/dev/null; }
  # The window is 1440 × 900 points, captured at 2×: whole windows at 1920 wide, panels cut out at full size.
  for pair in write-light:editor read-light:reading versions-light:versions panes-light:panes bible-light:bible \
              cast-light:cast scenes-light:scenes overview-light:overview history-light:history board-light:board board-dark:board-dark ultra-dark:ultra-focus second-light:second-screen; do
    sips --resampleWidth 1920 "$S/${pair%%:*}.png" --out "$S/w.png" >/dev/null; jpg "$S/w.png" "${pair##*:}" 84
  done
  # The inspector: right of its divider (2113), under the title bar's line (88).
  sips -c 620 766 --cropOffset 88 2114 "$S/notes-light.png" --out "$S/c.png" >/dev/null; jpg "$S/c.png" notes 90
  sips -c 1712 766 --cropOffset 88 2114 "$S/chat-light.png" --out "$S/c.png" >/dev/null; jpg "$S/c.png" chat 90
  sips -c 690 766 --cropOffset 88 2114 "$S/revise-light.png" --out "$S/c.png" >/dev/null; jpg "$S/c.png" corrections 90
  sips -c 1011 1276 --cropOffset 246 802 "$S/palette-light.png" --out "$S/c.png" >/dev/null; jpg "$S/c.png" command-bar 88
  # Pages: the book's chapter opening (page 3, after the title and its blank verso) and the next one; the manuscript's
  # second page (with its header).
  pdftoppm -f 3 -l 4 -r 200 -png "$S/book.pdf" "$S/book"
  pdftoppm -f 2 -l 2 -r 200 -png "$S/manuscript.pdf" "$S/ms"
  for pair in book-3:book-left book-4:book-right ms-2:manuscript; do
    src=$(ls "$S/${pair%%:*}"*.png | head -1)
    sips --resampleWidth 900 "$src" --out "$S/p.png" >/dev/null; jpg "$S/p.png" "${pair##*:}" 88
  done
  rm -f "$S/w.png" "$S/c.png" "$S/p.png"
  echo "  $(ls "$OUT" | wc -l | tr -d ' ') images in $OUT"
done
