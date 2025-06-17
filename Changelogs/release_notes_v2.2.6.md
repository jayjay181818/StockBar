# Stockbar v2.2.6 Release Notes

**Release Date**: June 17, 2025  
**Version**: 2.2.6  
**Previous Version**: 2.2.5  

## 🎯 Overview

Stockbar v2.2.6 introduces major performance improvements, enhanced portfolio analytics, and improved user experience features. This release focuses on configurable menu bar ordering, advanced retroactive portfolio calculations, and comprehensive build stability improvements.

---

## ✨ Major New Features

### 🔄 **Configurable Menu Bar Stock Ordering**
- **Drag-and-Drop Interface**: Reorder stocks in the Portfolio preferences tab using intuitive drag handles (≡)
- **Persistent Ordering**: Custom stock order is automatically saved and restored between app restarts
- **Real-Time Updates**: Menu bar immediately reflects the new ordering after changes
- **Smart Migration**: New stocks are automatically added at the end of existing custom orders

### 📊 **Enhanced Retroactive Portfolio Calculation System**
- **Pre-Calculated Analytics**: Portfolio charts now load instantly using pre-calculated historical data
- **Intelligent Background Processing**: Automatic calculation triggers (1% chance per data update + startup calculation)
- **Full vs. Incremental Updates**: Smart detection of portfolio changes for efficient recalculation
- **5-Year Historical Coverage**: Comprehensive portfolio value tracking with up to 2000 snapshots
- **Memory Optimized**: Chunked processing and automatic cleanup to prevent system overload

### 💱 **Improved UK Stock Currency Handling**
- **Auto-Detection**: Automatic GBX/GBP currency detection for UK stocks (.L suffix)
- **Currency Selection UI**: Interactive currency buttons next to average cost fields
- **Smart Conversion**: Automatic GBX to GBP conversion for accurate portfolio calculations
- **Data Migration**: Seamless migration of existing data with appropriate currency assignments

---

## 🔧 Performance & Stability Improvements

### ⚡ **Performance Optimizations**
- **Reduced Refresh Intervals**: Default intervals changed from 15 to 5 minutes for faster updates
- **Eliminated CPU Loops**: Fixed infinite currency refresh loops that caused 100% CPU usage
- **Python Script Timeouts**: Added 5-minute timeout protection for hanging historical data processes
- **Throttled Background Tasks**: Reduced excessive background processing frequency from 6% to 3%

### 🖥️ **UI & Navigation Fixes**
- **Protected Navigation**: Fixed navigation tabs being cut off when maximizing windows
- **Smart Window Resizing**: Intelligent resize logic that respects user window sizing preferences
- **Scrollable Content**: Debug logs and portfolio content now scroll properly instead of expanding windows
- **Improved Layout**: Better organization with fixed headers and flexible content areas

### 🏗️ **Build System Improvements**
- **Swift 6 Compatibility**: Fixed 200+ actor isolation errors across 20+ files
- **Logger Integration**: Systematic conversion to async Logger calls throughout codebase
- **Preferences Menu Fix**: Resolved blank preferences window issue after reopening
- **Memory Management**: Enhanced memory pressure monitoring and cleanup

---

## 🔄 Configuration Changes

### ⏱️ **Updated Default Intervals**
- **Main Refresh Interval**: 15 minutes → 5 minutes
- **Cache Duration**: 15 minutes → 5 minutes  
- **Chart Data Collection**: Maintains 5-minute interval for historical snapshots
- **User Customization**: All intervals remain fully configurable in preferences

### 📈 **Chart System Enhancements**
- **Instant Loading**: Pre-calculated portfolio data eliminates loading delays
- **Fallback Support**: Legacy calculation methods remain functional
- **Progress Indication**: Background calculations don't block UI interactions
- **Data Validation**: Enhanced error checking and reasonable data range validation

---

## 🐛 Bug Fixes

### High Priority Fixes
- **Fixed**: Menu bar stock ordering persistence between app restarts
- **Fixed**: High CPU usage (100%) caused by infinite background processing loops
- **Fixed**: Navigation tabs becoming invisible when maximizing preferences window
- **Fixed**: Python script processes hanging indefinitely during historical data fetching
- **Fixed**: Blank preferences window appearing after close/reopen cycles
- **Fixed**: UK stock (.L) portfolio calculations showing massive incorrect losses

### Performance Fixes
- **Fixed**: Excessive currency converter API calls causing log spam
- **Fixed**: Multiple simultaneous startup backfill tasks causing resource conflicts
- **Fixed**: Memory pressure warnings during large historical data operations
- **Fixed**: Swift 6 actor isolation errors preventing compilation

### UI/UX Fixes
- **Fixed**: Window auto-sizing overriding user manual resize preferences
- **Fixed**: Content overflow causing unusably large preference windows
- **Fixed**: Debug logs area not scrolling properly with large amounts of data
- **Fixed**: Portfolio tab layout issues with varying numbers of stocks

---

## 🔧 Technical Improvements

