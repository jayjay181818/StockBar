# Release Notes v2.4.1

## Portfolio Popover Modernisation

- Replaced the compact portfolio total menu with a first-class SwiftUI popover that matches the individual stock dropdown visual language.
- Added a portfolio header with total value, selected currency, owned-position count, and a gain/loss percentage pill.
- Added a portfolio value chart with 1D, 1W, and 1M ranges using stored historical portfolio snapshots plus the latest live summary point.
- Added portfolio stat cells for market value, total P&L, selected-range P&L, and cost basis.
- Added footer actions for Preferences, refresh, and Quit, with the same compact treatment as individual stock popovers.
- Routed portfolio popover actions directly through the menu bar controller/status item path instead of the old copied `NSMenuItem` flow.

## Shared Menu Chart Components

- Extracted common menu-popover formatting, chart rendering, time-range controls, stat boxes, and footer UI for reuse between individual stocks and the portfolio total.
- Kept the existing stock popover behaviour while moving shared chart drawing and hover styling into reusable SwiftUI components.
- Standardized menu-popover currency, percent, units, date, and range formatting across stock and portfolio views.
- Added deterministic portfolio chart downsampling that preserves the first and last points while capping rendered points.

## ⚡ Stability & Performance

- Refresh operations no longer block the UI while Python subprocesses run.
- Python subprocess output is streamed to avoid pipe deadlocks on large responses.
- Removed duplicate persistence/snapshot work after successful refreshes.
- Serialized replace-all Core Data trade writes to avoid duplicate rows when startup migration/load tasks overlap.
- Deduplicated trade loads by symbol so existing duplicate rows do not produce duplicate portfolio entries in the UI.

## Portfolio Accuracy

- Menu bar portfolio totals now use the same display-price logic as individual symbols, including pre-market and after-hours prices.
- Unified the menu bar and popup portfolio summaries onto one display-aware calculation path to keep daily P&L, total value, and gains consistent.
- Portfolio summaries now include total cost basis, total P&L percentage, and owned-position count.
- Portfolio calculations exclude watchlist-only rows, ignore invalid price inputs, normalize UK `.L` cost basis, aggregate through USD, and convert once to the selected display currency.
- Range P&L in the portfolio popover is calculated from filtered historical portfolio values with a flat fallback when no history exists.

## Data Recovery & Migration

- Core Data persistent-store load failures no longer destroy or recreate the user store automatically.
- Added a safety recovery path that preserves the SQLite store plus `-wal` and `-shm` files in a timestamped recovery folder before any empty-store fallback is considered.
- Added startup recovery messaging so users are told when a portfolio store was preserved and can open the recovery folder directly.
- Added structured Core Data store-load state for startup logging and recovery UI decisions.
- Hardened startup loading so benchmark helpers (`^GSPC`, `^FTSE`) are not added before the real portfolio has loaded.
- Blocked benchmark-only or incidental empty startup states from overwriting the persisted Core Data portfolio.
- Added recovery from legacy `usertrades` data when Core Data has no real portfolio rows.
- Fixed trade migration to read the active legacy keys (`usertrades`, `tradingInfoData`) and to rerun when migration flags are set but Core Data is empty.
- Added backward-compatible trade decoding for older backups/preferences that do not include `showInMenuBar` or `isWatchlistOnly`.
- Ensured backup restores replace and persist the portfolio through the canonical Core Data path instead of only updating in-memory UI state.

## Security & Logging

- Added a canonical log redaction layer for URLs, query strings, bearer tokens, API keys, environment-style secrets, and Python exception text.
- Routed app logging, network-service stderr handling, and Python script exception output through secret-safe sanitization.
- Redacted provider failures such as FMP `apikey=` URLs before they are persisted to app logs.
- Added runtime log scanning for unredacted secrets, recovery events, process timeouts, and repeated error patterns.
- Added current-log verification that no raw API keys or bearer tokens are present after the reliability fixes.

## Responsiveness & Background Work

- Moved OHLC Python fetching off the main actor and onto the shared asynchronous Python process runner.
- Added async subprocess pipe reads and timeout handling for OHLC fetches to avoid UI freezes from blocked process IO.
- Extracted pure historical portfolio calculation into a non-main-actor service using value snapshots, then publishes final results back to the UI layer.
- Reworked Core Data batch helpers to avoid mutating captured state from background closures and to use sendable batch payloads.
- Tightened menu-bar attributed-title formatting across actor boundaries while preserving the existing visual output.

## Reliability Monitoring

- Added a runtime issue monitor that periodically summarizes log health for errors, timeouts, Core Data recovery events, and secret-leak detection.
- Added startup scheduling for the runtime monitor alongside the existing backup and dependency checks.
- Added a one-off manual log review process for this release to confirm that post-fix runtime logs show no new crash, fatal, timeout, Core Data recovery, or secret-leak entries.

## Backup, Restore, Import & Export Safety

- Automatic backups now wait for the initial portfolio load before running.
- Backups now require at least one real portfolio holding before they are written or marked successful.
- Manual and automatic backups filter out internal benchmark rows.
- Restore and preview paths filter out benchmarks and reject benchmark-only backup files.
- CSV import rejects benchmark symbols, and CSV export excludes internal benchmark rows.
- Portfolio Preferences now hides benchmark helpers from editable rows, bulk actions, drag ordering, export, and restore flows.

## Tests

- Added all `StockbarTests/*.swift` files to the Xcode test target so local and CI test runs no longer under-report coverage.
- Added a project-membership regression test so orphaned test files fail the suite.
- Added Core Data recovery tests for store safety backups, including SQLite sidecar files and user-facing recovery notices.
- Added log redaction tests for FMP URLs, query secrets, bearer tokens, environment-style keys, raw stderr, and Python exception messages.
- Added runtime issue monitor tests for secret-leak detection, recovery counting, timeout counting, and tolerated redacted provider errors.
- Added OHLC fetch tests for timeout handling, stderr handling, JSON parsing, and injected process-runner fixtures.
- Added historical portfolio calculation tests for range filtering, currency conversion, missing data, cancellation/error paths, and parity with existing results.
- Added portfolio calculation coverage for cost basis, total P&L percentage, mixed currencies, UK `.L` cost normalization, invalid-price skipping, and watchlist exclusion.
- Added portfolio chart preparation coverage for range filtering, latest-point appending, empty-history fallback, and downsampling.
- Added backup/import/export regression coverage for benchmark filtering and legacy trade decoding.

## Developer & Build Hardening

- Enabled complete strict concurrency checking in Debug for the app and test targets while keeping Release behaviour unchanged.
- Addressed strict-concurrency warnings in the touched reliability paths, including Core Data stack state, batch processing, cache access, logging, configuration, export, and menu formatting.
- Added shared async Python process-running infrastructure for quote/OHLC subprocess work and test doubles.
- Verified the latest reliability changes with focused reliability tests, full `xcodebuild test`, Python compile checks, SwiftLint, and log secret scanning.

## Distribution Note

- The attached macOS zip is a local testing build signed to run locally and is not notarized with Developer ID.

**Full Changelog**: https://github.com/jayjay181818/StockBar/compare/v2.4.0...v2.4.1

Release Date: 29 Apr 2026
