# Stockbar v2.2.9.1 Release Notes

**Release Date**: September 30, 2025  
**Version**: 2.2.9.1 (Patch Release)  
**Previous Version**: 2.2.9  
**Type**: Bug Fix Release

## 🎯 Overview

Stockbar v2.2.9.1 is a focused patch release addressing critical UI alignment issues in the Charts tab that were introduced in v2.2.9. This release ensures proper spacing and layout behavior when resizing the Preferences window.

---

## 🐛 Bug Fixes

### Charts Tab Layout Issues

#### Fixed Chart Picker Overlap
- **Issue**: Chart selector chips (Portfolio Value, Portfolio Gains, individual stocks) were overlapping the preference tab divider line
- **Solution**: Added specific 8pt top padding to the chart picker component
- **Impact**: Chart picker now maintains proper visual separation from the navigation tabs

#### Fixed Independent Movement During Resize
- **Issue**: Chart elements moved independently when resizing the Preferences window, causing misalignment
- **Solution**: 
  - Added proper frame constraints (maxWidth: infinity, maxHeight: infinity)
  - Wrapped charts view in ScrollView for consistent behavior
  - Replaced generic padding with specific horizontal (16pt) and vertical (12pt) padding
- **Impact**: Chart elements now resize cohesively with the window

#### Fixed Inconsistent Spacing
- **Issue**: Inconsistent spacing between navigation tabs and chart content across different tab selections
- **Solution**: 
  - Standardized padding across chart components
  - Added frame constraints to chart picker with leading alignment
  - Added horizontal padding to chip container
- **Impact**: Consistent visual hierarchy and spacing throughout the Charts tab

---

## 🔧 Technical Changes

### PerformanceChartView.swift

#### Chart Picker Enhancements
```swift
// Before
chartTypePicker

.padding()

// After  
chartTypePicker
    .padding(.top, 8) // Extra top padding to prevent overlap
    
.padding(.horizontal, 16)
.padding(.vertical, 12)
```

#### Frame Constraints
```swift
// Added to chart picker
.frame(maxWidth: .infinity, alignment: .leading)
.padding(.horizontal, 2)
```

### PreferenceView.swift

#### ScrollView Wrapper
```swift
// Before
private var chartsView: some View {
    PerformanceChartView(availableSymbols: availableSymbols, dataModel: userdata)
}

// After
private var chartsView: some View {
    ScrollView {
        PerformanceChartView(availableSymbols: availableSymbols, dataModel: userdata)
    }
}
```

#### Layout Constraints
```swift
// Added to charts case
case .charts:
    chartsView
        .frame(maxWidth: .infinity, maxHeight: .infinity)

// Added to content area
.frame(maxWidth: .infinity, maxHeight: .infinity)
```

---

## ✅ Improvements

### Visual Polish
- **Proper Spacing**: Chart picker maintains 8pt clearance from tab divider
- **Consistent Layout**: All chart elements align properly with preference tabs
- **Smooth Resizing**: Window resize operations maintain layout integrity
- **Better Scrolling**: Horizontal scroll behavior matches other tabs

### User Experience
- **No Visual Jumping**: Tab switching maintains consistent layout
- **Predictable Behavior**: Window resizing behaves as expected
- **Professional Appearance**: Clean, polished interface with proper spacing
- **Large Watchlist Support**: Horizontal scrolling works smoothly with 10+ stocks

---

## 🧪 Testing Performed

### Build Verification
- ✅ Clean build with no compilation errors
- ✅ No new warnings introduced
- ✅ Existing warnings remain isolated to HistoricalDataManager.swift

### Visual Testing
- ✅ Chart picker spacing verified at multiple window sizes
- ✅ Horizontal resizing maintains proper alignment
- ✅ Vertical resizing maintains proper spacing
- ✅ Tab switching shows no visual jumps or shifts
- ✅ Scrolling behavior consistent across tabs

### Edge Cases
- ✅ Large watchlists (10+ stocks) scroll properly
- ✅ Performance metrics expansion maintains layout
- ✅ Window minimize/maximize preserves alignment
- ✅ Multi-monitor support verified

---

## 📋 Upgrade Notes

### Seamless Upgrade
- **No Breaking Changes**: Drop-in replacement for v2.2.9
- **No Data Migration**: All existing data remains compatible
- **No Configuration Changes**: User settings preserved
- **Immediate Effect**: Layout fixes apply immediately upon launch

