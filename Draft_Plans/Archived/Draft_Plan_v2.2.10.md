# Stockbar v2.2.10 Development Plan

**Date**: 2025-09-30
**Version**: 2.2.10
**Status**: Draft - Pending Approval

## Overview

This document outlines the planned improvements for Stockbar v2.2.10 based on a comprehensive codebase review. The focus is on code quality, UI enhancements, performance optimizations, and data reliability improvements.

---

## 1. Code Cleanup & Architecture

### 1.1 Remove Legacy/Unused Files ✅ **High Priority**

**Files to Remove:**
- `Stockbar/SymbolMenu.swift` - Legacy menu creation (confirmed unused)
- `Stockbar/ContentView.swift` - Default SwiftUI view (not used in menu bar app)
- `Stockbar/Models/StockData.swift` - Legacy calculated data model (confirmed unused)

**Verification Status:**
- ✅ SymbolMenu: No imports or instantiations found
- ✅ ContentView: Only used in own preview
- ✅ StockData: No instantiations found (method names coincidentally similar to other code)

**Benefits:**
- Reduces codebase size
- Eliminates confusion about what code is active
- Faster compilation times

**Implementation:**
1. Remove files from Xcode project
2. Verify build succeeds
3. Run tests to ensure no dependencies
4. Update CLAUDE.md to remove references

---

### 1.2 Reduce DataModel.swift Complexity ⚠️ **High Priority, High Effort**

**Current Issue:**
- `DataModel.swift` is 1,645 lines with too many responsibilities
- Handles: network refresh, caching, backfill, portfolio calculations, imports/exports, memory management

**Solution: Extract Specialized Services**

#### Create New Files:

**`Services/PortfolioCalculationService.swift`**
```swift
// Extract from DataModel.swift:
- calculateNetGains()
- calculateNetValue()
- calculatePortfolioMetricsEfficiently()
```

**`Services/HistoricalDataCoordinator.swift`**
```swift
// Extract from DataModel.swift:
- checkAndBackfillHistoricalData()
- checkAndBackfill5YearHistoricalData()
- staggeredBackfillHistoricalData()
- backfillHistoricalData()
- backfillHistoricalDataForSymbol()
- fetchHistoricalDataChunk()
- addHistoricalSnapshots()
- triggerFullHistoricalBackfill()
- calculate5YearPortfolioValues()
- checkAndCalculatePortfolioValues()
```

**`Services/RefreshCacheService.swift`**
```swift
// Extract from DataModel.swift:
- Cache timing properties (lastSuccessfulFetch, lastFailedFetch)
- setSuccessfulFetch(), setFailedFetch()
- getLastSuccessfulFetch(), getLastFailedFetch()
- Cache interval logic
```

**Benefits:**
- Each service has single responsibility
- Easier to test individual components
- Faster compilation (smaller files)
- Better code organization
- Easier onboarding for new developers

**Implementation Steps:**
1. Create new service files
2. Move methods incrementally (one service at a time)
3. Update DataModel to use new services as dependencies
4. Maintain existing public API for backward compatibility
5. Update tests to cover new services
6. Document new architecture in CLAUDE.md

**Estimated Effort:** 8-12 hours (careful refactoring required)

---

### 1.3 Consolidate Network Service ⚙️ **Medium Priority**

**Current Issue:**
- `NetworkService` protocol exists but only `PythonNetworkService` is used
- Creates unnecessary abstraction layer

**Options:**

**Option A: Remove Protocol (Simpler)**
- Remove `NetworkService` protocol
- Use `PythonNetworkService` directly in DataModel
- Benefits: Simpler code, one less layer

**Option B: Implement FMP Fallback**
- Keep protocol
- Implement `FMPNetworkService` as backup when yfinance fails
- Benefits: Redundancy, but more complex

**Recommendation:** Option A (remove protocol) unless you plan to support multiple data sources

**Implementation:**
1. Update DataModel to import PythonNetworkService directly
2. Remove NetworkService protocol file
3. Update any references
4. Test thoroughly

---

## 2. UI/UX Enhancements

### 2.1 Enhanced Menu Bar Visualization 🎨 **High Priority**

**Feature: Mini Sparkline Charts in Dropdown Menus**

Add small trend visualizations showing recent price movement for each stock.

**Mockup:**
```
┌─────────────────────────────────┐
│ AAPL - Apple Inc.              │
│ $175.23 (+$2.50 +1.45%)        │
│ ▁▂▃▄▅▆█▆▅ (7-day trend)        │
├─────────────────────────────────┤
│ Current Price: $175.23         │
│ Daily P&L: +$12.50             │
│ Total P&L: +$1,234.56          │
└─────────────────────────────────┘
```

