# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build and Development Commands

### Python Requirements

**Minimum Python Version:** 3.8+
**Tested with:** Python 3.9, 3.10, 3.11, 3.12

**Required Dependencies:**
```bash
# Install from requirements.txt (recommended)
pip3 install -r Stockbar/Resources/requirements.txt

# Or install individually
pip3 install yfinance>=0.2.0
pip3 install requests>=2.25.0
```

**Dependency Verification:**
- On first launch, Stockbar automatically checks if yfinance is installed
- If missing, shows an alert with installation instructions
- Offers to copy the install command or open Terminal
- Check is performed once per installation

**Manual Verification:**
```bash
# Test yfinance is installed
python3 -c "import yfinance; print('OK')"

# Update to latest version
pip3 install --upgrade yfinance
```

### Building the Application
- **Build in Xcode**: Open `Stockbar.xcodeproj` and build the `Stockbar` target
- **Target Platform**: macOS 15.4+, Swift 6.0, Bundle ID: `com.fhl43211.Stockbar`
- **Python Backend**: Ensure yfinance is installed (see Python Requirements above)

### Testing and Debugging
- **Test single stock**: `python3 Stockbar/Resources/get_stock_data.py AAPL`
- **Test multiple stocks**: `python3 Stockbar/Resources/get_stock_data.py AAPL GOOGL MSFT`
- **Update yfinance**: `pip3 install --upgrade yfinance`
- **View logs**: Check `~/Library/Application Support/com.fhl43211.Stockbar/stockbar.log` (with rotation to `.1.log` and `.2.log`) and Console.app for debug output
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

## v2.3.0 UI/UX Enhancement Features (Phase 1-4)

### Phase 1A: Menu Bar Display Enhancements

**Location**: [MenuBarDisplaySettings.swift](Stockbar/Models/MenuBarDisplaySettings.swift), [MenuBarFormattingService.swift](Stockbar/Services/MenuBarFormattingService.swift)

**Display Modes** (4 options):
1. **Compact**: `SYMBOL +X.XX%` - Space-saving format
2. **Expanded**: `SYMBOL $XXX.XX +X.XX%` - Full information display
3. **Minimal**: `SYMBOL ▲` - Symbol with indicator only
4. **Custom Template**: User-defined format with placeholders

**Template Placeholders**:
- `{symbol}` - Stock symbol (e.g., AAPL)
- `{price}` - Current price with currency
- `{change}` - Dollar change amount
- `{changePct}` - Percentage change
- `{currency}` - Currency code (USD, GBP, etc.)
- `{arrow}` - Directional indicator

**Change Format Options**:
- **Percentage**: `+2.51%`
- **Dollar**: `+$4.29`
- **Both**: `+$4.29 (2.51%)`

**Visual Customization**:
- **Decimal Places**: 0-4 (configurable precision)
- **Arrow Indicators**: None, Simple (▲▼), Bold (⬆⬇), Emoji (🟢🔴)
- **Arrow Position**: Before or after symbol
- **Currency Display**: Show/hide currency symbols
- **Color Coding**: Green (positive) / Red (negative) - respects existing setting

**Features**:
- Real-time validation with visual feedback (✓ valid / ⚠ warning)
- Live preview in preferences
- 5-second cache TTL for formatted strings (performance)
- Actor-based thread safety
- Settings persistence in UserDefaults

**UI Location**: Preferences → Portfolio tab → "Menu Bar Display" section

### Phase 1B: OHLC Data Infrastructure

**Location**: [get_stock_data.py](Stockbar/Resources/get_stock_data.py), [OHLCDataService.swift](Stockbar/Data/CoreData/OHLCDataService.swift), [NetworkService.swift](Stockbar/Data/Networking/NetworkService.swift)

**Python Script Enhancements**:
- New `--ohlc` flag for OHLC data fetching
- Batch OHLC support: `--batch-ohlc AAPL,GOOGL,MSFT 1mo 1d`
- Configurable periods: 1d, 5d, 1mo, 3mo, 6mo, 1y, 2y, 5y, 10y, ytd, max
- Configurable intervals: 1m, 2m, 5m, 15m, 30m, 60m, 90m, 1h, 1d, 5d, 1wk, 1mo, 3mo
- GBX to GBP conversion for UK stocks (.L suffix)

