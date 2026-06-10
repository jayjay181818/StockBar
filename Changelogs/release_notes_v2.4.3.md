# StockBar v2.4.3 Release Notes

**Status:** Implemented
**Date:** 2026-06-10

## Embedded Settings

- Moves Settings into the main Stockbar window as a first-class sidebar destination.
- Routes the sidebar Settings button, app menu Settings command, menu popover Preferences action,
  and `Cmd+,` into the embedded Settings section.
- Keeps the existing Settings tabs and controls as the single canonical settings implementation.
- Retires the separate Settings popout from active navigation paths.

## Menu Dropdown Graph

- Updates the individual stock and portfolio dropdown charts so the `1D` view uses two-minute
  display buckets.
- Feeds individual stock `1D` graphs with symbol snapshots and memory-only live samples from
  Trading 212 broker syncs and regular market refreshes, so linked holdings build an intraday line
  instead of falling back to sparse start/current points.
- Reconstructs the portfolio dropdown `1D` view as the current StockBar portfolio valued across the
  last 24 hours from current holdings plus available per-symbol snapshots/live samples.
- Skips low-coverage portfolio timestamps instead of drawing misleading points when too many
  current holdings are missing price coverage.
- Requests missing held-symbol history in the background when portfolio `1D` coverage is thin,
  without blocking the popover.
- Requests missing stock and benchmark menu chart history after relaunch when the memory-only
  live sample set is sparse.
- Refreshes open stock and portfolio dropdown charts when fetched price snapshots arrive, so the
  graph can fill in without closing and reopening the popover.
- Preserves the selected `1D` / `1W` / `1M` stock dropdown range per symbol when a live price
  refresh recreates or updates the dropdown chart.
- Allows linked Trading 212 holdings to use the normal market-data quote refresh during pre-market
  and post-market sessions, so the dropdown/header can display the latest extended-hours quote
  when Trading 212 positions only expose the broker position price.
- Fixes the stock menu popover open path so the header, market value, and chart endpoint use the
  extended-hours display price instead of falling back to the regular-session close.
- Uses the normal StockBar market-data cadence for those extended-hours quote checks, while keeping
  Trading 212 broker sync on its separate faster 30-second account/position cadence.
- Records refreshed market-data samples with StockBar's display price, including pre-market or
  post-market prices when available, so charts and alerts follow the same latest-price semantics
  as the UI.
- Aligns the main Charts individual-stock view with the dropdown chart data source by combining
  stored price snapshots with memory-only live samples, then refreshing the chart when price data
  changes.
- Preserves same-day backfilled historical points by deduplicating imported snapshots by timestamp
  instead of rejecting all points from a day that already has data.
- Uses the latest broker/live price as the final chart point so the graph reflects the current
  30-second Trading 212 refresh value.
- Leaves `1W` and `1M` on the existing coarser historical behavior while still showing the latest endpoint.
- Does not change historical snapshot write cadence, market-data provider cadence, holdings, backups, or cache keys.

## Holdings Window Polish

- Keeps the main Stockbar window inside the visible screen when it opens, avoiding the clipped
  launch state seen on narrower displays.
- Adds horizontal overflow handling to the Holdings table so all columns remain reachable without
  forcing the whole window off-screen.
- Formats Net Value and Total Net Gains summary cards with currency symbols and grouping
  separators, for example `£132,830.74`.
- Shows the USD equivalent in brackets for summary-card amounts when the primary display currency
  is not USD, for example `£132,830.74 ($179,826.22)`.
- Formats Day P/L and Total P/L amount mode with currency symbols and grouping separators, for
  example `+$100,123.56` and `-£2,763.66`.
- Formats menu dropdown market value and P/L amounts with leading currency symbols and grouping
  separators, for example `$114,772`, `+$103,253`, and `-£31,088`.
- Calculates the main Holdings summary cards from the same display price used by rows and menu
  popovers, so pre-market and post-market prices flow through Net Value and Total Net Gains.
- Treats zero-valued pre-market/post-market quotes as unavailable and falls back to the regular or
  broker current price, preventing valid holdings from being dropped out of portfolio totals.
- Adds an optional Menu Bar Visibility setting that only shows individual stock ticker items when
  an external display is connected.
