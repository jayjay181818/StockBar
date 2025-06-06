# StockBar

StockBar is a comprehensive macOS menu bar application for tracking stock portfolio performance in real-time. It displays individual stock day gains/losses directly in the menu bar and provides detailed portfolio analysis through an advanced preferences interface with interactive charts and debugging capabilities.

## Features

### Portfolio Management
- **Real-time Portfolio Tracking**: Monitor day gains/losses for each stock position
- **Multi-currency Support**: Automatic handling of USD, GBP, and GBX currencies
- **Net Portfolio Value**: Real-time calculation of total portfolio market value
- **Total Net Gains**: Aggregated gains/losses across all positions
- **Persistent Data**: Retains last successful stock data across app restarts
- **Smart Caching**: Intelligent refresh intervals (15 minutes) with failure retry (5 minutes)

### Interactive Charts & Analytics
- **Performance Charts**: Interactive line and area charts with Swift Charts framework
- **Multiple Chart Types**: Portfolio Value, Portfolio Gains, Individual Stock Performance
- **Time Range Selection**: 1 Day, 1 Week, 1 Month, 3 Months, 6 Months, 1 Year, All Time
- **Hover Tooltips**: Interactive data point inspection showing exact values, dates, and times
- **Performance Metrics**: Volatility analysis, total returns, percentage changes, and value ranges
- **Historical Data Collection**: Automatic 5-minute snapshots with 1000 data point limits
- **Auto-Expanding Interface**: Dynamic window resizing for optimal chart viewing

### User Interface
- **Menu Bar Integration**: Individual status items for each tracked stock
- **Dedicated Preferences Window**: Full-featured window interface replacing dropdown menus
- **Tabbed Interface**: Portfolio management, Charts, and Debug tabs
- **Keyboard Shortcuts**: ⌘, for quick preferences access
- **Color Coding**: Optional green/red indicators for gains/losses
- **Auto-Scroll Charts**: Smooth navigation to latest data points

### Developer Tools
- **Real-time Debug Console**: Live application logs with color-coded severity levels
- **Log Management**: Auto-refresh, configurable line limits, and log clearing
- **File Logging**: Persistent logs saved to disk for troubleshooting
- **Network Monitoring**: Detailed API call tracking and error reporting
- **Performance Tracking**: Data refresh timing and cache hit/miss analysis

### Reliability & Performance
- **Offline Resilience**: Shows last known data when network is unavailable
- **Intelligent Caching**: Time-based caching with automatic cache invalidation
- **Graceful Degradation**: Maintains functionality during network outages
- **Error Recovery**: Automatic retry logic with exponential backoff

## Architecture

StockBar uses a modern hybrid architecture combining Swift and Python with comprehensive data management:

### Frontend (Swift)
- **AppKit & SwiftUI**: Native macOS UI with declarative interface components
- **Swift Charts Framework**: High-performance interactive charting with hover support
- **Combine Framework**: Reactive data flow and real-time UI updates
- **MVVM Pattern**: Clean separation between data models and user interface
- **NSWindow Management**: Advanced window handling with automatic resizing

### Backend & Data
- **Python Integration**: Data fetching using `yfinance` library via subprocess
- **Historical Data Manager**: Singleton service for chart data collection and persistence
- **Multi-Layer Storage**: UserDefaults for configuration, file system for historical data
- **Logger System**: Comprehensive file-based logging with real-time console viewing

### Performance & Reliability
- **Intelligent Caching**: Time-based caching with failure retry mechanisms
- **Data Persistence**: Automatic snapshot recording every 5 minutes
- **Memory Management**: Efficient data structures with configurable limits
- **Error Handling**: Graceful degradation with comprehensive error reporting

## Building

### Prerequisites
1. **macOS Development Environment**: Xcode 12.0 or later
2. **Python 3**: With `yfinance` library installed
   ```bash
   pip3 install yfinance
   ```

### Build Steps
1. Clone the repository
2. Open `Stockbar.xcodeproj` in Xcode
3. Build and run the `Stockbar` target

## How it works

