# Stockbar FAQ (Frequently Asked Questions)

**Version:** 2.2.10
**Last Updated:** October 2025

---

## General Questions

### What is Stockbar?

Stockbar is a macOS menu bar application that tracks your stock portfolio in real-time. It displays current prices, gains/losses, and performance charts directly in your menu bar for quick access.

### Is Stockbar free?

[License/pricing information to be determined by project owner]

### What macOS version do I need?

**Minimum:** macOS 15.4 or later
**Recommended:** Latest macOS version for best performance

### Does Stockbar work offline?

**Partial functionality:**
- ✅ View last cached data (up to 1 hour old)
- ✅ Access historical charts
- ✅ View portfolio statistics
- ❌ Cannot fetch new real-time prices without internet

### Where is my data stored?

**All data is stored locally on your Mac:**
- Portfolio configuration: UserDefaults
- Historical data: Core Data database
- Cache: Temporary in-memory storage
- Logs: `~/Documents/stockbar.log`

**No cloud sync or external storage.** Your data never leaves your computer.

---

## Setup & Installation

### How do I install Stockbar?

1. Download Stockbar application
2. Move to Applications folder
3. Launch Stockbar
4. Install Python dependency: `pip3 install yfinance`
5. Grant necessary permissions if prompted
6. Configure first stock in Preferences

### Why do I see a Python dependency alert?

Stockbar uses Python's `yfinance` library to fetch stock data from Yahoo Finance.

**To fix:**
```bash
pip3 install yfinance
```

**Alternative (install all requirements):**
```bash
cd /path/to/Stockbar
pip3 install -r Stockbar/Resources/requirements.txt
```

This alert only appears once per installation.

### I don't have Python installed. What do I do?

**Install Python 3.8 or later:**