- Preserves the user's manual stock menu bar visibility preference when no external display is
  connected, then restores ticker items automatically when an external display returns.
- Improves external-display detection by checking CoreGraphics online displays, app activation,
  screen-change notifications, and a lightweight periodic refresh so ticker visibility updates
  after displays are connected post-launch.
- Forces a stock ticker menu-bar resync whenever external-display state is refreshed, with safe
  diagnostics that report whether ticker visibility is allowed and how many ticker items are
  currently allowed to show.
- Preserves existing ticker status items while the external-display rule temporarily hides them,
  rather than removing and recreating them, so Bartender arrangements can survive display
  disconnect/reconnect cycles.
- Keys ticker status items by stable stock symbol rather than transient in-memory trade UUIDs, so
  refreshed or rebuilt trade wrappers update the existing menu bar item instead of replacing it.
- Gives ticker status items an immediate plain-symbol fallback title before asynchronous formatted
  menu-bar text arrives, preventing blank or zero-width ticker items during refresh/reload races.
- Assigns stable AppKit autosave names to the portfolio and per-symbol menu bar items so macOS and
  Bartender can track ticker identities and ordering across relaunches and item refreshes.

## Credential Access

- Stores Trading 212 credentials as one Keychain record per live/demo environment for new saves,
  reducing secret reads from two Keychain items to one.
- Caches unlocked Trading 212 credentials in memory for the current app session so the 30-second
  linked-holdings sync does not repeatedly ask macOS Keychain for the same secret.
- Makes automatic Trading 212 background sync use non-interactive Keychain reads, so launch and
  timer-based syncs skip safely instead of showing a surprise macOS password prompt. Explicit
  Settings actions such as Test Connection and Sync Linked Holdings can still request approval.
- Uses metadata-only Keychain checks for stored/not-stored status so launch and Settings status
  refreshes do not read secret bytes just to update labels.
- Avoids starting background Trading 212 auto-sync from older split Keychain credentials at launch;
  explicit Test Connection, Preview, Sync, or re-save can upgrade those credentials to the new
  single-item format.
- Restarts the Trading 212 linked-holdings scheduler after a successful Test Connection so migrated
  credentials immediately resume the configured 30-second broker sync.

## Trading 212 Holding Sync

- Makes the Trading 212 sync status call out broker-only rows and direct the user to Preview Import
  when new broker holdings need to be imported or linked.
- Allows Preview Import to link clean manual matches even when the same preview also contains new
  broker-only holdings.
- Allows explicit linking of manual matches with quantity differences, so trimmed or topped-up
  holdings can be linked and then updated from Trading 212 on the next sync.
- Adds an explicit Import Broker-Only Holdings action for clean Trading 212 rows that have no
  manual StockBar holding yet.
- Imports broker-only holdings using canonical StockBar symbols such as `COPG.L` for `LSE:COPG`
  and `HIMS` for `US:HIMS`, rather than storing Trading 212 provider tickers as user symbols.
- Saves broker links for imported broker-only holdings immediately, so future 30-second Trading 212
  syncs update their quantity, average cost, price, and value.
- Keeps broker-only import explicit and user-confirmed; automatic sync still does not silently add
  brand-new holdings.
- Skips duplicate broker-only imports when the resolved StockBar symbol already exists, protecting
  existing manual holdings from accidental duplication.
- Prevents Trading 212 Test Connection, Preview Import, and manual Sync actions from immediately
  restarting a competing auto-sync request, reducing avoidable Trading 212 `429` rate-limit bursts.
- Pauses the scheduled Trading 212 linked-holdings sync while manual Test Connection, Preview
  Import, or Sync Linked Holdings requests run, then resumes the 30-second timer without an
  immediate duplicate request.
- Adds an opt-in hourly Trading 212 holding reconciliation setting that can automatically apply
  structural portfolio changes separately from the faster 30-second live-value sync.
- Adds an explicit `Reconcile Holdings Now` action in Data Sources for running the same guarded
  structural sync on demand.
- Keeps hourly reconciliation conservative: failed Trading 212 requests apply no changes, and an
  empty broker positions response for an account with linked holdings is treated as a manual-review
  condition rather than deleting the whole portfolio.