**Implementation:**
- Use Swift Charts framework with `.chartStyle(.line)`
- Show last 7-14 data points from historical data
- Render as compact inline chart (height: 20-30pt)
- Add to `StockStatusItemController.updateMenu()`

**Files to Modify:**
- `Stockbar/StockStatusBar.swift` (add sparkline rendering)
- Possibly create `Stockbar/Components/SparklineView.swift`

---

**Feature: Portfolio Summary in Main Menu**

Add summary section at top of main StockBar menu showing total portfolio performance.

**Mockup:**
```
┌─────────────────────────────────┐
│ 📊 Portfolio Summary           │
│ Total Value: $45,678.90        │
│ Daily P&L: +$234.56 (+0.51%)   │
│ Total Gains: +$5,678.90        │
├─────────────────────────────────┤
│ [Individual stocks below...]    │
```

**Implementation:**
- Add new section to main menu in `StockMenuBarController`
- Use `DataModel.calculateNetGains()` and `calculateNetValue()`
- Update on data refresh
- Make collapsible (optional)

**Files to Modify:**
- `Stockbar/StockMenuBarController.swift`
- `Stockbar/StockStatusBar.swift`

---

### 2.2 Preferences Window Improvements ⚙️ **Medium Priority**

**Feature: Bulk Edit Mode**

Allow selecting multiple stocks to change properties simultaneously.

**Features:**
- Checkbox selection for multiple stocks
- Bulk actions: Change currency, delete multiple, export selection
- "Select All" / "Deselect All" buttons

**Implementation:**
- Add `@State private var editMode: Bool = false` to PreferenceView
- Show checkboxes when edit mode enabled
- Add bulk action toolbar

**Files to Modify:**
- `Stockbar/PreferenceView.swift`

---

**Feature: Stock Symbol Validation**

Validate stock symbols as user types to catch errors early.

**Features:**
- Real-time validation indicator (✓ valid, ✗ invalid, ⏳ checking)
- Tooltip showing stock full name when valid
- Warning if symbol not found on Yahoo Finance

**Implementation:**
- Add async validation function using yfinance
- Debounce validation (wait 1s after typing stops)
- Cache validation results

**Files to Modify:**
- `Stockbar/PreferenceView.swift` (PreferenceRow)
- Possibly create `Stockbar/Services/SymbolValidationService.swift`

---

### 2.3 Chart Enhancements 📈 **Medium Priority**

**Feature: Comparison Mode**

Overlay multiple stocks on same chart for visual comparison.

**Implementation:**
- Add "Compare" toggle in chart type picker
- Allow selecting 2-5 stocks to compare
- Normalize to percentage change for fair comparison
- Different color per stock with legend

**Files to Modify:**
- `Stockbar/Charts/PerformanceChartView.swift`

---

**Feature: Custom Date Range Picker**

UI for the already-implemented custom date filter state.

**Implementation:**
- Add date pickers for `customStartDate` and `customEndDate`
- Add "Custom Range" option in time range picker
- Show selected range in UI

**Files to Modify:**
- `Stockbar/Charts/PerformanceChartView.swift` (already has state variables)

---

**Feature: Chart Annotations**

Allow marking significant events on charts (earnings, dividends, personal notes).

**Implementation:**
- Add annotation system to HistoricalDataManager
- UI to add/edit/delete annotations
- Render as vertical lines or markers on charts
- Store in Core Data

**Estimated Effort:** 6-8 hours (requires data model changes)

---

### 2.4 Dark Mode Refinements 🌙 **Low Priority**

**Tasks:**
- Audit all custom colors for light/dark mode compatibility
- Test all UI components in both modes
- Ensure charts remain readable in dark mode
- Consider adding explicit appearance preference (override system)

**Implementation:**
- Use semantic colors everywhere (`Color.primary`, `Color.secondary`)
- Test with `@Environment(\.colorScheme)` in previews
- Add appearance override in preferences if desired

---

## 3. Performance & Reliability

### 3.1 Optimize Historical Data Backfill 🚀 **High Priority**

**Current Issues:**
- 5-year backfill runs on startup (can block UI for new users)
- No user control over when backfill happens
- 2-hour cooldown is hardcoded

**Improvements:**

**1. User-Controlled Schedule**
- Add preferences option: "Auto-backfill" dropdown
  - Options: "On startup", "Daily at [time]", "Manual only"
