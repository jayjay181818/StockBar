# Stockbar v2.3.2 Development Plan

**Date**: October 4, 2025
**Version**: 2.3.2
**Status**: Planning Phase - Chart Interaction Completion

---

## Overview

Version 2.3.2 completes the interactive chart functionality deferred from v2.3.1. This release focuses on making desktop zoom/pan/gesture interactions fully functional and polished.

## Scope and Non-Goals

- **In scope (v2.3.2)**:
  - Desktop zoom/pan functionality (mouse scroll wheel, trackpad gestures)
  - Crosshair refinements for desktop
  - Chart interaction performance optimization
  - Bug fixes from v2.3.1

- **Non-goals** (defer to later versions):
  - Mobile/touch gestures (macOS only)
  - Advanced annotation features
  - Correlation heatmap
  - Python bundling

### Goals

- **Complete Desktop Chart Interactions**: Make zoom/pan fully functional with mouse and trackpad
- **Performance Optimization**: Ensure smooth 60fps interaction
- **Polish & Bug Fixes**: Address any issues found in v2.3.1

### Success Criteria

- Users can zoom charts with scroll wheel and trackpad pinch
- Users can pan charts with scroll or drag gestures
- Interactions feel smooth and responsive (≥55 fps)
- No regression in existing functionality

---

## Feature 1: Desktop Chart Zoom/Pan

### 1.1 Current State (from v2.3.1)

**Existing Implementation**:
- ✅ ChartInteractionManager (155 lines) - state management complete
- ✅ ChartGestureHandler (190 lines) - scaffolding in place
- ✅ Basic gesture infrastructure
- ❌ Desktop zoom/pan not working (scroll events not captured correctly)

**Issues Identified**:
- ScrollWheelHandler NSViewRepresentable not receiving events
- Zoom/pan state updates not triggering chart re-render
- Mouse position tracking for zoom anchor point incomplete

### 1.2 Technical Approach

**Root Cause Analysis**:
1. NSViewRepresentable scroll wheel handler needs proper first responder management
2. Chart view needs to properly observe interaction manager state changes
3. Zoom/pan transformations need to apply to chart axis domains

**Solution Architecture**:

```swift
// Option A: Pure SwiftUI approach (preferred)
- Use .gesture() modifiers directly on Chart
- Implement custom DragGesture for pan
- Use onContinuousHover for position tracking
- Apply zoom/pan via chartXScale/chartYScale modifiers

// Option B: Hybrid AppKit approach (if Option A fails)
- Wrap Chart in NSHostingView
- Capture scroll events at NSView level
- Bridge events to SwiftUI state
```

### 1.3 Implementation Tasks

**ChartGestureHandler.swift** (Enhancements):
1. Fix ScrollWheelHandler to properly capture events
2. Implement zoom transformation logic
3. Add pan bounds checking
4. Improve hover tracking for zoom anchor point

**ChartInteractionManager.swift** (Enhancements):
1. Add chart axis domain calculation methods
2. Implement zoom scale to axis range conversion
3. Add pan offset to axis domain shift conversion
4. Improve bounds checking with chart data range

**CandlestickChartView.swift** (Integration):
1. Apply zoom/pan state to chart axis domains
2. Use .chartXScale() and .chartYScale() modifiers
3. Update chart when interaction manager state changes
4. Test with various data ranges

**PerformanceChartView.swift** (Integration):
1. Mirror CandlestickChartView integration
2. Test with portfolio data ranges
3. Verify smooth updates

### 1.4 Gesture Controls Specification

**Mouse Controls**:
- **Vertical Scroll**: Zoom in/out (scroll up = zoom in)
- **Horizontal Scroll**: Pan left/right
- **Option + Scroll**: Alternative zoom control
- **Shift + Vertical Scroll**: Pan horizontally

**Trackpad Controls**:
- **Pinch**: Zoom in/out
- **Two-finger drag**: Pan in any direction
- **Hover**: Crosshair follows cursor

