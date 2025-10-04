# Stockbar v2.3.0 UI/UX Manual Testing Checklist

**Version**: 2.3.0 (Phase 1-4 Features)
**Date**: 2025-10-04
**Tester**: _________________
**Build**: _________________

---

## Pre-Testing Setup

- [ ] Clean install of Stockbar (delete app data if needed)
- [ ] Verify yfinance is installed: `pip3 show yfinance`
- [ ] Add test portfolio with diverse symbols (e.g., AAPL, MSFT, GOOGL, TSLA, JPM, JNJ, XOM, WMT)
- [ ] Ensure internet connection is active
- [ ] Note starting time: __________

---

## Phase 1A: Menu Bar Display Enhancements

### Display Modes Testing

**Test 1.1: Compact Mode** ⏱️ 2 min
- [ ] Open Preferences → Portfolio tab
- [ ] Find "Menu Bar Display" section
- [ ] Set Display Mode to **Compact**
- [ ] Set Change Format to **Percentage**
- [ ] **Expected**: Menu bar shows "SYMBOL +X.XX%"
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 1.2: Expanded Mode** ⏱️ 2 min
- [ ] Set Display Mode to **Expanded**
- [ ] Set Change Format to **Both**
- [ ] **Expected**: Menu bar shows "SYMBOL $XXX.XX +$X.XX (+X.XX%)"
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 1.3: Minimal Mode** ⏱️ 2 min
- [ ] Set Display Mode to **Minimal**
- [ ] Enable "Use Arrow Indicators"
- [ ] Set Arrow Style to **Simple**
- [ ] **Expected**: Menu bar shows "SYMBOL ▲" or "SYMBOL ▼"
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 1.4: Custom Template Mode** ⏱️ 3 min
- [ ] Set Display Mode to **Custom**
- [ ] Enter template: `{symbol}: {price} ({changePct})`
- [ ] **Expected**: Menu bar shows "AAPL: 175.23 (+2.51%)"
- [ ] Verify green checkmark appears (valid template)
- [ ] Try invalid template: `{invalid}`
- [ ] **Expected**: Orange warning appears
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

### Change Format Testing

**Test 1.5: Change Format Options** ⏱️ 2 min
- [ ] Set to Expanded mode
- [ ] Try Change Format: **Percentage** → shows "+2.51%"
- [ ] Try Change Format: **Dollar** → shows "+$4.29"
- [ ] Try Change Format: **Both** → shows "+$4.29 (2.51%)"
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

### Visual Options Testing

**Test 1.6: Decimal Places** ⏱️ 2 min
- [ ] Set Decimal Places to **0** → price rounds to whole number
- [ ] Set Decimal Places to **2** → shows XX.XX
- [ ] Set Decimal Places to **4** → shows XX.XXXX
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 1.7: Arrow Indicators** ⏱️ 2 min
- [ ] Enable "Use Arrow Indicators"
- [ ] Test Arrow Style: **Simple** (▲▼)
- [ ] Test Arrow Style: **Bold** (⬆⬇)
- [ ] Test Arrow Style: **Emoji** (🟢🔴)
- [ ] Toggle "Arrow Before Symbol" vs after
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 1.8: Color Coding** ⏱️ 2 min
- [ ] Enable "Show Color Coding"
- [ ] **Expected**: Positive changes = green, negative = red
- [ ] Disable color coding
- [ ] **Expected**: All text is default menu bar color
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 1.9: Currency Display** ⏱️ 2 min
- [ ] Enable "Show Currency"
- [ ] **Expected**: USD stocks show "$", GBP show "£"
- [ ] Disable "Show Currency"
- [ ] **Expected**: No currency symbols
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 1.10: Live Preview** ⏱️ 1 min
- [ ] Change any setting
- [ ] **Expected**: Preview updates instantly
- [ ] Preview shows sample data (AAPL $175.23 +2.51%)
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 1.11: Settings Persistence** ⏱️ 2 min
- [ ] Set custom configuration (Expanded, Both, 2 decimals, arrows)
- [ ] Quit Stockbar
- [ ] Relaunch Stockbar
- [ ] **Expected**: All settings preserved
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

---

## Phase 1B: OHLC Data Infrastructure

