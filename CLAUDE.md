# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build and Development Commands

### Building the Application
- **Build in Xcode**: Open `Stockbar.xcodeproj` and build the `Stockbar` target
- **Required Python dependency**: `pip3 install yfinance` (required for the Python backend)
- **Target Platform**: macOS 15.4+, Swift 6.0, Bundle ID: `com.fhl43211.Stockbar`

### Testing and Debugging
- **Test single stock**: `python3 Stockbar/Resources/get_stock_data.py AAPL`
- **Test multiple stocks**: `python3 Stockbar/Resources/get_stock_data.py AAPL GOOGL MSFT`
- **Update yfinance**: `pip3 install --upgrade yfinance`
- **View logs**: Check `~/Documents/stockbar.log` and Console.app for debug output
- **Test currency conversion**: Verify exchange rates via `CurrencyConverter.refreshRates()`
- **Run unit tests**: Select `StockbarTests` target in Xcode and run tests (⌘U)
- **Performance testing**: Use built-in Debug tab in preferences for real-time monitoring

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
- **Swift 6 Concurrency**:
  - `RefreshCoordinator` actor for serialized refresh operations
  - Async/await patterns throughout with proper isolation
  - Main actor binding for UI updates

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
- **`HistoricalData.swift`**: Price snapshots and portfolio tracking models

### Core Data Services Layer

The application includes a comprehensive service layer for data management located in `Data/CoreData/`:

**Migration & Persistence**
- **`DataMigrationService.swift`**: Core Data Model V2 migration with automatic lightweight migration
- **`TradeDataService.swift`**: Portfolio data persistence and retrieval
- **`TradeDataMigrationService.swift`**: Legacy data migration from UserDefaults to Core Data

**Performance & Optimization**
- **`MemoryManagementService.swift`**: Automatic cleanup under memory pressure, configurable limits
- **`DataCompressionService.swift`**: Historical data compression and optimization for storage efficiency
- **`BatchProcessingService.swift`**: Efficient batch operations for large data sets
- **`CacheManager.swift`**: Multi-tier caching with intelligent invalidation

**Historical Data Management**
- **`HistoricalDataService.swift`**: Chart data collection, persistence, and retrieval
- **`HistoricalDataManager.swift`**: Singleton coordinator for historical data with retroactive calculations
- **`OptimizedChartDataService.swift`**: Efficient chart data queries and aggregation

**Background Processing Architecture**
- **3% Comprehensive Check**: Full historical data gap detection and backfill (2-hour cooldown)
- **2% Standard Gap Check**: Quick gap detection for recent data
- **Startup Backfill**: One-time historical data validation on app launch
- **5-Minute Snapshots**: Automatic data collection triggered by successful price updates

### Networking & Data Fetching

**`NetworkService.swift` - Protocol-Based Service Layer**
- **Protocol**: `NetworkService` with async `fetchQuote`/`fetchBatchQuotes` methods
- **Implementation**: `PythonNetworkService` for subprocess execution
- **Error Handling**: Comprehensive `NetworkError` enum covering script execution failures
- **Resilience**: Failed fetches create `StockFetchResult` with `Double.nan` prices to preserve metadata
- **Timeout Protection**: 30-second process timeout, 5-minute maximum for network operations

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
- **Process Management**: Automatic termination of hanging processes after 30 seconds

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
  - Drag-and-drop stock reordering
  - Currency selection picker
  - Color coding toggle
  - Real-time net gains display with color coding
  - Exchange rate refresh functionality
  - Tabbed interface: Portfolio, Charts, Debug
- **`PreferenceViewController.swift`**: AppKit wrapper using NSHostingController
- **`PreferencePopover.swift`**: NSPopover container with transient behavior
- **`PreferenceHostingController.swift`**: Alternative hosting controller implementation
- **`PreferenceWindowController.swift`**: Window management for preferences

**Chart Components**
- **`PerformanceChartView.swift`**: Interactive Swift Charts implementation
  - Portfolio Value, Portfolio Gains, Individual Stock charts
  - Time ranges: 1 Day, 1 Week, 1 Month, 3 Months, 6 Months, 1 Year, All Time
  - Hover tooltips with precise values
  - Performance metrics: total return, volatility, value ranges