**Keyboard Shortcuts**:
- **Double-click**: Reset zoom to default
- **Cmd + 0**: Reset zoom to fit all data
- **Cmd + Plus/Minus**: Zoom in/out incrementally

### 1.5 Performance Budget

- **Zoom FPS**: ≥ 55 fps sustained
- **Pan Latency**: ≤ 16ms mean, ≤ 24ms p95
- **Memory Delta**: ≤ 10 MB during interaction
- **Chart Re-render**: ≤ 16ms per frame

### 1.6 Acceptance Criteria

**Zoom Functionality**:
- [ ] Mouse scroll wheel zooms chart smoothly
- [ ] Trackpad pinch zooms chart smoothly
- [ ] Zoom anchors around cursor position
- [ ] Zoom limits enforced (0.5x to 8x)
- [ ] Maintains 55+ fps during zoom
- [ ] Works on candlestick, line, and volume charts

**Pan Functionality**:
- [ ] Horizontal scroll pans chart left/right
- [ ] Trackpad drag pans chart
- [ ] Pan stays within data bounds
- [ ] Smooth animation (no jitter)
- [ ] Works on all chart types

**Crosshair**:
- [ ] Follows mouse cursor accurately
- [ ] Snaps to nearest data point
- [ ] Shows exact values in tooltip
- [ ] Works during zoom/pan
- [ ] No performance impact

**Integration**:
- [ ] Reset zoom returns to default view
- [ ] Annotations remain anchored during zoom/pan
- [ ] Chart axis labels update correctly
- [ ] No visual glitches or tearing

---

## Feature 2: Chart Interaction Polish

### 2.1 Visual Feedback

**Zoom Indicator**:
- Show current zoom level (e.g., "2.5x") in corner
- Fade out after 1 second of inactivity
- Color: subtle gray overlay

**Pan Boundaries**:
- Visual resistance when reaching data limits
- Subtle bounce-back animation
- Prevent panning beyond first/last data point

**Loading States**:
- Show spinner if chart data recalculation takes >100ms
- Prevent interaction during data load
- Graceful handling of empty data

### 2.2 Error Handling

**Edge Cases**:
- Single data point (disable zoom/pan)
- Empty chart (show placeholder)
- Very large datasets (>10k points) - sample for display
- Network errors during data fetch
- Rapid gesture changes (debounce)

### 2.3 Accessibility

**Keyboard Navigation**:
- Tab to focus chart
- Arrow keys for fine pan control
- +/- keys for zoom
- Escape to reset zoom

**VoiceOver Support**:
- Announce zoom level changes
- Announce pan position changes
- Accessible labels for all controls

---

## Testing Strategy

### Unit Tests

**ChartInteractionManager Tests**:
- [ ] Test zoom scale calculations
- [ ] Test pan offset bounds checking
- [ ] Test zoom limits (min/max)
- [ ] Test reset zoom functionality
- [ ] Test state updates trigger notifications

**ChartGestureHandler Tests**:
- [ ] Test scroll wheel event processing
- [ ] Test magnification event processing
- [ ] Test gesture coordination (no conflicts)
- [ ] Test hover position tracking

### Integration Tests

**Chart Integration Tests**:
- [ ] Test zoom on candlestick chart
- [ ] Test pan on performance chart
- [ ] Test zoom + pan combination
- [ ] Test annotation anchoring during interaction
- [ ] Test crosshair during zoom/pan

### Manual Testing Checklist

**Device Testing**:
- [ ] MacBook Pro with trackpad (M1/M2/M3)
- [ ] iMac with Magic Mouse
- [ ] Mac Studio with Magic Trackpad
- [ ] External mouse (Logitech, etc.)

**Chart Types**:
- [ ] Candlestick chart (OHLC data)
- [ ] Line chart (portfolio value)
- [ ] Volume chart
- [ ] RSI/MACD indicator charts

**Scenarios**:
- [ ] Zoom in to 1-day view from 1-year view
- [ ] Pan through entire historical range
- [ ] Zoom while hovering over specific candle
- [ ] Add annotation, then zoom/pan
- [ ] Switch chart type while zoomed
- [ ] Rapid zoom in/out (stress test)

