# StockBar Auto-Detection Feature for GBX/GBP Currency

## Overview

I've implemented an auto-detection system for UK stocks (.L suffix) to properly handle GBX (pence) to GBP (pounds) conversion, which should resolve the "Total Portfolio Return" calculation issue.

## Changes Made

### 1. Enhanced Position Model (`Trade.swift`)
- Added `costCurrency` field to track the currency unit the user entered their average cost in
- Added `getNormalizedAvgCost()` method that automatically converts GBX to GBP for UK stocks
- Added auto-detection logic that defaults to GBX for .L stocks and USD for others

### 2. Updated UI (`PreferenceView.swift`)
- Added currency selector buttons next to each average cost field
- Shows detected currency (GBX for .L stocks, USD for others)
- Allows users to manually override the currency if needed
- Added helpful tooltips and popover interface

### 3. Updated Calculation Logic
- **DataModel.swift**: Uses `getNormalizedAvgCost()` for gain calculations
- **StockStatusBar.swift**: Uses normalized costs for menu display
- **PerformanceChartView.swift**: Uses normalized costs for chart calculations
- **SymbolMenu.swift**: Updated to use normalized costs (though this file may not be actively used)

### 4. Data Migration
- Added automatic migration for existing data to set appropriate `costCurrency` values
- UK stocks (.L) default to GBX, others default to USD
- Migration runs once on app startup and saves updated data

## How It Works

### Auto-Detection Rules
1. **UK Stocks** (symbols ending in .L): Default to **GBX** (pence)
2. **Other Stocks**: Default to **USD**
3. **User Override**: Users can manually change the currency unit via the UI

### Conversion Logic
- When calculating gains/losses, the system automatically converts GBX to GBP by dividing by 100
- This ensures that user-entered costs in GBX are properly compared with current prices in GBP
- No conversion is applied for non-UK stocks or when costs are already in the correct currency

### UI Improvements
- Currency buttons show the detected/selected currency (e.g., "GBX", "USD")
- Clicking the button opens a popover to change the currency unit
- Available currencies depend on the stock type (UK stocks show GBX/GBP options)
- Column header updated to indicate currency selection is available

## Expected Result

This should fix the massive loss calculation issue by ensuring that:
1. UK stock average costs entered in GBX are properly converted to GBP for calculations
2. The conversion is applied consistently across all calculation functions
3. Users have visibility and control over which currency unit they're using
4. Existing data is automatically migrated to use the correct currency assumptions

## Testing

To test the fix:
1. Add a UK stock (e.g., "TSLA.L") 
2. Enter average cost in pence (e.g., "2500" for £25.00)
3. Verify the currency button shows "GBX"
4. Check that portfolio calculations now show reasonable gains/losses instead of massive losses
5. Optionally, click the currency button to change from GBX to GBP and see the difference

The auto-detection should eliminate the need for users to manually convert between pence and pounds, while still providing the flexibility to override when needed. 