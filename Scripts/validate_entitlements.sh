#!/bin/bash
set -euo pipefail

canonical="Stockbar/Stockbar.entitlements"
entitlements="$(find Stockbar -type f -name '*.entitlements' -print)"
entitlement_count="$(printf '%s\n' "$entitlements" | sed '/^$/d' | wc -l | tr -d ' ')"

if [[ "$entitlement_count" -ne 1 || "$entitlements" != "$canonical" ]]; then
  echo "Expected exactly one canonical entitlement file at $canonical"
  printf '%s\n' "$entitlements"
  exit 1
fi

plutil -lint "$canonical"

if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$canonical" 2>/dev/null | grep -q '^true$'; then
  echo "Stockbar must remain unsandboxed for its Python subprocess bridge"
  exit 1
fi

if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.server' "$canonical" 2>/dev/null | grep -q '^true$'; then
  echo "Stockbar must not request network.server"
  exit 1
fi

# The one hardened-runtime exception: without an Apple team the app cannot
# otherwise load its own Sparkle framework. Nothing else may be relaxed.
allowed_keys="com.apple.security.cs.disable-library-validation"
actual_keys="$(/usr/bin/plutil -convert json -o - "$canonical" \
  | /usr/bin/python3 -c 'import json, sys; print("\n".join(sorted(json.load(sys.stdin))))')"
if [[ "$actual_keys" != "$allowed_keys" ]]; then
  echo "Unexpected entitlements. Expected exactly:"
  printf '  %s\n' "$allowed_keys"
  echo "Found:"
  printf '  %s\n' "${actual_keys:-(none)}"
  exit 1
fi

echo "Entitlement validation passed"
