# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build and Development Commands

### Building the Application
- **Build in Xcode**: Open `Stockbar.xcodeproj` and build the `Stockbar` target
- **Required Python dependency**: `pip3 install yfinance` (required for the Python backend)
- **Target Platform**: macOS 15.4+, Swift 5.0, Bundle ID: `com.fhl43211.Stockbar`

### Testing and Debugging
- **Test single stock**: `python3 Stockbar/Resources/get_stock_data.py AAPL`
- **Test multiple stocks**: `python3 Stockbar/Resources/get_stock_data.py AAPL GOOGL MSFT`
- **Update yfinance**: `pip3 install --upgrade yfinance`
- **View logs**: Check `~/Documents/stockbar.log` and Console.app for debug output
- **Test currency conversion**: Verify exchange rates via `CurrencyConverter.refreshRates()`

## Complete Architecture Overview

Stockbar is a macOS menu bar application with a sophisticated hybrid Swift/Python architecture designed for reliable real-time stock portfolio monitoring.

### Application Structure & Entry Points

**Application Lifecycle**
- **`main.swift`**: Minimal entry point creating `AppDelegate` and launching app
- **`AppDelegate.swift`**: Creates single `StockMenuBarController` with shared `DataModel`
- **`Info.plist`**: Configured as menu bar-only app (`LSUIElement = true`), Finance category
- **`Stockbar.entitlements`**: Empty (no special permissions required)
- **Sandboxing**: `ENABLE_USER_SCRIPT_SANDBOXING = NO` for Python script execution

### Core Data Architecture

**`DataModel.swift` - Central Data Controller**
- **Pattern**: ObservableObject with MVVM architecture
- **Key Properties**:
  - `@Published var realTimeTrades: [RealTimeTrade]` - primary data collection
  - `@Published var showColorCoding: Bool` - UI preference with UserDefaults binding
  - `@Published var preferredCurrency: String` - portfolio currency with UserDefaults binding
- **Caching Strategy**:
  - `cacheInterval: 900s` (15 min) for successful fetches
  - `retryInterval: 300s` (5 min) for failed fetch retries
  - `maxCacheAge: 3600s` (1 hour) before forced refresh
  - Per-symbol cache tracking via `lastSuccessfulFetch`/`lastFailedFetch` dictionaries
- **Data Persistence**:
  - `UserDefaults["usertrades"]` - JSON encoded Trade array (configuration)
  - `UserDefaults["tradingInfoData"]` - JSON encoded TradingInfo dictionary (last successful market data)
  - Automatic persistence on data changes via Combine publishers

**Data Models Structure**
- **`Trade.swift`**:
  - `Trade`: User's stock configuration (symbol, Position)
  - `Position`: Investment details with validation (units, avg cost, currency)
  - `TradingInfo`: Real-time market data (current price, previous close, timestamps, metadata)
- **`UserData.swift`**:
  - `RealTimeTrade`: ObservableObject combining `Trade` + `TradingInfo`
  - Helper functions for empty trade creation and file logging
- **`StockFetchResult.swift`**: Network response format from Python service
- **`StockData.swift`**: Legacy calculated data model (not used in current architecture)

### Networking & Data Fetching

**`NetworkService.swift` - Protocol-Based Service Layer**
- **Protocol**: `NetworkService` with async `fetchQuote`/`fetchBatchQuotes` methods
- **Implementation**: `PythonNetworkService` for subprocess execution
- **Error Handling**: Comprehensive `NetworkError` enum covering script execution failures
- **Resilience**: Failed fetches create `StockFetchResult` with `Double.nan` prices to preserve metadata

**Python Backend (`get_stock_data.py`)**
- **Technology**: yfinance library with Yahoo Finance API
- **Features**: 
  - Batch symbol processing with fallback to individual fetches
  - File-based JSON cache in `~/.stockbar_cache.json` (5-minute duration)
  - Previous close calculation using 5-day historical data
  - Structured output parsing for price/previous close data
- **Output Format**: Text format parsed by regex in Swift
- **Error Handling**: `FETCH_FAILED` flag for explicit error signaling

**Process Communication**
- **Execution**: `/usr/bin/python3` with script path and symbol arguments
- **Parsing**: Regex extraction of Close/PrevClose prices from stdout
- **Error Recovery**: stderr logging, empty output handling, timeout protection
- **Rate Limiting**: 1-second delays between batch requests

### UI Architecture & Menu Bar Integration

**Menu Bar Components**
- **`StockMenuBarController.swift`**: Main coordinator managing timer, data binding, and status bar
- **`StockStatusBar.swift`**: Creates and manages NSStatusItem instances
  - `StockStatusItemController`: Individual stock menu items with reactive Combine updates
  - Dynamic title updates showing day P&L per stock
  - Color coding support (green/red) based on user preference
- **Menu Content**: Detailed stock information in dropdown menus (price, gains, market value, P&L, etc.)

**Preferences UI (SwiftUI/AppKit Hybrid)**
- **`PreferenceView.swift`**: SwiftUI interface for portfolio management
  - Add/remove stocks with `+`/`-` buttons
  - Currency selection picker
  - Color coding toggle
  - Real-time net gains display with color coding
  - Exchange rate refresh functionality
- **`PreferenceViewController.swift`**: AppKit wrapper using NSHostingController
- **`PreferencePopover.swift`**: NSPopover container with transient behavior
- **`PreferenceHostingController.swift`**: Alternative hosting controller implementation

### Currency Handling & Conversion

