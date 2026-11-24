#!/bin/zsh
# Makes the disk image someone downloads: the app, a way to Applications, and a window laid out to say so.
#
#   scripts/dmg/build.sh <Musset.app> <out.dmg> [volume name]
#
# The layout (window size, icon places, the picture behind) is asked of the Finder, on a writable image that is
# then compressed. That takes the Mac's permission for this terminal to control the Finder, asked once. Without it,
# or with MUSSET_PLAIN_DMG=1 (and on CI, where there is no Finder to ask), the image is still made, with a plain window: a release never fails on its looks.
set -euo pipefail
APP="${1:?usage: scripts/dmg/build.sh <Musset.app> <out.dmg> [volume name]}"
DMG="${2:?usage: scripts/dmg/build.sh <Musset.app> <out.dmg> [volume name]}"
VOL="${3:-Musset}"
HERE="$(cd "$(dirname "$0")" && pwd)"
NAME="$(basename "$APP")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/root"
mkdir -p "$ROOT/.background"
ditto "$APP" "$ROOT/$NAME"
ln -s /Applications "$ROOT/Applications"
# One picture for both screen densities.
tiffutil -cathidpicheck "$HERE/background.png" "$HERE/background@2x.png" -out "$ROOT/.background/background.tiff" >/dev/null 2>&1

RW="$WORK/rw.dmg"
hdiutil create -volname "$VOL" -srcfolder "$ROOT" -ov -format UDRW -fs HFS+ "$RW" >/dev/null
if [ -z "${MUSSET_PLAIN_DMG:-}" ] && [ -z "${CI:-}" ]; then
  MOUNT=$(hdiutil attach "$RW" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\//{print $NF; exit}')
  DISK="$(basename "$MOUNT")"
  if ! osascript >/dev/null 2>"$WORK/finder.err" <<OSA
tell application "Finder"
  tell disk "$DISK"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 140, 840, 568}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "$NAME" of container window to {170, 205}
    set position of item "Applications" of container window to {470, 205}
    update without registering applications
    -- The Finder keeps the window's size only once it has been closed and opened again.
    close
    open
    delay 1
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 140, 840, 568}
    update without registering applications
    delay 3
    close
  end tell
end tell
OSA
  then
    echo "warning: the Finder did not lay out the window ($(head -1 "$WORK/finder.err")); the image has a plain one" >&2
  fi
  sync
  hdiutil detach "$MOUNT" >/dev/null
fi
rm -f "$DMG"
hdiutil convert "$RW" -format ULMO -o "$DMG" >/dev/null
echo "Made $DMG"
