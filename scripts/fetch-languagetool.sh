#!/bin/sh
# Prepares the LanguageTool that ships inside Musset, for spelling and grammar in its six languages:
# the official LanguageTool release trimmed to English, French, German, Spanish, Italian and Portuguese,
# and a small Java runtime made with jlink from Eclipse Temurin. Both downloads are checked against pinned
# SHA-256s (languagetool.org publishes none: the pin is the one taken on 2026-11-09).
# Cached in ~/Library/Caches/Musset-build; prints the folder to copy into the app (it holds jre/ and languagetool/).
#   scripts/fetch-languagetool.sh                 # Apple silicon
#   scripts/fetch-languagetool.sh arm64 x86_64    # Intel too: a second runtime, jre-x86_64/, beside the first
# A Java runtime can't be made universal (its lib/modules differs by architecture), hence one folder each;
# the app starts the one for the Mac it runs on (LanguageToolServer.java).
set -eu

LT=6.6
LT_SHA=53600506b399bb5ffe1e4c8dec794fd378212f14aaf38ccef9b6f89314d11631
JDK=21.0.13+9
JDK_FILE=OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.13_9.tar.gz
JDK_SHA=bf036b35b071bfb2f54f2c0af8ee8d88afa95ee6eb3dce02c0f94cfc2524d04a
JDK_FILE_x86_64=OpenJDK21U-jdk_x64_mac_hotspot_21.0.13_9.tar.gz
JDK_SHA_x86_64=9aa1d1c17ae5467a022679e7e0af5c00797d94ac462ed1a46f4db07a8a34a6dd
KEEP="en fr de es it pt"

CACHE="$HOME/Library/Caches/Musset-build"
INTEL=""; ARM=1
case " $* " in *" x86_64 "*) INTEL=1 ;; esac
# Intel alone (a build for Intel Macs only): no Apple silicon runtime in it.
case " $* " in *" arm64 "*|"  ") ;; *) [ -n "$INTEL" ] && ARM="" ;; esac
KIND=""; [ -n "$INTEL" ] && KIND="-universal"; [ -z "$ARM" ] && KIND="-x86_64"
OUT="$CACHE/languagetool-bundle-$LT-$JDK$KIND"
if { [ -z "$ARM" ] || [ -x "$OUT/jre/bin/java" ]; } && { [ -z "$INTEL" ] || [ -x "$OUT/jre-x86_64/bin/java" ]; } && [ -f "$OUT/languagetool/languagetool-server.jar" ]; then echo "$OUT"; exit 0; fi

# Each download in its own fresh folder.
lt_dir="$CACHE/languagetool-$LT"
if [ ! -d "$lt_dir/LanguageTool-$LT" ]; then
  rm -rf "$lt_dir"; mkdir -p "$lt_dir"
  curl -fsSL -o "$lt_dir/lt.zip" "https://languagetool.org/download/LanguageTool-$LT.zip"
  echo "$LT_SHA  $lt_dir/lt.zip" | shasum -a 256 -c - >&2
  unzip -q "$lt_dir/lt.zip" -d "$lt_dir"
fi
jdk_dir="$CACHE/temurin-$JDK"
if [ ! -d "$jdk_dir/jdk-$JDK" ]; then
  rm -rf "$jdk_dir"; mkdir -p "$jdk_dir"
  curl -fsSL -o "$jdk_dir/jdk.tar.gz" "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-$(echo $JDK | sed 's/+/%2B/')/$JDK_FILE"
  echo "$JDK_SHA  $jdk_dir/jdk.tar.gz" | shasum -a 256 -c - >&2
  tar xzf "$jdk_dir/jdk.tar.gz" -C "$jdk_dir"
fi
JAVA_HOME="$jdk_dir/jdk-$JDK/Contents/Home"
intel_dir="$CACHE/temurin-$JDK-x86_64"
if [ -n "$INTEL" ] && [ ! -d "$intel_dir/jdk-$JDK" ]; then
  rm -rf "$intel_dir"; mkdir -p "$intel_dir"
  curl -fsSL -o "$intel_dir/jdk.tar.gz" "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-$(echo $JDK | sed 's/+/%2B/')/$JDK_FILE_x86_64"
  echo "$JDK_SHA_x86_64  $intel_dir/jdk.tar.gz" | shasum -a 256 -c - >&2
  tar xzf "$intel_dir/jdk.tar.gz" -C "$intel_dir"
  rm -f "$intel_dir/jdk.tar.gz"
fi

rm -rf "$OUT"; mkdir -p "$OUT"
lt="$OUT/languagetool"
cp -R "$lt_dir/LanguageTool-$LT" "$lt"
rm -f "$lt/testrules.sh" "$lt/testrules.bat" "$lt/languagetool.jar" "$lt/languagetool-commandline.jar"

# Only Musset's six languages: the others' data and dictionaries go (their rule classes stay: the registry loads them).
for kind in resource; do
  for d in "$lt/org/languagetool/$kind"/*/; do
    code=$(basename "$d")
    # The language detector still reads every language's common words: that file stays.
    case " $KEEP " in *" $code "*) ;; *) [ ${#code} -le 3 ] && find "$d" -type f ! -name common_words.txt -delete ;; esac
  done
done
for f in "$lt"/org/languagetool/MessagesBundle_*.properties; do
  code=$(basename "$f" .properties | sed 's/MessagesBundle_//; s/_.*//')
  case " $KEEP " in *" $code "*) ;; *) rm -f "$f" ;; esac
done
# The language registry stays whole: the language detector names every language at start, even unused ones.
for jar in dutch-pos-dict catalan-pos-dict asturian-pos-dict languagetool-ga-dicts hanlp lucene-gosen-ipadic \
           morfologik-ukrainian-lt morfologik-crh-lt morphology-el languagetool-core-tests junit hamcrest-core; do
  rm -f "$lt/libs/$jar.jar"
done
# Native code for other machines is never loaded: out of the jars, so nothing unsigned is left in them.
# Without Intel, that is all x86_64 code; with it, the Mac's x86_64 libraries stay.
WANTED='osx_x86_64|darwin-x86-64'
[ -n "$ARM" ] && WANTED="aarch64|aarch_64|arm64${INTEL:+|$WANTED}"
for jar in "$lt"/libs/*.jar; do
  natives=$(unzip -Z1 "$jar" 2>/dev/null | grep -E '\.(dylib|jnilib|so|dll)$' | grep -viE "$WANTED" || true)
  [ -n "$natives" ] && echo "$natives" | xargs zip -qd "$jar" >/dev/null
done

# A runtime with only the modules LanguageTool's server uses (jdeps), no man pages, no headers.
# jlink from the Apple silicon JDK makes the Intel one too, from the Intel JDK's modules.
MODULES=java.base,java.compiler,java.desktop,java.instrument,java.logging,java.management,java.naming,java.net.http,java.scripting,java.sql,java.xml,jdk.attach,jdk.crypto.ec,jdk.httpserver,jdk.jdi,jdk.management,jdk.unsupported
runtime() {  # <jmods folder> <output folder>
  "$JAVA_HOME/bin/jlink" --module-path "$1" --add-modules "$MODULES" \
    --strip-debug --no-man-pages --no-header-files --compress=zip-6 --output "$2"
}
[ -n "$ARM" ] && runtime "$JAVA_HOME/jmods" "$OUT/jre"
[ -n "$INTEL" ] && runtime "$intel_dir/jdk-$JDK/Contents/Home/jmods" "$OUT/jre-x86_64"
true

echo "$OUT"