- Store preference in UserDefaults

**2. Progress Notifications**
- Show macOS notification when background backfill starts/completes
- Include progress in notification if supported
- Make notifications optional

**3. Configurable Cooldown**
- Expose cooldown setting in Debug tab
- Options: 30min, 1hr, 2hr, 6hr, 12hr, 24hr
- Default: 2 hours (current behavior)

**Files to Modify:**
- `Stockbar/Data/DataModel.swift` (backfill logic)
- `Stockbar/PreferenceView.swift` (settings UI)
- Add notification handling in `AppDelegate.swift`

**Implementation Steps:**
1. Add preference settings UI
2. Add scheduled backfill using Timer
3. Add notification support
4. Test with various schedules

---

### 3.2 Log Rotation System 📄 **Medium Priority**

**Current Issue:**
- Logs in `~/Library/Application Support/Stockbar/stockbar.log` grow indefinitely
- Can consume disk space over time

**Solution: Implement Log Rotation**

**Features:**
- Maximum log file size: 10MB (configurable)
- Keep last 3 log files: `stockbar.log`, `stockbar.1.log`, `stockbar.2.log`
- Rotate when max size reached
- Add "Clear Old Logs" button in Debug tab

**Implementation:**
- Add rotation logic to `Logger.swift`
- Check file size before each write
- Rotate if exceeds limit

**Files to Modify:**
- `Stockbar/Utilities/Logger.swift`
- `Stockbar/PreferenceView.swift` (add clear button in debug view)

---

### 3.3 Network Timeout Improvements ⏱️ **Medium Priority**

**Current State:**
- Fixed 30s process timeout
- Fixed 5min retry interval after failures

**Improvements:**

**1. Exponential Backoff**
- First failure: retry in 1 minute
- Second failure: retry in 2 minutes
- Third failure: retry in 5 minutes
- Fourth+ failure: retry in 10 minutes
- Reset on successful fetch

**2. Circuit Breaker Pattern**
- After 5 consecutive failures for a symbol, mark as "suspended"
- Don't attempt refresh for 1 hour
- Show warning icon in UI for suspended symbols
- Allow manual "retry now" in menu

**Files to Modify:**
- `Stockbar/Data/DataModel.swift` (retry logic)
- `Stockbar/StockStatusBar.swift` (suspended state display)

---

### 3.4 Core Data Performance Audit ✅ **Low Priority**

**Tasks:**
- Verify `BatchProcessingService` is actually used
- Ensure background context for large imports
- Profile Core Data fetch performance
- Add indices if queries are slow

**Files to Review:**
- `Stockbar/Data/CoreData/BatchProcessingService.swift`
- `Stockbar/Data/CoreData/TradeDataService.swift`

---

## 4. Features & Data

### 4.1 Enhanced Currency Features 💱 **Medium Priority**

**1. Show Exchange Rates in UI**
- Add tooltip showing exchange rate used for each stock
- Example: "Using rate: 1 GBP = 1.27 USD (refreshed 2h ago)"

**2. Currency Conversion History**
- Track exchange rate changes over time
- Show chart of USD/GBP rate over last year
- Useful for understanding portfolio value changes

**3. Significant Change Alerts** (if notifications implemented)
- Alert when exchange rate changes >2% in one update
- Helps explain sudden portfolio value changes

**Files to Modify:**
- `Stockbar/CurrencyConverter.swift`
- `Stockbar/StockStatusBar.swift` (tooltips)
- `Stockbar/PreferenceView.swift` (currency history chart)

---

### 4.2 Watchlist vs Portfolio Separation 👀 **Medium Priority**

**Current Limitation:**
- All stocks require position data (units, avg cost)
- Can't track stocks you don't own

**Feature: Watchlist Mode**

**Implementation:**
- Add boolean flag to Trade: `isWatchlistOnly`
- Watchlist stocks don't require units/avg cost
- Don't include in portfolio calculations
- Different display in menu bar (maybe different icon)
- Separate section in preferences: "Portfolio" and "Watchlist" tabs

**Files to Modify:**
- `Stockbar/Data/Trade.swift` (add flag)
- `Stockbar/Data/DataModel.swift` (filter calculations)
- `Stockbar/PreferenceView.swift` (separate tabs)
- Migration needed for Core Data

**Estimated Effort:** 4-6 hours

---

### 4.3 Alerts & Notifications 🔔 **Medium-High Priority**

**Features:**

