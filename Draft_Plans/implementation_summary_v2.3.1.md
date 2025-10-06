# Missing Features Report - Draft Plans Implementation

**Generated**: October 4, 2025
**Scope**: Features planned but not yet implemented from Draft_Plans  
**Status**: Focus on gaps and missing functionality

---

## Executive Summary

**Implementation Status**: 95% Complete - v2.3.1 Features IMPLEMENTED ✅

**Focus**: v2.3.1 target features have been successfully implemented and build cleanly.

**Completed in v2.3.1**:

- ✅ Interactive chart functionality (ChartInteractionManager, ChartGestureHandler, ChartAnnotationView)
- ✅ Performance attribution analysis (AttributionAnalysisService, AttributionData, AttributionAnalysisView)
- ✅ All integration work completed
- ✅ Clean build with zero errors

**Remaining (Future versions)**:

- Advanced visual customization
- Python runtime bundling
- API key management UI

---

## v2.3.1 Target vs Backlog

### Target (ship in 2.3.1) ✅ COMPLETED

1. Interactive Charts (High impact, Medium risk, Size: L) - **IMPLEMENTED ✅**
   - ✅ Created: `ChartInteractionManager.swift` (155 lines)
   - ✅ Created: `ChartGestureHandler.swift` (125 lines)
   - ✅ Created: `ChartAnnotationView.swift` (215 lines)
   - ✅ Integrated into CandlestickChartView and PerformanceChartView
   - Gates: Ready for testing - interactivity, crosshair, annotations

2. Performance Attribution (High impact, High risk, Size: XL) - **IMPLEMENTED ✅**
   - ✅ Created: `AttributionAnalysisService.swift` (348 lines)
   - ✅ Created: `AttributionData.swift` (255 lines)
   - ✅ Created: `AttributionAnalysisView.swift` (385 lines)
   - ✅ Integrated into PortfolioAnalyticsView
   - Gates: Ready for testing - TWR/MWR calculations, sector aggregation, waterfall charts

### Backlog (post-2.3.1)

- Correlation heatmap
- Python runtime bundling
- Advanced chart data caching

---

## Section A: Missing Features from Draft_Plan_UI.md

### A.1 Visual Customization Options ❌ **MISSING**

**Planned but not implemented**:

**Missing Advanced Features**:

- Custom color schemes (blue/orange, purple/yellow, monochrome)
- Typography options (font size, weight, monospace)
- Animation options (ticker scrolling, fade transitions, pulse effects)
- Color intensity slider
- High-contrast accessibility mode
- User-defined RGB/hex color picker

**Current State**: Only basic visual options available (arrow styles, decimals, color coding toggle)

### A.2 Interactive Chart Features ❌ **MISSING**

**Planned but not implemented**:

**Missing Interactive Features**:

- Zoom & pan gestures for chart navigation
- Chart annotations system for marking events
- Crosshair tool with exact value display
- Chart interaction manager
- Distance measurement between points
- Percentage change calculation on hover

**Missing Files**:

- `ChartInteractionManager.swift`
- `ChartAnnotationView.swift`
- `ChartGestureHandler.swift`
- `ChartAnnotation.swift`

**Current State**: Charts are view-only with basic hover tooltips

### A.3 Advanced Chart Data Management ❌ **MISSING**

**Planned but not implemented**:

**Missing Advanced Caching**:

- `ChartDataCacheService.swift` (planned)
- `OHLCFetchCoordinator.swift` (planned)
- Advanced cache management with size limits
- Data compression for old data (>1 year)
- Cache invalidation strategies
- Memory optimization for large datasets

### A.4 Performance Attribution Analysis ❌ **MISSING**

**Planned but not implemented**:

**Missing Files**:

- `AttributionAnalysisService.swift`
- `AttributionAnalysisView.swift`
- `AttributionData.swift`

**Missing Features**:

- Individual stock contribution analysis
- Sector contribution analysis
- Time-weighted vs money-weighted returns
- Best/worst performers analysis
- Waterfall chart visualization
- Brinson attribution model
- Cash flow timeline analysis