**Test 2.1: OHLC Data Collection** ⏱️ 5 min
- [ ] Wait for data refresh (15-minute interval)
- [ ] Check logs: `~/Library/Application Support/com.fhl43211.Stockbar/stockbar.log`
- [ ] **Expected**: See "📊 OHLC" log entries
- [ ] **Expected**: No "FETCH_FAILED" errors for OHLC
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 2.2: Core Data OHLC Storage** ⏱️ 3 min
- [ ] Open Charts tab
- [ ] Select Candlestick chart
- [ ] **Expected**: Data appears (confirms Core Data storage)
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

---

## Phase 2: Chart Enhancements

### Candlestick Charts

**Test 3.1: Candlestick Chart Display** ⏱️ 3 min
- [ ] Open Preferences → Charts tab
- [ ] Select a stock (e.g., AAPL)
- [ ] Choose **Candlestick** chart type
- [ ] **Expected**: Green candles (up days), red candles (down days)
- [ ] **Expected**: Wicks show high/low
- [ ] **Expected**: Volume bars below chart
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 3.2: Time Range Selection** ⏱️ 3 min
- [ ] Test each time range: 1D, 1W, 1M, 3M, 6M, 1Y
- [ ] **Expected**: Chart updates with appropriate data
- [ ] **Expected**: Fewer candles for 1D, more for 1Y
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 3.3: Hover Tooltips** ⏱️ 2 min
- [ ] Hover over a candlestick
- [ ] **Expected**: Tooltip shows Date, Open, High, Low, Close, Volume
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

### Technical Indicators

**Test 3.4: Moving Averages (SMA/EMA)** ⏱️ 3 min
- [ ] Enable SMA (20-period)
- [ ] **Expected**: Smooth line overlay on price chart
- [ ] Enable EMA (12-period)
- [ ] **Expected**: Second line, more responsive than SMA
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 3.5: RSI Indicator** ⏱️ 3 min
- [ ] Enable RSI (14-period)
- [ ] **Expected**: Separate panel below chart
- [ ] **Expected**: Oscillates between 0-100
- [ ] **Expected**: Overbought/oversold zones (70/30) marked
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 3.6: MACD Indicator** ⏱️ 3 min
- [ ] Enable MACD
- [ ] **Expected**: MACD line, Signal line, Histogram
- [ ] **Expected**: Bullish/bearish crossovers visible
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 3.7: Bollinger Bands** ⏱️ 3 min
- [ ] Enable Bollinger Bands (20-period, 2 std dev)
- [ ] **Expected**: Upper, middle, lower bands
- [ ] **Expected**: Bands widen during volatility
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

### Volume Analysis

**Test 3.8: Volume Chart** ⏱️ 2 min
- [ ] Select **Volume** chart type
- [ ] **Expected**: Bar chart with volume data
- [ ] **Expected**: Green bars (up days), red bars (down days)
- [ ] **Expected**: Average volume line overlay
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 3.9: Volume Profile** ⏱️ 2 min
- [ ] Check volume statistics panel
- [ ] **Expected**: Total volume, average, max values
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

---

## Phase 3: Risk Analytics

**Test 4.1: Risk Analytics Tab** ⏱️ 2 min
- [ ] Open Preferences → Risk tab
- [ ] **Expected**: Risk dashboard visible
- [ ] **Expected**: 8 metric cards displayed
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 4.2: Value at Risk (VaR)** ⏱️ 3 min
- [ ] Verify VaR 95% and VaR 99% cards
- [ ] **Expected**: VaR 99% > VaR 95%
- [ ] **Expected**: Values shown in dollars and percentage
- [ ] Select different time ranges (1M, 3M, 6M, 1Y, All)
- [ ] **Expected**: VaR values update
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 4.3: Sharpe & Sortino Ratios** ⏱️ 3 min
- [ ] Check Sharpe Ratio card
- [ ] **Expected**: Value between -3 to 3 (typical range)
- [ ] **Expected**: Color-coded interpretation (Exceptional/Good/Adequate/Poor)
- [ ] Check Sortino Ratio card
- [ ] **Expected**: Higher than Sharpe (focuses on downside)
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 4.4: Beta Calculation** ⏱️ 2 min
- [ ] Check Beta card
- [ ] **Expected**: Value around 0.5-1.5 for diversified portfolio
- [ ] **Expected**: Indicates market correlation
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 4.5: Maximum Drawdown** ⏱️ 3 min
- [ ] Check Max Drawdown card
- [ ] **Expected**: Shows largest peak-to-trough decline
- [ ] **Expected**: Duration in days
- [ ] Check Drawdown History table
- [ ] **Expected**: Top 5 worst drawdown periods
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 4.6: Volatility Metrics** ⏱️ 2 min
- [ ] Check Volatility card (annualized)
- [ ] Check Downside Deviation card
- [ ] **Expected**: Downside < Volatility (only negative returns)
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 4.7: VaR Visualization** ⏱️ 2 min
- [ ] Check VaR distribution section
- [ ] **Expected**: Side-by-side 95% vs 99% comparison
- [ ] **Expected**: Visual bars/charts
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 4.8: Risk-Adjusted Returns** ⏱️ 2 min
- [ ] Check Risk-Adjusted Returns section
- [ ] **Expected**: Detailed Sharpe/Sortino breakdown
- [ ] **Expected**: Explanations of metrics
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

