#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

out=${1:-.github/assets/screenshots}
mkdir -p "$out"
bundle=com.zak-noble-clarke.TurmiOS
derived=$PWD/DerivedData-iOS

if [ -z "${SKIP_BUILD:-}" ]; then
  xcodebuild -project Turm.xcodeproj -scheme TurmiOS -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" build
fi
app=$derived/Build/Products/Debug-iphonesimulator/TurmiOS.app

udid=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)
booted = None
best = None
for runtime, devices in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if not device.get("isAvailable", True):
            continue
        name = device.get("name", "")
        if "iPhone" not in name:
            continue
        score = 0
        if "Pro" in name and "Max" not in name:
            score += 5
        elif "Pro Max" in name:
            score += 3
        rank = (score, runtime, name)
        if device.get("state") == "Booted" and (booted is None or rank > booted[0]):
            booted = (rank, device["udid"])
        if best is None or rank > best[0]:
            best = (rank, device["udid"])
chosen = booted or best
if not chosen:
    sys.exit("No iPhone simulator is available")
print(chosen[1])
')
echo "Using simulator $udid"

if ! xcrun simctl list devices | grep "$udid" | grep -q Booted; then
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" -b
fi

xcrun simctl ui "$udid" appearance dark
xcrun simctl status_bar "$udid" override \
  --time "9:41" \
  --dataNetwork wifi \
  --wifiMode active \
  --wifiBars 3 \
  --cellularMode active \
  --cellularBars 4 \
  --batteryState charged \
  --batteryLevel 100

xcrun simctl install "$udid" "$app"

shots=$(mktemp -d)
trap 'rm -rf "$shots"' EXIT

capture() {
  local screen=$1 name=$2
  local container
  container=$(xcrun simctl get_app_container "$udid" "$bundle" data 2>/dev/null || true)
  if [ -n "$container" ]; then
    rm -f "$container/Documents/demo-ready"
  fi
  xcrun simctl launch --terminate-running-process "$udid" "$bundle" -TurmDemoScreen "$screen" >/dev/null
  local ready=0
  for _ in $(seq 1 80); do
    container=$(xcrun simctl get_app_container "$udid" "$bundle" data 2>/dev/null || true)
    if [ -n "$container" ] && [ -f "$container/Documents/demo-ready" ]; then
      ready=1
      break
    fi
    sleep 0.25
  done
  [ "$ready" = 1 ] || { echo "The $screen demo never settled" >&2; exit 1; }
  xcrun simctl io "$udid" screenshot "$shots/$name.png"
  echo "Saved $shots/$name.png"
}

capture sidebar sidebar
capture running running
capture ssh ssh

swift Scripts/frame-phones.swift "$shots/sidebar.png" "$shots/running.png" "$shots/ssh.png" "$out/ios.png"
echo "Saved $out/ios.png"
