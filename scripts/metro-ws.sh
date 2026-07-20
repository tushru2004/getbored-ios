#!/usr/bin/env bash
# Print the live Hermes inspector websocketDebuggerUrl from Metro.
# Use the output as the "websocketAddress" value in .vscode/launch.json.
#
#   ./scripts/metro-ws.sh           # print first page (usually the iOS device)
#   ./scripts/metro-ws.sh --copy    # also copy to macOS clipboard
set -euo pipefail

URL=$(curl -s http://127.0.0.1:8081/json/list \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["webSocketDebuggerUrl"]) if d else (_ for _ in ()).throw(SystemExit("no inspector pages — start Metro + launch the app"))')

echo "$URL"

if [[ "${1:-}" == "--copy" ]]; then
  printf '%s' "$URL" | pbcopy
  echo "(copied to clipboard)"
fi
