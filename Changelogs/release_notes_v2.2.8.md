# Stockbar v2.2.8 Release Notes

**Release Date**: June 23, 2025  
**Version**: 2.2.8  
**Previous Version**: 2.2.7  

## 🎯 Overview

Stockbar v2.2.8 introduces comprehensive menu bar chart enhancements with improved data visualization, pre/post market support, and refined user experience. This release focuses on providing accurate, real-time price charts directly in the menu bar with intelligent data handling and professional visual design.

---

## ✨ Major New Features

### 📊 **Interactive Menu Bar Price Charts**
- **Real-Time Charts**: Live price charts displayed directly in each stock's menu bar dropdown
- **Time Period Toggles**: Quick switching between 1 Day, 1 Week, and 1 Month views
- **Pre/Post Market Support**: Charts include pre-market and after-hours price data when available
- **Hover Interactions**: Interactive data point selection with detailed price and timestamp information
- **Professional Design**: Rounded corners and polished visual styling that matches macOS design language

### 📈 **Enhanced Data Visualization**
- **Smart Y-Axis Scaling**: Automatic ±5% buffer around actual price range for better movement visibility
- **Intelligent Time Formatting**: Context-aware time labels (HH:mm for daily, MMM d for weekly/monthly)
- **Color-Coded Charts**: Dynamic chart colors (green/red) based on price movement direction
- **Centered Header Layout**: Ticker symbol and price information positioned to avoid corner clipping
- **Clean Empty States**: Informative messages distinguishing between missing data and invalid prices

### 🔧 **Data Management Improvements**
- **Real Data Priority**: Charts use actual historical price snapshots when available
- **Simplified Fallback**: When insufficient data exists, charts display clean straight lines instead of mock data
- **Price Validation**: Robust validation prevents charts from displaying with invalid or NaN price data
- **Memory Efficient**: Lightweight chart data structures optimized for menu bar integration
- **Consistent Display**: Same symbol always shows identical chart pattern based on real data

---

## 🔧 Performance & User Experience Improvements

### ⚡ **Chart Performance Optimizations**
- **Fixed Size Containers**: Consistent 280×200px chart dimensions prevent sizing issues
- **Efficient Rendering**: Optimized SwiftUI Charts integration with minimal memory footprint
- **Smooth Interactions**: Responsive time period switching without lag or flickering
- **Proper Layout**: Fixed horizontal overflow and sizing inconsistencies on first display
- **AppKit Integration**: Seamless NSHostingView wrapper for stable menu integration

### 🖥️ **Visual Design Enhancements**
- **32px Corner Radius**: Perfectly balanced rounded corners for professional appearance
- **Centered Content**: Symbol and price information centered to avoid corner radius clipping
- **Proper Spacing**: Optimized layout with appropriate padding and component spacing
- **Consistent Styling**: Charts match overall app design language and menu bar aesthetics
- **Adaptive Colors**: Chart colors automatically adapt to system appearance preferences

### 📊 **Chart Data Intelligence**
- **Historical Data Integration**: Seamless integration with existing HistoricalDataManager
- **Market State Awareness**: Charts properly handle different market states (open, pre, post, closed)
- **Currency Support**: Full support for multi-currency portfolios including UK stocks (GBX/GBP)
- **Data Validation**: Comprehensive validation prevents display of invalid or corrupt price data
- **Error Handling**: Graceful handling of network failures and missing data scenarios

---

## 🐛 Bug Fixes

### Chart Display Issues
- **Fixed**: Menu bar charts displaying different patterns on multiple clicks (eliminated random mock data)
- **Fixed**: Horizontal overflow causing chart content to be cut off on first display
- **Fixed**: Inconsistent chart sizing between first and subsequent menu opens
- **Fixed**: Y-axis scaling showing inappropriate ranges (e.g., 0-200 for $112 stock)
- **Fixed**: Time labels showing "00" values instead of proper time formatting
- **Fixed**: Symbol and price text being clipped by rounded corners

### Data Handling Improvements
- **Fixed**: Charts showing gains/returns instead of actual stock prices
- **Fixed**: US stocks not displaying charts when pre/post market data unavailable
- **Fixed**: Mock data causing inconsistent chart appearances between views
- **Fixed**: Invalid price data (NaN) causing blank or broken chart displays
- **Fixed**: Missing validation for edge cases with insufficient historical data

### User Interface Fixes
- **Fixed**: Double outline appearance with overlapping chart containers
- **Fixed**: Menu bar charts not reflecting pre-market and after-hours pricing
- **Fixed**: Corner radius appearing "cut off" rather than properly rounded
- **Fixed**: Chart container sizing issues preventing proper layout
- **Fixed**: Time range selection not persisting correctly between menu opens

---

## 🔧 Technical Improvements

### Architecture Enhancements
- **SwiftUI Charts Integration**: Native Swift Charts framework for optimal performance
- **NSHostingView Wrapper**: Proper AppKit integration for menu bar embedding
- **MenuPriceChartView Component**: Dedicated SwiftUI component for menu bar charts
- **Real-Time Data Binding**: Reactive data flow using Combine publishers
- **Modular Design**: Clean separation between chart logic and menu bar integration

