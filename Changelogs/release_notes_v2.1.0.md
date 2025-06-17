# StockBar v2.1.0 - Enhanced Portfolio Tracking with Persistent Storage

## 🚀 Major Features

### ✨ Persistent Storage
- **Data Retention**: Stock data now persists across app restarts
- **Offline Resilience**: Shows last successful prices when network is unavailable
- **Smart Recovery**: Maintains portfolio state even after extended offline periods

### 🔄 Intelligent Caching
- **15-minute refresh intervals** for successful data fetches
- **5-minute retry logic** for failed requests
- **Rate limiting protection** to handle Yahoo Finance API limits
- **Graceful degradation** when network requests fail

### 💰 Currency Improvements
- **Fixed GBX/GBP conversion** in net gains calculation
- **Proper UK stock handling** with automatic pence-to-pounds conversion
- **Multi-currency portfolio support** with accurate total calculations

## 🐛 Bug Fixes

- Fixed menu bar title showing "StockBar" instead of individual stock data
- Resolved rate limiting issues with Yahoo Finance API
- Improved error handling for network failures
- Fixed currency conversion calculations for UK stocks (.L suffix)
- Enhanced data persistence and recovery mechanisms

## 🔧 Technical Improvements

### Architecture Enhancements
- **MVVM Pattern**: Clean separation with reactive data flow using Combine
- **Repository Pattern**: Abstracted network layer for better testability
- **Enhanced Error Handling**: Comprehensive error management with graceful fallbacks
- **Memory Management**: Improved handling of Combine subscriptions and status bar items

### Code Quality
- Made `TradingInfo` struct conform to `Codable` for persistence
- Enhanced `DataModel` with `loadSavedTradingInfo()` and `saveTradingInfo()` methods
- Improved `NetworkService` with better caching strategy
- Added comprehensive logging and debug information

## 📚 Documentation Updates

- **Comprehensive README**: Complete rewrite with features, setup, and troubleshooting
- **Enhanced cline_docs**: Updated architecture documentation and progress tracking
- **Usage Guide**: Detailed instructions for setup and daily use
- **Technical Details**: Architecture patterns and design decisions
- **Troubleshooting**: Common issues and solutions

## 🏗️ Development Improvements

- Added proper `.gitignore` for Xcode projects
- Enhanced project structure with better organization
- Improved build process and dependency management
- Added comprehensive error logging for debugging

## 📱 User Experience

- **Reliable Data Display**: Always shows meaningful information, even during network issues
- **Faster Startup**: Immediate display of last known portfolio state
- **Better Performance**: Reduced API calls through intelligent caching
- **Enhanced Stability**: Robust error handling prevents crashes

## 🔄 Migration Notes

This version automatically migrates existing user data and preferences. No manual intervention required.

## 🧪 Testing

Thoroughly tested with:
- Multiple stock symbols (US and UK markets)
- Network failure scenarios
- App restart persistence
- Currency conversion accuracy
- Rate limiting recovery

---

**Full Changelog**: https://github.com/jayjay181818/StockBar/compare/v2.0.0...v2.1.0 