### Data Flow
1. **Swift Application**: Manages menu bar UI, user preferences, and data persistence
2. **Python Script**: `Resources/get_stock_data.py` fetches real-time stock data using yfinance
3. **Caching Layer**: Intelligent caching reduces API calls and handles Yahoo Finance rate limits
4. **Persistent Storage**: Last successful data is saved and restored across app sessions

### Currency Handling
- **USD Stocks**: Displayed as-is
- **UK Stocks (.L suffix)**: Automatically converted from GBX (pence) to GBP (pounds)
- **Multi-currency Portfolios**: Converted to preferred currency for total calculations

### Network Resilience
- **Successful Fetches**: Data cached for 15 minutes
- **Failed Fetches**: Retry after 5 minutes, retain last known good data
- **Offline Mode**: Shows last successful data with original timestamps

## Usage

### Initial Setup
1. Launch the application
2. Click the "StockBar" menu bar item
3. Select "Preferences" (or press ⌘,) to open the preferences window
4. In the **Portfolio** tab:
   - Add stock symbols using the "+" button
   - Enter number of units and average cost for each position
   - Configure your preferred currency and color coding preferences
5. Switch to the **Charts** tab to view performance analytics once data is collected

### Portfolio Management (Portfolio Tab)
- **Add Stocks**: Use "+" button to add new positions
- **Edit Positions**: Modify units and average costs directly in the table
- **Remove Stocks**: Use "-" button to remove positions
- **Total Net Gains**: View aggregated gains/losses across all positions
- **Net Portfolio Value**: See current market value of entire portfolio
- **Currency Settings**: Choose preferred display currency
- **Exchange Rate Updates**: Manual refresh of currency conversion rates

### Performance Analysis (Charts Tab)
- **Chart Types**: Switch between Portfolio Value, Portfolio Gains, and Individual Stock charts
- **Time Ranges**: Select from 1 Day to All Time views
- **Interactive Tooltips**: Hover over chart points to see exact values, dates (DD/MM/YY), and times (HH:MM)
- **Performance Metrics**: Expand section to view detailed analytics including:
  - Total return amounts and percentages
  - Portfolio volatility analysis
  - Value ranges (min/max) for selected time period
- **Auto-Resizing**: Window automatically adjusts height when expanding/collapsing metrics

### Debug & Troubleshooting (Debug Tab)
- **Real-Time Logs**: View live application logs with automatic refresh
- **Log Controls**: 
  - Toggle auto-refresh (updates every 2 seconds)
  - Adjust maximum displayed lines (100-2000)
  - Manual refresh and clear functions
- **Color-Coded Messages**: Easy identification of errors (red), warnings (orange), info (blue), and debug (gray) messages
- **Log File Access**: Copy log file path for external analysis
- **Network Monitoring**: Track API calls, cache hits/misses, and error conditions

### Daily Use
- **Menu Bar Display**: Each stock shows as "SYMBOL +/-X.XX" indicating day gain/loss
- **Detailed View**: Click any stock item to see comprehensive position information
- **Quick Access**: Use ⌘, keyboard shortcut to open preferences instantly
- **Manual Refresh**: Use "Refresh" option in the main StockBar menu
- **Chart Monitoring**: Check Charts tab periodically to analyze portfolio performance trends

### Supported Stock Formats
- **US Stocks**: `AAPL`, `GOOGL`, `MSFT`
- **UK Stocks**: `TSLA.L`, `BP.L`, `SHEL.L` (automatically converted from GBX to GBP)
- **Other Markets**: Most Yahoo Finance supported symbols

## Technical Details

### Refresh Intervals
- **Normal Operation**: 15-minute intervals for successful stocks
- **Failure Recovery**: 5-minute retry intervals for failed fetches
- **Cache Duration**: 15 minutes for successful data, 1 hour maximum age

### Data Persistence
- **User Configuration**: Stock symbols, units, average costs, currency preferences
- **Stock Data**: Last successful prices, timestamps, currency information
- **Storage Location**: macOS UserDefaults system