### Architecture Enhancements
- **Enhanced Storage System**: Efficient UserDefaults-based portfolio snapshot storage
- **Improved Error Handling**: Comprehensive fallback strategies for all major operations
- **Better Currency Management**: Centralized currency conversion with proper caching
- **Optimized Data Flow**: Priority-based data retrieval (cached → calculated → real-time)

### Code Quality
- **Async/Await Migration**: Modern Swift concurrency patterns throughout codebase
- **Comprehensive Logging**: Detailed debug information with categorized log levels
- **Memory Safety**: Proper weak reference handling and resource cleanup
- **Thread Safety**: MainActor compliance for UI updates with background processing

### Integration Improvements
- **Enhanced Core Data**: Better migration handling and batch processing
- **Improved Network Layer**: Timeout protection and error recovery for Python scripts
- **Better Configuration**: Centralized settings management with proper validation
- **Streamlined Preferences**: Simplified hosting controller for better reliability

---

## 🔄 Migration & Compatibility

### Automatic Migrations
- **Currency Data**: Existing portfolio data automatically migrated with appropriate currency detection
- **Historical Data**: Legacy calculation data cleaned up and migrated to new system
- **Configuration**: Previous custom intervals preserved, new defaults applied only to fresh installs

### Backward Compatibility
- **Legacy Support**: All previous calculation methods preserved as fallbacks
- **Data Integrity**: Existing portfolio data remains unchanged during migration
- **Progressive Enhancement**: New features available immediately without disrupting existing functionality

---

## 🚀 Installation & Upgrade

### System Requirements
- **macOS**: 15.4 or later
- **Python**: 3.9+ (required for stock data fetching)
- **Dependencies**: `yfinance` package (`pip3 install yfinance`)

### Upgrade Notes
- **Automatic Migration**: All data migrations happen automatically on first launch
- **Settings Preservation**: Custom refresh intervals and preferences are maintained
- **Cache Cleanup**: Old inconsistent data is automatically cleaned up during startup

---

## 🔍 Known Issues & Limitations

### Current Limitations
- **Historical Data Range**: Limited to 5 years of retroactive calculation
- **API Dependencies**: Historical data requires Financial Modeling Prep API key
- **Python Dependencies**: Requires system Python 3 installation with yfinance package

### Future Enhancements
- **Database Migration**: SQLite support for complex queries (planned)
- **Advanced Analytics**: Sharpe ratio and drawdown analysis (planned)
- **Export Functionality**: CSV/PDF portfolio reports (planned)
- **Multiple Portfolios**: Support for different portfolio scenarios (planned)

---

## 🧪 Testing Recommendations

### Critical Test Scenarios
1. **Menu Bar Ordering**: Drag stocks in preferences → restart app → verify order persists
2. **Performance**: Monitor CPU usage during normal operation (should be 0-1%)
3. **Navigation**: Maximize preferences window → verify tabs remain visible
4. **Chart Loading**: Open portfolio charts → verify instant loading with historical data
5. **Currency Handling**: Add UK stocks → verify GBX/GBP conversion accuracy

### Success Criteria
- ✅ Menu bar stocks appear in custom order after reordering
- ✅ CPU usage remains low during normal operation
- ✅ Navigation always visible regardless of window size
- ✅ Portfolio charts load instantly without delays
- ✅ UK stock portfolio calculations show reasonable gains/losses

---

## 👥 Contributors

### Development Team
- **Core Development**: System architecture, performance optimization, UI improvements
- **Quality Assurance**: Comprehensive testing across multiple scenarios
- **Documentation**: Detailed technical documentation and user guides

### Special Thanks
- Beta testers for identifying navigation visibility issues
- Community feedback on UK stock currency handling requirements
- Performance testing that identified CPU usage problems

---

## 📞 Support & Feedback

### Getting Help
- **GitHub Issues**: Report bugs at [repository issues page]
- **Documentation**: Comprehensive guides available in project documentation
- **Command Help**: Use `/help` command within the application

### Feedback Channels
- **Feature Requests**: Submit via GitHub issues with "enhancement" label
- **Bug Reports**: Include system information and reproduction steps
- **Performance Issues**: Monitor logs at `~/Documents/stockbar.log`

---

## 🔮 What's Next

### Upcoming in v2.2.7
- **Enhanced Export Features**: CSV and PDF portfolio reporting
- **Advanced Chart Analytics**: Additional performance metrics and indicators
- **Improved Configuration**: GUI for API key management and advanced settings
- **Database Optimization**: SQLite migration for improved query performance

### Long-term Roadmap
- **Multi-Portfolio Support**: Manage multiple investment portfolios
- **Advanced Analytics**: Professional-grade portfolio analysis tools
- **Cloud Sync**: Portfolio data synchronization across devices
- **API Integrations**: Additional data providers and brokerage connections

---

**Full Changelog**: [View detailed changes on GitHub]

*For technical details and implementation specifics, see the accompanying documentation files:*
- `RETROACTIVE_PORTFOLIO_SYSTEM.md` - Portfolio calculation system details
- `NAVIGATION_VISIBILITY_FIX.md` - UI improvement specifications  
- `BUILD_FIXES_DOCUMENTATION.md` - Build system and stability improvements
- `AUTO_DETECTION_UPDATE.md` - Currency handling enhancement details