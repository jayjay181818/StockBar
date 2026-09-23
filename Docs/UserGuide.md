# Stockbar User Guide

Stockbar tracks a stock portfolio from the macOS menu bar, with a main window for holdings, analysis, alerts and settings.

## Contents

- [Getting started](#getting-started)
- [The main window](#the-main-window)
- [Holdings](#holdings)
- [The menu bar](#the-menu-bar)
- [Analysis](#analysis)
- [Alerts](#alerts)
- [Currencies and UK stocks](#currencies-and-uk-stocks)
- [Connections: Trading 212 and Folync](#connections-trading-212-and-folync)
- [Refreshing and data freshness](#refreshing-and-data-freshness)
- [Backups, Data Health and Diagnostics](#backups-data-health-and-diagnostics)
- [Troubleshooting](#troubleshooting)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Privacy](#privacy)

## Getting started

**Requirements:** macOS 15.4 or later, Python 3.9 or later with the pinned packages in `requirements.txt`, and an internet connection for market data.

On first launch Stockbar checks the configured Python interpreter (`/usr/bin/python3` by default). If packages are missing or the wrong version, an alert offers **Copy Command**, which copies a ready-to-run command such as:

```bash
'/usr/bin/python3' -m pip install -r '/Applications/Stockbar.app/Contents/Resources/requirements.txt'
```

If pip reports an *externally managed environment* (common with Homebrew Python), create a virtual environment, install the requirements into it, and point Stockbar at it (then relaunch):

```bash
defaults write com.stockbar pythonInterpreterPath "$HOME/stockbar-venv/bin/python3"
```

The dependency check runs again whenever the interpreter changes.

Stockbar appears both in the Dock and in the menu bar. Click the Dock icon or choose **Open Stockbar** (⌘O) to show the main window.

## The main window

The sidebar groups every screen:

| Group | Screens |
|---|---|
| Portfolio | **Overview** (value, today's and selected-period movement, chart, position inspector), **Holdings**, **Alerts** |
| Analysis | **Performance** (charts), **Risk**, **Allocation** (including Attribution) |
| Maintenance | **Backups**, **Data Health**, **Diagnostics** |
| | **Settings** |

Use the arrow keys to move through the sidebar. **Refresh Prices** at the bottom of the sidebar (⌘R) requests an immediate update and shows progress. The window remembers its size, position and last screen.

## Holdings

The read-only table shows your positions in your saved order; click a column header to sort. Search filters the table without changing portfolio totals.

Choose **Edit positions** to change local holdings:

- **Add Holding** adds a row. Enter the symbol in Yahoo Finance format (`AAPL`, `VOD.L`, `SHOP.TO`), units, average cost and the currency that cost was entered in. Fractional units are kept as entered.
- A symbol already in the portfolio is flagged with a warning; only one row per symbol is kept when saved, so combine lots into one row.
- Row actions: 👁 **watchlist only** (price shown, excluded from totals and analytics), move up/down, and remove.
- The toggle in the first column controls whether the symbol has its own menu-bar item.

Positions provided by a linked Trading 212 account or by Folync are read-only here; their menu-bar visibility and alerts remain editable.

## The menu bar

**Portfolio item.** Shows total value and today's change. In Settings → Menu Bar → Portfolio Menu Bar choose the currency, decimal places and **Day Gain** format (*Amount and Percentage*, *Amount*, or *Percentage*); the preview matches the menu bar exactly. Click it for a popover with a chart (1D/1W/1M), market value, total and period P&L, and cost basis.

**Per-stock items.** Each visible holding can have its own item. Choose a display mode and change format in Settings → Menu Bar, or a **Custom** template using these tokens:

| Token | Meaning |
|---|---|
| `{symbol}` | Ticker |
| `{price}` | Current price |
| `{change}` | Price change today |
| `{changePct}` | Percentage change today |
| `{dayPL}` | Today's profit/loss for your position |
| `{currency}` | Currency symbol |
| `{arrow}` | Up/down arrow |

Example: `{symbol} {price} {arrow}{changePct}`.

Click a stock item for its popover: price chart with a benchmark comparison (S&P 500 or FTSE 100), market value, P&L and units. For local holdings, the pencil next to **Units** edits the quantity (the current locale's decimal separator is accepted). If updates for the symbol have been paused after repeated failures, the popover says so and offers **Retry Now**.

Gains are green and losses red when **Color Coding** is on (Settings → General); unchanged or unknown values are neutral. Settings → Menu Bar → Menu Bar Visibility can hide all stock items or show them only when an external display is connected.

## Analysis

- **Performance** — portfolio value, gains or an individual stock over preset or custom ranges, as a line or candlestick chart with optional indicators and comparisons.
- **Risk** — value at risk, Sharpe and Sortino ratios, volatility and drawdowns from stored portfolio history. Missing observations are ignored rather than treated as zero.
- **Allocation** — sector allocation and diversification, a correlation matrix built from at least 20 shared trading days of stored prices, and performance attribution. Benchmarks and watchlist symbols are excluded.

History accumulates as Stockbar runs (Settings → Refresh → Chart Data Collection) and is backfilled where providers allow.

## Alerts

Alerts → **Add Alert** creates an alert when a price rises above or falls below a threshold, or moves by a percentage. Alerts are delivered as macOS notifications; allow notifications for Stockbar when prompted. Existing alerts can be paused, resumed or deleted.

## Currencies and UK stocks

Choose the **Preferred Currency** in Settings → General (USD, GBP, EUR, JPY, CAD, AUD). Positions keep their own currencies and are converted for totals. Exchange rates and when they were last obtained are shown in Settings → General → Exchange Rates.

London prices are often quoted in pence (**GBX**, 100 GBX = £1). Stockbar converts pence to pounds once, when data arrives, and displays pounds. When entering an average cost, pick the currency you are typing in — **GBX** for `250` meaning 250p, or **GBP** for `2.50`.

## Connections: Trading 212 and Folync

Settings → **Connections** manages optional sources. Credentials are stored in your Keychain.

- **Trading 212** — link a read-only account, preview matches and differences, then link holdings. Linked positions take quantity, price, average cost and P&L from the broker.
- **Folync** — use a self-hosted Folync instance as the authoritative portfolio. While active, local holdings are kept aside and restored when you switch back. Supplemental routes (history, candles, benchmarks, FX) can be switched on or off individually.

Market-data API keys for FMP and Twelve Data, and the provider order, are also configured here.

## Refreshing and data freshness

- Prices refresh at the **Main Refresh Interval** (Settings → Refresh; default 5 minutes). A price younger than about 90% of the interval is reused.
- A symbol that fails is retried with increasing delays (1, 2, 5, then 10 minutes). After five consecutive failures it is paused for one hour; use **Retry Now** in its popover to resume sooner.
- **Data Health** summarises tracked rows, menu-bar visibility, currency and refresh settings.

## Backups, Data Health and Diagnostics

- **Backups** — Stockbar makes an automatic backup once a day. Settings → Advanced → Backups offers **Backup Now**, **Restore from Backup** and **View Backups**, plus how long to keep them. Restoring asks for confirmation. Keychain credentials are not included in backups.
- **Diagnostics** — view, refresh and clear the log. The log file is at `~/Library/Logs/com.stockbar/stockbar.log`.

For recovery from outside the app, see [Scripts/README.md](../Scripts/README.md).

## Troubleshooting

**Prices are not updating.** Check your connection, then open the symbol's popover: if updates are paused, click **Retry Now**. Confirm the symbol on [finance.yahoo.com](https://finance.yahoo.com) (UK listings need `.L`). Make sure the Python packages are installed for the configured interpreter.

**A value shows "—".** The price or history is not available yet, the symbol is invalid, or the provider is temporarily unavailable. Missing values are shown as "—" rather than as a price.

**Risk or correlation says there is not enough data.** These need stored history; leave Stockbar running and data accumulates.

**Exchange rates look stale.** Rates refresh at most every five minutes; Settings → General → Exchange Rates shows when they were last obtained. If no live rate is available, conversions that would rely on it are shown as unavailable rather than guessed.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘O | Open Stockbar |
| ⌘, | Settings |
| ⌘R | Refresh prices (main window) |
| ⌘W / ⌘M | Close / minimise window |
| ⌘C, ⌘V, ⌘X, ⌘A, ⌘Z | Standard editing in text fields |
| ⌘H | Hide Stockbar |
| ⌘Q | Quit |

## Privacy

Portfolio data is stored locally on your Mac (Application Support and Core Data). Market-data requests send ticker symbols to the configured providers. Broker and Folync credentials stay in your Keychain and are never written to logs.
