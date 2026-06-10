# StockBar

**Version 2.4.3** | **macOS 15.4+** | **Swift 6**

StockBar is a native macOS menu bar and portfolio window app for tracking holdings, watchlists, gains/losses, charts, alerts, backups, diagnostics, and multi-currency market data. It supports manual portfolios and linked Trading 212 broker holdings while keeping the existing yfinance/FMP/Twelve Data/Stooq market-data and historical-chart pipeline intact.

## Key Features

### Portfolio And Holdings
- Native Stockbar window with sidebar navigation: Holdings, Charts, Risk, Allocation, Alerts, Backups, Data Health, Diagnostics, and Settings.
- Editable Holdings table for visibility, symbol, units, average cost, currency, current price, value, Day P/L, Total P/L, and row actions.
- Day P/L and Total P/L columns toggle between amount and percentage when clicked.
- Net Value, Total Net Gains, and Tracked Symbols summary cards with currency symbols, thousands
  separators, and USD equivalents in brackets when USD is not the primary display currency.
- Manual holdings, watchlist-only symbols, and broker-linked holdings can coexist.
- UK `.L` holdings and GBX/GBP cost bases are normalized consistently for display and gain calculations.

### Trading 212 Broker Sync
- Trading 212 can be enabled from Settings -> Data Sources as a broker/portfolio provider.
- Credentials are API Key + API Secret and are stored in macOS Keychain only.
- Supports Live / Real Money and Demo / Paper environments with separated account keys and cache namespaces.
- Account type and label are configurable, including Stocks & Shares ISA, Invest/general, and Unknown/custom.
- Read-only Test Connection and Preview Import flow before linking anything.
- Preview maps Trading 212 provider tickers to canonical instruments and audits manual matches, quantity deltas, and conflicts.
- Link Matched Holdings saves broker links only after user confirmation.
- Linked Trading 212 holdings use broker-provided live position data by default for quantity, current price, value, average cost, and P/L.
- Auto-sync uses one bulk Trading 212 positions/account refresh every 30 seconds when enabled.
- Market-data providers are not called unnecessarily for linked Trading 212 holdings during normal broker sync.
- Optional setting can delete linked manual holdings when the position is removed from Trading 212.
- Trading/order execution is not supported and is never required.

### Market Data And Charts
- yfinance remains the primary general market-data provider.
- Financial Modeling Prep, Twelve Data, and Stooq remain fallback providers for watchlists, manual holdings, historical data, and provider failures.
- Fetch priority is configurable from Settings -> Data Sources.
- Historical charts continue to use the existing market-data system unless a future broker-history integration is added.
- Interactive Swift Charts views cover portfolio value, portfolio gains, and individual symbol performance.
- Individual stock charts combine stored price snapshots with memory-only live samples, and same-day
  historical backfills are merged by timestamp so earlier intraday points are not discarded just
  because the symbol already has a current-day sample.
- Benchmark support includes symbols such as `^GSPC` and `^FTSE`.

### Menu Bar Experience
- Portfolio total can be shown in the macOS menu bar with configurable formatting.
- Individual stock menu bar items can be shown or hidden.
- Stock dropdowns include current values, day/position changes, grouped currency-formatted P/L
  amounts, and lightweight chart surfaces with memory-only live samples, 2-minute `1D` display
  buckets, and the latest live endpoint.
- Stock dropdowns request missing 1D symbol/benchmark history after relaunch when memory-only
  samples are sparse, then refresh the open chart when fetched snapshots arrive.
- The portfolio dropdown `1D` reconstructs the current portfolio over the last 24 hours from
  current holdings plus available symbol snapshots/live samples, with missing symbol history
  fetched in the background when coverage is thin.
- Menu bar values update from Trading 212 broker sync for linked holdings and from market-data refreshes for manual/watchlist symbols.

### Settings
- Embedded Settings section in the main Stockbar window with tabs: General, Menu Bar, Appearance, Data Sources, Refresh, and Advanced.
- App menu Settings, `Cmd+,`, sidebar Settings, and menu popover Preferences all route to the embedded Settings section.
- Data Sources includes API key fields for FMP and Twelve Data, fetch priority/fallback order, and Trading 212 broker configuration.
- Trading 212 settings include enable/disable, environment, account type, account label, credential status, Test Connection, Preview Import, Link Matched Holdings, auto-sync settings, and missing-position deletion behavior.
- Sensitive credential fields stay empty after save by design; stored status is shown instead.

