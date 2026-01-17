# Release Notes v2.3.4

## 🚀 Major Refactoring, Performance & Stability Release

This release introduces significant architectural improvements, memory optimizations, security hardening, and new menu bar visibility controls.

---

## ✨ New Features

### 📍 Menu Bar Visibility Controls

- **Per-Stock Visibility Toggle**: Hide individual stocks from the menu bar while keeping them in portfolio calculations. Click the menu bar icon (left of each row) in Preferences → Portfolio.
- **Global Visibility Toggle**: New "Show stocks in menu bar" master toggle in Preferences → Portfolio to hide/show all stocks at once.
- **Core Data Model v7**: Added `showInMenuBar` attribute for persistent visibility preferences.

---

## 🎨 Charting Engine Overhaul

Completely deconstructed `PerformanceChartView` for improved maintainability and performance:

- **Modular Architecture**: Split into `PerformanceMetricsView`, `ChartInteractionSystem`, `ChartComparisonService`, and `ChartFormattingService`.
- **Improved Interaction**: Re-engineered pan/zoom and hover interactions for smoother performance.
- **Comparison Logic**: Extracted normalization logic to dedicated service for improved multi-stock comparison reliability.

---

## 🛠️ Menu Bar Customization & Stability

- **New Custom Tokens**: Expanded template support with `{totalPL}`, `{marketValue}`, `{units}`, and `{avgCost}` placeholders.
- **Crash Fix**: Resolved critical `EXC_BREAKPOINT` crash from async menu modification. Menu population now synchronous and thread-safe.
- **Rich Details Restored**: Dropdown menu correctly displays:
  - Secondary Metrics: Units, Position Cost, Last Update time
  - Extended Market Data: Pre-market and After-hours price/change
  - Exchange Rate: Automatic display when stock currency differs from portfolio currency

---

## 🧠 Memory Management

- **LRU Cache Eviction**: `HistoricalDataManager` now implements proper LRU eviction (max 50 entries) preventing unbounded memory growth.
- **Cache Key Normalization**: Prevents duplicate entries for same symbol/timeRange combinations.

---

## ⏱️ Timer & Resource Leak Fixes

- **OHLCFetchService**: Fixed timer leak with `defer`-based `DispatchSource` cancellation.
- **PerformanceMonitor**: Migrated from `Timer` to proper `@MainActor` isolation.

---

## 🔐 Security Improvements

- **Symbol Validation**: Strict allowlist validation (`^[A-Za-z0-9._^=-]+$`) for stock symbols before subprocess execution.
- **Input Sanitization**: All symbols validated before passing to Python scripts, preventing command injection.

---

## ⚡ Performance Optimizations

- **UI Update Coalescing**: `StockStatusBar` uses debounced Combine publishers, reducing O(n²) UI cascade to O(1) batched updates.
- **Correlation Matrix**: Pre-computed statistics + matrix symmetry exploitation (~50% faster).
- **Attribution Analysis**: Single sort outside loop, reducing O(n² log n) → O(n log n).
- **Targeted Notifications**: Menu bar visibility changes use `NotificationCenter` instead of `objectWillChange` to prevent excessive rebuilds.

---

## 🛡️ Type Safety

- **Force Cast Elimination**: Replaced unsafe `as!` with proper `guard let` / `if let` in:
  - `HistoricalDataService`
  - `DataValidationService`
  - `AttributionAnalysisService`
  - `PreferenceView`

---

## 🧹 Code Quality (SwiftLint)

- **Cyclomatic Complexity**: Extracted `colorForMenuItem()` helper in `StockStatusBar.swift` (24 → 16/18).
- **Shorthand Operators**: Fixed `convertedAmount *= 100.0` in `ChartFormattingService.swift`.

---

## 🧵 Concurrency & Thread Safety

- **CurrencyConverter Race Fix**: Added `NSLock` protection for `rateHistory`, `lastAlertTimestamps`, and `cachedRates`.
- **Thread-Safe Rate Caching**: Atomic updates during rate refresh.

---

## 🔔 Framework Modernization

- **UserNotifications Migration**: New `NotificationService` actor using modern `UserNotifications` framework, replacing deprecated `NSUserNotification`.
- **Centralized Notifications**: All notification logic consolidated with proper authorization handling.

---

## 🐛 Bug Fixes

- **Chart Hover**: Fixed regression where tooltip would not appear or update correctly.
- **Font System**: Restored missing `NSFont` extensions.
- **Visual Parity**: Restored separators and color coding in menu dropdown.
- **Duplicate Alert Notifications**: Fixed `checkAlerts` being called multiple times per refresh cycle. Now tracks batch-refreshed symbols and excludes from probe targets.

---

## 📊 Portfolio Menu Bar & Dropdown

- **Configurable Portfolio Total**: Show portfolio value with selectable currency, day gain format, and decimal precision.
- **Color-Coded Gains**: Portfolio gains use same green/red logic as individual stocks.
- **Expanded Summary**: Value, Day Gain, Total P&L, Total Cost, Last Update, Exchange Rate lines.
- **Trend + Chart**: 7-day sparkline and 1D/1W/1M chart in portfolio dropdown.

---

## 🔄 Smart Backfill

- **Auto-Trigger for 1M**: Kicks off backfill when 1M chart lacks historical data.
- **Auto-Refresh**: Chart refreshes after backfill completes, no menu reopen required.

---

## 📡 Connectivity Feedback

- **Suspension Probes**: Probes every 2 minutes without incrementing failure counts.
- **Fallback on Failures**: After three failed probes, attempts fallback quote request.
- **Menu Details**: Shows probe failures, next probe timing, last method attempted.

---

## 📋 Files Modified

| File | Change |
|------|--------|
| `Trade.swift` | Added `showInMenuBar` property |
| `DataModel.swift` | Added `hideAllMenuBarItems` @Published property |
| `StockMenuBarController.swift` | Visibility filtering, NotificationCenter subscription |
| `StockStatusBar.swift` | Global visibility check, debounced updates, `colorForMenuItem()` |
| `PreferenceView.swift` | Per-stock visibility toggle, safe unwrapping |
| `TradeDataExtensions.swift` | `showInMenuBar` Core Data mapping |
| `StockbarDataModel 7.xcdatamodel` | **NEW** - Added `showInMenuBar` attribute |
| `NotificationService.swift` | **NEW** - UserNotifications framework |
| `RefreshService.swift` | Duplicate alert fix |
| `HistoricalDataManager.swift` | LRU cache |
| `OHLCFetchService.swift` | Timer leak fix |
| `PerformanceMonitor.swift` | @MainActor isolation |
| `NetworkService.swift` | Symbol validation |
| `CurrencyConverter.swift` | NSLock thread safety |
| `CorrelationMatrixService.swift` | Matrix symmetry optimization |
| `AttributionAnalysisService.swift` | Sort optimization, safe casting |
| `ChartFormattingService.swift` | Shorthand operator |

---

*Release Date: 17th January 2026*