---

## Phase 4: Portfolio Analytics

**Test 5.1: Analytics Tab** ⏱️ 2 min
- [ ] Open Preferences → Analytics tab
- [ ] **Expected**: Portfolio analytics dashboard visible
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 5.2: Sector Allocation Pie Chart** ⏱️ 3 min
- [ ] Check sector allocation pie chart
- [ ] **Expected**: Color-coded sectors (Technology, Financials, Healthcare, etc.)
- [ ] **Expected**: Percentage labels
- [ ] Click on sector slice
- [ ] **Expected**: Highlights related data
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 5.3: Sector Breakdown Table** ⏱️ 3 min
- [ ] Check sector breakdown table
- [ ] **Expected**: Lists all sectors with:
  - Total value
  - Percentage of portfolio
  - Day change ($)
  - Day change (%)
- [ ] **Expected**: Color-coded circle indicators matching pie chart
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 5.4: Diversification Analysis** ⏱️ 3 min
- [ ] Check diversification score (0-100)
- [ ] **Expected**: Score with color coding
  - 70-100: Green (Well diversified)
  - 50-69: Orange (Moderate)
  - 0-49: Red (Concentrated)
- [ ] Check concentration risk level
- [ ] **Expected**: Low/Medium/High with explanation
- [ ] Check recommendations list
- [ ] **Expected**: Actionable suggestions (if applicable)
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 5.5: Correlation Matrix** ⏱️ 3 min
- [ ] Check correlation summary
- [ ] **Expected**: Average correlation metric
- [ ] **Expected**: Effective N (independent positions)
- [ ] **Expected**: Diversification ratio
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 5.6: Correlation Insights** ⏱️ 3 min
- [ ] Check "Highest Correlated Pairs" section
- [ ] **Expected**: List of top 5 stock pairs with high correlation
- [ ] **Expected**: Red/orange indicators for risk
- [ ] Check "Lowest Correlated Pairs" section
- [ ] **Expected**: List of top 5 pairs with low/negative correlation
- [ ] **Expected**: Green indicators for diversification
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 5.7: Time Range Selection** ⏱️ 2 min
- [ ] Test time ranges: 1M, 3M, 6M, 1Y, All Time
- [ ] **Expected**: All analytics update accordingly
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 5.8: Empty State Handling** ⏱️ 2 min
- [ ] Remove all stocks except one
- [ ] **Expected**: Message "Add at least 2 stocks for correlation analysis"
- [ ] Add stocks back
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

---

## Performance Testing

**Test 6.1: CPU Usage** ⏱️ 5 min
- [ ] Run performance monitoring script:
  ```bash
  cd Scripts
  ./measure_performance.sh
  ```
- [ ] **Expected**: Average CPU < 5%
- [ ] **Actual**: _______ %
- [ ] ✅ Pass / ❌ Fail

**Test 6.2: Memory Footprint** ⏱️ 2 min
- [ ] Check Activity Monitor
- [ ] **Expected**: Memory < 200 MB
- [ ] **Actual**: _______ MB
- [ ] ✅ Pass / ❌ Fail

**Test 6.3: Chart Rendering Speed** ⏱️ 3 min
- [ ] Switch between chart types rapidly
- [ ] **Expected**: Charts render in <100ms (smooth, no lag)
- [ ] **Subjective**: Feels responsive? Yes / No
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 6.4: Menu Bar Update Latency** ⏱️ 2 min
- [ ] Trigger manual refresh
- [ ] **Expected**: Menu bar updates within 50ms
- [ ] **Subjective**: Updates feel instant? Yes / No
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 6.5: App Startup Time** ⏱️ 2 min
- [ ] Quit and relaunch app
- [ ] Measure time to full functionality
- [ ] **Expected**: < 3 seconds
- [ ] **Actual**: _______ seconds
- [ ] ✅ Pass / ❌ Fail