**1. Price Alerts**
- Set target price for any stock
- Notify when price crosses threshold (above or below)
- Example: "Alert me when AAPL reaches $200"

**2. Percentage Change Alerts**
- Notify on significant daily moves
- Example: "Alert me if any stock moves ±5%"

**3. Portfolio Milestones**
- Notify when portfolio hits specific value
- Example: "Alert me when portfolio reaches $100,000"

**Implementation:**
- Use `UserNotifications` framework
- Store alerts in Core Data (new AlertEntity)
- Check alerts on each price refresh
- Add "Alerts" tab in preferences

**Files to Create:**
- `Stockbar/Services/AlertService.swift`
- `Stockbar/Data/CoreData/AlertEntity+CoreDataProperties.swift`
- `Stockbar/Views/AlertsPreferenceView.swift`

**Files to Modify:**
- `Stockbar/Data/DataModel.swift` (check alerts on refresh)
- `Stockbar/PreferenceView.swift` (add alerts tab)
- `Stockbar/AppDelegate.swift` (notification permissions)
- Core Data model (add AlertEntity)

**Estimated Effort:** 8-12 hours (complete feature)

---

## 5. Data Integrity & Safety

### 5.1 Enhanced Backup System 💾 **High Priority**

**Current State:**
- Only manual CSV/JSON export via UI
- No automatic backups

**Improvements:**

**1. Automatic Daily Backups**
- Auto-backup portfolio at app launch (once per day)
- Store in `~/Library/Application Support/Stockbar/Backups/`
- Format: `portfolio_backup_YYYY-MM-DD.json`
- Keep last 30 days, auto-delete older

**2. Restore from Backup UI**
- Add "Restore from Backup..." button in preferences
- Show list of available backups with dates
- Preview backup contents before restoring
- Confirmation dialog with warning

**3. Backup Management**
- Show backup status in preferences (last backup date)
- Manual "Backup Now" button
- "View Backups Folder" button
- Configure retention period (7/14/30/90 days)

**Implementation:**
- Create `BackupService.swift`
- Schedule daily backup with Timer
- Add restore UI to preferences

**Files to Create:**
- `Stockbar/Services/BackupService.swift`

**Files to Modify:**
- `Stockbar/PreferenceView.swift` (backup section in Portfolio tab)
- `Stockbar/AppDelegate.swift` (schedule backups)

**Estimated Effort:** 4-6 hours

---

### 5.2 Data Validation Improvements ✅ **Medium Priority**

**1. Symbol Validation** (covered in 2.2 above)

**2. Price Sanity Checks**
- Alert if stock price changes >50% in single update
- Likely indicates data error or stock split
- Ask user to verify before accepting
- Log unusual price movements

**3. Position Size Warnings**
- Warn if entering very large units (>10,000)
- Warn if entering very high avg cost (>$1,000)
- Just a confirmation dialog, not blocking

**Implementation:**
- Add validation functions to DataModel
- Show alerts on suspicious data
- Add "Ignore this warning" checkbox

**Files to Modify:**
- `Stockbar/Data/DataModel.swift`
- `Stockbar/PreferenceView.swift`

---

## 6. Developer Experience

### 6.1 Improved Debug Tools 🛠️ **Low-Medium Priority**

**Features:**

**1. Network Request Inspector**
- Show all API calls made in last session
- Display: timestamp, symbol, endpoint, response time, status
- Useful for debugging rate limits and failures

**2. Cache Inspector**
- View cache contents for each symbol
- Show: last fetch time, next refresh time, cache status
- "Clear Cache" button per symbol
- "Clear All Caches" button

**3. "Simulate Market Closed" Mode**
- Toggle to test closed market behavior
- Override market state detection
- Useful for development

**4. Export Debug Report**
- Bundle logs + config + portfolio summary (no sensitive data)
- Save as `.zip` file
- Helpful for support/troubleshooting

**Implementation:**
- Add debug panels to Debug tab
- Store request history in memory (last 100 requests)
- Add report generation utility

**Files to Modify:**
- `Stockbar/PreferenceView.swift` (debug tab)
- `Stockbar/Data/DataModel.swift` (request logging)
- Create `Stockbar/Utilities/DebugReportGenerator.swift`

---

### 6.2 Unit Test Coverage 🧪 **Medium Priority**

**Current State:**
- `StockbarTests` exists but coverage unknown

**Goal: 70% Coverage of Business Logic**

**Priority Test Coverage:**

**1. Currency Conversion** (Critical)
- Test all currency pairs
- Test GBX→GBP conversion
- Test edge cases (NaN, zero, negative)