**Core Data Schema**:
- **OHLCSnapshotEntity** (Model Version 6):
  - timestamp: Date
  - symbol: String
  - open, high, low, close: Double
  - volume: Int64
- **Indexes**: bySymbol, byTimestamp, bySymbolAndTimestamp (performance)
- **Automatic Migration**: Lightweight migration from v5 to v6

**OHLCDataService Features**:
- Thread-safe actor-based operations
- Batch save operations for efficiency
- Duplicate prevention (1-minute minimum interval)
- Automatic cleanup (max 10,000 snapshots per symbol)
- Date range queries
- Latest snapshot retrieval

**NetworkService Integration**:
- `fetchOHLCData(symbol:period:interval:)` - Single symbol
- `fetchBatchOHLCData(symbols:period:interval:)` - Multiple symbols
- Timeout protection (2min single, 5min batch)
- Comprehensive logging with 📊 OHLC prefix
- JSON response parsing with error handling

### Phase 2: Advanced Charting & Technical Indicators

**Location**: [CandlestickChartView.swift](Stockbar/Charts/CandlestickChartView.swift), [VolumeChartView.swift](Stockbar/Charts/VolumeChartView.swift), [TechnicalIndicatorService.swift](Stockbar/Services/TechnicalIndicatorService.swift)

**Candlestick Charts** (493 lines):
- OHLC visualization with color-coded candles (green up, red down)
- Hollow/filled candle bodies
- High/low wicks
- Volume bars below chart
- Interactive time range selection (1D, 1W, 1M, 3M, 6M, 1Y)
- Hover tooltips with OHLC data
- Automatic chart scaling and formatting

**Technical Indicators** (8 indicators, 330 lines):
1. **SMA (Simple Moving Average)**: Configurable periods (20, 50, 200 day common)
2. **EMA (Exponential Moving Average)**: Fast-reacting MA (12, 26 day common)
3. **RSI (Relative Strength Index)**: Momentum oscillator (0-100 scale, 14-period default)
   - Overbought zone: >70
   - Oversold zone: <30
4. **MACD (Moving Average Convergence Divergence)**:
   - MACD line (12-26 EMA difference)
   - Signal line (9-period EMA of MACD)
   - Histogram (MACD - Signal)
   - Bullish/bearish crossover detection
5. **Bollinger Bands**:
   - Middle band (20-period SMA)
   - Upper/lower bands (2 standard deviations)
   - Bandwidth indicator
6. **Stochastic Oscillator**: %K and %D lines
7. **ATR (Average True Range)**: Volatility measurement
8. **OBV (On-Balance Volume)**: Volume-based momentum

**Volume Analysis** (420 lines):
- Standalone volume chart with bar visualization
- Color-coded bars (green up days, red down days)
- Average volume line indicator
- Volume profile analysis
- Volume-by-price histogram (horizontal)
- Statistics panel (total, average, max volume)

**Chart Integration**:
- Switchable chart types (Line, Candlestick, OHLC Bars, Area, Volume)
- Multi-indicator overlay support
- Time period selector (1D, 5D, 1M, 3M, 6M, 1Y, 5Y)
- Interval selector (1m, 5m, 15m, 1h, 1D, 1W)

**UI Location**: Preferences → Charts tab

### Phase 3: Risk Analytics Dashboard

**Location**: [RiskMetricsService.swift](Stockbar/Analytics/RiskMetricsService.swift) (410 lines), [RiskAnalyticsView.swift](Stockbar/Views/RiskAnalyticsView.swift) (665 lines)

**Risk Metrics Calculated** (7 comprehensive metrics):

1. **Value at Risk (VaR)**:
   - **95% Confidence**: Potential loss exceeded only 5% of the time
   - **99% Confidence**: Potential loss exceeded only 1% of the time
   - **Method**: Historical simulation using actual return distribution
   - **Display**: Absolute dollars and percentage of portfolio