**`CurrencyConverter.swift`**
- **API Integration**: exchangerate-api.com with USD as base currency
- **Supported Currencies**: USD, GBP, EUR, JPY, CAD, AUD
- **Refresh Strategy**: Manual refresh via preferences UI
- **Conversion Logic**: USD-based conversion (amount/sourceRate * targetRate)

**UK Stock Special Handling**
- **Detection**: `.L` suffix symbols (London Stock Exchange)
- **Automatic Conversion**: GBX (pence) to GBP (pounds) via ÷100
- **Currency Normalization**: All GBX data standardized to GBP internally
- **Average Cost Adjustment**: User-entered costs converted from GBX to GBP for calculations
- **Display Consistency**: All UK stock data displayed in GBP with conversion notes

### Error Handling & Resilience Patterns

**Graceful Degradation**
- **Network Failures**: Retain last successful data with original timestamps
- **Invalid Data**: Display "N/A" for failed fetches while preserving currency information
- **Rate Limiting**: Intelligent backoff with cached data display
- **Python Errors**: Comprehensive error logging with fallback behavior

**Data Validation**
- **Price Validation**: `isNaN`/`isFinite` checks throughout calculations
- **Position Validation**: String-to-Double conversion with sensible defaults
- **Currency Validation**: Fallback to USD for unknown currencies
- **Timestamp Validation**: Graceful handling of invalid/missing timestamps

### Logging & Debugging

**`Logger.swift` - Centralized Logging System**
- **Levels**: Debug (🔍), Info (ℹ️), Warning (⚠️), Error (🔴)
- **Outputs**: Console (debug builds) + file logging to `~/Documents/stockbar.log`
- **Context**: Automatic file/function/line capturing for debugging
- **Thread Safety**: Main thread dispatch for UI-related logs

**Debug Capabilities**
- **Network Tracing**: Request/response logging with timing
- **Cache Status**: Cache hit/miss logging with timestamps
- **Price Updates**: Before/after price comparison logging
- **Currency Conversion**: Detailed conversion calculation logs

### Legacy Components & Code Patterns

**Legacy Files**
- **`SymbolMenu.swift`**: Original menu creation logic (unused in current architecture)
- **`ContentView.swift`**: Default SwiftUI view (unused in menu bar app)

**Development Patterns**
- **Memory Management**: Careful `weak self` usage in Combine subscriptions
- **Threading**: Background network operations with main thread UI updates
- **Resource Management**: Proper NSStatusItem cleanup and timer invalidation
- **State Management**: Reactive data flow with minimal imperative updates

### Key Implementation Details

**Reactive Data Flow**
- **Central Pipeline**: `DataModel.$realTimeTrades` drives all UI updates
- **Status Bar Updates**: Automatic menu bar refresh on data changes
- **Preferences Binding**: Two-way binding between SwiftUI and UserDefaults
- **Cache Coordination**: Intelligent refresh scheduling based on cache state

**Performance Optimizations**
- **Staggered Refresh**: Individual stock updates spread across refresh interval
- **Batch Processing**: Multiple symbol fetching with individual fallbacks
- **Memory Efficiency**: Proper Combine subscription cleanup
- **UI Responsiveness**: Background network operations with main thread UI updates

**Security Considerations**
- **No Special Entitlements**: App runs with standard sandbox permissions
- **External API Usage**: Yahoo Finance (via yfinance) and exchange rate API
- **Local Data Storage**: UserDefaults and file-based caching only
- **Script Execution**: Python subprocess with controlled input/output

This architecture provides a robust, maintainable foundation for real-time financial data monitoring with excellent error recovery and user experience.

## Performance Charts Feature

Stockbar includes comprehensive performance charting capabilities with historical data tracking:

### Chart Components
- **`HistoricalData.swift`**: Core data models for price snapshots and portfolio tracking
- **`HistoricalDataManager.swift`**: Singleton service managing data collection, persistence, and retrieval
- **`PerformanceChartView.swift`**: SwiftUI chart interface using Swift Charts framework

### Chart Types Available
- **Portfolio Value**: Total portfolio value over time
- **Portfolio Gains**: Net gains/losses tracking
- **Individual Stocks**: Price history for each stock symbol

### Time Range Options
- 1 Day, 1 Week, 1 Month, 3 Months, 6 Months, 1 Year, All Time
- Dynamic date formatting based on selected range
- Automatic start date calculation for each range

### Data Collection Strategy
- **Snapshot Interval**: 5-minute minimum between recordings
- **Triggers**: Successful price updates in both batch and individual refresh cycles
- **Data Limit**: Maximum 1000 data points per symbol to manage storage
- **Persistence**: UserDefaults storage with automatic cleanup

### Performance Metrics
- **Total Return**: Absolute and percentage gains/losses
- **Volatility**: Standard deviation of daily returns
- **Value Range**: Min/max portfolio values for selected period
- **Automatic Calculation**: Based on available historical data

### Chart Features
- **Interactive Time Ranges**: Segmented picker for quick period selection
- **Chart Type Switching**: Toggle between portfolio and individual stock views
- **Color Coding**: Dynamic colors based on gains/losses
- **Area Charts**: Filled area under line for visual impact
- **Performance Metrics Panel**: Collapsible detailed statistics
- **Empty State Handling**: Informative placeholder when no data available

### Integration Points
- **Preferences UI**: Charts accessible via tabbed interface in preferences
- **Data Recording**: Automatic snapshot recording after successful price updates
- **Currency Handling**: Portfolio values calculated in user's preferred currency
- **Memory Management**: Proper cleanup and data limitations to prevent memory issues