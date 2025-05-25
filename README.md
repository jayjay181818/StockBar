# StockBar

StockBar is a macOS menu bar application for tracking stock portfolio performance in real-time. It displays individual stock day gains/losses directly in the menu bar and provides detailed portfolio information through contextual menus.

## Features

- **Real-time Portfolio Tracking**: Monitor day gains/losses for each stock position
- **Multi-currency Support**: Automatic handling of USD, GBP, and GBX currencies
- **Persistent Data**: Retains last successful stock data across app restarts
- **Smart Caching**: Intelligent refresh intervals (15 minutes) with failure retry (5 minutes)
- **Menu Bar Integration**: Individual status items for each tracked stock
- **Detailed Information**: Click any stock for comprehensive position details
- **Color Coding**: Optional green/red indicators for gains/losses
- **Total Portfolio View**: Aggregated net gains calculation in preferences
- **Offline Resilience**: Shows last known data when network is unavailable

## Architecture

StockBar uses a hybrid architecture combining Swift and Python:

- **Swift Frontend**: Native macOS UI using AppKit and Combine for reactive data flow
- **Python Backend**: Data fetching script using the `yfinance` library
- **Persistent Storage**: UserDefaults for configuration and last successful stock data
- **Intelligent Caching**: Time-based caching to minimize API requests and handle rate limiting

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
3. Select "Preferences" to open the configuration panel
4. Add stock symbols using the "+" button
5. Configure your preferred currency and color coding preferences

### Daily Use
- **Menu Bar Display**: Each stock shows as "SYMBOL +/-X.XX" indicating day gain/loss
- **Detailed View**: Click any stock item to see comprehensive position information
- **Portfolio Summary**: Access total net gains through the preferences panel
- **Manual Refresh**: Use "Refresh" option in the main StockBar menu

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

### Common Issues
1. **"N/A" Prices**: Check internet connection and Python/yfinance installation
2. **Rate Limiting**: Wait for automatic retry (5 minutes) or manually refresh later
3. **Currency Issues**: Ensure UK stocks use .L suffix for proper GBX/GBP conversion
4. **Missing Data**: Verify stock symbols are valid on Yahoo Finance

### Debug Information
- Check Console.app for StockBar log messages
- Verify Python script execution: `python3 Resources/get_stock_data.py AAPL`
- Ensure yfinance is up to date: `pip3 install --upgrade yfinance`

## Contributing

This project uses modern Swift development practices:
- **Combine Framework**: For reactive data binding
- **MVVM Architecture**: Clean separation of concerns
- **Protocol-Oriented Design**: Testable and maintainable code structure
- **Comprehensive Error Handling**: Graceful failure modes

## License

[Add your license information here]