2. **Sharpe Ratio**:
   - Risk-adjusted return measurement
   - Formula: (Portfolio Return - Risk-Free Rate) / Volatility
   - Annualized calculation (252 trading days)
   - Configurable risk-free rate (default: 4%)
   - **Interpretation**:
     - >2.0: Exceptional
     - 1.0-2.0: Very Good
     - 0.5-1.0: Good
     - 0-0.5: Adequate
     - <0: Poor

3. **Sortino Ratio**:
   - Downside risk-adjusted return
   - Only considers negative returns (downside deviation)
   - Typically higher than Sharpe ratio
   - Better measure for asymmetric return distributions

4. **Beta** (Market Correlation):
   - Measures systematic risk vs. benchmark (S&P 500)
   - Beta = 1.0: Moves with market
   - Beta > 1.0: More volatile than market
   - Beta < 1.0: Less volatile than market
   - Covariance and variance calculations

5. **Maximum Drawdown**:
   - Largest peak-to-trough decline
   - Duration tracking (days in drawdown)
   - Multiple drawdown period identification (>5% threshold)
   - Recovery time analysis
   - Current drawdown status

6. **Volatility**:
   - Annualized standard deviation of returns
   - Rolling volatility (30-day, 60-day, 90-day)
   - Comparison to market volatility

7. **Downside Deviation**:
   - Volatility of negative returns only
   - Excludes positive returns from calculation
   - Used in Sortino ratio

**Risk Dashboard UI**:
- 8 metric cards in grid layout with color-coded values
- VaR visualization (95% vs 99% comparison chart)
- Risk-adjusted returns section (Sharpe/Sortino breakdown)
- Maximum drawdown analysis with duration
- Drawdown history table (top 5 periods >5%)
- Time range selection (1M, 3M, 6M, 1Y, All Time)
- Calculation methodology details
- Empty state and error handling
- Real-time calculation with loading states

**Technical Implementation**:
- Actor-based thread safety
- Statistical helper functions (mean, stddev, downside deviation)
- Comprehensive logging with detailed debug output
- Integration with HistoricalDataManager
- Async/await patterns throughout

**UI Location**: Preferences → Risk tab

### Phase 4: Portfolio Analytics & Diversification

**Location**: [CorrelationMatrixService.swift](Stockbar/Analytics/CorrelationMatrixService.swift) (392 lines), [SectorAnalysisService.swift](Stockbar/Analytics/SectorAnalysisService.swift) (340 lines), [PortfolioAnalyticsView.swift](Stockbar/Views/PortfolioAnalyticsView.swift) (583 lines)

**Correlation Analysis**:
- **N×N Correlation Matrix**: Pearson correlation coefficients between all stock pairs
- **Diversification Metrics**:
  - Average/max/min correlation tracking
  - Effective number of independent positions (Effective N)
  - Diversification ratio (portfolio vol / weighted avg vol)
  - Concentration score (Herfindahl index, 0-1 scale)
- **Correlation Insights**:
  - Top 5 highest correlated pairs (risk identification)
  - Top 5 lowest correlated pairs (diversification opportunities)
  - Color-coded correlation values (red high, green low)
- **Diversification Score** (0-100):
  - Formula combines correlation factor (40pts), concentration factor (30pts), effective N factor (30pts)
  - Risk levels: Low (70-100), Medium (50-69), High (0-49)

**Sector Analysis** (11 GICS Sectors):
1. Technology
2. Healthcare
3. Financials
4. Consumer Cyclical
5. Consumer Defensive
6. Industrials
7. Energy
8. Utilities
9. Real Estate
10. Basic Materials
11. Communication Services

**Sector Allocation Features**:
- **Pie Chart**: Color-coded sectors with percentage breakdown
- **Sector Breakdown Table**:
  - Total value per sector
  - Percentage of portfolio
  - Day change ($ and %)
  - Circle indicators matching pie chart colors
- **Industry Breakdown**: Sub-sector classification within each GICS sector
- **Symbol-to-Sector Mapping**: 100+ common stocks pre-mapped
- **Unknown Symbol Handling**: Defaults to "Unknown" sector

