# Alignment Fix v2.2.9.1 - Chart Picker Layout

**Date**: September 30, 2025  
**Issue**: Chart picker chips overlapping preference tab line and moving independently during window resize

## Problem Description

In the Charts tab of the Preferences window:
- The chart selector chips (Portfolio Value, Portfolio Gains, individual stocks) were overlapping the preference tab divider line
- Chart elements moved independently when resizing the window
- Inconsistent spacing between the navigation tabs and chart content

## Root Cause

1. **Insufficient top padding**: The `PerformanceChartView` had generic padding that didn't account for the fixed navigation area
2. **Layout constraints**: The charts view wasn't properly constrained within the parent PreferenceView frame
3. **Missing ScrollView wrapper**: Charts tab lacked consistent scrolling behavior compared to other tabs

## Changes Made

### 1. PerformanceChartView.swift

#### Added specific top padding to chart picker
```swift
chartTypePicker
    .padding(.top, 8) // Extra top padding to prevent overlap with tab divider
```

#### Changed generic padding to specific padding
**Before:**
```swift
.padding()
```

**After:**
```swift
.padding(.horizontal, 16)
.padding(.vertical, 12)
```

#### Enhanced chart picker frame constraints
**Added:**
```swift
.frame(maxWidth: .infinity, alignment: .leading)
.padding(.horizontal, 2)
```

### 2. PreferenceView.swift

#### Added frame constraints to charts view
```swift
case .charts:
    chartsView
        .frame(maxWidth: .infinity, maxHeight: .infinity)
```

#### Added frame constraint to content area
```swift
.frame(maxWidth: .infinity, maxHeight: .infinity)
```

#### Wrapped charts view in ScrollView
**Before:**
```swift
private var chartsView: some View {
    PerformanceChartView(availableSymbols: availableSymbols, dataModel: userdata)
}
```

**After:**
```swift
private var chartsView: some View {
    ScrollView {
        PerformanceChartView(availableSymbols: availableSymbols, dataModel: userdata)
    }
}
```

## Benefits

✅ **Fixed overlap**: Chart picker chips no longer overlap the preference tab divider  
✅ **Consistent resizing**: Chart elements now resize properly with the window  
✅ **Better spacing**: Improved visual hierarchy with proper padding  
✅ **Scrolling behavior**: Charts tab now has consistent scrolling like other tabs  
✅ **Frame constraints**: Proper max width/height constraints prevent layout issues  

## Testing Recommendations

1. ✅ Open Preferences → Charts tab
2. ✅ Verify chart picker chips have proper spacing from tab bar
3. ✅ Resize the window horizontally - chips should scroll properly
4. ✅ Resize the window vertically - content should maintain proper spacing
5. ✅ Switch between tabs - no visual jumping or layout shifts
6. ✅ Test with large watchlists (10+ stocks) to verify horizontal scrolling
7. ✅ Expand/collapse performance metrics - window should resize smoothly

## Build Status

✅ **Build Successful**: No compilation errors  
⚠️ **Warnings**: Existing warnings in HistoricalDataManager.swift (unrelated to changes)

## Files Modified

- `Stockbar/Charts/PerformanceChartView.swift`
- `Stockbar/PreferenceView.swift`

## Version

This fix will be included in **v2.2.9.1** patch release.