### Error Handling
- **Network Failures**: Graceful degradation showing last known data
- **Rate Limiting**: Intelligent caching and retry logic
- **Invalid Symbols**: Clear error indication in menu items
- **Python Script Errors**: Fallback to cached data with error logging

## Troubleshooting

### Built-in Debug Tools
StockBar now includes comprehensive debugging capabilities:

1. **Access Debug Tab**: Open Preferences (⌘,) → Debug tab
2. **Real-Time Monitoring**: Watch live logs to see exactly what the app is doing
3. **Error Identification**: Color-coded logs make it easy to spot issues:
   - 🔴 **Red**: Critical errors requiring attention
   - 🟠 **Orange**: Warnings about potential issues
   - 🔵 **Blue**: Informational messages about normal operations
   - ⚪ **Gray**: Detailed debug information
4. **Log Analysis**: Use log file path to examine historical issues
5. **Network Diagnostics**: Monitor API calls, cache performance, and retry attempts

### Common Issues & Solutions

#### Data Problems
- **"N/A" Prices**: Check Debug tab for network errors, verify internet connection and Python/yfinance installation
- **Missing Charts**: Ensure data collection has run for sufficient time (minimum 2 data points needed)
- **Stale Data**: Check Debug tab for refresh failures, verify Yahoo Finance API accessibility

#### Performance Issues
- **Slow Charts**: Reduce "Max Lines" in Debug tab, check for excessive log output
- **High CPU Usage**: Monitor Debug tab for excessive API calls or infinite refresh loops
- **Memory Issues**: Clear historical data in Charts tab if datasets become too large

#### Network & API Issues
- **Rate Limiting**: Debug tab will show "429" errors, wait for automatic retry (5 minutes) or manually refresh later
- **Currency Issues**: Ensure UK stocks use .L suffix, check Debug tab for conversion errors
- **Invalid Symbols**: Debug tab will show fetch failures for non-existent symbols

### Advanced Debugging
- **Log File Location**: Available in Debug tab for external analysis tools
- **Python Script Testing**: `python3 Resources/get_stock_data.py AAPL`
- **Dependency Updates**: `pip3 install --upgrade yfinance`
- **Cache Inspection**: Debug tab shows cache hit/miss ratios and expiration times
- **Performance Metrics**: Monitor refresh timing and API response times in logs

### When to Contact Support
- Persistent errors in Debug tab that don't resolve after app restart
- Charts showing incorrect data despite successful API calls in logs
- Application crashes (check Debug log file for crash details)
- Performance issues not explained by Debug tab monitoring

## Contributing

This project uses modern Swift development practices and advanced macOS technologies:

### Development Stack
- **Swift 5**: Latest language features and performance optimizations
- **SwiftUI + AppKit**: Hybrid UI approach combining declarative and imperative paradigms
- **Swift Charts**: Native charting framework for high-performance data visualization
- **Combine Framework**: Reactive data binding and asynchronous operations
- **MVVM Architecture**: Clean separation between models, views, and business logic

### Code Organization
- **Protocol-Oriented Design**: Testable and maintainable interfaces
- **Singleton Pattern**: Shared services (Logger, HistoricalDataManager) for data consistency
- **Comprehensive Error Handling**: Graceful failure modes with detailed logging
- **Memory Management**: Efficient data structures with automatic cleanup
- **Concurrent Programming**: Async/await patterns for network operations

### Quality Assurance
- **Real-Time Debugging**: Built-in logging and monitoring capabilities
- **Performance Monitoring**: Automatic tracking of refresh timing and cache efficiency
- **Error Tracking**: Comprehensive error reporting with context preservation
- **User Experience Testing**: Interactive tooltips and responsive UI components

### Development Guidelines
- **Logging**: Use `Logger.shared` for all diagnostic output
- **Data Management**: Leverage `HistoricalDataManager` for chart data persistence
- **UI Updates**: Ensure all UI modifications occur on main thread
- **Error Handling**: Always provide fallback behavior and user-friendly error messages
- **Performance**: Monitor Debug tab during development to catch performance regressions

## License

[Add your license information here]
