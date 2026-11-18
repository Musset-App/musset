#!/bin/zsh
# Releases Musset outside the App Store: a notarized DMG (scripts/package.sh), signed for Sparkle, uploaded to the
# R2 bucket behind musset.app, and announced in the update feed. Afterwards:
#   https://musset.app/download                 the latest DMG (what the website's buttons point to)
#   https://musset.app/download/Musset-X.Y.Z.dmg each release, kept
#   https://musset.app/appcast.xml              Sparkle's feed, newest first
#
#   scripts/release.sh 0.2.0 "What's new, one line or a few"
#   scripts/release.sh 0.2.0 "…" --dry-run      build, notarize and sign; upload nothing
#
# The build number comes from the version (0.2.0 → 200), so it grows with it, on this Mac or in CI. Needs, on this Mac: the Developer ID and notary profile
# package.sh needs, the Sparkle key in the keychain (or MUSSET_SPARKLE_KEY_FILE), and wrangler logged in to the
# account that holds the bucket (or CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID, as in CI).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh X.Y.Z \"release notes\" [--dry-run]}"
NOTES="${2:-}"
DRY="${3:-}"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "version must be X.Y.Z" >&2; exit 1; }
BUCKET="musset-downloads"
SITE="https://musset.app"
WRANGLER=(npx --yes wrangler@4.40.0)
[ -n "$(git status --porcelain --untracked-files=no)" ] && [ "$DRY" != "--dry-run" ] && { echo "commit first: a release is built from a clean tree" >&2; exit 1; }

export MUSSET_VERSION="$VERSION"
IFS=. read -r MAJ MIN PAT <<< "$VERSION"
export MUSSET_BUILD=$(( MAJ * 10000 + MIN * 100 + PAT ))   # 0.2.0 → 200: grows with the version, wherever it's built
scripts/package.sh
DMG="build/dist/Musset-$VERSION.dmg"
NAME="Musset-$VERSION.dmg"

# Sparkle's EdDSA signature: the key in the keychain, or a file (CI).
BIN=$(find build -path '*artifacts/sparkle/Sparkle/bin/sign_update' -type f 2>/dev/null | head -1)
[ -x "$BIN" ] || { echo "sign_update not found: build the app once so SwiftPM fetches Sparkle" >&2; exit 1; }
SIG=$("$BIN" ${MUSSET_SPARKLE_KEY_FILE:+--ed-key-file "$MUSSET_SPARKLE_KEY_FILE"} "$DMG")   # sparkle:edSignature="…" length="…"
echo "Signed for Sparkle: $SIG"

# The feed: this release on top of the ones already published.
FEED="build/dist/appcast.xml"
curl -fsS "$SITE/appcast.xml" -o "$FEED.old" 2>/dev/null || rm -f "$FEED.old"
python3 -I - "$FEED" "$VERSION" "$MUSSET_BUILD" "$SITE/download/$NAME" "$SIG" "$NOTES" <<'PY'
import html, os, re, sys
from email.utils import formatdate
out, version, build, url, sig, notes = sys.argv[1:7]
old = open(out + ".old", encoding="utf-8").read() if os.path.exists(out + ".old") else ""
items = re.findall(r"<item>.*?</item>", old, re.S)
items = [i for i in items if f"<sparkle:shortVersionString>{version}<" not in i]
rest = "\n    ".join(items)
desc = "".join(f"<p>{html.escape(l)}</p>" for l in notes.splitlines() if l.strip())
item = f"""<item>
      <title>Musset {version}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[{desc}]]></description>
      <enclosure url="{url}" type="application/x-apple-diskimage" {sig.strip()}/>
    </item>"""
feed = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Musset</title>
    <link>https://musset.app/appcast.xml</link>
    <language>en</language>
    {item}
    {rest}
  </channel>
</rss>
"""
open(out, "w", encoding="utf-8").write(feed)
PY
rm -f "$FEED.old"
printf '{"version":"%s","build":%s,"file":"%s"}\n' "$VERSION" "$MUSSET_BUILD" "$NAME" > build/dist/latest.json

if [ "$DRY" = "--dry-run" ]; then echo "Dry run: $DMG, build/dist/appcast.xml and latest.json are ready; nothing uploaded."; exit 0; fi

# The DMG first, then the feed and the pointer: nobody is offered a file that isn't there yet.
"${WRANGLER[@]}" r2 object put "$BUCKET/$NAME" --file "$DMG" --content-type application/x-apple-diskimage --remote
"${WRANGLER[@]}" r2 object put "$BUCKET/appcast.xml" --file "$FEED" --content-type "application/rss+xml; charset=utf-8" --remote
"${WRANGLER[@]}" r2 object put "$BUCKET/latest.json" --file build/dist/latest.json --content-type application/json --remote
git tag -f "v$VERSION" >/dev/null
echo "Released Musset $VERSION (build $MUSSET_BUILD): $SITE/download"
