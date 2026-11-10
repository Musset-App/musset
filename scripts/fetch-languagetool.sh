#!/bin/sh
# Prepares the LanguageTool that ships inside Musset, for spelling and grammar in its six languages:
# the official LanguageTool release trimmed to English, French, German, Spanish, Italian and Portuguese,
# and a small Java runtime made with jlink from Eclipse Temurin. Both downloads are checked against pinned
# SHA-256s (languagetool.org publishes none: the pin is the one taken on 2026-11-09).
# Cached in ~/Library/Caches/Musset-build; prints the folder to copy into the app (it holds jre/ and languagetool/).
#   scripts/fetch-languagetool.sh
set -eu

LT=6.6
LT_SHA=53600506b399bb5ffe1e4c8dec794fd378212f14aaf38ccef9b6f89314d11631
JDK=21.0.13+9
JDK_FILE=OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.13_9.tar.gz
JDK_SHA=bf036b35b071bfb2f54f2c0af8ee8d88afa95ee6eb3dce02c0f94cfc2524d04a
KEEP="en fr de es it pt"

CACHE="$HOME/Library/Caches/Musset-build"
OUT="$CACHE/languagetool-bundle-$LT-$JDK"
if [ -x "$OUT/jre/bin/java" ] && [ -f "$OUT/languagetool/languagetool-server.jar" ]; then echo "$OUT"; exit 0; fi

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
# Intel native code is never loaded on Apple silicon: out of the jars, so nothing unsigned is left for x86_64.
for jar in "$lt"/libs/*.jar; do
  natives=$(unzip -Z1 "$jar" 2>/dev/null | grep -E '\.(dylib|jnilib|so|dll)$' | grep -viE 'aarch64|aarch_64|arm64' || true)
  [ -n "$natives" ] && echo "$natives" | xargs zip -qd "$jar" >/dev/null
done

# A runtime with only the modules LanguageTool's server uses (jdeps), no man pages, no headers.
"$JAVA_HOME/bin/jlink" --add-modules java.base,java.compiler,java.desktop,java.instrument,java.logging,java.management,java.naming,java.net.http,java.scripting,java.sql,java.xml,jdk.attach,jdk.crypto.ec,jdk.httpserver,jdk.jdi,jdk.management,jdk.unsupported \
  --strip-debug --no-man-pages --no-header-files --compress=zip-6 --output "$OUT/jre"

echo "$OUT"
