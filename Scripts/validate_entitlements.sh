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

echo "Entitlement validation passed"
