# Release Notes v2.3.3

## 🚀 Major Infrastructure & Stability Improvements

This release focuses on hardening the application's core infrastructure, particularly around concurrency, data fetching, and application lifecycle management. These changes resolve critical issues with menu bar visibility and ensuring thread safety across the application.

### 🛠 Application Lifecycle & Entry Point

- **Restored Manual Entry Point**: Replaced the `@main` attribute on `AppDelegate` with a manual `main.swift` entry point using `MainActor.assumeIsolated`. This ensures `NSApplication` is correctly initialized and the delegate is assigned before the run loop starts, resolving issues where the menu bar icon would not appear or respond to clicks.
- **Actor Isolation**: `AppDelegate` is now properly marked as `@MainActor` to align with Swift concurrency requirements for UI-related delegates.

### 🧵 Concurrency & Thread Safety (Swift 6 Readiness)

- **MainActor Enforcement**: Explicitly marked key UI and data coordinating classes as `@MainActor` to prevent data races and UI updates on background threads:
  - `DataModel`
  - `StockMenuBarController`
  - `StockStatusBar` & `StockStatusItemController`
  - `ChartAnnotationService`
- **Refresh Serialization**: Introduced `RefreshCoordinator` actor to serialize data refresh operations, preventing race conditions during simultaneous data updates.
- **Safe Data Buffering**: Implemented `SafeDataBuffer` in `NetworkService` using `NSLock` to handle concurrent writes during Python process output reading.

### 🐍 Python Bridge Robustness

- **Buffer Overflow Protection**: Modified `NetworkService` to read process output incrementally using a readability handler and the new `SafeDataBuffer`. This prevents pipe buffer overflows (which have a 65KB limit) when fetching large datasets (e.g., batch quotes or historical data) from the Python backend.
- **Error Handling**: Improved error capture from the Python script standard error pipe.

### ⚡️ Performance Optimizations

- **Intelligent Chart Sampling**: Updated `OptimizedChartDataService` to use different sampling strategies based on dataset size:
  - **Large Datasets**: Uses SQL-level `LIMIT` and `OFFSET` for memory efficiency.
  - **Small Datasets**: Performs in-memory sampling for speed.
- **Refresh Guard**: Added `isRefreshing` state tracking in `RefreshService` to prevent redundant refresh cycles from overlapping.

### 🐛 Bug Fixes

- **Type Safety**: Fixed type mismatch in `StubNetworkService` (converted `Int64` volume to `Double`).
- **Compiler Warnings**: Resolved unused variable warnings in `TechnicalIndicatorService` and other files.
- **Isolation Fixes**: Corrected `nonisolated` access to `HistoricalDataManager` in `BackfillScheduler` and `DataModel`.

### 🌐 Data Source Configuration & Fallbacks

- **Unified Data Settings Tab**: Added a dedicated “Data” tab in Preferences for managing Financial Modeling Prep and Twelve Data API keys, including show/hide toggles, `Save & Test` buttons, and real-time success/failure indicators.
- **Configurable Fetch Priority**: Users can now reorder historical data providers (Yahoo Finance, FMP, Twelve Data, Stooq) to control fallback order. The priority list is persisted via the updated `ConfigurationManager`.
- **New Providers**: Integrated Twelve Data and Stooq historical fetchers (including GBX→GBP normalization) and exposed their API keys through the configuration manager and Python backend.
- **Backend Verification Hook**: `get_stock_data.py` gained a `--test-key` command, enabling the Swift UI to validate API keys by calling the Python bridge.

### 🧪 Testing

- **Stub Network Service**: Added `StubNetworkService` to facilitate testing without external network or Python dependencies.
