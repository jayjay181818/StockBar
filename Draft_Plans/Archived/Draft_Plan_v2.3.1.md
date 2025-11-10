# Stockbar v2.3.1 Development Plan

**Date**: October 4, 2025
**Version**: 2.3.1
**Status**: Planning Phase - High-Impact Missing Features

---

## Overview

Version 2.3.1 focuses on implementing the highest-value missing features identified in the implementation summary. This release prioritizes user-facing functionality that will significantly enhance the charting and portfolio analysis experience.

## Scope and Non-Goals

- In scope (v2.3.1):
  - Interactive Charts: zoom, pan, crosshair, basic text annotations, earnings markers
  - Performance Attribution: individual and sector attribution, TWR/MWR, waterfall visualization
- Non-goals (defer to later versions): correlation heatmap, Python bundling, advanced data caching

### Goals

- **Interactive Charts**: Enable zoom/pan navigation, crosshair tool, and basic annotations
- **Performance Attribution**: Add individual stock contribution analysis, sector attribution, and TWR/MWR calculations

### Success Criteria

- Users can interact with charts (zoom, pan, crosshair, annotations)
- Users can analyze performance attribution with clear visualizations

---

## Feature 1: Interactive Chart Features

### 1.1 Functionality

**Core Interactive Features**:

- **Zoom & Pan**: Pinch-to-zoom and drag-to-pan gestures on all chart types
- **Crosshair Tool**: Hover to show exact values with vertical/horizontal lines
- **Basic Annotations**: Add/delete simple text notes and earnings markers

### 1.2 Files to Create/Modify

**New Files**:

- `Stockbar/Charts/ChartInteractionManager.swift` (200 lines)
  - Centralized interaction state management
  - Zoom/pan calculations and bounds checking
  - Crosshair position tracking
- `Stockbar/Charts/ChartGestureHandler.swift` (150 lines)
  - Gesture recognizer setup and handling
  - Pinch, pan, and tap gesture coordination
  - Gesture state management
- `Stockbar/Charts/ChartAnnotationView.swift` (180 lines)
  - Annotation creation and editing UI
  - Annotation rendering on charts
  - Earnings marker integration

**Modified Files**:

- `Stockbar/Charts/CandlestickChartView.swift` (+50 lines)
  - Wire interaction manager and gesture handlers
  - Add crosshair overlay
  - Integrate annotation rendering
- `Stockbar/Charts/PerformanceChartView.swift` (+30 lines)
  - Add interaction support
  - Crosshair integration

### 1.3 Technical Approach

**Gesture Handling**:

- Use `MagnificationGesture` and `DragGesture` for zoom/pan
- Implement gesture state management with proper bounds checking
- Coordinate between multiple gesture recognizers

**Crosshair Implementation**:

- Overlay `RuleMark` elements on Swift Charts
- Track mouse/touch position and snap to data points
- Display exact values in tooltip overlay

**Annotation System**:

- Simple data model for text annotations and earnings markers
- Context menu for adding annotations
- Persistent storage in Core Data (optional)

### 1.3.1 Architecture Decisions

- Use Swift Charts overlays for crosshair using `RuleMark` lines; snap to nearest datum
- Central `ChartInteractionManager` manages zoom, pan, and crosshair state (single source of truth)
- `ChartGestureHandler` coordinates magnification, drag, and tap; bounds enforced in manager
- `ChartAnnotationView` holds local in-memory annotations; persistence is optional (deferred)
- No third-party chart libraries; rely on Swift Charts + SwiftUI

### 1.4 Acceptance Criteria

**Zoom & Pan**:

- [ ] Pinch gesture zooms chart in/out smoothly
- [ ] Pan gesture moves chart view within bounds
- [ ] Double-tap resets zoom to default
- [ ] Zoom limits prevent over-zooming
- [ ] Zoom range constrained between 0.5x and 8x
- [ ] Panning mean latency ≤ 16 ms (p95 ≤ 24 ms) on MacBook Pro M1+

**Crosshair Tool**:

- [ ] Hover shows vertical/horizontal crosshair lines
- [ ] Displays exact OHLC values at cursor position
- [ ] Snaps to nearest data point
- [ ] Works on all chart types (candlestick, line, volume)
- [ ] Tooltip also shows % change vs previous close

**Annotations**:

- [ ] Right-click adds annotation at cursor position
- [ ] Text annotations can be edited and deleted
- [ ] Earnings markers show on chart
- [ ] Annotations persist across chart updates

---

## Feature 2: Performance Attribution Analysis

### 2.1 Functionality

**Attribution Features**:

- **Individual Stock Contribution**: Show each stock's contribution to portfolio return
- **Sector Attribution**: Aggregate contributions by GICS sector
- **Time-Weighted vs Money-Weighted Returns**: Calculate and display both metrics
- **Waterfall Visualization**: Visual breakdown of contributions

### 2.2 Files to Create/Modify

**New Files**:

