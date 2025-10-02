# Gap Resolution Progress Report

## Overview
This document tracks the progress of resolving 5 key gaps between the v2.2.10 plan and actual implementation.

---

## ✅ GAP 1: DataModel Complexity - PARTIAL PROGRESS

### ✅ Completed
1. **Created PortfolioCalculationService.swift** (New file)
   - Extracted `calculateNetGains()` 
   - Extracted `calculateNetValue()`
   - Extracted `calculatePortfolioMetricsEfficiently()`
   
2. **Created HistoricalDataCoordinator.swift** (New file)
   - Extracted `checkAndBackfillHistoricalData()`
   - Extracted `checkAndBackfill5YearHistoricalData()`
   - Extracted `staggeredBackfillHistoricalData()`
   - Extracted `backfillHistoricalDataForSymbol()`
   - Extracted `fetchHistoricalDataChunk()`
   - **RESOLVED**: Now reads `backfillSchedule` setting from UserDefaults
   - **RESOLVED**: Implements "On Startup" vs "Manual Only" modes
   - **RESOLVED**: Sends notifications if enabled

3. **Updated DataModel.swift**
   - Added service properties (portfolioCalculationService, historicalDataCoordinator)
   - Initialized services in init()
   - Delegated calculation methods to PortfolioCalculationService
   - Delegated startup backfill to HistoricalDataCoordinator
   - Removed old state variables (isRunningComprehensiveCheck, isRunningStandardCheck, lastComprehensiveCheckTime, comprehensiveCheckCooldown)

### ⚠️ Remaining Work
**DataModel.swift still contains ~420 lines of backfill implementation that should be removed:**

Lines to REMOVE and replace with delegation:
- Lines 407-477: `checkAndBackfill5YearHistoricalData()` - Replace with call to coordinator
- Lines 479-512: `staggeredBackfillHistoricalData()` - Already in coordinator, remove from DataModel
- Lines 498-512: `backfillHistoricalData()` - Replace with call to coordinator
- Lines 514-574: `backfillHistoricalDataForSymbol()` - Already in coordinator, remove from DataModel
- Lines 579-625: `fetchHistoricalDataChunk()` - Already in coordinator, remove from DataModel
- Lines 628-711: `backfillHistoricalDataLegacy()` - Remove (legacy, no longer needed)
- Lines 713-718: `addHistoricalSnapshots()` - Keep (simple wrapper)
- Lines 720-730: `triggerFullHistoricalBackfill()` - Replace with call to coordinator
- Lines 734-741: `getHistoricalDataStatus()` - Replace with call to coordinator
- Lines 743-749: `calculate5YearPortfolioValues()` - Keep (calls historicalDataManager, not backfill)
- Lines 817-833: `checkAndCalculatePortfolioValues()` - Keep (calls historicalDataManager)

**Simple replacements needed:**
```swift
// Line 407-477: Replace with
public func checkAndBackfill5YearHistoricalData() async {
    let symbols = realTimeTrades.map { $0.trade.name }
    await historicalDataCoordinator.checkAndBackfill5YearHistoricalData(symbols: symbols)
}

// Line 498-512: Replace with
public func backfillHistoricalData(for symbols: [String]) async {
    await historicalDataCoordinator.backfillHistoricalData(for: symbols)
}

// Line 479-512, 514-574, 579-625: DELETE ENTIRE METHODS (private, already in coordinator)

// Line 628-711: DELETE backfillHistoricalDataLegacy (no longer needed)

// Line 720-730: Replace with
public func triggerFullHistoricalBackfill() async {
    let symbols = realTimeTrades.map { $0.trade.name }.filter { !$0.isEmpty }
    await historicalDataCoordinator.triggerFullHistoricalBackfill(symbols: symbols)
}

// Line 734-741: Replace with
public func getHistoricalDataStatus() -> (isRunningComprehensive: Bool, isRunningStandard: Bool, lastComprehensiveCheck: Date, nextComprehensiveCheck: Date) {
    return historicalDataCoordinator.getHistoricalDataStatus()
}
```

**Expected Result After Cleanup:**
- DataModel.swift: ~835 lines → **~415 lines** (51% reduction)
- Target: <800 lines ✅ **TARGET EXCEEDED**

---

## ❌ GAP 2: Chart Annotations - NOT STARTED

### Required Implementation
1. **Create Core Data Entity** for annotations
   - ChartAnnotation entity with: id, symbol, date, title, note, type (earnings/dividend/personal)
   
2. **Add to HistoricalDataManager.swift**:
   - `addAnnotation(symbol:date:title:note:type:)`
   - `getAnnotations(symbol:) -> [ChartAnnotation]`
   - `deleteAnnotation(id:)`
   
3. **Update PerformanceChartView.swift** (lines 261-273 in plan):
   - Add annotation picker UI
   - Add `.chartAnnotation()` marks for Swift Charts
   - Render vertical lines/markers at annotation dates
   - Show tooltip on hover with annotation details

**Files to Create:**
- `Stockbar/Data/CoreData/ChartAnnotation+CoreDataProperties.swift`

**Files to Modify:**
- `Stockbar/Data/StockbarDataModel.xcdatamodeld/` - Add ChartAnnotation entity
- `Stockbar/Data/HistoricalDataManager.swift` - Add annotation management
- `Stockbar/Charts/PerformanceChartView.swift` - Add annotation UI and rendering

---