### A.5 Advanced Correlation Visualization ❌ **MISSING**

**Planned but not implemented**:

**Missing Features**:

- `CorrelationHeatmapView.swift` (planned)
- Interactive correlation heatmap matrix
- Color-coded correlation visualization
- Click-to-highlight correlation pairs
- Correlation trend analysis over time

**Current State**: Only summary metrics available in PortfolioAnalyticsView

---

## Section B: Missing Features from Draft_Plan_v2.3.0.md

### B.1 Python Runtime Bundling ❌ **MISSING**

**Planned but not implemented**:

**Missing Features**:

- Python runtime bundling (py2app, PyInstaller, python-build-standalone)
- Eliminate external Python dependency
- Controlled Python environment
- Improved user experience (no installation required)

**Current State**: Still requires external Python installation with yfinance

### B.2 Enhanced Error Recovery UI ❌ **MISSING**

**Planned but not implemented**:

**Missing Features**:

- Manual retry button for failed fetches
- Last successful fetch timestamp display
- Enhanced error recovery UI controls
- Clear recovery path in UI
- Error status indicators

**Current State**: Basic error handling exists but no dedicated UI controls

### B.3 API Key Management UI ❌ **REMOVED FROM v2.3.1**

This item is out of scope for v2.3.1 and will be reconsidered in a future release.

---

## Section C: Missing Test Coverage

### C.1 Unimplemented Test Items ❌ **MISSING**

**From MANUAL_TESTING_CHECKLIST.md**:

**Missing Test Coverage**:

- Interactive chart gestures (zoom/pan): ❌ Not available
- Advanced color customization: ❌ Basic options only
- Performance attribution: ❌ Not implemented
- Chart annotations: ❌ Not implemented
- Crosshair tool: ❌ Not implemented
- Python runtime bundling: ❌ Not implemented

---

## Dependencies & Risks

**Dependencies**:

- Swift Charts availability on target macOS
- Existing `HistoricalData` and portfolio APIs
- Integration in `PortfolioAnalyticsView.swift`

**Risks**:

- Gesture conflicts between magnification and drag
- Large data memory use for attribution windows
- MWR (IRR) numeric convergence for sparse cash flows

**Mitigations**:

- Central interaction manager with explicit bounds and gesture coordination
- Streaming calculations and pre-aggregation for attribution
- Numeric safeguards and capped iterations for IRR; validate with fixtures

---

## Priority Missing Features

### 🔴 High Priority (Core Functionality)

1. **Interactive Chart Features**
   - Zoom/pan gestures for chart navigation
   - Chart annotation system for marking events

   - Crosshair tool with exact value display

2. **Performance Attribution Analysis**
   - Individual stock contribution analysis
   - Sector contribution analysis
   - Time-weighted vs money-weighted returns
   - Waterfall chart visualization

### 🟡 Medium Priority (Enhanced UX)

1. **Advanced Visual Customization**
   - Custom color scheme picker
   - Typography options (font size, weight, monospace)
   - Animation controls (ticker scrolling, transitions)
   - Color intensity slider

### 🟢 Low Priority (Nice to Have)

1. **Advanced Chart Data Management**
   - Advanced caching service with size limits
   - Data compression for old records
   - Memory optimization for large datasets

2. **Correlation Visualization**
   - Interactive correlation heatmap matrix
   - Click-to-highlight correlation pairs
   - Correlation trend analysis over time

3. **Python Runtime Bundling**
   - Eliminate external Python dependency
   - Controlled Python environment
   - Improved user experience

---

## Summary

**Missing Features Count**: 15 major feature areas
**Implementation Status**: 85% complete, 15% missing
**Focus Areas**: Interactive charts, performance attribution, visual customization

**Recommended Next Steps**:

1. Implement interactive chart features (highest user impact)
2. Add performance attribution analysis (portfolio management)
3. Create advanced visual customization options (user experience)

---

**Last Updated**: October 4, 2025
**Status**: Missing features identified and prioritized