**2. Portfolio Calculations** (Critical)
- Test `calculateNetGains()`
- Test `calculateNetValue()`
- Test with mixed currencies
- Test with GBX stocks

**3. Cache Logic** (Important)
- Test cache expiration
- Test retry intervals
- Test exponential backoff (once implemented)

**4. Data Migration** (Important)
- Test migration from V1 to V2
- Test empty database migration
- Test rollback scenarios

**5. Historical Data** (Nice to have)
- Test snapshot recording
- Test backfill logic
- Test data cleanup

**Implementation:**
- Create test files in `StockbarTests/`
- Use XCTest framework
- Add mock network service for testing
- Set up CI if desired (GitHub Actions)

**Estimated Effort:** 12-16 hours (comprehensive test suite)

---

### 6.3 Documentation 📚 **Low Priority**

**1. User Guide**
- In-app help button
- PDF user manual
- Cover: adding stocks, understanding UI, troubleshooting

**2. FAQ Section**
- Common issues and solutions
- "Why is my data not updating?"
- "What does GBX mean?"
- "How do I back up my data?"

**3. Contributing Guide** (if open-sourcing)
- Code style guidelines
- How to run tests
- Pull request process

**Files to Create:**
- `Docs/UserGuide.md`
- `Docs/FAQ.md`
- `CONTRIBUTING.md` (if open source)

---

## 7. Python Backend

### 7.1 Python Error Handling Improvements 🐍 **Medium Priority**

**Current State:**
- Errors go to stderr
- Swift parses "FETCH_FAILED" string

**Improvement: Structured JSON Errors**

**Current Output:**
```
FETCH_FAILED
Error: Rate limit exceeded
```

**New Output:**
```json
{
  "success": false,
  "error": {
    "code": "RATE_LIMIT",
    "message": "API rate limit exceeded. Try again in 60 seconds.",
    "retry_after": 60,
    "timestamp": 1727734800
  }
}
```

**Error Codes:**
- `RATE_LIMIT` - API rate limit hit
- `INVALID_SYMBOL` - Symbol not found
- `NETWORK_ERROR` - Connection failed
- `API_KEY_INVALID` - FMP API key rejected
- `TIMEOUT` - Request timed out
- `UNKNOWN` - Unexpected error

**Benefits:**
- Better error messages to user
- Can display retry countdown
- Easier debugging

**Implementation:**
- Modify `get_stock_data.py` to output JSON
- Update Swift NetworkService to parse JSON errors
- Show user-friendly error messages in UI

**Files to Modify:**
- `Stockbar/Resources/get_stock_data.py`
- `Stockbar/Data/Networking/NetworkService.swift`
- `Stockbar/StockStatusBar.swift` (error display)

---

### 7.2 Python Dependencies Management 📦 **Low Priority**

**Tasks:**

**1. Create requirements.txt**
```txt
yfinance>=0.2.0
requests>=2.25.0
```

**2. Document Python Version**
- Specify minimum Python 3.8+
- Test with Python 3.9, 3.10, 3.11, 3.12

**3. Dependency Check on Launch**
- Swift checks if yfinance is available on first run
- Show alert with installation instructions if missing
- Offer to open Terminal with pip command

**4. Consider Bundling Python** (Future)
- Use py2app or PyInstaller to bundle Python
- Eliminates user setup requirement
- Increases app size significantly
- Research effort required

**Files to Create:**
- `Stockbar/Resources/requirements.txt`

**Files to Modify:**
- `Stockbar/AppDelegate.swift` (dependency check)
- `CLAUDE.md` (document requirements)

---

## 8. Implementation Priority

### Phase 1: Quick Wins (1-2 weeks)
**Effort:** Low | **Impact:** High

- ✅ Remove legacy files (1.1)
- 💾 Enhanced backup system (5.1)
- 📊 Portfolio summary in main menu (2.1)
- 🔄 Log rotation (3.2)
- 🐍 Python structured errors (7.1)

### Phase 2: Core Improvements (3-4 weeks)
**Effort:** Medium-High | **Impact:** High

- 🏗️ Reduce DataModel complexity (1.2) - **Largest effort**
- 📈 Mini sparkline charts (2.1)
- 🚀 Optimize historical backfill (3.1)
- 🔔 Alerts & notifications (4.3)
- ✅ Data validation (5.2)

### Phase 3: Feature Expansion (2-3 weeks)
**Effort:** Medium | **Impact:** Medium-High