### Reliability, Backups, And Diagnostics
- Backups view for creating, inspecting, and restoring portfolio backups.
- Data Health and Diagnostics views for current portfolio/cache state and log review.
- Core Data persistence for trades, trading info, historical snapshots, and analytics data.
- Broker links are stored separately from market quote/historical caches.
- Log redaction covers API keys, Trading 212 credentials, auth headers, and sensitive account identifiers.
- Memory pressure handling, cache maintenance, retry/cooldown behavior, and Python subprocess timeouts are built in.

## Architecture

StockBar uses a hybrid Swift + Python architecture:

- **Swift/AppKit/SwiftUI**: Main app windows, settings, menu bar controllers, portfolio state, Trading 212 provider, broker sync, analytics, diagnostics, and persistence orchestration.
- **Core Data**: Portfolio trades, trading info, historical price snapshots, and portfolio snapshots.
- **Keychain**: Trading 212 credentials and other secrets where supported.
- **Python/yfinance subprocesses**: General market quotes, OHLC data, and historical data fetches.
- **MarketDataProvider path**: yfinance, FMP, Twelve Data, and Stooq for quotes, watchlists, and history.
- **BrokerProvider path**: Trading 212 for broker-linked holdings and live position data.

Broker data and market data are intentionally separate. Trading 212 is the source of truth for linked broker positions, while yfinance/FMP/Twelve Data/Stooq continue to serve general quotes, watchlists, fallbacks, and historical chart data.

## Getting Started

### Prerequisites
1. macOS 15.4 or later.
2. Xcode 15 or later for local development.
3. Python 3.7+ with yfinance for the market-data subprocess path:

   ```bash
   pip3 install yfinance
   ```

### Build From Source

```bash
git clone https://github.com/jayjay181818/StockBar.git
cd StockBar
open Stockbar.xcodeproj
```

Or build/run from this local workspace:

```bash
./script/build_and_run.sh --verify
```

### Manual Portfolio Setup
1. Launch StockBar.
2. Open the main Stockbar window from the menu bar or app menu.
3. Go to Holdings.
4. Use Add Holding to add or edit manual positions.
5. Use Settings -> Data Sources to configure market-data API keys and provider priority if needed.
6. Use Charts, Risk, Allocation, Alerts, Backups, Data Health, Diagnostics, and Settings from the sidebar as needed.

### Trading 212 Setup
1. Open Settings -> Data Sources.
2. Enable Trading 212.
3. Choose Live / Real Money or Demo / Paper.
4. Select the account type and account label, for example `Trading 212 ISA`.
5. Paste the Trading 212 API Key and API Secret, then save credentials to Keychain.
6. Use Test Connection.
7. Use Preview Import to review proposed mappings and conflicts.
8. If all rows are clean manual matches, use Link Matched Holdings.
9. Enable auto-sync if you want linked holdings refreshed from Trading 212 every 30 seconds.

Trading 212 setup is read-only until you explicitly link matched holdings. Previewing does not mutate holdings, backups, historical data, market caches, or Core Data trade rows.

## Usage Guide

### Holdings
- **Current** shows the latest display price for the position source.
- **Value** is current price multiplied by units.
- **Day P/L** compares current price with previous close.
- **Total P/L** compares current price with normalized average cost.
- Click either P/L column header or value to toggle that column between amount and percentage.
- Amount mode shows signed currency values with symbols and thousands separators, for example `+$100,123.56`.
- Summary cards show the primary currency first and add the USD equivalent in brackets when USD is
  not the selected display currency, for example `£132,830.74 ($179,826.22)`.
- Linked Trading 212 holdings use broker-provided live position data by default.
- Manual and watchlist-only rows continue through the configured market-data provider chain.

### Charts And Analytics
- Charts use existing historical data and provider fetches.
- Trading 212 linked holdings still use the market-data provider chain for history unless broker history is added later.
- Main individual-stock charts and stock dropdowns both read from stored symbol snapshots plus
  memory-only live samples, and refresh as new price data arrives.
- Individual stock dropdown `1D` charts render symbol snapshots and memory-only live samples in
  2-minute display buckets, then use the latest live/broker price for the final value.
