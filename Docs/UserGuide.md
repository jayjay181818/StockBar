# Stockbar User Guide

**Version:** 2.2.10
**Last Updated:** October 2025

---

## Table of Contents

1. [Getting Started](#getting-started)
2. [Adding Your First Stock](#adding-your-first-stock)
3. [Understanding the Menu Bar Display](#understanding-the-menu-bar-display)
4. [Managing Your Portfolio](#managing-your-portfolio)
5. [Performance Charts](#performance-charts)
6. [Currency Settings](#currency-settings)
7. [Advanced Features](#advanced-features)
8. [Troubleshooting](#troubleshooting)

---

## Getting Started

### System Requirements

- macOS 15.4 or later
- Python 3.8+ installed
- Internet connection for real-time stock data

### First Launch Setup

When you launch Stockbar for the first time:

1. **Python Dependency Check:** Stockbar will automatically verify that the required Python package (`yfinance`) is installed
2. **If Missing:** You'll see an alert with installation instructions:
   ```bash
   pip3 install yfinance
   ```
3. **Menu Bar Icon:** Stockbar appears in your menu bar (look for the stock icon)
4. **Access Preferences:** Click the menu bar icon → "Preferences..." to begin setup

---

## Adding Your First Stock

1. **Open Preferences:** Click the Stockbar icon → "Preferences..."
2. **Click the "+" Button:** Located in the Portfolio tab
3. **Enter Stock Information:**
   - **Symbol:** Stock ticker symbol (e.g., `AAPL`, `GOOGL`, `MSFT`)
     - For UK stocks: Add `.L` suffix (e.g., `VOD.L` for Vodafone)
     - For other exchanges: Use Yahoo Finance ticker format
   - **Units:** Number of shares you own
   - **Average Cost:** Price per share you paid
   - **Currency:** Select the currency you purchased in (USD, GBP, EUR, JPY, CAD, AUD)
4. **Click "Add":** Stock will appear in your portfolio list
5. **Data Updates:** Stockbar fetches real-time price data automatically

### Example: Adding Apple Stock

- Symbol: `AAPL`
- Units: `10`
- Average Cost: `150.00`
- Currency: `USD`

This tracks 10 shares of Apple purchased at $150 per share.

---

## Understanding the Menu Bar Display

### Menu Bar Items

Each stock in your portfolio appears as a separate menu bar item showing:

```
AAPL: $1,700.00 (+$200.00)
```

**Format:** `SYMBOL: Current Value (Day Gain/Loss)`

- **Current Value:** Current total value of this position (price × units)
- **Day Gain/Loss:** Change in value since previous market close
- **Color Coding:** (if enabled in preferences)
  - 🟢 **Green:** Positive gains
  - 🔴 **Red:** Negative losses

### Dropdown Menu Details

Click any stock item to see detailed information:

- **Current Price:** Latest market price
- **Previous Close:** Yesterday's closing price
- **Market Value:** Total position value (price × units)
- **Total Gains:** Overall profit/loss since purchase (current value - cost basis)
- **Day Change:** Today's price movement ($ and %)
- **Last Updated:** Timestamp of last price update

---

## Managing Your Portfolio

### Editing Stock Positions

1. Click stock in portfolio list
2. Modify units, average cost, or currency
3. Changes save automatically

### Removing Stocks

1. Select stock in portfolio list
2. Click "-" (minus) button
3. Confirm removal

### Reordering Stocks

- **Drag and Drop:** Click and drag stocks to reorder them
- **Menu Bar Order:** Menu bar items match portfolio order

### Watchlist Mode

For stocks you want to track without ownership data:

1. Add stock with symbol only
2. Leave units/cost empty or set to zero
3. Stock appears in menu bar showing only current price

---

## Performance Charts

### Accessing Charts

1. Open Preferences → **Charts** tab
2. Select chart type:
   - **Portfolio Value:** Total portfolio value over time
   - **Portfolio Gains:** Net profit/loss tracking
   - **Individual Stock:** Price history for specific stock

### Time Range Selection

Choose from preset ranges:
- **1 Day:** Intraday performance
- **1 Week, 1 Month, 3 Months, 6 Months:** Recent trends
- **1 Year:** Annual performance
- **All Time:** Complete historical data

### Performance Metrics

Charts display:
- **Total Return:** Absolute gain/loss amount and percentage
- **Value Range:** Min/max portfolio values for period
- **Volatility:** Risk measure (higher = more price swings)

### Data Collection

- Stockbar automatically records price snapshots every 5 minutes
- Historical data builds over time as you use the app
- Retroactive backfill captures past performance when possible

---

## Currency Settings

### Setting Preferred Currency

1. Open Preferences → **Portfolio** tab
2. Use **Currency** dropdown
3. Select: USD, GBP, EUR, JPY, CAD, AUD
4. All values convert to your preferred currency

### Multi-Currency Portfolios

**Stockbar automatically handles mixed currencies:**

- Each stock tracks its original purchase currency
- Display values convert to your preferred currency
- Exchange rates refresh via API
- Manual refresh: Click **Refresh Exchange Rates** button

### UK Stocks (GBX → GBP)

**Important:** UK stocks on London Stock Exchange trade in **pence (GBX)**, not pounds.

**Stockbar automatically converts:**
- When you add a UK stock (symbol ending in `.L`)
- Price data from API comes in pence (GBX)
- Display shows values in pounds (GBP)
- Average cost should be entered in **pence** (e.g., `150` for 150p)

**Example:**
- Symbol: `VOD.L` (Vodafone)
- Price from API: 150 GBX (150 pence)
- Displayed as: £1.50 GBP
- Enter average cost: `150` (pence), shown as £1.50

---

## Advanced Features

### Debug Tools

Access via Preferences → **Debug** tab:

#### Performance Monitoring
- **CPU Usage:** Real-time processor utilization
- **Memory Usage:** App memory footprint
- **Network Efficiency:** Data transfer metrics
- **Active Stocks:** Number of tracked symbols

#### Cache Inspector
- View cache status for each stock:
  - **Fresh:** Recent data (< 15 minutes old)
  - **Stale:** Older data (15min - 1 hour)
  - **Expired:** Very old data (> 1 hour)
  - **Suspended:** Symbol temporarily paused after failures
- **Clear Caches:** Force refresh all data
- **Retry Now:** Resume suspended symbols

#### Advanced Tools
- **Export Debug Report:** Generate diagnostic file
- **Simulate Market Closed:** Test mode for development

### Data Management

#### Backup Portfolio
1. Debug tab → **Backup Portfolio** button
2. Choose save location
3. Creates `.json` backup file

#### Restore Portfolio
1. Debug tab → **Restore from Backup** button
2. Select backup file
3. Confirm restoration (overwrites current portfolio)

### Appearance Settings

**Choose display mode:**
- **System:** Follow macOS appearance
- **Light:** Always use light mode
- **Dark:** Always use dark mode

**Color Coding:**
- Toggle in Portfolio tab
- Shows green/red for gains/losses

---

## Troubleshooting

### Data Not Updating?

**Check these common issues:**

1. **Internet Connection:** Verify you're online
2. **Cache Status:**
   - Open Debug tab → Cache Inspector
   - Look for "Suspended" stocks
   - Click "Retry Now" or "Clear All Caches"
3. **Symbol Validity:**
   - Verify ticker symbol is correct (use Yahoo Finance format)
   - UK stocks need `.L` suffix
4. **Python Dependencies:**
   - Ensure `yfinance` is installed
   - Run: `pip3 install --upgrade yfinance`
5. **Rate Limiting:**
   - Yahoo Finance may temporarily limit requests
   - Wait 5-10 minutes and try again
   - Stockbar automatically backs off on errors

**Force Manual Refresh:**
- Preferences → Portfolio tab
- Click **Refresh Exchange Rates** (also triggers price refresh)
- Or quit and relaunch Stockbar

### Symbol Shows "N/A"?

**Possible causes:**

1. **Invalid Symbol:** Double-check ticker on Yahoo Finance
2. **Delisted Stock:** Stock may no longer trade
3. **Market Closed:** Some symbols don't provide pre/post-market data
4. **Exchange Issues:** Data source temporarily unavailable

**Resolution:**
- Verify symbol on [finance.yahoo.com](https://finance.yahoo.com)
- Try removing and re-adding the stock
- Check Debug tab for error details

### What Does GBX Mean?

**GBX = Pence Sterling (UK Currency)**

- UK stocks trade in **pence**, not pounds
- 100 pence = 1 pound (£1.00)
- Stockbar automatically converts GBX → GBP for display
- Always enter UK stock costs in **pence**

**Example:**
- Stock price: 250 GBX = £2.50 GBP
- You bought 100 shares at 250 pence each
- Enter average cost: `250` (automatically converts to £2.50)

### Performance Issues?

**If Stockbar feels slow:**

1. **Reduce Portfolio Size:** Limit to < 20 stocks for best performance
2. **Clear Old Data:**
   - Debug tab → Advanced Tools
   - Export then clear old cache entries
3. **Check Memory Usage:**
   - Debug tab shows current memory
   - Normal: < 100 MB
   - High: > 200 MB (consider fewer stocks)

### Exchange Rates Not Updating?

**Currency conversion issues:**

1. **Manual Refresh:** Portfolio tab → **Refresh Exchange Rates**
2. **Check Last Update:** Shows timestamp of last rate fetch
3. **Fallback Rates:** If API fails, uses hardcoded fallback rates:
   - USD: 1.0 (base)
   - GBP: 0.79
   - EUR: 0.92
   - JPY: 149.50
   - CAD: 1.36
   - AUD: 1.53
4. **Wait and Retry:** API has 5-minute cooldown between refreshes

### Python Installation Issues?

**If yfinance alert appears:**

```bash
# Install yfinance
pip3 install yfinance

# Or install all requirements
cd /path/to/Stockbar
pip3 install -r Stockbar/Resources/requirements.txt
```

**Verify installation:**
```bash
python3 -c "import yfinance; print('OK')"
```

**Python not found?**
- Install Python 3.8+ from [python.org](https://www.python.org/downloads/)
- Or use Homebrew: `brew install python3`

---

## Tips & Best Practices

### Data Accuracy
- **Market Hours:** Most accurate during exchange trading hours
- **Delayed Data:** Free API may have 15-minute delay
- **Pre/Post Market:** Limited availability depending on exchange

### Portfolio Tracking
- **Regular Updates:** Stockbar refreshes every 15 minutes during market hours
- **Manual Refresh:** Available via preferences if needed
- **Historical Data:** Builds automatically over time

### Privacy & Security
- **Local Storage:** All data stored locally on your Mac
- **No Account:** No sign-up or personal information required
- **Data Control:** Full ownership of portfolio data via backup/restore

### Performance Optimization
- **Limit Symbols:** Keep portfolio under 20 stocks
- **Clear Caches:** Periodically clear old cache data
- **Monitor Debug:** Watch CPU/memory usage in Debug tab

---

## Keyboard Shortcuts

- **⌘,** (Command-Comma): Open Preferences
- **⌘Q** (Command-Q): Quit Stockbar
- **⌘W** (Command-W): Close Preferences window

---

## Getting Help

### Resources

- **GitHub Issues:** Report bugs or request features
- **FAQ:** See `Docs/FAQ.md` for common questions
- **Logs:** Check `~/Documents/stockbar.log` for errors

### Support

If you encounter issues not covered in this guide:

1. Check the FAQ document
2. Review Debug tab for error messages
3. Export debug report for analysis
4. Check GitHub repository for similar issues

---

## About Stockbar

**Stockbar** is a macOS menu bar application for tracking stock portfolios in real-time.

**Key Features:**
- ✅ Real-time price tracking
- ✅ Multi-currency support (6 currencies)
- ✅ Historical performance charts
- ✅ Automatic data caching
- ✅ Lightweight and efficient
- ✅ Privacy-focused (local data only)

**Technology:**
- Swift 6.0 (macOS native)
- Python 3 (yfinance backend)
- Core Data (persistence)
- Swift Charts (visualization)

**Version:** 2.2.10
**License:** [License Type]
**Created by:** [Author Name]

---

*Last updated: October 2025*
