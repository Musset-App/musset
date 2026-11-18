#!/bin/bash
# Builds musset-typeset (Musset's reading engine, Rust on the Typst library) as an XCFramework for the
# MussetPage package: macOS (arm64 + x86_64) and iOS (device, and simulator arm64 + x86_64).
#   scripts/build-typeset.sh            release build
#   scripts/build-typeset.sh --debug    faster to build, much slower to run
#   scripts/build-typeset.sh --mac-only the macOS slice alone (CI, and the Mac app's release)
# Output: Packages/MussetPage/MussetTypeset.xcframework (not in git: run this after a fresh clone).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
CRATE="$ROOT/musset-typeset"
OUT="$ROOT/Packages/MussetPage/MussetTypeset.xcframework"
PROFILE=release; FLAG=--release; MAC_ONLY=
for a in "$@"; do
  case "$a" in --debug) PROFILE=debug; FLAG= ;; --mac-only) MAC_ONLY=1 ;; esac
done

command -v cargo >/dev/null || { echo "error: Rust is needed (https://rustup.rs)" >&2; exit 1; }
TARGETS=(aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios)
[ -n "$MAC_ONLY" ] && TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
INSTALLED="$(rustup target list --installed 2>/dev/null || true)"
for t in "${TARGETS[@]}"; do
  grep -qx "$t" <<<"$INSTALLED" || rustup target add "$t"
done

# Xcode's own environment (when run from a build phase) would point cargo at the wrong SDK.
unset SDKROOT MACOSX_DEPLOYMENT_TARGET IPHONEOS_DEPLOYMENT_TARGET
export MACOSX_DEPLOYMENT_TARGET=14.0 IPHONEOS_DEPLOYMENT_TARGET=17.0
TARGET_DIR="${CARGO_TARGET_DIR:-$CRATE/target}"
export CARGO_TARGET_DIR="$TARGET_DIR"
# No LLVM bitcode in the objects: it would more than double the libraries and nothing here uses it.
export RUSTFLAGS="${RUSTFLAGS:-} -C embed-bitcode=no"
for t in "${TARGETS[@]}"; do
  echo "→ $t"
  (cd "$CRATE" && cargo build $FLAG --lib --target "$t")
done

lib() { echo "$TARGET_DIR/$1/$PROFILE/libmusset_typeset.a"; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/macos" "$WORK/ios" "$WORK/ios-sim" "$WORK/headers"
lipo -create "$(lib aarch64-apple-darwin)" "$(lib x86_64-apple-darwin)" -output "$WORK/macos/libmusset_typeset.a"
if [ -z "$MAC_ONLY" ]; then
  cp "$(lib aarch64-apple-ios)" "$WORK/ios/libmusset_typeset.a"
  lipo -create "$(lib aarch64-apple-ios-sim)" "$(lib x86_64-apple-ios)" -output "$WORK/ios-sim/libmusset_typeset.a"
fi
cp "$CRATE/include/musset_typeset.h" "$CRATE/include/module.modulemap" "$WORK/headers/"
# Debug symbols are not needed in the app; they make the libraries several times larger.
[ "$PROFILE" = release ] && for d in macos ios ios-sim; do [ -f "$WORK/$d/libmusset_typeset.a" ] && strip -S -x "$WORK/$d/libmusset_typeset.a" 2>/dev/null || true; done

rm -rf "$OUT"
SLICES=(-library "$WORK/macos/libmusset_typeset.a" -headers "$WORK/headers")
[ -z "$MAC_ONLY" ] && SLICES+=(-library "$WORK/ios/libmusset_typeset.a" -headers "$WORK/headers" \
  -library "$WORK/ios-sim/libmusset_typeset.a" -headers "$WORK/headers")
xcodebuild -create-xcframework "${SLICES[@]}" -output "$OUT" >/dev/null
echo "$OUT ($(du -sh "$OUT" | cut -f1))"
