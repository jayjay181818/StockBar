# Stockbar FAQ

For a walkthrough of every screen, see the [User Guide](UserGuide.md).

## General

### What is Stockbar?

A macOS portfolio tracker that lives in the menu bar and the Dock. It shows live prices and gains in the menu bar, and a main window with holdings, charts, risk and allocation analysis, alerts and settings.

### What do I need?

macOS 15.4 or later and an internet connection for new prices. Stockbar sets up its own Python (**Settings → Advanced → Python → Set Up**) without anything installed first. If you point it at another interpreter, it must be Python 3.10 or later; Apple's `/usr/bin/python3` 3.9 is no longer supported.

### Does it work offline?

You can still browse holdings, stored history and charts. New prices, exchange rates and broker/Folync data need a connection.

### Where is my data stored?

Everything is local:

| Data | Location |
|---|---|
| Holdings and preferences | UserDefaults (`com.stockbar`) and Core Data |
| Price and portfolio history | `~/Library/Application Support/Stockbar/StockbarDataModel.sqlite` |
| Backups | `~/Library/Application Support/Stockbar/Backups/portfolio_backup_*.json` |
| Provider order | `~/Library/Application Support/com.stockbar/.stockbar_config.json` (readable only by your account) |
| Market-data API keys, Trading 212 and Folync credentials | Keychain |
| Quote cache | `~/Library/Caches/stockbar-cache/quote_cache.json` |
| Logs | `~/Library/Logs/com.stockbar/stockbar.log` |

## Setup

### Why do I see a "Set Up Stockbar's Python" or "Python Dependencies Required" alert?

Stockbar fetches market data through a bundled Python script. "Set Up Stockbar's Python" appears when its own environment does not exist yet, for example on a new Mac or after updating from a version that used `/usr/bin/python3`. "Python Dependencies Required" appears when the interpreter is missing a pinned package or has a different version, for example after an update raises a pin. Choose **Set Up Automatically** to build or rebuild Stockbar's own environment. If you point Stockbar at another interpreter, the alert also offers **Copy Command**; run the copied command in Terminal. With Homebrew Python you may need a virtual environment:

```bash
python3.13 -m venv ~/stockbar-venv
~/stockbar-venv/bin/python3 -m pip install -r /Applications/Stockbar.app/Contents/Resources/requirements.txt
defaults write com.stockbar pythonInterpreterPath "$HOME/stockbar-venv/bin/python3"
```

Relaunch Stockbar afterwards; it re-checks whenever the interpreter or the pinned versions change.

### macOS says it cannot verify Stockbar. How do I open it?

Stockbar is not notarised by Apple, so macOS blocks the first launch of a downloaded copy. Move Stockbar to Applications, try to open it, then open **System Settings → Privacy & Security**, scroll down to **Security** and choose **Open Anyway**. You do this once per Mac; updates do not ask again.

### How do I update Stockbar?

