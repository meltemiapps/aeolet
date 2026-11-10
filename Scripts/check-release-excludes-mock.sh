#!/bin/sh
# Proves the mock Gmail server is compiled into Debug builds only.
# Builds Release and Debug for the simulator, then fails if the Release app contains any trace of the mock,
# or if the Debug app doesn't (which would mean this check can't see the mock at all).
set -eu
cd "$(dirname "$0")/.."
OUT="${1:-build/release-check}"
MARKERS='MockGmail|AeoletMockGmail|AEOLET_MOCK_FAULT|mock-probe|mock-access-'

build() {
  xcodebuild -project Aeolet.xcodeproj -scheme Aeolet -configuration "$1" -sdk iphonesimulator \
    -derivedDataPath "$OUT/$1" CODE_SIGNING_ALLOWED=NO build >"$OUT/$1.log" 2>&1 \
    || { tail -40 "$OUT/$1.log"; exit 1; }
  echo "$OUT/$1/Build/Products/$1-iphonesimulator/Aeolet.app"
}

# Debug builds keep the code in Aeolet.debug.dylib, so every file in the bundle is scanned.
scan() { find "$1" -type f -print0 | xargs -0 strings -a 2>/dev/null; }
symbols() { find "$1" -type f -print0 | xargs -0 nm 2>/dev/null; }

mkdir -p "$OUT"
debug_app=$(build Debug)
release_app=$(build Release)

debug_hits=$(scan "$debug_app" | grep -cE "$MARKERS" || true)
release_hits=$(scan "$release_app" | grep -cE "$MARKERS" || true)
release_symbols=$(symbols "$release_app" | grep -cE "MockGmail" || true)

echo "Debug build: $debug_hits mock markers"
echo "Release build: $release_hits mock markers, $release_symbols mock symbols"
if [ "$debug_hits" -eq 0 ]; then
  echo "FAIL: the Debug build has no mock markers, so this check cannot detect the mock."; exit 1
fi
if [ "$release_hits" -ne 0 ] || [ "$release_symbols" -ne 0 ]; then
  echo "FAIL: the Release build contains mock code:"; scan "$release_app" | grep -E "$MARKERS" | head; exit 1
fi
echo "PASS: the mock is absent from Release."
