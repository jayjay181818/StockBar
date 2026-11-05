# StockBar v3.0.0 Release Notes

**Status:** Implemented  
**Date:** 2026-11-05

Version 3 is a reliability release. A full project review found crashes, ways to lose holdings or history, and wrong analytics; this release fixes them, adds a redesigned main window, and makes Folync and Trading 212 safer to use. It is a major version because stored data is migrated (Core Data model v8, a one-time UK price-scale repair, a widened backup format) and the legacy Preferences window and several old code paths have been removed.

Back up before upgrading: **Backups → Back Up Now**. A first launch of 3.0.0 migrates the store in place; older backups still restore.

## Data safety

- Stored price history is loaded at launch and saved after backfills and imports. Charts no longer start empty after every relaunch.
- Recorded portfolio snapshots are never replaced by a recalculation; recalculation only fills days that have no snapshot.
- In-memory history is bounded by resolution instead of a fixed count, so intraday samples no longer push out multi-year history. Core Data keeps every snapshot.
- Saves of trades and trading info are atomic and happen in order, and edits made just before quitting are kept.
- If the startup load fails, portfolio writes are refused until a restore or import succeeds, so the next edit cannot overwrite the stored portfolio.
- Deleting every holding no longer brings old legacy holdings back on relaunch.
- The one-time UK price-scale repair uses each symbol's saved quote as its reference, skips symbols whose latest rows disagree, and saves the original values to the Backups folder before rescaling.
- Removed an unreachable compression service whose density step would have deleted three of every four old snapshots.
- Core Data persistent history older than seven days is purged after launch.

## Crashes and Trading 212

- Repeated keys (two holdings with the same symbol, duplicate provider rows) no longer crash the app.
- An empty Trading 212 positions response no longer deletes every linked holding.
- Changing the Trading 212 account label or rotating the API key keeps existing broker links.
- USD-priced London ETFs stay on the London listing instead of matching or importing a duplicate US listing.
- Test Connection and Preview use the typed credentials and save them only on success. Linking a quantity mismatch needs an explicit choice.

## Backups and restore

- Backups use the local portfolio even while Folync is active, and restore is disabled while Folync is active.
- A restore reads the chosen backup first, its safety backup can never delete it, and the restore stops if the safety copy fails.
- Backups keep the watchlist flag, menu-bar visibility and quote currency. The newest five backups are always kept.
- A blank or non-numeric average cost no longer makes every backup fail.

## Folync

- A rejected token (401) slows automatic checks to every 15 minutes; a rate limit (429) waits for `Retry-After`. Polling and supplemental routes share one backoff.
- A corrupt snapshot cache is discarded instead of blocking polling.
- Test Connection and Preview no longer change the active session. Cancelled or deactivated sessions cannot come back to life.
- Partial benchmark responses apply the benchmarks that are usable.
- Clearer connection states (rate limited, unavailable) and setup errors; a blank token field keeps using the stored token.

## Currency and prices

- A position with no exchange rate is left out of totals instead of turning every total and the menu-bar title into NaN.
- ZAc and ILA convert through ZAR and ILS, like GBp through GBP.
- Price and OHLC history divide by 100 only when the reported currency is GBp, so USD- and GBP-quoted London listings keep the right scale.
- The previous close is chosen by the exchange's date, not the Mac's.
- Exchange rates refresh hourly and show **Stale** after a day.
- OHLC bars with no volume are kept (volume 0); bars with no price are skipped.

## Analytics and charts

- Sector allocation, attribution and risk convert every position into one currency and refuse fallback exchange rates instead of mixing currencies.
- Risk metrics use one close per day, flow-adjusted returns and calendar-day drawdowns. Sharpe and Sortino show "—" when they cannot be computed.
- MACD and RSI edge cases are fixed. Period Return uses the series the chart draws.
- Longer portfolio ranges are labelled **Value Change**, because they include money added or withdrawn. A change is not claimed when the history for the range is incomplete.
- Unknown sectors are shown as **Unclassified** and excluded from the diversification score. More UK, US and ADR listings are classified.
- The allocation chart uses the same sector colours as its table.
- Chart interaction: pinch zoom, Option+scroll zoom, box selection and candlestick hover work correctly. Downsampling keeps each bucket's highs and lows.
- Stock charts and menu-bar charts reload only when their own symbols change.
- CSV exports use ISO 8601 UTC dates, RFC 4180 quoting and formula escaping. Chart CSV/PDF exports note the filters used.

## Alerts

- Alerts keep their identity, so deletes, pauses and cooldowns survive relaunches.
- Alerts fire for holdings priced by Folync or Trading 212, not only market quotes.
- Percentage alerts measure the move from the previous close.
- Duplicate alerts are rejected, and a level that has already been passed gets a warning.

## Interface

- Redesigned main window: grouped sidebar (Portfolio, Analysis, Maintenance) showing the portfolio source and last update, Overview, Holdings with search and Edit mode, Performance, Risk, Allocation, Alerts, Backups, Data Health, Diagnostics and Settings.
- Standard App, Edit, Window and Help menus. Copy, paste, Cmd-W and Cmd-R work.
- Settings use native tabbed forms: General, Menu Bar, Appearance, Connections, Refresh and Advanced.
- Stored API keys can be removed from Settings → Connections.
- Deleting alerts and clearing logs ask for confirmation; Clear Logs offers to export first.
- Neutral colour for zero or unknown changes, "—" for missing values, VoiceOver labels and Reduce Motion support throughout.

## Refresh and Python helper

- Refresh requests that arrive during a pass are queued for one follow-up pass. Retry forces a refresh past freshness and backoff.
- Offline failures no longer count toward suspending a symbol.
- Cancelling a refresh terminates its Python process.
- The quote cache honours the refresh interval and lives in `~/Library/Caches/stockbar-cache`.

## Development

- One entry point for local work and CI: `bash script/develop.sh build|test|python-tests|checks|docs-check|analyze|run`.
- Strict concurrency checking with a warning-free build, and invariant checks that reject the crashing dictionary initialiser.
- 509 XCTest tests plus offline Python tests.
- Dependabot keeps GitHub Actions and the pinned Python helper packages up to date.

## Comparison basis

These notes cover the 30 commits on `testing` after tag `v2.4.4`.
