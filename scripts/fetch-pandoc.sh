#!/bin/sh
# Downloads the official pandoc release for macOS, checks it against the pinned SHA-256
# and Apple's Developer ID signature, and prints the path of a binary for the requested
# architectures (several → one universal binary made with lipo).
# Cached in ~/Library/Caches/Musset-build so builds and worktrees share one download.
#   scripts/fetch-pandoc.sh            # this Mac's architecture
#   scripts/fetch-pandoc.sh arm64 x86_64
set -eu

VERSION=3.9.0.2  # the last release built for macOS 14 (3.10 to 3.13 need macOS 15)
SHA_arm64=6e9eca844076bcbb599bbeebbba78a70f93b5307782b85c2c272872812c88875
SHA_x86_64=b9fbceabccbc8f34ac021a50483fc32f8160568d0b4b2c22d81bb29e3054fd82
TEAM=5U2WKE6DES  # John MacFarlane's Developer ID

CACHE="$HOME/Library/Caches/Musset-build/pandoc-$VERSION"
[ $# -eq 0 ] && set -- "$(uname -m)"

one() {
  arch=$1
  dir="$CACHE/$arch"
  bin="$dir/pandoc-$VERSION-$arch/bin/pandoc"
  if [ ! -x "$bin" ]; then
    eval "sha=\${SHA_$arch:-}"
    [ -n "$sha" ] || { echo "error: no pandoc release for $arch" >&2; exit 1; }
    # A fresh, empty folder for each download.
    rm -rf "$dir"; mkdir -p "$dir"
    zip="$dir/pandoc.zip"
    curl -fsSL -o "$zip" "https://github.com/jgm/pandoc/releases/download/$VERSION/pandoc-$VERSION-$arch-macOS.zip"
    echo "$sha  $zip" | shasum -a 256 -c - >&2
    unzip -q "$zip" -d "$dir"
    rm -f "$zip"
  fi
  codesign --verify --strict "$bin"
  codesign -dv "$bin" 2>&1 | grep -q "TeamIdentifier=$TEAM" || { echo "error: $bin is not signed by pandoc's author" >&2; exit 1; }
  echo "$bin"
}

if [ $# -eq 1 ]; then one "$1"; exit 0; fi
parts=""
for a in "$@"; do parts="$parts $(one "$a")"; done
out="$CACHE/universal/pandoc"
mkdir -p "$CACHE/universal"
# shellcheck disable=SC2086
lipo -create $parts -output "$out"
echo "$out"
