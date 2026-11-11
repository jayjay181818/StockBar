# Stockbar architecture

Reference material; read the relevant section when needed. Shared working instructions are in [AGENTS.md](../AGENTS.md). Implementation details may change; inspect the linked source of truth before relying on exact values.

## Architecture Overview

macOS portfolio tracker with Swift/Python integration. `LSUIElement = false`: the app has a Dock-visible window and menu bar controls.

### Lifecycle
`main.swift` → acceptance preflight hooks → `AppDelegate` → `StockMenuBarController` (owns `DataModel`, `StockStatusBar`, and `StockbarMainWindowController`).

`main.swift` intercepts `--acceptance-preflight` / `--acceptance-bootstrap` and exits before `NSApplicationMain` — keep that block first.

### Data flow (MVVM + Observation)
```
DataModel (@MainActor @Observable)        central state hub
  ├── realTimeTrades: [RealTimeTrade]             ← drives menu bar + all views
  ├── RefreshService                              ← refresh scheduling; RefreshPassScheduler serializes passes
  ├── CacheCoordinator (actor)                     ← TTL + backoff + circuit breaker
  ├── PythonNetworkService → python3 subprocess → get_stock_data.py
  ├── Trading212BrokerSyncService / Trading212Provider   ← broker-linked holdings
  ├── FolyncPortfolioSource / FolyncSupplementalData     ← self-hosted portfolio source
  └── Core Data (historical prices, OHLC, snapshots) + UserDefaults
```

Shared models (`DataModel`, `RealTimeTrade`, `HistoricalDataManager`, `CurrencyConverter` and the shared services) use `@Observable`, so SwiftUI redraws only views that read the property that changed. Internal state that views must not track is `@ObservationIgnored`. AppKit and service code subscribes through `ObservationPublisher` (`Utilities/ObservationPublisher.swift`), which replaces `$property` publishers. View-owned chart view models stay `ObservableObject` with `@StateObject`, which builds them once per view.

### Portfolio sources (mutually layered, not alternatives)
Three sources coexist and must stay non-destructive to each other:
1. **Local/manual** trades in UserDefaults + Core Data — the base layer, always preserved.
2. **Trading 212** — broker-linked holdings; linked positions take quantity/price/avg-cost/P&L from the broker and deliberately *skip* market-data providers. Credentials live in Keychain only. Read-only; no order execution.
3. **Folync** — a self-hosted instance acting as authoritative read-only portfolio source. When active, `legacyPortfolioTrades` holds the shadowed local portfolio so switching back restores it. Folync-backed financial fields are read-only; watchlists, alerts, and menu-bar prefs stay Stockbar-owned. Supplemental routes (line history, OHLCV, benchmarks, FX) are independently toggled and **never splice Folync and legacy points into one series**.