### Code Quality
- **Removed Mock Data**: Eliminated all random data generation for consistent chart display
- **Enhanced Validation**: Comprehensive price data validation before chart rendering
- **Memory Management**: Proper resource cleanup and efficient data structures
- **Error Handling**: Robust error handling with informative user feedback
- **Performance Optimization**: Optimized chart rendering with minimal resource usage

### Development Infrastructure
- **Enhanced Logging**: Detailed chart data logging for debugging and monitoring
- **Debug Information**: Comprehensive logging of data sources and chart generation
- **Component Testing**: Improved testability with modular chart components
- **Documentation**: Updated architecture documentation with chart integration details

---

## 🔄 Migration & Compatibility

### Automatic Enhancements
- **Seamless Integration**: Charts automatically appear in existing stock menu items
- **Historical Data**: Existing price snapshots immediately available for chart display
- **Preference Preservation**: All existing user settings and preferences maintained
- **Performance**: No impact on existing app performance or functionality

### Backward Compatibility
- **Data Preservation**: All existing historical data continues to work with new charts
- **Settings Compatibility**: Previous configuration settings remain unchanged
- **Gradual Enhancement**: Charts enhance existing functionality without disrupting workflow
- **Optional Usage**: Charts appear automatically but don't affect users who prefer text-only menus

---

## 🚀 Installation & Upgrade

### System Requirements
- **macOS**: 15.4 or later
- **Python**: 3.9+ (required for stock data fetching)
- **Dependencies**: `yfinance` package (`pip3 install yfinance`)
- **Graphics**: Minimal GPU requirements for SwiftUI Charts rendering

### Upgrade Notes
- **Immediate Availability**: Charts appear automatically after upgrade
- **No Configuration**: Charts work out-of-the-box with existing portfolio setup
- **Historical Data**: Charts utilize existing historical data immediately
- **Performance**: Minimal additional memory usage with new chart functionality

---

## 🔍 Usage & Features

### Chart Interaction
- **Time Period Selection**: Click 1D, 1W, or 1M buttons to change chart timeframe
- **Data Point Hover**: Click anywhere on the chart to see specific price and time details
- **Market State Indicators**: Visual indicators for pre-market, after-hours, and closed market states
- **Real-Time Updates**: Charts automatically update when new price data arrives
- **Professional Styling**: Clean, modern design that integrates seamlessly with macOS

### Data Intelligence
- **Smart Scaling**: Charts automatically scale to show meaningful price movements
- **Currency Awareness**: Proper handling of different currencies including UK stocks
- **Market Hours**: Automatic inclusion of pre-market and after-hours data when available
- **Data Validation**: Charts only display when valid price data is available
- **Fallback Handling**: Informative messages when charts cannot be displayed

---

## 🧪 Testing Recommendations

### Critical Test Scenarios
1. **Chart Display**: Verify charts appear correctly in all stock menu items
2. **Time Period Switching**: Test 1D/1W/1M toggle functionality and data accuracy
3. **Data Consistency**: Confirm same stock shows identical chart on multiple views
4. **Market State Handling**: Test chart behavior during pre/post market hours
5. **Multi-Currency**: Verify proper chart display for different currency stocks

### Success Criteria
- ✅ Charts display consistently without random variations
- ✅ Time period toggles work smoothly with appropriate data ranges
- ✅ Y-axis scaling shows meaningful price movements
- ✅ Pre/post market data included when available
- ✅ Professional appearance with proper rounded corners and layout

---

## 🔮 What's Next

### Upcoming Chart Enhancements
- **Volume Indicators**: Add trading volume data to price charts
- **Technical Indicators**: Moving averages and basic technical analysis
- **Zoom and Pan**: Enhanced interaction capabilities for detailed analysis
- **Chart Themes**: Customizable chart appearance and color schemes

### Long-term Chart Features
- **Historical Comparisons**: Side-by-side chart comparisons between stocks
- **Performance Overlays**: Portfolio performance overlays on individual stock charts
- **Export Functionality**: Save chart images and data for external analysis
- **Advanced Analytics**: Integration with portfolio analytics and risk metrics

---

## 👥 Contributors

### Development Team
- **UI/UX Design**: Menu bar chart integration and visual design
- **Data Integration**: Historical data connection and real-time updates
- **Performance Optimization**: Chart rendering efficiency and memory management

### Special Thanks
- Users providing feedback on chart functionality and design preferences
- Beta testers helping identify data consistency and display issues
- Community members suggesting improved market hours support

---

## 📞 Support & Feedback

### Getting Help
- **GitHub Issues**: Report chart-related bugs at [repository issues page]
- **Documentation**: Updated chart usage guides in project documentation
- **Debug Information**: Chart debug logs available at `~/Documents/stockbar.log`

### Feedback Channels
- **Chart Features**: Submit enhancement requests for additional chart functionality
- **Data Issues**: Report any chart data accuracy or display problems
- **Performance**: Share feedback on chart responsiveness and integration

---

**Full Changelog**: [View detailed changes on GitHub]

*For technical implementation details, see:*
- `CLAUDE.md` - Updated architecture documentation including chart integration
- `MenuPriceChartView.swift` - Complete chart component implementation
- Chart integration documentation in StockStatusBar.swift