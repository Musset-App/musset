#!/bin/zsh
# Musset Reader's screenshots for the App Store, taken in the simulator on a local server (never git.musset.app):
# the shelf, a page by day and by night, a conversation, the activity, the circle.
#   scripts/reader-shots.sh <simulator udid> <out folder> [user] [password]
# Needs the Reader built for that simulator (signed ad hoc, or its keychain refuses the key) and the local stack
# of server/dev-proxy.py on port 3940 with a book shared with <user>.
set -euo pipefail
cd "$(dirname "$0")/.."
SIM="${1:?usage: scripts/reader-shots.sh <simulator udid> <out folder> [user] [password]}"
OUT="${2:?the folder for the pictures}"
USER_NAME="${3:-claire}"; PASSWORD="${4:-reader-pass-1234}"
APP="${MUSSET_READER_APP:?set MUSSET_READER_APP to the built MussetReader.app}"
mkdir -p "$OUT"
xcrun simctl status_bar "$SIM" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
xcrun simctl install "$SIM" "$APP"
n=0
for screen in shelf book night talk activity circle; do
  n=$((n + 1))
  xcrun simctl terminate "$SIM" app.musset.Reader 2>/dev/null || true
  xcrun simctl ui "$SIM" appearance "$([ $screen = night ] && echo dark || echo light)"
  SIMCTL_CHILD_MUSSET_SERVER=http://localhost:3940 SIMCTL_CHILD_MUSSET_READER_USER="$USER_NAME" SIMCTL_CHILD_MUSSET_READER_PASSWORD="$PASSWORD" \
    SIMCTL_CHILD_MUSSET_READER_SCREEN="$screen" SIMCTL_CHILD_MUSSET_READER_BOOK="${MUSSET_READER_BOOK:-the-salt-road}" xcrun simctl launch "$SIM" app.musset.Reader >/dev/null
  # The page is typeset on the phone: give it time.
  sleep "$([ $screen = book ] || [ $screen = night ] || [ $screen = talk ] && echo 16 || echo 7)"
  xcrun simctl io "$SIM" screenshot "$OUT/$n-$screen.png" >/dev/null 2>&1
  echo "$OUT/$n-$screen.png"
done
xcrun simctl ui "$SIM" appearance light