- `Stockbar/Analytics/AttributionAnalysisService.swift` (300 lines)
  - Individual stock contribution calculations
  - Sector aggregation logic
  - TWR/MWR calculation methods
  - Brinson attribution model implementation
- `Stockbar/Models/AttributionData.swift` (120 lines)
  - Data models for attribution results
  - Stock contribution, sector contribution, TWR/MWR models
  - Waterfall chart data structures
- `Stockbar/Views/AttributionAnalysisView.swift` (250 lines)
  - Attribution dashboard UI
  - Waterfall chart visualization
  - TWR/MWR comparison display
  - Integration with existing Analytics tab

**Modified Files**:

- `Stockbar/Views/PortfolioAnalyticsView.swift` (+30 lines)
  - Add attribution section
  - Wire attribution service
  - Add navigation to detailed attribution view

### 2.3 Technical Approach

**Contribution Calculation**:

```swift
// Individual stock contribution
Stock Contribution = Stock Weight × Stock Return
Portfolio Return = Σ(Stock Contributions)

// Sector contribution
Sector Contribution = Σ(Stock Contributions in Sector)
```

**TWR vs MWR**:

- **TWR**: Geometric linking of sub-period returns (not affected by cash flows)
- **MWR**: Internal Rate of Return calculation (affected by timing of deposits/withdrawals)

**Waterfall Chart**:

- Use Swift Charts `BarMark` with cumulative positioning
- Color-code positive/negative contributions
- Show running total progression

### 2.4 Acceptance Criteria

**Individual Attribution**:

- [ ] Shows top 10 contributors by dollar amount
- [ ] Shows top 10 contributors by percentage
- [ ] Displays both positive and negative contributions
- [ ] Updates with time range selection

**Sector Attribution**:

- [ ] Aggregates individual stocks by GICS sector
- [ ] Shows sector contribution breakdown
- [ ] Displays sector performance vs allocation
- [ ] Updates with portfolio changes

**TWR/MWR Comparison**:

- [ ] Calculates both return metrics accurately
- [ ] Displays difference between TWR and MWR
- [ ] Explains the difference to users
- [ ] Updates with time range changes
- [ ] MWR (IRR) calculation converges within 200 ms for typical portfolios

**Waterfall Visualization**:

- [ ] Shows cumulative contribution progression
- [ ] Color-codes positive/negative contributions
- [ ] Displays final portfolio return
- [ ] Interactive tooltips with details

---

## Performance Budgets

- Panning latency (mean): ≤ 16 ms; p95 ≤ 24 ms
- Zoom FPS: ≥ 55 fps sustained on MacBook Pro M1 or newer
- Memory delta when crosshair shown: ≤ +40 MB vs idle
- Attribution calc time (1k positions, 3y data): ≤ 300 ms

---

## Dependencies & Integration Points

- New files: `Stockbar/Charts/ChartInteractionManager.swift`, `Stockbar/Charts/ChartGestureHandler.swift`, `Stockbar/Charts/ChartAnnotationView.swift`
- Modified charts: `Stockbar/Charts/CandlestickChartView.swift`, `Stockbar/Charts/PerformanceChartView.swift`
- Attribution (new): `Stockbar/Analytics/AttributionAnalysisService.swift`, `Stockbar/Models/AttributionData.swift`, `Stockbar/Views/AttributionAnalysisView.swift`
- Views integration: `Stockbar/Views/PortfolioAnalyticsView.swift`

---

## Feature Flags & Rollout

- Flags: `charts.interaction`, `analytics.attribution`
- Rollout: enable flags in Test/Canary builds first; production on when QA complete

---

## Open Questions

1) Do annotations need persistence in v2.3.1? Default: no (defer)
2) Minimum macOS target for interactivity perf budgets? Default: macOS 14+
3) Data source for earnings markers? Default: existing historical feed

---

## Testing Strategy

### Manual Testing

- Use existing `MANUAL_TESTING_CHECKLIST.md` as base
- Add specific test cases for new features
- Test on different chart types and data ranges

### Unit Testing

- Test attribution calculations with known data
- Test gesture handling edge cases

### Integration Testing

- Test feature interactions (zoom + annotations)
- Test attribution updates with portfolio changes

---

## Success Metrics

### User Experience

- [ ] Charts feel responsive and smooth during interaction
- [ ] Attribution analysis provides clear insights

### Technical Quality

- [ ] No performance regression in chart rendering
- [ ] Gesture handling works reliably
- [ ] Attribution calculations are accurate

### Feature Completeness

- [ ] All acceptance criteria met
- [ ] Features work across all chart types
- [ ] Integration with existing UI is seamless
- [ ] Documentation updated for new features

---

**Next Steps**:

1. Begin Phase 1 implementation (Interactive Charts)
2. Set up progress tracking in PROGRESS_v2.3.1.md
3. Create feature branches for each major component
4. Implement and test incrementally

---

**Last Updated**: October 4, 2025
**Status**: Ready for Implementation
**Estimated Completion**: 2 weeks