## ✅ GAP 3: Backfill Scheduling - RESOLVED

**Status:** ✅ **FULLY IMPLEMENTED**

The HistoricalDataCoordinator now:
- Reads `backfillSchedule` from UserDefaults (line 49-51)
- Implements "On Startup" mode (line 35-73)
- Implements "Manual Only" mode (skips if not "startup")
- Honors the cooldown period from UserDefaults
- Sends notifications if enabled

The PreferenceView already has the UI controls (lines 344, 1199-1209).

---

## ❌ GAP 4: Currency History & Alerts - NOT STARTED

### Required Implementation

**1. Add to CurrencyConverter.swift:**
```swift
// Add property
@Published private(set) var rateHistory: [Date: [String: Double]] = [:] // date -> rates
private let maxHistoryDays = 365 // Keep 1 year

// Add to refreshRates() success block:
let today = Calendar.current.startOfDay(for: Date())
rateHistory[today] = response.rates
// Cleanup old history
cleanupOldHistory()

// Add new methods
func getRateHistory(currency: String, days: Int) -> [(date: Date, rate: Double)] {
    // Returns rate history for past N days
}

func getSignificantRateChanges(threshold: Double = 0.02) -> [(currency: String, change: Double)] {
    // Detects >2% rate changes in last update
}

private func cleanupOldHistory() {
    let cutoffDate = Calendar.current.date(byAdding: .day, value: -maxHistoryDays, to: Date())!
    rateHistory = rateHistory.filter { $0.key >= cutoffDate }
}
```

**2. Add Currency Change Alert Detection:**
```swift
// In refreshRates() after rates update:
if let previousRates = getPreviousRates() {
    for (currency, newRate) in response.rates {
        if let oldRate = previousRates[currency] {
            let change = abs((newRate - oldRate) / oldRate)
            if change > 0.02 { // 2% threshold
                sendCurrencyAlert(currency: currency, change: change)
            }
        }
    }
}

private func sendCurrencyAlert(currency: String, change: Double) {
    let notification = NSUserNotification()
    notification.title = "💱 Significant Currency Change"
    notification.informativeText = "\(currency) changed by \(String(format: "%.1f%%", change * 100))"
    notification.soundName = NSUserNotificationDefaultSoundName
    NSUserNotificationCenter.default.deliver(notification)
}
```

**3. Add UI in PreferenceView to show rate history:**
- Chart showing USD/GBP rate over time
- Display in Exchange Rates section (line 615-667)

---

## ❌ GAP 5: Alerts Core Data Migration - NOT STARTED

### Required Implementation

**1. Create Core Data Entity:**
```
AlertEntity
├── id: UUID
├── symbol: String?  // nil for portfolio alerts
├── alertType: String  // "price_above", "price_below", "percent_change", "portfolio_milestone"
├── threshold: Double
├── isEnabled: Bool
├── createdAt: Date
├── lastTriggered: Date?
└── milestoneValue: Double?  // For portfolio milestones
```

**2. Migrate PriceAlertService.swift:**
- Replace `UserDefaults` storage with Core Data
- Add `AlertEntityService` similar to TradeDataService
- Keep in-memory cache for performance

**3. Add Portfolio Milestone Alerts:**
```swift
struct PortfolioMilestoneAlert {
    let targetValue: Double
    let currency: String
    let isEnabled: Bool
}

// In DataModel.swift, after calculateNetValue:
func checkPortfolioMilestones() {
    let currentValue = calculateNetValue()
    for alert in PriceAlertService.shared.getPortfolioAlerts() {
        if alert.conditionMet(currentValue: currentValue.amount) {
            PriceAlertService.shared.triggerAlert(alert)
        }
    }
}
```

**Files to Create:**
- `Stockbar/Data/CoreData/AlertEntity+CoreDataProperties.swift`
- `Stockbar/Data/CoreData/AlertEntityService.swift`

**Files to Modify:**
- `Stockbar/Data/StockbarDataModel.xcdatamodeld/` - Add AlertEntity
- `Stockbar/Services/PriceAlertService.swift` - Switch to Core Data
- `Stockbar/Data/DataModel.swift` - Add `checkPortfolioMilestones()` call after refresh

---

## Summary

| Gap | Status | Completion | Priority |
|-----|--------|------------|----------|
| 1. DataModel Complexity | 🟡 Partial | 60% | HIGH |
| 2. Chart Annotations | ❌ Not Started | 0% | MEDIUM |
| 3. Backfill Scheduling | ✅ Complete | 100% | HIGH |
| 4. Currency History | ❌ Not Started | 0% | MEDIUM |
| 5. Alerts Core Data | ❌ Not Started | 0% | MEDIUM-HIGH |

**Overall Progress: 32% Complete**

---

## Next Steps (Priority Order)

1. **Complete DataModel refactoring** (15 mins)
   - Replace remaining backfill methods with delegation
   - Remove ~420 lines of duplicate code
   - Achieve <800 line target

2. **Update release notes** (10 mins)
   - Remove references to unimplemented features
   - Accurately describe current capabilities

3. **Implement Currency History** (30 mins)
   - Lowest hanging fruit of remaining gaps
   - High user value

4. **Migrate Alerts to Core Data** (45 mins)
   - Fixes architectural issue
   - Enables portfolio milestones

5. **Add Chart Annotations** (60 mins)
   - Most complex remaining feature
   - Requires Core Data changes

