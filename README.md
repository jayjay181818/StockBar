# StockBar

**Version 2.2.9** | **macOS 15.4+** | **Swift 6.0**

StockBar is a high-performance macOS menu bar application for real-time stock portfolio monitoring. It combines advanced data visualization, intelligent caching, and comprehensive debugging tools to provide professional-grade portfolio tracking directly in your menu bar.

## ✨ Key Features

### 🎯 Real-Time Portfolio Tracking
- **Individual Stock Display**: Each stock shows live day gains/losses in the menu bar
- **Drag-and-Drop Reordering**: Customize stock order in Portfolio preferences tab
- **Multi-Currency Support**: Automatic USD, GBP, EUR, JPY, CAD, AUD handling
- **Smart UK Stock Detection**: Automatic GBX ↔ GBP conversion for London Exchange (.L) stocks
- **Intelligent Caching**: 5-minute refresh intervals with failure retry logic
- **Persistent Data**: Retains portfolio state and last successful data across app restarts

### 📊 Advanced Analytics & Charts
- **Interactive Performance Charts**: Built with Swift Charts framework for smooth 60fps rendering
- **Multiple Chart Types**: Portfolio Value, Portfolio Gains, Individual Stock Performance
- **Comprehensive Time Ranges**: 1 Day, 1 Week, 1 Month, 3 Months, 6 Months, 1 Year, All Time
- **Hover Tooltips**: Precise data point inspection with values, dates, and times
- **Performance Metrics**: Total returns, volatility analysis, value ranges with auto-calculated statistics
- **Historical Data Collection**: Automatic 5-minute snapshots with up to 5 years of data storage
- **Retroactive Portfolio Calculations**: Complete historical portfolio value reconstruction

### 🎛️ Professional User Interface
- **Native Menu Bar Integration**: Individual status items for each tracked stock with color coding
- **Interactive Menu Bar Charts**: Real-time price charts with 1D/1W/1M views in each stock's dropdown menu
- **Quick Status Menu Actions**: Preferences and Quit commands in every status menu with keyboard shortcuts
- **Tabbed Preferences Window**: Portfolio Management, Charts, and Debug tabs with responsive layout
- **Modern SwiftUI Design**: Adaptive interface with automatic window resizing and scrollable chart pickers
- **Pre/Post Market Indicators**: Visual indicators for market hours (🔆 pre-market, 🌙 after-hours, 🔒 closed)
- **Keyboard Shortcuts**: ⌘, for instant preferences access from any status menu
- **Accessibility Support**: Full VoiceOver and keyboard navigation support with enhanced chart picker labels

### 🔧 Developer-Grade Debugging
- **Real-Time Debug Console**: Live application logs with async Swift 6 actor-based logging
- **Advanced Log Management**: Auto-refresh, configurable line limits (100-2000), tail mode for large files
- **Color-Coded Severity**: Instant visual identification of errors, warnings, info, and debug messages
- **Performance Monitoring**: Network timing, cache efficiency, memory usage tracking
- **Export Capabilities**: One-click log file access for detailed analysis

### ⚡ Performance & Reliability
- **CPU Optimization**: Reduced from 100% to <5% CPU usage with intelligent background processing
- **Thread-Safe Refresh Pipeline**: Actor-backed coordinator preventing overlapping updates
- **Memory-Aware Caching**: 512KB entry limits with automatic disk promotion for large payloads
- **Memory Management**: Automatic cleanup under memory pressure with configurable limits
- **Network Resilience**: Graceful degradation during outages with urllib fallback and smart retry logic
- **Timeout Protection**: 5-minute limits on data fetching to prevent hanging processes
- **Error Recovery**: Comprehensive fallback mechanisms with detailed error reporting

## 🏗️ Architecture

StockBar uses a modern hybrid architecture optimized for performance and reliability:

### Frontend (Swift 6.0)
- **AppKit & SwiftUI**: Native macOS UI with declarative interface components and AppKit integration
- **Swift Charts Framework**: Hardware-accelerated interactive charting with hover support
- **Combine Framework**: Reactive data flow with debounced updates and memory-safe publishers
- **Actor-Isolated Components**: Thread-safe logging and data management with Swift 6 actor isolation
- **MVVM Pattern**: Clean separation with ObservableObject data models and reactive UI binding

### Backend & Data Management
- **Python Integration**: Subprocess-based data fetching using `yfinance` library with timeout protection and urllib fallback
- **Actor-Based Coordination**: RefreshCoordinator ensures thread-safe, non-overlapping data updates
- **Core Data Stack**: Modern Core Data Model V2 with automatic lightweight migration
- **Multi-Tier Storage**: UserDefaults for configuration, Core Data for persistent data, in-memory for active data
- **Comprehensive Services**: Data migration, memory optimization, cache management, and cleanup services

### Performance Systems
- **Intelligent Caching**: Memory-aware caching with 512KB entry limits and automatic disk promotion
- **Background Processing**: Prioritized task queue with 3% chance background checks (reduced from 6%)
- **Memory Optimization**: Automatic data compression, cleanup, and efficient data structures with pressure handling
- **Thread-Safe Coordination**: Actor-based refresh pipeline preventing overlapping updates
- **Timeout Management**: 5-minute protection on all network operations with automatic process termination