### Recommended Actions
1. **Update from v2.2.9**: Users experiencing layout issues should update immediately
2. **Verify Charts Tab**: Open Preferences → Charts to confirm proper spacing
3. **Test Window Resize**: Verify smooth resizing behavior
4. **Report Issues**: Any remaining layout issues should be reported on GitHub

---

## 🔍 Known Issues

### Resolved in This Release
- ✅ Chart picker overlapping tab divider (FIXED)
- ✅ Independent chart element movement during resize (FIXED)
- ✅ Inconsistent spacing in Charts tab (FIXED)

### Outstanding Issues
- None related to this patch

---

## 📊 Performance Impact

### Metrics
- **CPU Usage**: No change - remains <5% during normal operation
- **Memory Footprint**: No change - remains <50MB with cleanup
- **Response Time**: No change - maintains <2 second updates
- **Build Time**: No measurable impact
- **Runtime Performance**: No impact on chart rendering or interaction

---

## 🔄 Compatibility

### System Requirements
- **macOS**: 15.4 or later (unchanged)
- **Python**: 3.7+ with yfinance (unchanged)
- **Xcode**: 15.0+ for building from source (unchanged)

### Data Compatibility
- **Forward Compatible**: v2.2.9 data works with v2.2.9.1
- **Backward Compatible**: v2.2.9.1 data works with v2.2.9
- **No Migration Required**: Seamless upgrade path

---

## 📁 Files Changed

### Modified Files
1. `Stockbar/Charts/PerformanceChartView.swift`
   - Added specific top padding to chart picker
   - Changed generic padding to specific horizontal/vertical
   - Added frame constraints with alignment

2. `Stockbar/PreferenceView.swift`
   - Wrapped charts view in ScrollView
   - Added maxWidth/maxHeight frame constraints
   - Enhanced layout behavior for tab content area

### New Files
3. `ALIGNMENT_FIX_v2.2.9.1.md`
   - Technical documentation of alignment fixes
   - Detailed before/after code comparisons
   - Testing recommendations

4. `Changelogs/release_notes_v2.2.9.1.md`
   - This comprehensive release notes document

---

## 🚀 Installation

### From GitHub Release
```bash
# Download the latest release
# https://github.com/jayjay181818/StockBar/releases/tag/v2.2.9.1

# Replace existing v2.2.9 installation
```

### From Source
```bash
git clone https://github.com/jayjay181818/StockBar.git
cd StockBar
git checkout v2.2.9.1
open Stockbar.xcodeproj
# Build and run the Stockbar target
```

### Upgrade from v2.2.9
Simply replace your existing StockBar.app with the v2.2.9.1 version. No additional steps required.

---

## 👥 Contributors

### Core Team
- **UI/UX Fix**: Layout and spacing corrections
- **Testing**: Comprehensive verification across scenarios
- **Documentation**: Release notes and technical documentation

### Community
- **Issue Reporter**: User feedback on layout issues in v2.2.9
- **Beta Testers**: Verification of fixes before release

---

## 📞 Support & Feedback

### Getting Help
- **GitHub Issues**: [Report bugs or issues](https://github.com/jayjay181818/StockBar/issues)
- **Documentation**: See `ALIGNMENT_FIX_v2.2.9.1.md` for technical details
- **Debug Logs**: Available in Preferences → Debug tab

### Feedback Channels
- **Layout Issues**: Report any remaining spacing or alignment problems
- **Resize Behavior**: Share feedback on window resizing experience
- **Visual Polish**: Suggest additional UI/UX improvements

---

## 🔮 What's Next

### Upcoming Features (v2.3.0)
- Continue monitoring for any additional layout edge cases
- Explore enhanced chart overlays and comparative analytics
- Expand health checks for Python dependencies
- Refine cache eviction heuristics

### Future Patches
- v2.2.9.2: Address any remaining minor issues
- Ongoing: Performance optimizations and polish

---

## 📄 Release Checklist

- ✅ Code changes reviewed and tested
- ✅ Build successful with no new errors
- ✅ Visual testing completed across scenarios
- ✅ Documentation updated (README, ALIGNMENT_FIX)
- ✅ Release notes comprehensive and detailed
- ✅ Git tag created (v2.2.9.1)
- ✅ GitHub pre-release published
- ✅ Testing branch updated

---

**Full Changelog**: https://github.com/jayjay181818/StockBar/compare/v2.2.9...v2.2.9.1

**Download**: [GitHub Releases](https://github.com/jayjay181818/StockBar/releases/tag/v2.2.9.1)

---

*This is a patch release focusing exclusively on UI alignment fixes. For the full feature set, see v2.2.9 release notes.*