`InstrumentResolver` maps provider tickers (esp. Trading 212's) to canonical instrument identities; `SymbolMetadata` distinguishes benchmark symbols (`^GSPC`, `^FTSE`) from holdings, and `Trade.isWatchlistOnly` marks symbols with no position math.

### Python bridge
- `NetworkService` protocol → `PythonNetworkService`; process spawning isolated in `PythonProcessRunner`; interpreter/env in `PythonConfiguration` (the `pythonInterpreterPath` default, else Stockbar's own `python-env` in Application Support, even before it exists; there is no system-Python fallback). `PythonEnvironmentSetup` builds that environment by running the bundled `setup_python_env.sh` from Settings → Advanced → Python or the missing-package alert; `script/setup_python_env.sh` runs the same script from a checkout.
- `PythonWorkerPool` keeps up to two `stockbar_worker.py` processes running so `get_stock_data.py` and `get_ohlc_data.py` requests skip interpreter start-up and package imports. The worker runs the script in place with fresh globals and returns its stdout, stderr and exit code, so the script contract below is unchanged. When every worker is busy, or a worker fails, the request runs as its own process. Workers are replaced when the interpreter or environment changes, stopped after a timeout or cancellation, and exit after 15 idle minutes or when the app quits.
- **Contract: JSON on stdout, human logs on stderr only.** Quotes use `get_stock_data.py --json <symbols…>`; also `--historical` and `--test-key`. Candles come from `get_ohlc_data.py`. Errors come back as a JSON envelope with `error: true` and `error_code`. (This is JSON parsing, not the old stdout regex.)
- Timeout values and batch sizing live in `Stockbar/Data/Networking/NetworkService.swift`; inspect the relevant operation when changing fetch behavior.
- Failed fetches return a placeholder `StockFetchResult` with `.nan` prices rather than throwing, so metadata survives.
- `PythonConfiguration.validateSymbol/sanitizeSymbol` restrict symbols to `A-Z0-9.^=-` to prevent argument injection — route new symbol paths through them.
- Providers inside the script: live quotes use a fixed order (yfinance, Twelve Data, the Yahoo quote API, then FMP); historical data follows `DATA_SOURCE_PRIORITY` (default yfinance, then FMP). Python-side quote cache at `~/Library/Caches/stockbar-cache/quote_cache.json` (passed by the app via `STOCKBAR_CACHE_FILE`, acceptance-aware; a legacy `~/.stockbar_cache.json` is moved there once), lock-file guarded with atomic replace.
- `ENABLE_USER_SCRIPT_SANDBOXING = NO` and the app must stay unsandboxed — the subprocess bridge depends on it. The entitlement validator checks app sandbox and server permissions; the Xcode project defines script sandboxing.

### UI layer
- **Window**: `StockbarMainWindowController` hosts `Views/StockbarMainView.swift`, a sidebar over ten sections — Overview, Holdings, Alerts, Charts, Risk, Allocation, Backups, Data Health, Diagnostics, Settings. "Preferences" now just opens the Settings section.
- **Menu bar**: `StockMenuBarController` + `StockStatusBar`, one `NSStatusItem` per visible symbol, Combine-driven; also handles external-display polling for status-item visibility.
- **Charts**: Swift Charts — `PerformanceChartView`, `CandlestickChartView`, `MenuPriceChartView`. `PerformanceChartView` is split by concern: the main file holds state, loading and the line chart; `+Comparison`, `+Metrics`, `+Export` and `+Candlestick` hold those panels.
- **History**: `HistoricalDataManager` is split the same way: the main file holds storage, snapshot recording and chart reads; `+Folync` holds the Folync overlay, `+PortfolioMenu` the menu-bar values, `+Retroactive` the recalculation of past days, `+Metrics` and `+Thinning` the helpers.

### Persistence
| Store | Location | Contents |
|---|---|---|
| UserDefaults | `com.stockbar` (via `StockbarRuntimeStorage.userDefaults`) | Trades, preferences, cache timestamps |
| Core Data | `<App Support>/Stockbar/StockbarDataModel.sqlite` | Historical prices, OHLC, snapshots — model selected by `Stockbar/Data/StockbarDataModel.xcdatamodeld/.xccurrentversion`; data migration flags in `DataMigrationService`; `CoreDataStoreRecovery` handles corrupt stores |
| Config JSON | `<App Support>/com.stockbar/.stockbar_config.json` | `DATA_SOURCE_PRIORITY` (auto-migrated from the legacy `com.fhl43211.Stockbar` path); FMP + Twelve Data keys an earlier version wrote here are moved to the Keychain on first use |
| Keychain | `com.stockbar.folync`, Trading 212 service, `com.stockbar.marketdata` | Persistent broker/Folync credentials and the FMP + Twelve Data keys (`MarketDataKeyStore`, passed to the Python scripts as environment variables per run); acceptance fixtures use a separate restricted token file |

Settings export/import (`SettingsTransferService`) seals an allowlist of defaults (`SettingsTransferKeys`), the config-file keys and Keychain credentials, and for Everything a Core Data copy, into one AES-GCM `.stockbarexport` file (`SettingsTransferContainer`). Imports validate everything first, snapshot the current state, and roll back on failure. `CoreDataStoreTransfer` copies and replaces stores through `replacePersistentStore`, and keeps the live store read-only until relaunch.

### Caching & failure policy

`Stockbar/Services/CacheCoordinator.swift` owns freshness, retry intervals and circuit-breaker thresholds. Preserve that policy when adding fetch paths.

- Freshness follows the user's Main Refresh Interval (`RefreshService.freshnessInterval`); the Python quote cache is bounded to match through `STOCKBAR_QUOTE_CACHE_SECONDS` (set by `PythonConfiguration.load`).
- Symbols with recorded failures are governed only by backoff (`shouldRetry`) and the circuit breaker; `shouldRefresh` never returns true for them. The per-symbol popover exposes suspension state and Retry Now.

### Currency
`CurrencyConverter` (exchangerate-api.com, USD base) for USD/GBP/EUR/JPY/CAD/AUD. **Normalize GBX/GBp to GBP once at the provider boundary.** Preserve values already reported as GBP, including cost bases. Use reported currency and existing provider-specific fallbacks; a `.L` suffix alone is not evidence that a value still needs division. See `PythonTests/test_get_ohlc_data.py` for regression examples.