### Performance Testing

**Tools**:
- Xcode Instruments (Time Profiler, Allocations)
- FPS counter overlay
- Manual observation

**Benchmarks**:
- [ ] 60fps zoom on 1000-point dataset
- [ ] 60fps pan on 1000-point dataset
- [ ] <50ms chart re-render after zoom
- [ ] <10MB memory increase during interaction
- [ ] No memory leaks after 100 zoom/pan cycles

---

## Implementation Plan

### Phase 1: Core Zoom/Pan (Week 1, Days 1-3)

**Day 1**:
- [ ] Fix ScrollWheelHandler event capture
- [ ] Implement zoom scale to axis domain conversion
- [ ] Test basic scroll wheel zoom

**Day 2**:
- [ ] Implement pan offset to axis domain conversion
- [ ] Add bounds checking for pan
- [ ] Test horizontal scroll pan

**Day 3**:
- [ ] Integrate zoom/pan with CandlestickChartView
- [ ] Test trackpad pinch gesture
- [ ] Fix any integration issues

### Phase 2: Polish & Performance (Week 1, Days 4-5)

**Day 4**:
- [ ] Add zoom indicator UI
- [ ] Implement pan boundary feedback
- [ ] Optimize chart re-render performance

**Day 5**:
- [ ] Add keyboard shortcuts
- [ ] Implement reset zoom functionality
- [ ] Performance testing and optimization

### Phase 3: Testing & Bug Fixes (Week 2)

**Days 6-7**:
- [ ] Complete manual testing checklist
- [ ] Fix identified bugs
- [ ] Performance profiling
- [ ] Edge case handling

**Days 8-9**:
- [ ] Integration testing with all chart types
- [ ] Regression testing (v2.3.1 features)
- [ ] Documentation updates
- [ ] Release notes preparation

**Day 10**:
- [ ] Final QA pass
- [ ] Code review
- [ ] Release preparation

---

## Risk Assessment

### High Risk
- **Scroll event capture on NSViewRepresentable**: May require AppKit bridge
  - *Mitigation*: Have Plan B using pure SwiftUI gestures

### Medium Risk
- **Chart rendering performance with large datasets**: May need optimization
  - *Mitigation*: Implement data sampling for >5k points

### Low Risk
- **Gesture conflicts between zoom and pan**: Unlikely with proper coordination
  - *Mitigation*: Clear gesture priority rules

---

## Dependencies

**External**:
- Swift Charts framework (built-in)
- macOS 14+ for modern chart APIs

**Internal**:
- ChartInteractionManager (v2.3.1)
- ChartGestureHandler (v2.3.1)
- CandlestickChartView (v2.3.0)
- PerformanceChartView (v2.3.0)

---

## Success Metrics

### User Experience
- [ ] Users report smooth zoom/pan interaction
- [ ] No complaints about gesture conflicts
- [ ] Chart interactions feel natural and responsive

### Technical Quality
- [ ] All performance budgets met
- [ ] No memory leaks
- [ ] 100% of acceptance criteria passed
- [ ] Zero critical bugs

### Deliverables
- [ ] Fully functional desktop chart zoom
- [ ] Fully functional desktop chart pan
- [ ] Updated documentation
- [ ] Release notes
- [ ] Manual testing report
- [ ] Performance benchmark results

---

## Out of Scope (Future Versions)

- Mobile/iOS chart interaction (v2.4+)
- Advanced gesture customization
- Chart animation effects
- 3D chart visualizations
- Multi-touch gestures
- Gesture recording/playback

---

**Next Steps**:

1. Begin Phase 1 implementation (Core Zoom/Pan)
2. Create PROGRESS_v2.3.2.md for tracking
3. Set up performance monitoring
4. Daily standup updates

---

**Last Updated**: October 4, 2025
**Status**: Ready for Implementation
**Estimated Completion**: 2 weeks (Oct 18, 2025)
**Owner**: Development Team