- Portfolio dropdown `1D` charts value the current displayed holdings across the last 24 hours
  using available per-symbol snapshots/live samples, skip low-coverage timestamps, and request
  missing held-symbol history in the background when needed.
- The live chart samples are memory-only and do not increase historical snapshot writes.
- Risk and Allocation views use stored portfolio and historical data.

### Backups And Data Health
- Create a backup before large portfolio changes or broker-linking work.
- Data Health shows portfolio/cache state.
- Diagnostics shows logs with redacted sensitive values.

## Configuration

### Data Sources
- **Market data**: Yahoo Finance/yfinance, FMP, Twelve Data, Stooq.
- **Broker data**: Trading 212 for linked broker positions.
- **FMP/Twelve Data keys**: configured in Settings -> Data Sources.
- **Trading 212 credentials**: stored in Keychain only.
- **Fetch priority**: configurable for market-data fallbacks.

### Refresh Behavior
- Trading 212 linked holdings: one bulk broker sync every 30 seconds when enabled.
- General market-data fallback refreshes retain the slower app/provider cadence.
- Historical chart data uses the existing historical fetch/backfill system.

### Storage
- **UserDefaults**: non-secret preferences and settings.
- **Keychain**: Trading 212 API Key/API Secret.
- **Core Data**: portfolio trades, trading info, historical data, portfolio snapshots.
- **Broker links**: local broker-link records keyed by broker account and instrument identity.
- **Caches**: market quote, historical data, and broker preview/sync data remain separate.

## Troubleshooting

### Trading 212
- If Test Connection fails, verify environment selection, API Key/API Secret, and Account data permission.
- Metadata permission is recommended for reliable mapping, but preview can still work with lower-confidence mappings when account-position fields are usable.
- Orders - Execute is not needed and should not be enabled for StockBar.
- If a linked holding disappears from Trading 212, StockBar reports it as missing; deletion of the local linked holding is controlled by the Settings option.

### Market Data
- Missing manual/watchlist quotes usually indicate provider fallback, yfinance, or network issues.
- FMP `403` messages usually indicate key/plan limits; keys are redacted in logs.
- Python `urllib3`/LibreSSL warnings can appear from the local Python environment and are separate from Trading 212 broker sync.

### Logs
- Diagnostics shows redacted logs.
- Log files are stored under `~/Library/Logs/com.fhl43211.Stockbar/stockbar.log`.
- Trading 212 sync health can be confirmed by log lines like:

  ```text
  Trading 212 linked sync (auto): Synced 11 linked holdings. Deleted 0. Missing 0. Broker-only 0.
  ```

## Development

### Useful Commands

```bash
# Build
xcodebuild build -project Stockbar.xcodeproj -scheme Stockbar -destination 'platform=macOS'

# Test
xcodebuild test -project Stockbar.xcodeproj -scheme Stockbar -destination 'platform=macOS'

# Build and run local debug app
./script/build_and_run.sh --verify

# Python market-data smoke test
python3 Stockbar/Resources/get_stock_data.py AAPL
```

### Test Coverage
- Portfolio calculation tests cover day/total P/L amount and percentage calculations.
- Trading 212 auth tests cover API Key/API Secret Basic auth and secret redaction.
- Trading 212 preview/resolver tests cover UK `.L`/`.LON`/legacy `.XC`, LSE/GBP hints, US symbols, HIMS aliasing, and manual-match safety.
- Trading 212 broker-link/sync tests cover broker account keys, linked updates, missing-position deletion behavior, 30-second sync defaults, and GBX/GBP normalization.
- Portfolio menu chart tests cover display-only `1D` synthetic history, mixed-currency holdings,
  low-coverage filtering, background fetch candidate selection, and preserved `1W`/`1M` behavior.

## Release History

### Version 2.4.3 (Current) - Embedded Settings & Live Menu Graph Polish
- **Embedded Settings**: Moved Settings into the main Stockbar window as a first-class sidebar destination.
- **Unified Settings Routing**: App menu Settings, `Cmd+,`, sidebar Settings, and menu popover Preferences now open the embedded Settings section instead of a separate popout.
- **Menu Dropdown Graphs**: `1D` stock dropdown charts use symbol snapshots/live samples, while portfolio dropdown charts reconstruct the current portfolio over the last 24 hours from current holdings plus available symbol snapshots/live samples.
- **Chart Backfill Continuity**: Main individual-stock charts now use the same stored-plus-live
  symbol data source as dropdown charts, and same-day historical backfills merge by timestamp
  instead of being discarded as duplicate days.
