#!/bin/zsh
# Regenerates the App Store screenshots from the mock Gmail UI test (ScreenshotUITests), in one run:
#
#   Screenshots/iPhone-6.3  iPhone 17               1206 x 2622  (required by App Store Connect: medium display)
#   Screenshots/iPhone      iPhone 17 Pro Max       1320 x 2868  (6.9-inch, large display)
#   Screenshots/iPad        iPad Pro 13-inch (M5)   2064 x 2752  (13-inch iPad)
#   Screenshots/Mac         this Mac                2880 x 1800  (Mac App Store; a 1440 x 900 point window)
#
# Each set holds 1-Inbox, 2-Thread, 3-Compose, 4-Settings and 5-Encrypted, from mock data (no real account).
# iOS sets have the clock at 9:41. The Mac set runs MacScreenshotUITests on this Mac, which needs UI automation
# (macOS asks for your password the first time) and takes over the mouse for a minute or two. On a Retina
# display the window is captured at 2880 x 1800; on a standard display it is captured at 1440 x 900 and scaled up.
# Usage: Scripts/screenshots.sh [set...]   e.g. Scripts/screenshots.sh iPhone-6.3 Mac   (default: all four)
set -eu
cd "$(dirname "$0")/.."

typeset -A DEVICE SIZE
DEVICE=(iPhone-6.3 "iPhone 17"  iPhone "iPhone 17 Pro Max"  iPad "iPad Pro 13-inch (M5)")
SIZE=(iPhone-6.3 1206x2622  iPhone 1320x2868  iPad 2064x2752)
SHOTS=(1-Inbox 2-Thread 3-Compose 4-Settings 5-Encrypted)
OUT=build/screenshots
mkdir -p "$OUT"

sets=("$@")
(( $#sets )) || sets=(iPhone-6.3 iPhone iPad Mac)

udid() {
  xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for d in devices:
        if d["name"] == name and "iOS" in runtime:
            print(d["udid"]); sys.exit()
sys.exit(f"No available simulator named {name!r}")' "$1"
}

# Copies the 1-Inbox ... 5-Encrypted attachments out of a result bundle into Screenshots/<set>.
extract() {
  local result=$1 set=$2 tmp
  tmp=$(mktemp -d)
  xcrun xcresulttool export attachments --path "$result" --output-path "$tmp" >/dev/null
  rm -rf "Screenshots/$set"
  mkdir -p "Screenshots/$set"
  python3 - "$tmp" "Screenshots/$set" <<'PY'
import json, re, shutil, sys
tmp, out = sys.argv[1:]
for test in json.load(open(f"{tmp}/manifest.json")):
    for a in test["attachments"]:
        m = re.match(r"(\d-[A-Za-z]+)_", a.get("suggestedHumanReadableName", ""))
        if m:
            shutil.copy(f"{tmp}/{a['exportedFileName']}", f"{out}/{m.group(1)}.png")
PY
  rm -rf "$tmp"
}

shoot_mac() {
  local want=2880x1800 result="$OUT/Mac.xcresult" shot file got
  echo "== Mac: this Mac"
  rm -rf "$result"
  xcodebuild test -project Aeolet.xcodeproj -scheme AeoletMac -destination "platform=macOS" \
    -derivedDataPath build/DDMac -resultBundlePath "$result" -only-testing:AeoletMacUITests/MacScreenshotUITests \
    -allowProvisioningUpdates >"$OUT/Mac.log" 2>&1 || { tail -30 "$OUT/Mac.log"; echo "Mac: test failed, see $OUT/Mac.log"; exit 1; }
  extract "$result" Mac
  for shot in $SHOTS; do
    file="Screenshots/Mac/$shot.png"
    [[ -f $file ]] || { echo "Mac: missing $shot"; exit 1; }
    got=$(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w "x" h}')
    if [[ $got == 1440x900 ]]; then
      sips -z 1800 2880 "$file" >/dev/null
      echo "   $shot: captured at 1440 x 900 (standard display), scaled to $want. A Retina display gives sharper text."
    elif [[ $got != "$want" ]]; then
      echo "Mac: $shot is $got, expected $want"; exit 1
    fi
  done
  echo "   5 screenshots at $want in Screenshots/Mac"
}

shoot() {
  local set=$1 name=${DEVICE[$1]} want=${SIZE[$1]} id result tmp shot file got
  [[ -n $name ]] || { echo "Unknown set $set (use iPhone-6.3, iPhone, iPad or Mac)"; exit 1; }
  id=$(udid "$name")
  echo "== $set: $name ($id)"

  # A fresh boot clears leftovers such as the "◀ Safari" back link in the status bar.
  xcrun simctl shutdown "$id" 2>/dev/null || true
  xcrun simctl boot "$id"
  xcrun simctl bootstatus "$id" -b >/dev/null
  xcrun simctl status_bar "$id" override --time "9:41" --dataNetwork wifi --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100

  result="$OUT/$set.xcresult"
  rm -rf "$result"
  xcodebuild test -project Aeolet.xcodeproj -scheme Aeolet -destination "platform=iOS Simulator,id=$id" \
    -derivedDataPath build/DD -resultBundlePath "$result" -only-testing:AeoletUITests/ScreenshotUITests \
    DEVELOPMENT_TEAM= >"$OUT/$set.log" 2>&1 || { tail -30 "$OUT/$set.log"; echo "$set: test failed, see $OUT/$set.log"; exit 1; }

  extract "$result" "$set"

  for shot in $SHOTS; do
    file="Screenshots/$set/$shot.png"
    [[ -f $file ]] || { echo "$set: missing $shot"; exit 1; }
    got=$(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w "x" h}')
    [[ $got == "$want" ]] || { echo "$set: $shot is $got, expected $want"; exit 1; }
  done
  xcrun simctl status_bar "$id" clear
  echo "   5 screenshots at $want in Screenshots/$set"
}

for set in $sets; do
  if [[ $set == Mac ]]; then shoot_mac; else shoot "$set"; fi
done
