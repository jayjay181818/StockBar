#!/bin/bash
set -euo pipefail

allowed='^(Stockbar/CurrencyConverter.swift|Stockbar/Data/Networking/PythonProcessRunner.swift|Stockbar/Data/Networking/StubNetworkService.swift|Stockbar/Services/MenuBarFormattingService.swift|Stockbar/Data/CoreData/(CoreDataStack|DataMigrationService|HistoricalDataService|InstrumentAliasMigrationService|TradeDataMigrationService|TradeDataService).swift|Stockbar/Utilities/(CacheManager|ConfigurationManager|FolyncConfiguration|StockbarAcceptancePreflight|Trading212CredentialStore).swift):'

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