**Test 6.6: Data Refresh Performance** ⏱️ 5 min
- [ ] Add 10+ stocks to portfolio
- [ ] Wait for 15-minute refresh cycle
- [ ] **Expected**: No UI freezing during refresh
- [ ] **Expected**: Background operation, app stays responsive
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

---

## Integration & Edge Cases

**Test 7.1: Multiple Stocks** ⏱️ 3 min
- [ ] Add 15+ diverse stocks
- [ ] **Expected**: All features work correctly
- [ ] **Expected**: No performance degradation
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 7.2: Network Interruption** ⏱️ 3 min
- [ ] Disable internet
- [ ] Wait for refresh cycle
- [ ] **Expected**: Graceful error handling
- [ ] **Expected**: Last successful data still displayed
- [ ] Re-enable internet
- [ ] **Expected**: Automatic recovery
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 7.3: Invalid Stock Symbol** ⏱️ 2 min
- [ ] Add invalid symbol (e.g., "INVALID123")
- [ ] **Expected**: Shows "N/A" or error message
- [ ] **Expected**: Doesn't crash app
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 7.4: UK Stock Handling** ⏱️ 3 min
- [ ] Add UK stock (e.g., "VOD.L")
- [ ] **Expected**: Prices in GBP (£)
- [ ] **Expected**: GBX to GBP conversion applied
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 7.5: Currency Conversion** ⏱️ 2 min
- [ ] Set preferred currency to GBP
- [ ] **Expected**: All values converted correctly
- [ ] Click "Refresh Exchange Rates"
- [ ] **Expected**: Rates update successfully
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 7.6: Settings Boundary Values** ⏱️ 3 min
- [ ] Test extreme decimal places (0 and 4)
- [ ] Test very long custom template
- [ ] **Expected**: Handles gracefully, no crashes
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

---

## Regression Testing (Existing Features)

**Test 8.1: Basic Portfolio Management** ⏱️ 3 min
- [ ] Add new stock
- [ ] Remove stock
- [ ] Reorder stocks (drag & drop)
- [ ] **Expected**: All work as before
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 8.2: Price Alerts** ⏱️ 2 min
- [ ] Test existing price alert functionality
- [ ] **Expected**: Alerts still work
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 8.3: Historical Performance Charts** ⏱️ 2 min
- [ ] Check original performance charts (Phase 0)
- [ ] **Expected**: Still functional
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

---

## User Experience

**Test 9.1: UI Consistency** ⏱️ 3 min
- [ ] Check all tabs for consistent spacing
- [ ] Check font sizes and styles
- [ ] **Expected**: Professional, polished appearance
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 9.2: Error Messages** ⏱️ 2 min
- [ ] Trigger various errors (network, invalid data)
- [ ] **Expected**: Clear, helpful error messages
- [ ] **Expected**: No technical jargon
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 9.3: Loading States** ⏱️ 2 min
- [ ] Observe loading indicators during data fetch
- [ ] **Expected**: Spinner or progress indicator
- [ ] **Expected**: No frozen UI
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

**Test 9.4: Empty States** ⏱️ 2 min
- [ ] Remove all stocks
- [ ] **Expected**: Helpful message "Add stocks to get started"
- [ ] **Actual**: _________________
- [ ] ✅ Pass / ❌ Fail

---

## Final Checklist

- [ ] All Phase 1A tests passed (11/11)
- [ ] All Phase 1B tests passed (2/2)
- [ ] All Phase 2 tests passed (9/9)
- [ ] All Phase 3 tests passed (8/8)
- [ ] All Phase 4 tests passed (8/8)
- [ ] All Performance tests passed (6/6)
- [ ] All Integration tests passed (6/6)
- [ ] All Regression tests passed (3/3)
- [ ] All UX tests passed (4/4)

**Total Tests**: 57
**Passed**: _____ / 57
**Failed**: _____ / 57
**Pass Rate**: _____ %

---

## Issues Found

| # | Test | Severity | Description | Status |
|---|------|----------|-------------|--------|
| 1 |      |          |             |        |
| 2 |      |          |             |        |
| 3 |      |          |             |        |

**Severity Levels**: 🔴 Critical | 🟠 High | 🟡 Medium | 🟢 Low

---

## Notes

**Testing Duration**: _____ minutes
**Overall Assessment**: _________________

**Recommended Actions**:
- [ ] Fix critical issues
- [ ] Address high-priority issues
- [ ] Schedule follow-up testing

**Tester Signature**: _________________
**Date**: _________________