It updates itself. Stockbar checks about once a day and offers a new version with its release notes; **Settings → General → Updates** has **Check Now**, the automatic check, and the channel: **Stable** for released versions, **Testing** for every change before it is released. See [Updates](UserGuide.md#updates) in the User Guide.

### Can Stockbar start at login?

Yes: System Settings → General → Login Items → add Stockbar.

## Holdings

### How do I add or edit a stock?

Holdings → **Add Holding** (or **Edit** to change existing rows). Enter the symbol in Yahoo Finance format, units, average cost and the currency of that cost. You can also edit units from a stock's menu-bar popover.

### Which symbols are supported?

Yahoo Finance tickers: US stocks without a suffix (`AAPL`), London with `.L` (`VOD.L`), Toronto with `.TO`, and so on. Indices such as `^GSPC` and `^FTSE` are used internally as benchmarks.

### Can I track a stock I don't own?

Yes. In Edit mode, click the 👁 button on its row to make it **watchlist only**: its price is shown but it is excluded from totals and analytics.

### Why can't I add the same symbol twice?

Stockbar stores one row per symbol. A duplicate is flagged in red; combine the units into one row, using a weighted average cost.

### Why can't I edit some holdings?

Holdings from a linked Trading 212 account or from Folync are authoritative and read-only. You can still change their menu-bar visibility and alerts.

### How do I reorder holdings?

Use the arrows on each row in Edit mode. The read-only table and menu bar follow that order until you sort by a column.

## Data and updates

### How often do prices update?

At your **Main Refresh Interval** (Settings → Refresh; default 5 minutes). Press ⌘R or the refresh button at the bottom of the sidebar to request an immediate update; prices fetched very recently may be reused.

### Why has a stock stopped updating?

Failing symbols are retried after 1, 2, 5 and then 10 minutes. After five consecutive failures the symbol is paused for an hour to avoid hammering providers and triggering rate limits. Open its menu-bar popover: an **Updates paused** notice appears with **Retry Now**. Also check the symbol is valid, you're online, and the Python packages are installed.

### What does "—" mean?

The value isn't available yet — no price, not enough history, or no current exchange rate for a conversion.

### Why is Risk or correlation empty?

They are computed from stored history. Correlation needs at least 20 trading days shared by two or more holdings. Leave Stockbar running and history accumulates.

## Currencies and UK stocks

### What does GBX mean?

Pence sterling: 100 GBX = £1. Many London prices are quoted in pence. Stockbar converts them to pounds once, when data arrives. When entering a cost, choose **GBX** if you type pence (`250`) or **GBP** if you type pounds (`2.50`).

### Which currencies can I display in?

USD, GBP, EUR, JPY, CAD and AUD (Settings → General → Preferred Currency). Holdings keep their own currencies and are converted for totals.

### How do exchange rates update?

Automatically, at most every five minutes, from exchangerate-api.com or from Folync if that route is enabled. Settings → General → Exchange Rates shows when rates were last obtained. A failed update doesn't reset that time.

## Menu bar

### My stock items disappeared.

Check Settings → Menu Bar → Menu Bar Visibility: stock items may be hidden, or set to appear only with an external display. Each holding's **Menu Bar** switch in Holdings controls its own item. macOS may also hide items when the menu bar is full.

### The portfolio total isn't in the menu bar.

It is usually there but hidden: a full menu bar, the notch or a menu-bar manager can push it out of sight. Open the manager's hidden section, or quit a few other menu-bar apps. Settings → Menu Bar → **Show portfolio total in the menu bar** must also be on.

### After an update, Folync says it is waiting for Keychain access.

macOS asks before a rebuilt or re-signed app reads its saved Keychain items. Until you answer, Stockbar can't read the Folync token or API keys, so Folync shows **Waiting for Keychain access**, exchange rates don't refresh and Allocation has no sector data. Choose **Always Allow** in the Keychain prompt; everything recovers within a minute. This happens once after every update, because each released build has a new signature. (The first update to a version that keeps all credentials in one Keychain item asks once more for each credential the version before had saved, to move it across.) Local builds signed with an Apple Development certificate keep that answer across rebuilds; ad-hoc-signed builds ask every time.

### Colours aren't showing.

Turn on **Color Coding** in Settings → General. Unchanged values are intentionally shown in the normal text colour.

### Can I customise the text?

Yes. Settings → Menu Bar → Display Mode → Custom, with the tokens listed in the [User Guide](UserGuide.md#the-menu-bar). The portfolio total's Day Gain format is set in Portfolio Menu Bar.

## Backups and troubleshooting

### How do backups work?

Stockbar makes one automatic backup per day while running. The Backups screen and Settings → Advanced → Backups offer Back Up Now, Restore from Backup and View Backups, and how long to keep them (30 days by default). Backups are plain JSON listing your holdings, so store them privately. Keychain credentials are not included. Command-line recovery is described in [Scripts/README.md](../Scripts/README.md).

### How do I move Stockbar to another Mac?

Use Settings → Advanced → Export & Import. Choose **Everything** to bring your portfolio and history as well as your settings and keys, or **Settings & Keys** for just those. The export is encrypted with a password you choose; keep both safe. On the new Mac, choose **Import…**, check what the file contains, and confirm. Stockbar then relaunches. Set up Stockbar's Python on the new Mac when asked.

### Where are the logs?

Diagnostics in the main window shows them; the file is `~/Library/Logs/com.stockbar/stockbar.log`. Credentials and API keys are redacted.

### How do I uninstall Stockbar?

Quit Stockbar, move it to the Trash, and optionally remove its data:

```bash
defaults delete com.stockbar
rm -rf ~/Library/Application\ Support/Stockbar ~/Library/Application\ Support/com.stockbar
rm -rf ~/Library/Caches/stockbar-cache ~/Library/Logs/com.stockbar
```

Before uninstalling, clear Trading 212 credentials and remove the market-data API keys from Settings → Connections. Other saved credentials, including any Folync token, can be removed in Keychain Access.

## Privacy and security

### Does Stockbar collect my data?

No. There is no account, telemetry or analytics. Holdings stay on your Mac.

### What network connections does it make?

- **Market data** through the Python script: Yahoo Finance (yfinance), plus FMP and Twelve Data if configured. Only ticker symbols (and your API key for FMP/Twelve Data) are sent.
- **Exchange rates** from exchangerate-api.com.
- **Trading 212** (read-only) and **your Folync instance**, only if you connect them.
- **Updates** from GitHub: a list of available versions about once a day, and the download when you install one. Nothing about you or your portfolio is sent.

Stockbar never places trades.
