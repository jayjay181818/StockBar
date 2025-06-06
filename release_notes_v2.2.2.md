# StockBar v2.2.2 Release Notes

## 🚀 Enhanced Charts with Currency Fixes and Window Auto-Resizing

**Release Date:** June 6, 2025  
**Version:** v2.2.2  
**Branch:** testing  

---

## 🎯 Overview

Version 2.2.2 delivers critical fixes for currency conversion issues and introduces intelligent window auto-resizing, significantly improving the user experience when working with charts and financial data. This release focuses on accuracy and usability enhancements.

---

## 🚀 New Features

### **Automatic Window Resizing**
- **Smart Tab-Based Sizing**: Window automatically adjusts height when switching between tabs
  - Portfolio tab: 400px height (compact view)
  - Charts tab: 700px height (expanded for charts)
  - Debug tab: 600px height (medium view)
- **Smooth Animations**: Seamless transitions with animated window resizing
- **No Manual Intervention**: Eliminates need for users to manually resize windows

### **Comprehensive Return Analysis**
- **Enhanced Charts Tab**: Added detailed return analysis section with comprehensive portfolio insights
- **Three-Column Layout**:
  - Left: Total portfolio return vs purchase price with percentage
  - Center: Period return for selected time range
  - Right: Current portfolio value and average price
- **Investment Performance Metrics**: ROI calculations, total invested amounts, and performance indicators

### **Enhanced Chart Visualization**
- **Proper Chart Boundaries**: Fixed chart undershadow to stay within graph limits
- **Better Visual Clarity**: Improved chart rendering with constrained area fills
- **Dynamic Scaling**: Enhanced Y-axis scaling with proper data range visualization

---

## 🐛 Critical Bug Fixes

### **Currency Conversion Issues**
- **Fixed Major Bug**: GBP values were incorrectly showing the same as USD values
- **Accurate Exchange Rates**: Proper conversion between USD and GBP with real exchange rates
- **Fallback System**: Robust fallback rates when API is unavailable
  - GBP: 0.79 USD
  - EUR: 0.85 USD  
  - JPY: 110.0 USD
  - CAD: 1.25 USD
  - AUD: 1.35 USD

### **Chart Rendering Fixes**
- **AreaMark Boundaries**: Fixed chart undershadow extending beyond graph boundaries
- **Proper Constraints**: Chart area fills now respect Y-axis domain limits
- **Visual Consistency**: Improved chart appearance and boundary management

### **Window Management**
- **Responsive Sizing**: Fixed issues where Charts tab content was cut off
- **Proper Layout**: Ensured all chart content is visible without manual resizing
- **Cross-Tab Consistency**: Maintained proper window dimensions across tab switches

---

## 💰 Currency System Improvements

### **Enhanced Exchange Rate Logic**
- **USD-Base Architecture**: Improved currency converter with proper USD-as-base logic
- **API Integration**: Better handling of exchange rate API responses
- **Error Resilience**: Graceful fallback when exchange rate API is unavailable

### **Multi-Currency Display**
- **Dual Currency Format**: Primary currency with secondary in brackets
- **User Preference Respect**: Display based on user's preferred currency setting
- **GBX/GBP Handling**: Enhanced support for UK stocks with proper pence conversion

### **Accurate Financial Calculations**
- **Portfolio Calculations**: More accurate net gains and portfolio value calculations
- **Currency Conversion**: Proper conversion logic for international stocks
- **Regional Stock Support**: Better handling of UK (.L) stocks and currency formats

---

## 🔧 Technical Enhancements

### **Window Management System**
- **Intelligent Resizing**: `PreferenceView.swift` now includes automatic window adjustment
- **Performance Optimized**: Efficient window sizing with minimal performance impact
- **Coordinated Logic**: Harmonized tab-based resizing with existing metrics expansion

### **Chart Architecture Improvements**
- **AreaMark Enhancement**: Updated chart rendering with `yStart` and `yEnd` parameters
- **Boundary Constraints**: Proper chart area filling within defined boundaries
- **Data Integration**: Enhanced DataModel integration for portfolio calculations

### **Currency Converter Overhaul**
- **Robust Logic**: Complete rewrite of currency conversion logic in `CurrencyConverter.swift`
- **Fallback Rates**: Built-in fallback exchange rates for offline functionality
- **Error Handling**: Improved error handling and graceful degradation

---

## 🎯 User Experience Improvements

### **Seamless Navigation**
- **No Manual Resizing**: Users no longer need to manually adjust window size
- **Consistent Layout**: Proper content visibility across all tabs
- **Smooth Transitions**: Animated window resizing for better visual experience