**Diversification Recommendations**:
- **Top-Heavy Sector Detection**: Warns if any sector >25% of portfolio
- **Missing Sector Suggestions**: Recommends diversification into underrepresented sectors
- **Concentration Risk Assessment**: Low/Medium/High with explanations
- **Actionable Insights**: Specific stocks to consider for better balance

**Portfolio Analytics Dashboard**:
- Sector allocation pie chart and table
- Diversification analysis with score and recommendations
- Correlation matrix summary (matrix calculated, heatmap simplified for performance)
- Correlation insights (highest/lowest pairs)
- Time range selection (1M, 3M, 6M, 1Y, All Time)
- Empty state for <2 stocks
- Metric cards with tooltips
- Color coding throughout (green/red/orange)

**Technical Implementation**:
- Actor-based thread safety for all calculations
- Pearson correlation algorithm
- Herfindahl concentration index
- Sector performance attribution
- Integration with historical data for time-series analysis

**UI Location**: Preferences → Analytics tab

### Performance & Quality

**Performance Targets**:
- CPU usage: <5% average (meets target)
- Memory footprint: <200 MB (meets target)
- Chart rendering: <100ms (60 FPS)
- Menu bar update: <50ms (feels instant)
- Risk calculation: <1s for 50-stock portfolio

**Testing Coverage**:
- **Unit Tests**: 1,685 lines, 80+ test methods
  - RiskMetricsServiceTests (406 lines, 17 tests)
  - TechnicalIndicatorServiceTests (394 lines, 19 tests)
  - MenuBarFormattingServiceTests (480 lines, 23 tests)
  - PortfolioAnalyticsServicesTests (405 lines, 21 tests)
- **Manual Testing**: 57 comprehensive test scenarios
- **Performance Monitoring**: Scripts/measure_performance.sh

**Code Quality**:
- Swift 6.0 concurrency patterns throughout
- Actor isolation for thread safety
- Comprehensive error handling
- Extensive logging with context
- No memory leaks (weak self patterns)
- Clean build with zero errors

## Data Storage & Backup

Stockbar stores data in three locations with different purposes:

### 1. UserDefaults (`~/Library/Preferences/com.fhl43211.Stockbar.plist`)
**Contains:**
- Portfolio configuration (trades with symbol, units, avg cost, currency)
- App preferences (color coding, preferred currency, menu bar display settings)
- Last refresh timestamps and cache coordination data

**Backup:**
```bash
defaults export com.fhl43211.Stockbar ~/Desktop/stockbar_prefs.plist
```

**Restore:**
```bash
defaults import com.fhl43211.Stockbar ~/Desktop/stockbar_prefs.plist
```

### 2. Core Data (`~/Library/Application Support/Stockbar/StockbarDataModel.sqlite`)
**Contains:**
- Historical price snapshots (PriceSnapshotEntity)
- Portfolio value history (PortfolioSnapshotEntity)
- OHLC candlestick data (OHLCSnapshotEntity)
- Typical size: ~85-100 MB with full history

**Files:**
- `StockbarDataModel.sqlite` - Main database file
- `StockbarDataModel.sqlite-wal` - Write-ahead log (SQLite WAL mode)
- `StockbarDataModel.sqlite-shm` - Shared memory file

**Backup:**
```bash
cp -r ~/Library/Application\ Support/Stockbar/StockbarDataModel.sqlite* ~/Desktop/
```

### 3. Configuration File (`~/Documents/.stockbar_config.json`)
**Contains:**
- FMP API key (plain-text JSON)

**Format:**
```json
{
  "FMP_API_KEY": "your_api_key_here"
}
```

**Security Note:** API keys are stored in plain-text for convenience. The data accessed (stock prices) is not sensitive.

### Automated Backup Scripts

Complete backup/restore scripts are available in `Scripts/`:

**Create Complete Backup:**
```bash
cd Scripts
./backup_stockbar_data.sh
```

**Restore from Backup:**
```bash
cd Scripts
./restore_stockbar_data.sh stockbar_complete_backup_2025-10-03_103443
```

See `Scripts/README.md` for detailed documentation.
