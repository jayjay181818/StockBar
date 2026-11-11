# Stockbar User Guide

Stockbar tracks a stock portfolio from the macOS menu bar, with a main window for holdings, analysis, alerts and settings.

## Contents

- [Installing](#installing)
- [Getting started](#getting-started)
- [The main window](#the-main-window)
- [Holdings](#holdings)
- [The menu bar](#the-menu-bar)
- [Analysis](#analysis)
- [Alerts](#alerts)
- [Currencies and UK stocks](#currencies-and-uk-stocks)
- [Connections: Trading 212 and Folync](#connections-trading-212-and-folync)
- [Refreshing and data freshness](#refreshing-and-data-freshness)
- [Updates](#updates)
- [Backups, Data Health and Diagnostics](#backups-data-health-and-diagnostics)
- [Troubleshooting](#troubleshooting)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Privacy](#privacy)

## Installing

1. Download `Stockbar-<version>.zip` from the [latest release](https://github.com/jayjay181818/StockBar/releases/latest) and unzip it.
2. Move **Stockbar** to your Applications folder before you open it. Until it is moved, macOS runs a downloaded app from a read-only copy, where it cannot update itself.
3. Open it. macOS refuses the first time, because the app is not notarised by Apple. Open **System Settings → Privacy & Security**, scroll down to **Security** and choose **Open Anyway**. This is needed once per Mac, not after each update.

If you prefer the terminal, this does the same as step 3:

```bash
xattr -dr com.apple.quarantine /Applications/Stockbar.app
```

Stockbar then keeps itself up to date; see [Updates](#updates).

## Getting started

**Requirements:** macOS 15.4 or later and an internet connection for market data. Stockbar sets up its own Python (below); nothing needs installing first. Another interpreter must be Python 3.10 or later; Apple's `/usr/bin/python3` 3.9 is no longer supported.

Stockbar uses the interpreter in the `pythonInterpreterPath` setting if there is one; otherwise its own environment at `~/Library/Application Support/Stockbar/python-env`. Until that environment is set up, market data from Python providers is unavailable.

Open **Settings → Advanced → Python** and choose **Set Up**. Stockbar installs a current Python and its pinned packages in its own environment and uses it from the next refresh. It uses `uv` or a Python 3.10 or later from Homebrew or python.org if one is installed; otherwise it downloads a pinned release of `uv`, checks its SHA-256, and keeps it and its Python in Stockbar's Application Support folder, so nothing needs installing first. It needs an internet connection. **Rebuild** reinstalls it.

On first launch, and again after an update changes the pinned versions, Stockbar checks the interpreter it uses. If the environment is not set up, or packages are missing or out of date, an alert offers **Set Up Automatically**, which does the same as the Settings button. For an interpreter set with `pythonInterpreterPath`, the alert also offers **Copy Command** and **Open Terminal**; Copy Command copies a ready-to-run command such as:

```bash
'/opt/homebrew/bin/python3' -m pip install -r '/Applications/Stockbar.app/Contents/Resources/requirements.txt'
```

If pip reports an *externally managed environment* (common with Homebrew Python), create a virtual environment, install the requirements into it, and point Stockbar at it (then relaunch):

```bash
defaults write com.stockbar pythonInterpreterPath "$HOME/stockbar-venv/bin/python3"
```

The dependency check runs again whenever the interpreter or the pinned versions change.

Stockbar appears both in the Dock and in the menu bar. Click the Dock icon or choose **Open Stockbar** (⌘O) to show the main window.

## The main window

The sidebar groups every screen:

| Group | Screens |
|---|---|
| Portfolio | **Overview** (value, today's and selected-period movement, chart, position inspector), **Holdings**, **Alerts** |
| Analysis | **Performance** (charts), **Risk**, **Allocation** (including Attribution) |
| Maintenance | **Backups**, **Data Health**, **Diagnostics** |
| | **Settings** |

Use the arrow keys to move through the sidebar. The bottom of the sidebar shows where your portfolio comes from (local, Trading 212 or Folync) and when prices last updated; its refresh button (⌘R) requests an immediate update and spins while it runs. The window remembers its size, position and last screen. Motion follows System Settings → Accessibility → Display → Reduce Motion.

**Overview** shows the total value with today's and the selected period's change, a portfolio chart (hover to read any point), a summary, and details for one position.

## Holdings

The read-only table shows your positions in your saved order; click a column header to sort, and click a Today or Total P&L value to switch between amount and percentage. Search filters the table without changing portfolio totals.

Choose **Edit** to change local holdings, and **Done** when finished (changes save as you type):

- **Add Holding** adds a row. Enter the symbol in Yahoo Finance format (`AAPL`, `VOD.L`, `SHOP.TO`), units, average cost and the currency that cost was entered in. Fractional units are kept as entered.
- A symbol already in the portfolio is flagged with a warning; only one row per symbol is kept when saved, so combine lots into one row.
- Row actions: 👁 **watchlist only** (price shown, excluded from totals and analytics), move up/down, and remove. Removing a holding asks for confirmation.
- The **Menu Bar** switch (checkbox while editing) controls whether the symbol has its own menu-bar item. Profit and loss columns are shown outside Edit mode.

Positions provided by a linked Trading 212 account or by Folync are read-only here; their menu-bar visibility and alerts remain editable.

## The menu bar

**Portfolio item.** Shows total value and today's change. In Settings → Menu Bar → Portfolio Menu Bar choose the currency, decimal places and **Day Gain** format (*Amount and Percentage*, *Amount*, or *Percentage*); the preview matches the menu bar exactly. Click it for a popover with a chart (Today, 1 Week, 1 Month), market value, total and period P&L, and cost basis. Hover over the chart to read the value at any point.

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

Click a stock item for its popover: a price chart with an optional benchmark line (S&P 500 or FTSE 100; switch it off in Settings → Menu Bar → Stock Popover), market value, P&L and units. Hover over the chart to read the price at any point. A symbol without stored history shows **No history yet** rather than a flat line. For local holdings, the pencil next to **Units** edits the quantity (the current locale's decimal separator is accepted); a lock means the quantity comes from a linked source. If updates for the symbol have been paused after repeated failures, the popover says so and offers **Retry Now**.

Both popovers end with the last update time (click it to refresh) and buttons to open the Stockbar window, open Settings and quit. Popovers follow the **Theme** in Settings → Appearance.

Gains are green and losses red when **Color Coding** is on (Settings → General); unchanged or unknown values are neutral. Settings → Menu Bar → Menu Bar Visibility can hide all stock items or show them only when an external display is connected.

## Analysis

- **Performance** — portfolio value, gains or an individual stock over preset or custom ranges, as a line or candlestick chart with optional indicators and comparisons. On the 1 Day and 1 Week ranges the line chart draws nights and weekends narrow, so the hours with prices fill the chart; longer ranges are drawn to scale.
- **Risk** — value at risk, Sharpe and Sortino ratios, volatility and drawdowns from stored portfolio history. Missing observations are ignored rather than treated as zero.
- **Allocation** — sector allocation and diversification, a correlation matrix built from at least 20 shared trading days of stored prices, and performance attribution. Benchmarks and watchlist symbols are excluded.

History accumulates as Stockbar runs (Settings → Refresh → Chart Data Collection) and is backfilled where providers allow.

## Alerts

Alerts → **Add Alert** creates an alert when a price rises above or falls below a threshold, or moves from the previous close by a percentage; the sheet shows the symbol's current price for reference. Above and below alerts fire when the price crosses the level, so the sheet warns if the price is already past it. Alerts work for every holding, including ones priced by Folync or Trading 212. Alerts are delivered as macOS notifications; allow notifications for Stockbar when prompted. Existing alerts can be paused, resumed or deleted from their row or its right-click menu.

## Currencies and UK stocks

Choose the **Preferred Currency** in Settings → General (USD, GBP, EUR, JPY, CAD, AUD). Positions keep their own currencies and are converted for totals. Exchange rates and when they were last obtained are shown in Settings → General → Exchange Rates.

London prices are often quoted in pence (**GBX**, 100 GBX = £1). Stockbar converts pence to pounds once, when data arrives, and displays pounds. When entering an average cost, pick the currency you are typing in — **GBX** for `250` meaning 250p, or **GBP** for `2.50`.

## Connections: Trading 212 and Folync

Settings → **Connections** manages optional sources. Credentials are stored in your Keychain.

- **Trading 212** — link a read-only account, preview matches and differences, then link holdings. Linked positions take quantity, price, average cost and P&L from the broker.
- **Folync** — use a self-hosted Folync instance as the authoritative portfolio. While active, local holdings are kept aside and restored when you switch back. Supplemental routes (history, candles, benchmarks, FX) can be switched on or off individually. With VoiceOver, Stockbar speaks the result of each Folync action and of **Refresh Now**, and announces a connection problem once when it starts.

Market-data API keys for FMP and Twelve Data, and the provider order, are also configured here.

## Refreshing and data freshness

- Prices refresh at the **Main Refresh Interval** (Settings → Refresh; default 5 minutes). A price younger than about 90% of the interval is reused.
- A symbol that fails is retried with increasing delays (1, 2, 5, then 10 minutes). After five consecutive failures it is paused for one hour; use **Retry Now** in its popover to resume sooner.
- **Data Health** summarises tracked rows, menu-bar visibility, currency and refresh settings.

## Updates

Stockbar looks for a new version about once a day. When there is one it shows the version and its release notes; choose **Install Update** and Stockbar downloads it, checks it, installs it and reopens.

**Settings → General → Updates** shows the version you are running and has:

- **Update Channel** — **Stable** offers released versions only. **Testing** also offers every change as it lands, before it is released; these builds may be rough. With automatic checks on, changing the channel checks again straight away.
- **Check Automatically** — turn off to check only when you ask.
- **Check Now** — the same as **Check for Updates…** in the **Stockbar** menu.

Things to know:

- **Keychain prompt after an update.** macOS asks once for access to your saved credentials (Trading 212, Folync, FMP and Twelve Data are kept in one Keychain item, "Stockbar credentials"). Choose **Always Allow**. The first update to a version that keeps them in one item asks once more for each credential saved by the version before, to move it across. Stockbar is built without an Apple developer account, so each build has a new signature and macOS does not carry the answer over.
- **Leaving Testing.** Stockbar never moves to an older build. After switching back to Stable you keep the testing build you have until a newer version is released.
- **Where updates come from.** They are built by GitHub from Stockbar's source and downloaded from its GitHub releases. Stockbar checks each one against a signing key built into the app and refuses a download or an update list that does not match.
- **Development builds.** A build made from source in Xcode shows only its version here; updates are off.

## Backups, Data Health and Diagnostics

- **Backups** — Stockbar makes an automatic backup once a day. The Backups screen (and Settings → Advanced → Backups) shows the last backup and offers **Back Up Now**, **Restore from Backup…** and **View Backups**, plus how long to keep them. Restoring asks for confirmation. Keychain credentials are not included in backups.
- **Export & Import** — Settings → Advanced → Export & Import saves Stockbar to one password-protected `.stockbarexport` file, for example to move to another Mac. **Settings & Keys** holds your preferences plus the FMP, Twelve Data, Trading 212 and Folync keys. **Everything** adds your portfolio database; its estimated size is shown first. The file contains your API keys, so keep it and its password safe. **Import…** shows what the file contains and asks before replacing anything. Keys not in the file stay as they are, and Stockbar backs up your portfolio before replacing it, then relaunches. The Python setup, window positions and caches are not exported.
- **Data Health** — price and exchange-rate freshness, portfolio source, tracked symbols, menu-bar visibility and preferred currency.
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
| ⌘1 – ⌘9 | Show a page of the main window, in sidebar order (also in the **View** menu) |
| ⌘W / ⌘M | Close / minimise window |
| ⌘C, ⌘V, ⌘X, ⌘A, ⌘Z | Standard editing in text fields |
| ⌘H | Hide Stockbar |
| ⌘Q | Quit |

The **Help** menu opens Data Health and Diagnostics and shows the log files in Finder.

## Privacy

Portfolio data is stored locally on your Mac (Application Support and Core Data). Market-data requests send ticker symbols to the configured providers. Broker and Folync credentials stay in your Keychain and are never written to logs. Update checks fetch a file from GitHub and send nothing about you or your Mac beyond what any web request shows (your IP address and the Stockbar version).