- Allows clean broker-only positions to be imported automatically during hourly reconciliation only
  when the new `Automatically import clean broker-only holdings` setting is enabled.

## Performance And Logging

- Fixes a high-CPU logging loop caused by currency conversion debug messages being emitted on the
  portfolio valuation hot path.
- Makes debug logging opt-in via `STOCKBAR_DEBUG_LOGGING=1` or the
  `stockbar.debugLoggingEnabled` user default, while keeping info, warning, and error logs enabled.
- Avoids creating asynchronous debug-log tasks from `CurrencyConverter` during normal portfolio
  refreshes.
- Caches the Stockbar log file path and rotates logs by size/write count without repeatedly reading
  and scanning the whole log file.

## Storage And Privacy

- Moves Stockbar runtime logs to the standard user log folder:
  `~/Library/Logs/com.fhl43211.Stockbar/stockbar.log`.
- Moves the market-data provider configuration file out of Documents and into Stockbar's
  Application Support folder.
- Passes the app-owned configuration path to the Python market-data fetcher so normal quote,
  history, and API-key verification subprocesses no longer probe Documents.
- Redirects legacy debug report and migration backup output to app-owned Application Support
  folders to avoid macOS Documents permission prompts.

## Validation

- Added unit coverage for `1D` two-minute menu graph bucketing and latest live endpoint handling.
- Added unit coverage proving memory-only live samples are available to the menu chart snapshot path.
- Added unit coverage proving memory-only live portfolio samples are available to the portfolio
  menu chart path.
- Added unit coverage for the embedded Settings sidebar destination.
- Added unit coverage for signed Holdings P/L currency formatting, summary-card USD secondary
  amounts, and compact menu dropdown currency formatting.
- Added unit coverage for display-only portfolio `1D` synthetic history, mixed-currency synthetic
  values, low-coverage timestamp filtering, background fetch candidates, and unchanged `1W`/`1M`
  portfolio behavior.
- Added unit coverage for menu stock history-fetch candidate selection after relaunch.
- Added unit coverage proving stock dropdown range selection survives chart model recreation.
- Added unit coverage proving linked Trading 212 holdings remain eligible for market-data quote
  refresh during US pre-market and post-market sessions while still skipping regular-session market
  refreshes.
- Added unit coverage proving Net Value and Total Net Gains use pre-market/post-market display
  prices when extended-hours data is available.
- Added unit coverage proving zero-valued extended-hours quotes fall back to the regular/current
  price instead of dropping those holdings from portfolio totals.
- Added unit coverage proving main Charts individual-stock data includes memory-only live samples.
- Added unit coverage proving same-day historical backfills merge by timestamp instead of being
  dropped as duplicate days.
- Added unit coverage for Trading 212 single-item credential storage and explicit migration from
  the older split Keychain layout.
- Added unit coverage proving Trading 212 credentials are served from the session cache after the
  first successful unlock.
- Added unit coverage for non-interactive Trading 212 credential cache access.
- Added unit coverage for Trading 212 broker-only import planning, duplicate protection, and
  partial matched-linking when a preview also contains broker-only rows.
- Added unit coverage for Trading 212 hourly holding reconciliation settings, including safe
  defaults and persisted opt-in automation flags.
- Added unit coverage for the external-display stock ticker visibility policy and setting
  persistence.
- Added unit coverage proving Stockbar log and market-data config paths avoid Documents.
- Added unit coverage that linked Trading 212 holdings skip normal market-data refresh during
  regular sessions, remain eligible during US pre-market/post-market sessions, and use a shorter
  extended-hours cache freshness window without changing the global fallback-provider cadence.
- Verified `LoggerTests` pass after the logging hot-path fix.
- Verified a freshly launched debug build stays near idle CPU after the Trading 212 30-second
  scheduler starts and produces no live CurrencyConverter debug log growth.
- Verified `xcodebuild build -project Stockbar.xcodeproj -scheme Stockbar -destination 'platform=macOS'` succeeds.
- Verified `xcodebuild test -project Stockbar.xcodeproj -scheme Stockbar -destination 'platform=macOS'`
  succeeds with 223 tests passing.