- 👀 Watchlist mode (4.2)
- 💱 Enhanced currency features (4.1)
- ⏱️ Network timeout improvements (3.3)
- 📊 Bulk edit mode (2.2)
- 🎨 Chart enhancements (2.3)

### Phase 4: Polish & Quality (2-3 weeks)
**Effort:** Medium | **Impact:** Medium

- 🧪 Unit test coverage (6.2)
- 🛠️ Debug tools (6.1)
- 🌙 Dark mode refinements (2.4)
- 📚 Documentation (6.3)
- ⚙️ Core Data audit (3.4)
- 📦 Python dependencies (7.2)

---

## 9. Testing Strategy

### Before Each Release

**1. Manual Testing Checklist**
- [ ] Add new stock (valid symbol)
- [ ] Add invalid symbol (should validate/warn)
- [ ] Reorder stocks (drag & drop)
- [ ] Delete stock
- [ ] Export portfolio (CSV & JSON)
- [ ] Import portfolio
- [ ] Change currency
- [ ] Toggle color coding
- [ ] View all chart types and time ranges
- [ ] Check both light & dark mode
- [ ] Force quit and restart (data persists)
- [ ] Check memory usage (<5% CPU target)
- [ ] Test with UK stocks (.L symbols)

**2. Automated Tests**
- Run full test suite: `⌘U` in Xcode
- All tests must pass before release

**3. Performance Profiling**
- Use Instruments to check for memory leaks
- Verify CPU usage stays under 5%
- Check network request timing

---

## 10. Documentation Updates

**Files to Update:**
- `CLAUDE.md` - Document new architecture after refactoring
- `README.md` - Update feature list
- `Draft_Plans/CHANGELOG.md` - Document all changes for v2.2.10

---

## 11. Estimated Timeline

**Total Estimated Effort:** 70-95 hours

**Breakdown:**
- Phase 1 (Quick Wins): 10-12 hours
- Phase 2 (Core): 25-35 hours
- Phase 3 (Features): 20-25 hours
- Phase 4 (Polish): 15-23 hours

**Recommended Schedule:**
- Sprint 1 (Week 1-2): Phase 1 complete
- Sprint 2 (Week 3-6): Phase 2 complete
- Sprint 3 (Week 7-9): Phase 3 complete
- Sprint 4 (Week 10-12): Phase 4 complete + release prep

**Release Target:** ~3 months for full feature set

---

## 12. Success Metrics

**v2.2.10 will be considered successful if:**

1. ✅ DataModel.swift is under 800 lines (refactored)
2. ✅ No crashes in 2 weeks of daily use
3. ✅ Automatic backups working reliably
4. ✅ Unit test coverage >70% on business logic
5. ✅ Users can add stocks without manual symbol lookup
6. ✅ Historical backfill doesn't block UI on startup
7. ✅ Sparkline charts render smoothly in menu
8. ✅ Dark mode looks good in all UI areas

---

## Appendix A: Files Requiring Major Changes

### High-Impact Files (Most Changes)
1. `Stockbar/Data/DataModel.swift` - Major refactoring
2. `Stockbar/PreferenceView.swift` - Many UI additions
3. `Stockbar/StockStatusBar.swift` - Menu enhancements
4. `Stockbar/Charts/PerformanceChartView.swift` - Chart features

### New Files to Create (~10-15)
1. `Services/PortfolioCalculationService.swift`
2. `Services/HistoricalDataCoordinator.swift`
3. `Services/RefreshCacheService.swift`
4. `Services/BackupService.swift`
5. `Services/AlertService.swift`
6. `Services/SymbolValidationService.swift`
7. `Components/SparklineView.swift`
8. `Views/AlertsPreferenceView.swift`
9. `Utilities/DebugReportGenerator.swift`
10. And more as needed...

---

## Appendix B: Excluded Items (Per User Request)

**Not implementing:**
- ❌ Keyboard shortcuts in preferences
- ❌ Export chart as image (PNG/PDF)
- ❌ Advanced analytics (dividends, beta, etc.)
- ❌ iCloud sync via CloudKit
- ❌ API key security (Keychain migration)
- ❌ Privacy policy & data privacy section
- ❌ Update mechanism (Sparkle framework)
- ❌ App Store preparation

---

**End of Plan**

---

**Next Steps:**
1. Review and approve this plan
2. Prioritize phases based on your needs
3. Begin Phase 1 implementation
4. Iterate based on feedback

**Questions or Changes?**
Feel free to modify priorities, add items, or remove features from this plan before starting implementation.