**Option 1 - Official Python:**
- Download from [python.org](https://www.python.org/downloads/)
- Install the package
- Verify: `python3 --version`

**Option 2 - Homebrew:**
```bash
# Install Homebrew first (if needed): https://brew.sh
brew install python3
```

**Then install yfinance:**
```bash
pip3 install yfinance
```

---

## Stock Management

### How do I add a stock?

1. Click Stockbar menu bar icon → **Preferences...**
2. Ensure **Portfolio** tab is selected
3. Click **+** (plus) button
4. Enter:
   - **Symbol:** Ticker symbol (e.g., `AAPL`)
   - **Units:** Number of shares owned
   - **Average Cost:** Price per share paid
   - **Currency:** Purchase currency
5. Click **Add**

### What stock symbols are supported?

**Stockbar supports all symbols available on Yahoo Finance:**

- **US Stocks:** `AAPL`, `GOOGL`, `MSFT`, `TSLA`
- **UK Stocks:** Add `.L` suffix - `VOD.L`, `BP.L`, `HSBA.L`
- **European Stocks:** Add exchange suffix - `BMW.DE` (Germany), `SAN.MC` (Spain)
- **Asian Stocks:** `SONY` (Japan), `BABA` (Alibaba)
- **Crypto:** `BTC-USD`, `ETH-USD` (via Yahoo Finance tickers)

**To verify a symbol:** Search on [finance.yahoo.com](https://finance.yahoo.com) and use the ticker shown.

### Can I track stocks I don't own?

**Yes! Use Watchlist Mode:**

1. Add stock with symbol only
2. Set **Units: 0** and **Average Cost: 0**
3. Stock appears in menu bar showing current price only
4. No gains/losses calculated

**Perfect for:**
- Stocks you're considering buying
- Market indices (e.g., `^GSPC` for S&P 500)
- Competitor tracking

### How do I remove a stock?

1. Open Preferences → Portfolio tab
2. Click the stock to select it
3. Click **-** (minus) button
4. Stock removed immediately

### Can I reorder my stocks?

**Yes, via drag-and-drop:**

1. Open Preferences → Portfolio tab
2. Click and hold a stock
3. Drag to desired position
4. Release to drop

**Menu bar items update automatically** to match your portfolio order.

---

## Data & Updates

### Why is my data not updating?

**Common causes and fixes:**

#### 1. Internet Connection
- **Check:** Ensure you're connected to the internet
- **Test:** Visit [finance.yahoo.com](https://finance.yahoo.com) in a browser

#### 2. Cache Issues
- **Solution:** Open Debug tab → **Clear All Caches** button
- **Or:** Restart Stockbar

#### 3. Rate Limiting
- **Cause:** Yahoo Finance temporarily limits requests
- **Solution:** Wait 5-10 minutes, Stockbar will retry automatically
- **Status:** Check Debug tab → Cache Inspector for "Suspended" symbols

#### 4. Invalid Symbol
- **Check:** Verify ticker on Yahoo Finance
- **Fix:** Remove and re-add with correct symbol

#### 5. Python Issues
- **Verify:** `python3 -c "import yfinance; print('OK')"`
- **Reinstall:** `pip3 install --upgrade yfinance`

#### 6. Market Closed
- **Note:** Some symbols don't update outside market hours
- **Solution:** Wait for market open (check exchange hours)

**Force refresh:**
- Preferences → **Refresh Exchange Rates** button
- Or quit and relaunch Stockbar

### How often does data update?

**Automatic Updates:**
- **During Market Hours:** Every 15 minutes
- **Stale Cache:** 15-60 minutes triggers refresh
- **Expired Cache:** > 1 hour forces refresh

**Manual Updates:**
- Click **Refresh Exchange Rates** button
- Quit and relaunch app

**Historical Snapshots:**
- Recorded every 5 minutes
- Triggered after successful price updates

### What does "N/A" mean?

**"N/A" indicates data unavailable for this symbol:**

**Possible reasons:**
1. **Invalid symbol** - doesn't exist on Yahoo Finance
2. **Delisted stock** - no longer trading
3. **API failure** - temporary Yahoo Finance issue
4. **Market closed** - symbol has no pre/post-market data
5. **Suspended symbol** - too many consecutive fetch failures

**How to fix:**
- Verify symbol on [finance.yahoo.com](https://finance.yahoo.com)
- Check Debug → Cache Inspector for error details
- Click **Retry Now** for suspended symbols
- Remove and re-add stock if problem persists

### Why do I see old timestamps?

**Data may be cached:**

- **Fresh:** < 15 minutes old (normal)
- **Stale:** 15-60 minutes old (acceptable)
- **Expired:** > 1 hour old (problem)

**If timestamps are very old:**
1. Check internet connection
2. Clear caches (Debug tab)
3. Check for suspended symbols
4. Verify Python/yfinance working: `python3 -c "import yfinance; print('OK')"`

---

## Currency & International Stocks

### What does GBX mean?

**GBX = Pence Sterling (UK currency unit)**

- **1 GBX = 1 pence**
- **100 GBX = 100 pence = £1.00 GBP**

**Why it matters:**
- UK stocks on London Stock Exchange trade in **pence**, not pounds
- Stock price of "150 GBX" means 150 pence = £1.50
- Stockbar automatically converts GBX → GBP for display

**Example - Vodafone (VOD.L):**
- API returns: 75.50 GBX (75.5 pence)
- Stockbar displays: £0.755 GBP
- Enter average cost: `75.5` (pence) → shown as £0.755

### How do I add UK stocks?

**UK stocks require `.L` suffix:**

1. Add stock with symbol ending in `.L` (e.g., `VOD.L` for Vodafone)
2. Enter **units** normally
3. Enter **average cost in pence** (not pounds):
   - If you paid £2.50 per share → enter `250` (250 pence)
4. Select **GBP** currency (not GBX)

**Stockbar automatically handles GBX → GBP conversion.**

### What currencies are supported?

**Six major currencies:**

- **USD** - US Dollar (default)
- **GBP** - British Pound
- **EUR** - Euro
- **JPY** - Japanese Yen
- **CAD** - Canadian Dollar
- **AUD** - Australian Dollar

### Can I mix currencies in one portfolio?

**Yes! Stockbar automatically converts:**

1. Each stock tracks its original purchase currency
2. Display values convert to your **Preferred Currency** (set in Portfolio tab)
3. Exchange rates refresh automatically
4. Manual refresh available: **Refresh Exchange Rates** button

**Example:**
- Preferred Currency: **USD**
- Stock 1: Apple (USD) - shows in USD
- Stock 2: Vodafone (GBP) - converts to USD for display
- Total portfolio: Combined value in USD

### How do exchange rates update?

**Automatic updates:**
- Exchange rates fetch from exchangerate-api.com
- **Cooldown:** 5 minutes minimum between refreshes
- **Manual refresh:** Click **Refresh Exchange Rates** button

**Fallback rates:**
If API fails, uses hardcoded fallback rates:
- USD: 1.0 (base)
- GBP: 0.79
- EUR: 0.92
- JPY: 149.50
- CAD: 1.36
- AUD: 1.53

**Check last update:** Portfolio tab shows timestamp.

---

## Performance & Charts

### Why don't I see chart data?

**Charts require historical data:**

- **Just installed?** No historical data yet
- **Solution:** Wait for data to collect (5-minute snapshots)
- **Timeframe:** After a few hours, you'll see 1D chart
- **Long-term:** Charts fill in over days/weeks

**Retroactive backfill:** Stockbar attempts to fill historical gaps when possible.

### How far back does historical data go?

**Depends on usage:**

- **New installation:** Only forward from install date
- **Active use:** Data collected every 5 minutes during market hours
- **Maximum:** "All Time" shows all collected data
- **Retroactive:** Stockbar attempts to backfill when portfolio changes

**Limits:**
- Maximum 1000 data points per symbol
- Automatic cleanup of very old data

### What does "volatility" mean?

**Volatility = Price movement magnitude**

- **High volatility:** Large price swings (riskier)
- **Low volatility:** Stable prices (less risky)
- **Calculation:** Standard deviation of daily returns

**Example:**
- Stock A: ±1% daily = Low volatility
- Stock B: ±10% daily = High volatility

### Why is chart data compressed?

**For performance:**

- Charts intelligently downsample data for time ranges
- **1 Day:** Every data point shown
- **1 Month:** Daily aggregation
- **1 Year:** Weekly aggregation
- **All Time:** Monthly aggregation

**Benefits:**
- Faster chart rendering
- Lower memory usage
- Cleaner visualization

---

## Troubleshooting

### Stockbar is using too much CPU

**Normal CPU usage: < 5%**

**If CPU is high:**

1. **Check active stocks:** Debug tab shows count
2. **Reduce portfolio:** Limit to < 20 stocks
3. **Clear caches:** May have stale data causing retries
4. **Check for loops:** Restart Stockbar
5. **Update yfinance:** `pip3 install --upgrade yfinance`

**Temporary spike during refresh is normal** (15-30 seconds).

### Stockbar is using too much memory

**Normal memory: 50-100 MB**

**If memory is high (> 200 MB):**

1. **Clear chart cache:** Debug tab → Advanced Tools
2. **Reduce portfolio size:** Fewer stocks = less memory
3. **Restart app:** Fresh start clears accumulated data
4. **Check for leaks:** Report if persists after restart

### Menu bar items disappeared

**Possible causes:**

1. **No stocks in portfolio** - add stocks via Preferences
2. **All stocks failed to load** - check internet/Python
3. **macOS menu bar limit** - too many other menu bar apps
   - Remove some menu bar items
   - Reduce number of stocks in Stockbar

**To restore:**
- Open Preferences → verify stocks are listed
- Click **Refresh Exchange Rates**
- Restart Stockbar

### Colors not showing in menu bar

**Enable color coding:**

1. Open Preferences → Portfolio tab
2. Find **"Enable color coding"** toggle
3. Turn **ON**
4. Gains show green, losses show red

**Note:** Some macOS themes may override colors.

### Data backup failed

**Common issues:**

1. **Permission denied** - choose a folder you own (Documents, Desktop)
2. **File already exists** - delete old backup or choose new name
3. **Disk full** - free up space

**Backup location tips:**
- Use `/Users/[YourName]/Documents/StockbarBackups/`
- Create folder first
- Use descriptive names: `stockbar-backup-2025-10-01.json`

### Restore from backup failed

**Common issues:**

1. **Invalid file format** - ensure it's a `.json` file from Stockbar
2. **Corrupted backup** - try an older backup file
3. **Wrong version** - backup from much older Stockbar version may not work

**Safe restore process:**
1. **First backup current portfolio** (in case restore fails)
2. Select backup file
3. Confirm restoration
4. Verify stocks loaded correctly

---

## Advanced Usage

### What is the Cache Inspector?

**Debug tool showing cache status per symbol:**

**Cache States:**
- **Fresh** (green) - Data < 15 minutes old
- **Stale** (orange) - Data 15-60 minutes old
- **Expired** (red) - Data > 1 hour old
- **Failed Recently** (orange) - Recent fetch error, will retry
- **Suspended** (red) - Too many failures (circuit breaker)

**Actions:**
- **Clear All Caches** - Force refresh everything
- **Retry Now** - Resume specific suspended symbol

### What is the circuit breaker?

**Automatic failure protection:**

- After **5 consecutive failures** for a symbol
- Symbol becomes **suspended** for 1 hour
- Prevents hammering Yahoo Finance API with failing requests
- Protects against rate limiting

**How to recover:**
- Wait 1 hour (automatic)
- Or click **Retry Now** in Cache Inspector
- Or click **Clear All Caches**

**Common causes of suspension:**
- Invalid symbol
- Delisted stock
- API rate limiting
- Network issues

### What's in the debug report?

**Export Debug Report** creates a `.txt` file containing:

- App version and system info
- Current configuration (number of stocks, currency, etc.)
- Cache statistics (fresh/stale/expired counts)
- Performance metrics (CPU, memory)
- Portfolio data (symbols, prices, values)
- Last 50 log entries

**Use for:**
- Troubleshooting issues
- Bug reports on GitHub
- Performance analysis

**Privacy:** Review before sharing - contains portfolio details.

### Can I run Stockbar at startup?

**Yes, using macOS System Settings:**

1. **System Settings** → **General** → **Login Items**
2. Click **+** button
3. Select Stockbar from Applications
4. Ensure checkbox is enabled

**Stockbar will launch automatically when you log in.**

### How do I uninstall Stockbar?

**Complete removal:**

1. Quit Stockbar (⌘Q)
2. Move Stockbar.app to Trash (from Applications)
3. Delete data (optional):
   ```bash
   rm ~/Documents/stockbar.log
   defaults delete com.fhl43211.Stockbar
   ```
4. Remove Python dependency (optional):
   ```bash
   pip3 uninstall yfinance
   ```

**Note:** Portfolio data is deleted when you remove UserDefaults/Core Data.

---

## Privacy & Security

### Does Stockbar collect my data?

**No. Stockbar is privacy-focused:**

- ✅ All data stored locally on your Mac
- ✅ No telemetry or analytics
- ✅ No account required
- ✅ No data sent to external servers (except Yahoo Finance API for prices)

**What data is accessed:**
- **Yahoo Finance API:** Fetches public stock prices only
- **Exchange Rate API:** Fetches public currency rates only

**Your portfolio details never leave your computer.**

### Is my portfolio data secure?

**Local storage only:**

- Portfolio configuration: macOS UserDefaults (system-protected)
- Historical data: Core Data database (local SQLite file)
- No encryption (since all data is public market data)

**Backup security:**
- Backup files are **plain JSON text**
- Store backups securely (they contain your holdings)
- Don't share backups publicly (reveals your portfolio)

**No financial transactions:**
- Stockbar is read-only for market data
- No buy/sell functionality
- No brokerage integration

### What network connections does Stockbar make?

**Only two external APIs:**

1. **Yahoo Finance (via yfinance Python library)**
   - Purpose: Fetch stock prices
   - Frequency: Every 15 minutes (during market hours)
   - Data sent: Stock symbols only
   - Data received: Public market prices

2. **exchangerate-api.com**
   - Purpose: Currency exchange rates
   - Frequency: On-demand (manual or automatic every 5+ minutes)
   - Data sent: None (uses free endpoint)
   - Data received: Public exchange rates

**No other connections. No analytics. No tracking.**

---

## Contact & Support

### Where can I get help?

1. **This FAQ** - Check this document first
2. **User Guide** - See `Docs/UserGuide.md` for detailed instructions
3. **Debug Logs** - Check `~/Documents/stockbar.log` for errors
4. **GitHub Issues** - Report bugs or request features
5. **Debug Report** - Export and analyze for troubleshooting

### How do I report a bug?

**Before reporting:**

1. Check this FAQ and User Guide
2. Verify Python/yfinance installed: `pip3 list | grep yfinance`
3. Review debug logs: `~/Documents/stockbar.log`
4. Export debug report

**When reporting:**

1. Visit GitHub repository
2. Create new issue
3. Include:
   - Stockbar version (see About in menu)
   - macOS version
   - Steps to reproduce
   - Expected vs actual behavior
   - Debug report (if relevant)
   - Screenshots (if UI issue)

### How do I request a feature?

**Feature requests welcome on GitHub:**

1. Check existing issues/requests first
2. Create new issue with "Feature Request" label
3. Describe:
   - Use case / problem to solve
   - Proposed solution
   - Why it would benefit users
   - Any implementation ideas

### Is Stockbar open source?

[To be determined by project owner - update with license info]

---

## Version History

### v2.2.10 (Current)
- Added comprehensive unit test coverage
- Improved debug tools (Cache Inspector, Advanced Tools)
- Dark mode refinements
- Core Data performance optimizations
- Python dependency management
- Enhanced documentation

### v2.2.9
- Reliability & memory efficiency improvements
- Enhanced caching system
- Performance optimizations

### v2.2.8
- Enhanced menu bar charts
- Interactive features

### v2.2.7
- Performance optimizations
- Enhanced charts
- Robust data migration

For complete version history, see release notes in repository.

---

## Glossary

**Terms used in Stockbar:**

- **Average Cost:** Price per share you paid when purchasing
- **Cache:** Temporary stored data to reduce API requests
- **Circuit Breaker:** Automatic pause after repeated failures
- **Current Price:** Latest market price for stock
- **Day Change:** Price movement since previous close
- **Exchange Rate:** Conversion rate between currencies
- **Fresh Data:** Recently fetched (< 15 minutes old)
- **GBX:** Pence Sterling (UK currency, 1/100 of GBP)
- **Market Value:** Total current value of position (price × units)
- **Previous Close:** Stock price at end of previous trading day
- **Stale Data:** Older cached data (15-60 minutes)
- **Suspended Symbol:** Symbol paused due to failures
- **Symbol/Ticker:** Unique stock identifier (e.g., AAPL)
- **Total Gains:** Overall profit/loss (current value - cost basis)
- **Units:** Number of shares owned
- **Volatility:** Measure of price fluctuation magnitude
- **Watchlist:** Tracking stocks without ownership data

---

*Last updated: October 2025*
*For latest version, see `Docs/FAQ.md` in repository*
