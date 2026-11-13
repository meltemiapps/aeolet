#!/bin/sh
# Proves the mock Gmail server is compiled into Debug builds only.
# Builds Release and Debug, then fails if the Release app contains any trace of the mock,
# or if the Debug app doesn't (which would mean this check can't see the mock at all).
#
# Usage: Scripts/check-release-excludes-mock.sh [ios|mac] [output folder]   (default: ios)
set -eu
cd "$(dirname "$0")/.."
PLATFORM="${1:-ios}"
case "$PLATFORM" in
  ios) SCHEME=Aeolet; SDK=iphonesimulator; SUFFIX=-iphonesimulator ;;
  mac) SCHEME=AeoletMac; SDK=macosx; SUFFIX= ;;
  *) echo "Usage: $0 [ios|mac] [output folder]"; exit 2 ;;
esac
OUT="${2:-build/release-check-$PLATFORM}"
MARKERS='MockGmail|AeoletMockGmail|AEOLET_MOCK_FAULT|mock-probe|mock-access-|MockKeychain|AeoletWindowSize|AeoletAutoSave'

build() {
  xcodebuild -project Aeolet.xcodeproj -scheme "$SCHEME" -configuration "$1" -sdk "$SDK" \
    -derivedDataPath "$OUT/$1" CODE_SIGNING_ALLOWED=NO build >"$OUT/$1.log" 2>&1 \
    || { tail -40 "$OUT/$1.log"; exit 1; }
  echo "$OUT/$1/Build/Products/$1$SUFFIX/Aeolet.app"
}

# Debug builds keep the code in Aeolet.debug.dylib, so every file in the bundle is scanned.
scan() { find "$1" -type f -print0 | xargs -0 strings -a 2>/dev/null; }
symbols() { find "$1" -type f -print0 | xargs -0 nm 2>/dev/null; }

mkdir -p "$OUT"
debug_app=$(build Debug)
release_app=$(build Release)

debug_hits=$(scan "$debug_app" | grep -cE "$MARKERS" || true)
release_hits=$(scan "$release_app" | grep -cE "$MARKERS" || true)
release_symbols=$(symbols "$release_app" | grep -cE "MockGmail|MockKeychain" || true)

echo "Debug build ($PLATFORM): $debug_hits mock markers"
echo "Release build ($PLATFORM): $release_hits mock markers, $release_symbols mock symbols"
if [ "$debug_hits" -eq 0 ]; then
  echo "FAIL: the Debug build has no mock markers, so this check cannot detect the mock."; exit 1
fi
if [ "$release_hits" -ne 0 ] || [ "$release_symbols" -ne 0 ]; then
  echo "FAIL: the Release build contains mock code:"; scan "$release_app" | grep -E "$MARKERS" | head; exit 1
fi
echo "PASS: the mock is absent from Release."
