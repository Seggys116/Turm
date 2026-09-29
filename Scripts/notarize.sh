#!/bin/bash
set -euo pipefail

file="$1"
result="$RUNNER_TEMP/notary-result.json"

xcrun notarytool submit "$file" \
  --key "$RUNNER_TEMP/notary.p8" \
  --key-id "$KEY_ID" \
  --issuer "$ISSUER_ID" \
  --wait \
  --output-format json > "$result" || true

id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id", ""))' "$result")
status=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status", ""))' "$result")
echo "notarization $id: $status"

if [ "$status" != "Accepted" ]; then
  xcrun notarytool log "$id" --key "$RUNNER_TEMP/notary.p8" --key-id "$KEY_ID" --issuer "$ISSUER_ID" || true
  exit 1
fi
