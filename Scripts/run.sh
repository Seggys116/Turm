#!/bin/bash
set -euo pipefail

destination=
previous=
for argument in "$@"; do
  [ "$previous" = -destination ] && destination=$argument
  previous=$argument
done

xcodebuild "$@" build

found=$(xcodebuild "$@" -showBuildSettings 2>/dev/null | awk '
  /^Build settings for/ { if (wrapper == "app") found = 1; if (!found) dir = name = bundle = wrapper = "" }
  found { next }
  /^    TARGET_BUILD_DIR = / { sub(/^[^=]*= /, ""); dir = $0 }
  /^    FULL_PRODUCT_NAME = / { sub(/^[^=]*= /, ""); name = $0 }
  /^    PRODUCT_BUNDLE_IDENTIFIER = / { sub(/^[^=]*= /, ""); bundle = $0 }
  /^    WRAPPER_EXTENSION = / { sub(/^[^=]*= /, ""); wrapper = $0 }
  END { if (wrapper == "app") print dir "/" name "\n" bundle }
')
if [ -z "$found" ]; then
  echo "The scheme builds no app to run" >&2
  exit 1
fi
app=$(sed -n 1p <<< "$found")
bundle=$(sed -n 2p <<< "$found")

id=${destination#*id=}
id=${id%%,*}
case "$destination" in
  platform=macOS*)
    open "$app" ;;
  *Simulator*)
    xcrun simctl boot "$id" 2>/dev/null || true
    xcrun simctl bootstatus "$id" > /dev/null
    open -a Simulator
    xcrun simctl install "$id" "$app"
    xcrun simctl launch "$id" "$bundle" ;;
  platform=*id=*)
    xcrun devicectl device install app --device "$id" "$app"
    xcrun devicectl device process launch --device "$id" "$bundle" ;;
  *)
    echo "Choose a run destination" >&2
    exit 1 ;;
esac