- **`MenuPriceChartView.swift`**: Compact chart view for menu dropdown

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
- **Timeout Protection**: Automatic process termination after 30 seconds
- **Memory Pressure**: Automatic cleanup and data compression

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
- **Thread Safety**: Actor-isolated with Swift 6 patterns
- **Async Operation**: Non-blocking logging with main thread dispatch for UI-related logs

**Debug Capabilities**
- **Network Tracing**: Request/response logging with timing
- **Cache Status**: Cache hit/miss logging with timestamps
- **Price Updates**: Before/after price comparison logging
- **Currency Conversion**: Detailed conversion calculation logs
- **Performance Monitoring**: CPU, memory, and network efficiency tracking

**Utilities**
- **`PerformanceMonitor.swift`**: Real-time performance metrics collection
- **`ExportManager.swift`**: Portfolio data export functionality
- **`ConfigurationManager.swift`**: Centralized app configuration management
- **`CacheOptimizations.swift`**: Advanced caching strategies

### Legacy Components & Code Patterns

**Legacy Files**
- **`SymbolMenu.swift`**: Original menu creation logic (unused in current architecture)
- **`ContentView.swift`**: Default SwiftUI view (unused in menu bar app)

**Development Patterns**
- **Memory Management**: Careful `weak self` usage in Combine subscriptions
- **Threading**: Background network operations with main thread UI updates
- **Resource Management**: Proper NSStatusItem cleanup and timer invalidation
- **State Management**: Reactive data flow with minimal imperative updates
- **Actor Isolation**: Swift 6 concurrency with proper isolation boundaries

### Key Implementation Details

**Reactive Data Flow**
- **Central Pipeline**: `DataModel.$realTimeTrades` drives all UI updates
- **Status Bar Updates**: Automatic menu bar refresh on data changes
- **Preferences Binding**: Two-way binding between SwiftUI and UserDefaults
- **Cache Coordination**: Intelligent refresh scheduling based on cache state
- **RefreshCoordinator Actor**: Serializes refresh operations to prevent race conditions

**Performance Optimizations**
- **Staggered Refresh**: Individual stock updates spread across refresh interval
- **Batch Processing**: Multiple symbol fetching with individual fallbacks
- **Memory Efficiency**: Proper Combine subscription cleanup, automatic data compression
- **UI Responsiveness**: Background network operations with main thread UI updates
- **CPU Optimization**: Reduced from 100% to <5% CPU usage
- **Timeout Management**: 30-second process timeout, 5-minute network operation limit

**Security Considerations**
- **No Special Entitlements**: App runs with standard sandbox permissions
- **External API Usage**: Yahoo Finance (via yfinance) and exchange rate API
- **Local Data Storage**: UserDefaults and Core Data only
- **Script Execution**: Python subprocess with controlled input/output and timeout protection

This architecture provides a robust, maintainable foundation for real-time financial data monitoring with excellent error recovery and user experience.

## Development Workflow

### Code Style and Patterns
- **Swift 6.0 Features**: Use actor isolation, async/await, and modern concurrency patterns
- **Memory Management**: Always use `weak self` in closures to prevent retain cycles
- **Threading**: Network operations on background queues, UI updates on main thread only
- **Error Handling**: Use comprehensive error types with detailed context
- **Logging**: Use `Logger.shared` with appropriate severity levels (debug, info, warning, error)

### Key Files for Common Tasks
- **Adding new stock symbols**: Modify `Trade.swift` and update validation logic
- **UI changes**: `PreferenceView.swift` for SwiftUI, `StockMenuBarController.swift` for menu bar
- **Network/data fetching**: `NetworkService.swift` and `get_stock_data.py`
- **Charts and analytics**: `PerformanceChartView.swift` and `HistoricalDataManager.swift`
- **Logging and debugging**: `Logger.swift` and Debug tab implementation
- **Data services**: Files in `Data/CoreData/` for persistence and optimization

### Testing Strategy
- **Unit Tests**: Located in `StockbarTests/` - run with ⌘U in Xcode
- **Manual Testing**: Use Debug tab for real-time monitoring during development
- **Performance Validation**: Monitor CPU usage should stay <5% during normal operation
- **Python Backend Testing**: Test `get_stock_data.py` script independently with sample symbols
- **Memory Testing**: Monitor memory usage and verify automatic cleanup under pressure

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
- **Persistence**: Core Data storage with automatic cleanup
- **Background Processing**: 3% chance comprehensive gap check, 2% standard gap check

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