#!/bin/bash
set -euo pipefail
command -v rg >/dev/null 2>&1 || { echo "ripgrep (rg) is required: brew install ripgrep" >&2; exit 1; }

allowed='^(Stockbar/CurrencyConverter.swift|Stockbar/Data/Networking/(PythonProcessRunner|PythonWorkerPool).swift|Stockbar/Data/Networking/StubNetworkService.swift|Stockbar/Services/MenuBarFormattingService.swift|Stockbar/Data/CoreData/(CoreDataStack|DataMigrationService|HistoricalDataService|InstrumentAliasMigrationService|TradeDataMigrationService|TradeDataService).swift|Stockbar/Utilities/(CacheManager|ConfigurationManager|FolyncConfiguration|StockbarAcceptancePreflight|Trading212CredentialStore).swift):'

unexpected="$(
  rg -n '@unchecked( @retroactive)? Sendable|@unchecked Sendable' Stockbar -g '*.swift' \
    | grep -Ev "$allowed" || true
)"

if [[ -n "$unexpected" ]]; then
  echo "Unexpected @unchecked Sendable conformance:"
  echo "$unexpected"
  exit 1
fi

echo "Unchecked Sendable allowlist validation passed"