### **Accurate Financial Data**
- **Trustworthy Calculations**: Fixed currency conversion ensures accurate portfolio values
- **Clear Presentation**: Better formatted financial information with proper currency symbols
- **Comprehensive Insights**: More detailed return analysis and performance metrics

### **Enhanced Chart Interaction**
- **Better Visualization**: Improved chart boundaries for clearer data representation
- **Professional Appearance**: Charts now look more polished and professional
- **Consistent Scaling**: Proper Y-axis scaling shows data clearly without excessive whitespace

---

## 📊 Technical Details

### **Files Modified**
- **`CurrencyConverter.swift`**: Complete overhaul of currency conversion logic
- **`PerformanceChartView.swift`**: Enhanced charts with return analysis and fixed boundaries
- **`PreferenceView.swift`**: Added automatic window resizing functionality

### **Code Statistics**
- **Files Changed**: 3
- **Lines Added**: 346
- **Lines Removed**: 14
- **Net Change**: +332 lines

### **Build System**
- **Xcode Compatibility**: Maintains compatibility with latest Xcode versions
- **CI/CD Pipeline**: All GitHub Actions workflows pass successfully
- **Code Quality**: No new warnings or errors introduced

---

## 🔄 Upgrade Path

### **From v2.2.1**
- **Automatic**: No user action required
- **Settings Preserved**: All user preferences and portfolio data maintained
- **Immediate Benefits**: Currency fixes and window resizing work immediately

### **Data Migration**
- **No Migration Needed**: Existing portfolio data remains unchanged
- **Enhanced Calculations**: Existing data now calculated with improved currency logic
- **Backward Compatible**: Previous currency settings continue to work

---

## 🧪 Testing & Quality Assurance

### **Manual Testing**
- **Currency Conversion**: Verified accurate USD/GBP conversion
- **Window Resizing**: Tested smooth transitions between all tabs
- **Chart Rendering**: Confirmed proper chart boundaries and scaling
- **Portfolio Calculations**: Validated financial calculation accuracy

### **Automated Testing**
- **Build Success**: All compilation and build processes complete successfully
- **CI/CD Pipeline**: GitHub Actions workflows pass without errors
- **Code Analysis**: Static analysis shows no new issues or vulnerabilities

---

## 🚨 Known Issues & Limitations

### **Minor Limitations**
- **Exchange Rate API**: Currency conversion depends on external API availability
- **Window Animation**: Very fast tab switching may occasionally skip animation
- **Chart Rendering**: Complex datasets with many points may experience minor performance impact

### **Workarounds**
- **Offline Mode**: Fallback rates ensure functionality when API is unavailable
- **Performance**: Chart performance optimizations planned for future release
- **Animation**: Window resizing will complete even if animation is skipped

---

## 🔮 Future Roadmap

### **Next Release (v2.2.3)**
- **Performance Optimizations**: Enhanced chart rendering performance
- **Additional Currencies**: Support for more international currencies
- **Advanced Analytics**: More sophisticated portfolio analysis tools

### **Planned Features**
- **Real-time Updates**: Live currency rate updates
- **Custom Time Ranges**: User-defined chart time periods
- **Export Functionality**: Portfolio data export capabilities

---

## 🙏 Acknowledgments

- **User Feedback**: Thanks to users who reported currency conversion issues
- **Testing Community**: Appreciation for thorough testing of chart improvements
- **Development Tools**: Built with Claude Code - AI-powered development assistant

---

## 📞 Support & Feedback

- **GitHub Issues**: https://github.com/jayjay181818/StockBar/issues
- **Documentation**: Available in repository README
- **Community**: Join discussions in GitHub Discussions

---

## 📋 Full Changelog

**New Features:**
- Added automatic window resizing for tab navigation
- Implemented comprehensive return analysis in Charts tab
- Enhanced chart visualization with proper boundaries

**Bug Fixes:**
- Fixed critical currency conversion issue (GBP showing as USD)
- Corrected chart undershadow extending beyond boundaries
- Resolved window sizing issues when accessing Charts tab

**Improvements:**
- Enhanced currency converter with USD-base logic and fallback rates
- Improved financial calculations accuracy
- Better user experience with seamless tab switching

**Technical:**
- Upgraded CurrencyConverter with robust error handling
- Enhanced PerformanceChartView with return analysis section
- Improved PreferenceView with intelligent window management

---

**Full Diff:** [v2.2.1...v2.2.2](https://github.com/jayjay181818/StockBar/compare/v2.2.1...v2.2.2)

---

*Generated with Claude Code - AI-powered development assistant*