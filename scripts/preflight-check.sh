#!/usr/bin/env bash
# Preflight guard: refuse to install GetBored.app if a binary inside the
# bundle declares an @rpath/Foo.framework/Foo LC_LOAD_DYLIB whose framework is
# not present under Frameworks/.
set -euo pipefail

APP_PATH="${1:-}"
if [[ -z "$APP_PATH" ]]; then
  echo "usage: $0 <path/to/GetBored.app>" >&2
  exit 2
fi
if [[ ! -d "$APP_PATH" ]]; then
  echo "PREFLIGHT FAILED: app bundle not found: $APP_PATH" >&2
  exit 1
fi

FW_DIR="$APP_PATH/Frameworks"
ERRORS=()

require_framework() {
  local name="$1"
  if [[ ! -d "$FW_DIR/$name.framework" ]]; then
    ERRORS+=("$name.framework not embedded in $(basename "$APP_PATH")/Frameworks/. Open GetBoredIOS.xcodeproj -> select \"GetBored iOS\" target -> Build Phases -> Embed Frameworks -> add $name.xcframework with Code Sign on Copy.")
  fi
}

# Hermes is a dynamic framework embedded by CocoaPods and required at runtime.
# GetBoredSharedCore.xcframework is static and must not be embedded here.
require_framework "hermes"

check_binary() {
  local bin="$1"
  [[ -f "$bin" ]] || return 0
  while IFS= read -r line; do
    local ref="${line#@rpath/}"
    ref="${ref%% *}"
    if [[ "$ref" == *.framework/* ]]; then
      local fw_name="${ref%%.framework/*}"
      local expected="$FW_DIR/$fw_name.framework/$fw_name"
      if [[ ! -f "$expected" ]]; then
        ERRORS+=("$(basename "$bin") links @rpath/$ref but $expected is missing. Embed $fw_name.framework in the app target.")
      fi
    fi
  done < <(otool -L "$bin" 2>/dev/null | awk '/@rpath\//{sub(/^[ \t]+/,""); print}')
}

scan_bundle() {
  local bundle="$1"
  local main_name
  main_name="$(basename "$bundle")"
  main_name="${main_name%.app}"
  main_name="${main_name%.appex}"
  check_binary "$bundle/$main_name"
  check_binary "$bundle/$main_name.debug.dylib"
}

scan_bundle "$APP_PATH"

if [[ -d "$APP_PATH/PlugIns" ]]; then
  for appex in "$APP_PATH/PlugIns"/*.appex; do
    [[ -d "$appex" ]] || continue
    scan_bundle "$appex"
  done
fi

if (( ${#ERRORS[@]} > 0 )); then
  echo "PREFLIGHT FAILED:" >&2
  for e in "${ERRORS[@]}"; do
    echo "  - $e" >&2
  done
  exit 1
fi

echo "preflight ok: $(basename "$APP_PATH") frameworks satisfied"
