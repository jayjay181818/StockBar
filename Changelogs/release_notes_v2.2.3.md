# Stockbar v2.2.3 Release Notes

**Release Date:** June 9, 2025  
**Build:** v2.2.3  
**Platform:** macOS 15.4+

## 🎯 Major Features

### 📊 Individual Stock Performance Analytics
**Transform your stock analysis experience with dedicated individual stock metrics**

- **Stock-Specific Performance Metrics**: When viewing individual stock charts, performance metrics now show stock-specific data instead of portfolio-level statistics
- **Comprehensive Stock Analysis Panel**: New detailed analysis section for individual stocks including:
  - Current stock price with real-time day change and percentage
  - Period-specific return calculations for selected time ranges (1D, 1W, 1M, 3M, 6M, 1Y, All)
  - Your position details: shares owned, position gain/loss
  - Average cost per share analysis
  - Current market value of your holdings
  - Stock-specific volatility calculations
- **Smart Chart Type Detection**: Automatically switches between portfolio and individual stock analytics based on chart selection
- **Time Range Aware**: All metrics dynamically update based on selected time period

### 🕒 Enhanced Pre/Post Market Data Support
**Access extended trading hours data for better market insights**

- **Extended Trading Hours**: Now captures pre-market (4:00 AM - 9:30 AM ET) and after-hours (4:00 PM - 8:00 PM ET) trading data
- **Multi-Fallback Data Retrieval**: Enhanced reliability with three-tier data fetching:
  1. **fast_info API** - Most current real-time prices
  2. **Intraday history with extended hours** - Backup with pre/post market data
  3. **Daily close data** - Final fallback for maximum reliability
- **Improved Previous Close Calculation**: More accurate previous close values using 2-day daily history
- **Enhanced Error Handling**: Graceful degradation when data sources are unavailable

## 🔧 Technical Improvements

### 🏗️ Infrastructure Enhancements
- **Performance Optimizations**: Improved data fetching algorithms for better responsiveness
- **Memory Management**: Enhanced memory efficiency in chart data processing
- **Error Recovery**: Improved error handling and logging throughout the application
- **Code Quality**: Comprehensive refactoring for better maintainability

### 📈 Chart System Improvements
- **Dynamic Metrics Switching**: Seamless transition between portfolio and stock-specific analytics
- **Enhanced Currency Handling**: Better support for multi-currency portfolios with proper conversion
- **Improved Data Validation**: Robust validation for price data and calculations
- **Visual Consistency**: Unified chart styling and layout improvements

## 🐛 Bug Fixes

### 📊 Chart Analytics Fixes
- **Fixed Variable Scope Issues**: Resolved compilation errors in individual stock analysis sections
- **Currency Display Consistency**: Fixed currency formatting issues in stock-specific views
- **Performance Metrics Accuracy**: Corrected calculation errors in individual stock volatility and returns

### 🔄 Data Processing Improvements
- **Rate Limiting Handling**: Better management of API rate limits with improved fallback mechanisms
- **Data Validation**: Enhanced validation for stock price data to prevent display of invalid values
- **Cache Management**: Improved caching strategies for better performance and reliability

## 💱 Currency & Market Support

### 🌍 Enhanced Multi-Market Support
- **LSE Stock Improvements**: Better handling of London Stock Exchange securities with proper GBP conversion
- **Currency Detection**: Improved automatic currency detection for different market symbols
- **Exchange Rate Integration**: Enhanced currency conversion with real-time exchange rates

## 🔧 Developer Experience

### 🛠️ Build & Development
- **Clean Build Process**: Removed build artifacts from version control for cleaner repository
- **Development Tools**: Improved debugging capabilities and logging infrastructure
- **Code Organization**: Better separation of concerns between chart types and analytics

## 📱 User Experience

### 🎨 Interface Improvements
- **Contextual Analytics**: Charts now show relevant metrics based on what you're analyzing
- **Information Density**: More comprehensive data presentation without overwhelming the interface
- **Responsive Design**: Better handling of different data states and loading conditions

### 🚀 Performance
- **Faster Data Loading**: Optimized data fetching with improved caching strategies
- **Reduced API Calls**: Smarter data management to minimize unnecessary network requests
- **Memory Efficiency**: Better memory usage patterns for large datasets

## 🔍 What's New for Users

### 📊 For Portfolio Analysis
- Switch to individual stock charts to see stock-specific performance metrics
- Analyze individual stock volatility and returns over custom time periods
- View your specific position details for each stock
- Compare stock performance across different time ranges

### 🕒 For Real-Time Trading
- Access pre-market and after-hours pricing data
- Get more reliable price updates with multiple data source fallbacks
- Better previous close calculations for accurate day change percentages

### 💼 For Multi-Currency Portfolios
- Improved currency handling for international stock holdings
- Better support for LSE stocks with proper GBX/GBP conversions
- Enhanced exchange rate management

## 🔗 Technical Details

### 🛠️ API & Data Sources
- **yfinance Integration**: Enhanced integration with multiple fallback methods
- **Financial Modeling Prep**: Improved FMP API usage for backup data
- **Rate Limit Management**: Better handling of API limitations with graceful degradation

### 📊 Analytics Engine
- **Stock-Specific Calculations**: New calculation engine for individual stock metrics
- **Volatility Analysis**: Advanced volatility calculations using standard deviation of returns
- **Performance Metrics**: Comprehensive performance analysis for both portfolio and individual stocks

## 🔄 Migration Notes

This release is fully backward compatible with existing portfolios and preferences. No manual migration is required.

### ⚠️ Important Notes
- Pre/post market data availability depends on your data provider and market conditions
- Some extended hours data may not be available for all international markets
- Individual stock analytics require sufficient historical data for accurate calculations

## 🚀 Getting Started

### New Users
1. Add your stock positions in Preferences
2. Navigate to the Charts tab
3. Select individual stocks to see detailed analytics
4. Use time range selectors to analyze different periods

### Existing Users
1. Update to v2.2.3 to access new features automatically
2. Open Charts and select individual stocks to see the new analytics
3. Explore pre/post market data during extended trading hours

---

**Download:** Available through the Stockbar update system or from GitHub releases  
**System Requirements:** macOS 15.4 or later  
**Dependencies:** Python 3.9+ with yfinance package

For support, feedback, or bug reports, please visit our [GitHub repository](https://github.com/your-repo/stockbar) or contact support through the application.