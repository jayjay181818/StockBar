#!/bin/bash
set -euo pipefail

# Enforces invariants that CLAUDE.md states but that were previously only
# convention. Each of these had at least one real violation in the codebase;
# a written rule that nothing checks does not stay true.

status=0

fail() {
  echo "❌ $1"
  status=1
}

# 1. Logging must go through Logger (which applies LogRedactor). Bare print()
#    bypasses redaction and writes to the unified log in release builds.
print_calls="$(
  rg -n '(^|[^A-Za-z0-9_.])print\(' Stockbar -g '*.swift' \
    -g '!Stockbar/Utilities/Logger.swift' || true
)"
if [[ -n "$print_calls" ]]; then
  fail "print() found in app code; use await Logger.shared.debug/info/warning/error instead:"
  echo "$print_calls"
fi

# 2. Core Data writes belong on background contexts, not viewContext.
view_context_writes="$(
  rg -n 'save\(context: viewContext\)|viewContext\.save\(\)|viewContext\.delete\(' Stockbar -g '*.swift' \
    -g '!Stockbar/Data/CoreData/CoreDataStack.swift' || true
)"
if [[ -n "$view_context_writes" ]]; then
  fail "Core Data write on viewContext; use a background context:"
  echo "$view_context_writes"
fi

# 3. Every file that performs live network I/O must gate on the provider access
#    policy, so acceptance runs (STOCKBAR_DISABLE_LIVE_PROVIDERS=1) stay offline.
network_files="$(
  rg -l 'session\.data\(|URLSession\.shared\.dataTask|session\.dataTask' Stockbar -g '*.swift' || true
)"
for file in $network_files; do
  if ! rg -q 'authorize\(\.' "$file"; then
    fail "Live network call without StockbarProviderAccessPolicy.authorize: $file"
  fi
done

# 4. Internal agent documentation must not ship inside the app bundle.
if ! rg -q 'PBXFileSystemSynchronizedBuildFileExceptionSet' Stockbar.xcodeproj/project.pbxproj; then
  fail "Markdown exclusion missing from project.pbxproj; internal docs would ship in the app bundle"
fi

# 5. Stale Python bytecode must not sit in the resource folder, because the
#    folder-synced build copies whatever is there into the bundle.
if [[ -d "Stockbar/Resources/__pycache__" ]] || compgen -G "Stockbar/Resources/*.pyc" >/dev/null; then
  fail "Python bytecode present in Stockbar/Resources; it would be copied into the app bundle"
fi

# 6. App defaults go through StockbarRuntimeStorage so acceptance runs stay
#    isolated. @AppStorage without store: silently uses UserDefaults.standard.
unscoped_app_storage="$(
  rg -n '@AppStorage\(' Stockbar -g '*.swift' | rg -v 'store: StockbarRuntimeStorage\.userDefaults' || true
)"
if [[ -n "$unscoped_app_storage" ]]; then
  fail "@AppStorage without store: StockbarRuntimeStorage.userDefaults:"
  echo "$unscoped_app_storage"
fi

# 7. Dictionary(uniqueKeysWithValues:) traps on a repeated key. Keys built from
#    holdings or provider data can repeat, so use Dictionary(firstValuesFor:).
trapping_dictionaries="$(
  rg -n 'Dictionary\(uniqueKeysWithValues:' Stockbar -g '*.swift' || true
)"
if [[ -n "$trapping_dictionaries" ]]; then
  fail "Dictionary(uniqueKeysWithValues:) traps on duplicate keys; use Dictionary(firstValuesFor:):"
  echo "$trapping_dictionaries"
fi

if [[ "$status" -eq 0 ]]; then
  echo "Invariant validation passed"
fi
exit "$status"