## 🚀 Getting Started

### Prerequisites
1. **macOS 15.4 or later**
2. **Python 3.7+** with yfinance library:
   ```bash
   pip3 install yfinance
   ```
3. **Xcode 15.0+** (for building from source)

### Installation
1. **From Release**: Download the latest release from [GitHub Releases](https://github.com/jayjay181818/StockBar/releases)
2. **From Source**: 
   ```bash
   git clone https://github.com/jayjay181818/StockBar.git
   cd StockBar
   open Stockbar.xcodeproj
   # Build and run the Stockbar target
   ```

### Quick Setup
1. Launch StockBar
2. Click the StockBar menu bar item → "Preferences" (or ⌘,)
3. **Portfolio Tab**:
   - Add stock symbols with the "+" button
   - Enter units and average cost for each position
   - Drag stocks to reorder them in the menu bar
   - Set preferred currency and enable color coding
4. **Charts Tab**: View analytics once data collection begins (2+ data points needed)
5. **Debug Tab**: Monitor real-time logs for troubleshooting

## 📈 Usage Guide

### Portfolio Management
- **Adding Stocks**: Use "+" button, supports US stocks (`AAPL`), UK stocks (`BP.L`), and most international markets
- **Position Entry**: Enter number of units and average cost per share
- **Currency Handling**: Automatic detection - USD for most stocks, GBX/GBP for UK (.L) stocks
- **Reordering**: Drag and drop stocks in the list to customize menu bar order
- **Real-Time Values**: Total portfolio value and net gains update automatically

### Chart Analysis
- **Chart Types**: Toggle between Portfolio Value, Portfolio Gains, and Individual Stock charts
- **Time Selection**: Choose from 1 Day to All Time with automatic data optimization
- **Interactive Features**: Hover for exact values, dates (DD/MM/YY), and times (HH:MM)
- **Performance Metrics**: Expand for detailed statistics including volatility and total returns
- **Historical Data**: Automatic collection with retroactive portfolio value calculations

### Debug & Monitoring
- **Live Logs**: Real-time application monitoring with auto-refresh every 10 seconds
- **Log Controls**: 
  - Auto-refresh toggle for performance
  - Adjustable line limits (100-2000) with tail mode for large files
  - Manual refresh and clear functions
- **Performance Tracking**: Monitor API calls, cache efficiency, and memory usage
- **Error Analysis**: Color-coded messages for quick issue identification

### Advanced Features
- **Background Processing**: Automatic historical data gaps detection and filling
- **API Key Management**: Optional Financial Modeling Prep API key for enhanced data
- **Data Export**: Portfolio data export and historical data management
- **Memory Optimization**: Automatic cleanup with configurable limits and memory pressure detection

## 🔧 Configuration

### Refresh Intervals (Debug Tab)
- **Main Refresh Interval**: 5 minutes (default) - how often stock prices update
- **Cache Duration**: 5 minutes (default) - how long to keep data before re-fetching  
- **Chart Data Collection**: 5 minutes (default) - how often to save data for charts

### Performance Tuning
- **Background Tasks**: 3% chance comprehensive checks, 2% chance standard gap checks
- **Memory Limits**: 100 trades in memory, automatic cleanup under pressure
- **Timeout Protection**: 5-minute maximum for any network operation
- **Cache Management**: Smart invalidation with maximum 1-hour age

### Data Storage
- **Configuration**: macOS UserDefaults for settings and preferences
- **Persistent Data**: Core Data for historical data and trading information
- **Temporary Data**: In-memory for active trading data with automatic persistence
- **Historical Data**: Up to 5 years with automatic data compression and optimization

## 🐛 Troubleshooting

### Built-in Diagnostics
The Debug tab provides comprehensive monitoring:

1. **Error Identification**:
   - 🔴 **Red**: Critical errors requiring immediate attention
   - 🟠 **Orange**: Warnings about potential issues  
   - 🔵 **Blue**: Normal operational information
   - ⚪ **Gray**: Detailed debug traces

2. **Performance Monitoring**:
   - API call timing and success rates
   - Cache hit/miss ratios and efficiency
   - Memory usage and cleanup events
   - Background task execution frequency

3. **Network Diagnostics**:
   - Real-time API request monitoring
   - Rate limiting and retry logic
   - Currency conversion API status
   - Historical data fetch progress

### Common Issues

#### Data Problems
- **"N/A" or Missing Prices**: Check Debug tab for network errors, verify Python/yfinance installation
- **Incorrect Values**: Verify stock symbols are correct, check currency conversion in logs
- **Chart Loading Issues**: Ensure sufficient data collection time (minimum 2 data points)

#### Performance Issues  
- **High CPU Usage**: Check Debug tab for infinite loops, verify 5-minute refresh intervals
- **Memory Warnings**: Enable memory optimization in Debug tab, clear old historical data
- **Slow Performance**: Reduce log line limits, check for excessive background processing

#### Network Issues
- **Rate Limiting**: Debug tab shows "429" errors, automatic retry after 5 minutes
- **API Failures**: Monitor Debug tab for specific error messages and retry attempts
- **Currency Issues**: Verify UK stocks use .L suffix, check conversion logs

### Advanced Debugging
- **Python Script Testing**: 
  ```bash
  python3 Stockbar/Resources/get_stock_data.py AAPL
  ```
- **Dependency Updates**: 
  ```bash
  pip3 install --upgrade yfinance
  ```
- **Log File Analysis**: Access via Debug tab for external analysis tools
- **Performance Profiling**: Monitor refresh timing and memory usage in real-time logs

## 📋 Release History

### Version 2.2.9 (Current) - Reliability & Memory Efficiency
- **🧭 Quick Status Menu Actions**: Added Preferences and Quit commands to every status menu with keyboard shortcuts
- **📈 Chart Picker Enhancements**: Replaced segmented control with scrollable horizontal chip buttons for large watchlists
- **🔄 Safer Refresh Pipeline**: Actor-backed RefreshCoordinator for thread-safe, non-overlapping updates
- **🧠 Memory-Aware Caching**: 512KB cache entry limits with automatic disk promotion for larger payloads
- **🐍 Python Backend Improvements**: urllib fallback when requests package unavailable for enhanced reliability
- **🐛 Bug Fixes**: Staggered refresh scheduling, historical snapshot generation, log compaction improvements

### Version 2.2.8 - Interactive Menu Bar Charts
- **📊 Interactive Menu Bar Price Charts**: Real-time charts with 1D/1W/1M views directly in stock menu dropdowns
- **📈 Enhanced Data Visualization**: Smart Y-axis scaling, color-coded charts, hover interactions
- **🔧 Data Management**: Real data priority with intelligent fallback, price validation, memory-efficient structures
- **🖥️ Visual Design**: Professional rounded corners, centered content, adaptive colors matching macOS design

### Version 2.2.6 - Performance & Feature Enhancements
- **🚀 Major Performance Improvements**: Fixed infinite loops, reduced CPU usage from 100% to <5%
- **✨ New Features**: Drag-and-drop stock reordering, retroactive portfolio calculations
- **🔧 Technical Improvements**: Core Data Model V2, Swift 6 compliance, enhanced error handling
- **🐛 Bug Fixes**: Preferences window issues, hanging processes, memory leaks

### Previous Versions
- See [Changelogs/](./Changelogs/) for detailed release notes

## 🛠️ Development

### Technology Stack
- **Swift 6.0**: Latest language features with actor isolation and async/await
- **SwiftUI + AppKit**: Hybrid approach for optimal performance and native feel
- **Core Data**: Modern stack with automatic migration and optimization
- **Combine**: Reactive programming with memory-safe publishers
- **Swift Charts**: Hardware-accelerated interactive data visualization

### Code Quality
- **SwiftLint Integration**: Automated code style enforcement with CI/CD
- **Actor Isolation**: Thread-safe design with Swift 6 actor patterns
- **Comprehensive Testing**: Unit tests for core functionality with automated CI
- **Memory Safety**: Weak references, proper cleanup, and leak detection
- **Error Handling**: Comprehensive error types with detailed context

### Development Setup
1. Clone repository and install dependencies
2. Run SwiftLint for code quality checks
3. Use Debug tab for real-time development monitoring
4. Follow logging guidelines with `Logger.shared`
5. Test with multiple portfolios and network conditions

### Contributing Guidelines
- **Logging**: Use structured logging with appropriate severity levels
- **Performance**: Monitor Debug tab for performance regressions
- **UI**: Ensure all modifications occur on main thread
- **Error Handling**: Provide graceful fallbacks and user-friendly messages
- **Testing**: Validate with Debug tab monitoring during development

## 📊 Performance Metrics

StockBar v2.2.9 delivers professional-grade performance:

- **CPU Usage**: <5% during normal operation (down from 100%)
- **Memory Footprint**: <50MB with automatic cleanup under pressure and smart cache promotion
- **Response Time**: <2 seconds for portfolio updates with thread-safe coordination
- **Chart Rendering**: 60fps interactive charts with smooth animations and scrollable pickers
- **Data Capacity**: Up to 5 years historical data with automatic optimization
- **Network Efficiency**: <10 API calls per hour with intelligent caching (512KB memory limit)
- **Cache Intelligence**: Automatic disk promotion for large payloads, memory-aware eviction

## 📄 License

[Add your license information here]

## 🔗 Links

- **Releases**: [GitHub Releases](https://github.com/jayjay181818/StockBar/releases)
- **Issues**: [GitHub Issues](https://github.com/jayjay181818/StockBar/issues)
- **Changelogs**: [Release Notes](./Changelogs/)
- **Documentation**: [Technical Documentation](./BUILD_FIXES_DOCUMENTATION.md)

---

**Built with ❤️ using Swift 6.0 and modern macOS technologies**

*Last updated: September 30, 2025 - Version 2.2.9*