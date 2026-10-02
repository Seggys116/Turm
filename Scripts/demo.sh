#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

out=${1:-.github/assets/screenshots}
mkdir -p "$out"

if [ -z "${SKIP_BUILD:-}" ]; then
  xcodebuild -project Turm.xcodeproj -scheme Turm -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath DerivedData build
fi
app=$PWD/DerivedData/Build/Products/Debug/Turm.app
binary=$app/Contents/MacOS/Turm

tmp=$(getconf DARWIN_USER_TEMP_DIR)
home=$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory | awk '{ print $2 }')
scratch=$home/Library/Caches/turm-demo

if pgrep -f "^$binary" > /dev/null; then
  echo "Quit the Debug build of Turm before taking screenshots" >&2
  exit 1
fi

hosts='[{"id":"3F6A1C0E-5B7D-4E29-8A14-D2C09B7E5F31","key":"prod-web","hostname":"prod-web.internal","user":"deploy","remembersPassword":false},'
hosts+='{"id":"9C2E7B48-1D3A-4F65-B0E8-6A5D4C3B2F10","key":"pi","hostname":"raspberrypi.local","user":"pi","remembersPassword":false}]'

capture() {
  local screen=$1 name=$2
  mkdir -p "$scratch"
  rm -f "$scratch/ready"
  open -n -a "$app" \
    --env HOME="$scratch" --env CFFIXED_USER_HOME="$scratch" --env ZDOTDIR="$scratch" --env TMPDIR="$tmp" --env LLVM_PROFILE_FILE="$tmp/turm-demo-%p.profraw" \
    --args \
    -TurmDemoScreen "$screen" \
    -turm.sshHosts "$hosts" \
    -turm.sidebarPlacement left \
    -turm.appearance dark \
    -ApplePersistenceIgnoreState YES \
    -NSQuitAlwaysKeepsWindows NO
  local pid=
  for _ in $(seq 1 20); do
    pid=$(pgrep -n -f "^$binary" || true)
    [ -n "$pid" ] && break
    sleep 0.5
  done
  [ -n "$pid" ] || { echo "The demo app did not start" >&2; exit 1; }
  trap 'kill "$pid" 2>/dev/null || true' EXIT

  for _ in $(seq 1 180); do
    [ -f "$scratch/ready" ] && break
    kill -0 "$pid" 2>/dev/null || { echo "The demo app exited early" >&2; exit 1; }
    sleep 0.5
  done
  [ -f "$scratch/ready" ] || { echo "The demo never settled" >&2; exit 1; }

  screencapture -x -o -l"$(cat "$scratch/window-id")" "$out/$name"

  kill "$pid"
  while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
  trap - EXIT
  echo "Saved $out/$name"
}

capture hero mac-hero.png