- **Menu Relaunch Recovery**: Sparse stock and benchmark dropdown charts now request missing history after app relaunch and refresh the open chart when snapshots arrive.
- **Portfolio 1D Coverage**: Missing held-symbol history is requested in the background when coverage is thin; low-coverage timestamps are skipped and no historical snapshot write cadence changes are made.
- **Currency Formatting Polish**: Summary cards, Holdings P/L amount mode, and menu dropdown P/L values now show currency symbols plus comma separators, with USD equivalents in brackets for non-USD summary cards.
- **Extended-Hours Valuation Safety**: Zero-valued pre-market/post-market quotes are treated as unavailable, so valid holdings stay included in Net Value and Total Net Gains.
- **Holdings Window Polish**: The main window opens within the visible screen and the Holdings table remains reachable on narrower widths.
- **Refresh Safety**: Historical snapshot cadence, provider fallback cadence, holdings, backups, and cache keys are unchanged.
- See [Changelogs/release_notes_v2.4.3.md](./Changelogs/release_notes_v2.4.3.md).

### Version 2.4.2 - Trading 212 Broker Sync & Modern UI
- **Trading 212 Broker Provider**: Added read-only connection testing, import preview, manual-match audit, broker-link persistence, and linked holding sync.
- **Secure Credentials**: Trading 212 API Key/API Secret are stored in Keychain; logs redact credentials, auth headers, account identifiers, and sensitive payload fields.
- **Broker-Primary Linked Holdings**: Linked Trading 212 holdings use broker-provided live position data by default for quantity, price, value, average cost, and P/L.
- **30-Second Broker Sync**: Trading 212 sync uses one bulk positions refresh every 30 seconds without changing the slower market-data fallback cadence.
- **ISA/Account Labelling**: Users can configure account type and account label, including Stocks & Shares ISA.
- **Safe Linking**: Preview/import does not mutate holdings until explicit linking; broker links are keyed by broker account and instrument identity.
- **Modern Stockbar Window**: Added the first-class sidebar UI for Holdings, Charts, Risk, Allocation, Alerts, Backups, Data Health, and Diagnostics.
- **Modern Settings Window**: Added General, Menu Bar, Appearance, Data Sources, Refresh, and Advanced tabs.
- **Holdings P/L**: Added Total P/L beside Day P/L with amount/percentage toggles.
- **Fixes**: Corrected Trading 212 LSE pence/GBP cost-basis normalization and HIMS provider alias mapping.
- See [Changelogs/release_notes_v2.4.2.md](./Changelogs/release_notes_v2.4.2.md).

### Version 2.4.1 - Reliability & Portfolio Popover Release
- **Portfolio Popover**: Modernized the portfolio total popover and shared menu chart components.
- **Data Safety**: Added Core Data recovery safeguards and hardened backup, restore, import, and export flows.
- **Logging Safety**: Added canonical secret redaction across app and Python subprocess logs.
- **Responsiveness**: Moved OHLC/Python subprocess work off the UI actor with async pipe reads and timeouts.
- **Test Coverage**: Restored full Xcode test target membership and added reliability regression coverage.

### Version 2.4.0 - Portfolio Popover & Data Provider Improvements
- **Popover Improvements**: Fixed menu popover anchoring, footer layout, dismissal behavior, and updated timestamp formatting.
- **Charts & Benchmarks**: Added benchmark overlays for `^GSPC` and `^FTSE` with range-aware chart changes.
- **Menu Bar Stability**: Reused status items across refreshes to reduce menu bar reshuffling and formatting loss.
- **Data Providers**: Added symbol aliases, improved UK symbol handling, and expanded quote/historical fallbacks.
- **Persistence Fixes**: Restored deep-edit persistence and prevented benchmark helpers from persisting as user trades.

### Previous Versions
- See [Changelogs/](./Changelogs/) for detailed release notes.

## Links

- **Releases**: [GitHub Releases](https://github.com/jayjay181818/StockBar/releases)
- **Issues**: [GitHub Issues](https://github.com/jayjay181818/StockBar/issues)
- **Changelogs**: [Release Notes](./Changelogs/)

---

Built with Swift, SwiftUI, AppKit, Core Data, and Python/yfinance.

Last updated: June 10, 2026 - Version 2.4.3
