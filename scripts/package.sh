#!/bin/zsh
# Builds Musset for distribution outside the App Store: Release, Developer ID, hardened runtime,
# Apple silicon only: the bundled typst comes from Homebrew and has no Intel slice.
# notarized and stapled, in a DMG. Result: build/dist/Musset-<version>.dmg
# Needs the notary credentials once: xcrun notarytool store-credentials AC_NOTARY
# `--sign-only` stops before anything is sent to Apple.
set -euo pipefail
cd "$(dirname "$0")/.."

# The Developer ID to sign with: MUSSET_SIGN_IDENTITY, or scripts/local.env (ignored by git) that sets it.
[ -f scripts/local.env ] && source scripts/local.env
IDENTITY="${MUSSET_SIGN_IDENTITY:?set MUSSET_SIGN_IDENTITY to your \"Developer ID Application: …\" certificate}"
PROFILE="AC_NOTARY"
DIST="build/dist"
DERIVED="build/release"

xcodegen generate >/dev/null
xcodebuild -project Musset.xcodeproj -scheme Musset -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO COPY_PHASE_STRIP=YES build | grep -E "error:|\*\* BUILD" || true

BUILT="$DERIVED/Build/Products/Release/Musset.app"
[ -x "$BUILT/Contents/MacOS/Musset" ] || { echo "No build"; exit 1; }
# A Finder window open on the folder keeps writing .DS_Store into it: empty it rather than fail.
rm -rf "$DIST" 2>/dev/null || { sleep 1; rm -rf "$DIST" 2>/dev/null || true; }
mkdir -p "$DIST"; rm -rf "$DIST/Musset.app"
APP="$DIST/Musset.app"
ditto "$BUILT" "$APP"
chmod -R u+w "$APP"
xattr -cr "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")

# LanguageTool: the native libraries inside its jars, then every binary of its Java runtime, each signed.
LT="${APP:A}/Contents/Resources/LanguageTool"
if [ -d "$LT" ]; then
  WORK=$(mktemp -d)
  for jar in "$LT"/languagetool/libs/*.jar(N); do
    for n in ${(f)"$(unzip -Z1 "$jar" | grep -E '\.(dylib|jnilib)$' || true)"}; do
      rm -rf "$WORK/x"; mkdir -p "$WORK/x"
      (cd "$WORK/x" && unzip -q "$jar" "$n" && codesign --force --options runtime --timestamp --sign "$IDENTITY" "$n" && zip -q "$jar" "$n")
    done
  done
  rm -rf "$WORK"
  find "$LT/jre" -type f | while read -r f; do
    file -b "$f" | grep -q "Mach-O" || continue
    codesign --force --options runtime --timestamp --entitlements scripts/LanguageTool.entitlements --sign "$IDENTITY" "$f"
  done
fi

# Inside out: --deep doesn't reach the tools in Resources/bin, and notarization would refuse them.
for tool in "$APP"/Contents/Resources/bin/*(N); do
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$tool"
done
codesign --force --options runtime --timestamp --entitlements scripts/Musset.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Signed $APP ($VERSION)"
[ "${1:-}" = "--sign-only" ] && exit 0

ZIP="$DIST/Musset.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait | tee "$DIST/notary-app.log"
grep -q "status: Accepted" "$DIST/notary-app.log"
xcrun stapler staple "$APP"
rm -f "$ZIP"

ROOT="$DIST/dmgroot"
mkdir -p "$ROOT"
ditto "$APP" "$ROOT/Musset.app"
ln -s /Applications "$ROOT/Applications"
DMG="$DIST/Musset-$VERSION.dmg"
hdiutil create -volname "Musset" -srcfolder "$ROOT" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$ROOT"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait | tee "$DIST/notary-dmg.log"
grep -q "status: Accepted" "$DIST/notary-dmg.log"
xcrun stapler staple "$DMG"

# As someone downloading it would get it.
MOUNT=$(hdiutil attach "$DMG" -nobrowse | awk -F'\t' '/\/Volumes\//{print $NF; exit}')
spctl --assess --type execute --verbose=4 "$MOUNT/Musset.app"
hdiutil detach "$MOUNT" >/dev/null
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
echo "Ready: $DMG"
