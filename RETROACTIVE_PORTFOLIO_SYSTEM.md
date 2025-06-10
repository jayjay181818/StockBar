# Enhanced Retroactive Portfolio Calculation System

## Overview

The Enhanced Retroactive Portfolio Calculation System transforms Stockbar's portfolio analytics from real-time computation to intelligent pre-calculated data, providing instant chart loading and comprehensive historical analysis.

## Core Architecture

### Data Models (`HistoricalData.swift`)

#### `HistoricalPortfolioSnapshot`
Complete portfolio state at a specific date:
```swift
struct HistoricalPortfolioSnapshot: Codable, Identifiable {
    let date: Date                                    // Snapshot date
    let totalValue: Double                           // Total portfolio value
    let totalGains: Double                           // Total gains/losses
    let totalCost: Double                            // Original investment cost
    let currency: String                             // Portfolio currency
    let portfolioComposition: [String: PositionSnapshot] // Individual positions
}
```

#### `PortfolioComposition`
Tracks portfolio changes with hash-based detection:
```swift
struct PortfolioComposition: Codable, Hashable {
    let positions: [PortfolioPosition]               // All positions
    let compositionHash: String                      // Change detection hash
}
```

#### `PositionSnapshot`
Individual stock position at a specific date:
```swift
struct PositionSnapshot: Codable {
    let symbol: String                               // Stock symbol
    let units: Double                                // Number of shares
    let priceAtDate: Double                          // Price on this date
    let valueAtDate: Double                          // Total position value
    let currency: String                             // Position currency
}
```

### Storage System (`HistoricalDataManager.swift`)

#### Enhanced Properties
- `historicalPortfolioSnapshots`: Pre-calculated portfolio data
- `currentPortfolioComposition`: Tracks portfolio changes
- `lastRetroactiveCalculationDate`: Last calculation timestamp

#### Storage Keys
```swift
private enum StorageKeys {
    static let historicalPortfolioSnapshots = "historicalPortfolioSnapshots"
    static let currentPortfolioComposition = "currentPortfolioComposition"
    static let lastRetroactiveCalculationDate = "lastRetroactiveCalculationDate"
    // ... additional keys
}
```

## Calculation Engine

### Main Entry Point
```swift
func calculateRetroactivePortfolioHistory(using dataModel: DataModel) async
```

**Process Flow:**
1. Create current portfolio composition
2. Check if composition changed using hash comparison
3. Trigger full recalculation OR incremental update
4. Store results persistently
5. Update tracking variables

### Full Recalculation
**Triggered when:** Portfolio composition changes (new stocks, quantity changes)
```swift
private func performFullPortfolioRecalculation(using dataModel: DataModel, composition: PortfolioComposition) async
```

**Process:**
1. Clear existing portfolio snapshots
2. Find earliest available historical data
3. Calculate portfolio values for entire date range
4. Store complete historical record

### Incremental Update
**Triggered when:** Portfolio unchanged, only new dates need calculation
```swift
private func performIncrementalPortfolioUpdate(using dataModel: DataModel) async
```

**Process:**
1. Find last calculated date
2. Calculate only new dates since last calculation
3. Append to existing snapshots
4. Maintain chronological order

### Core Calculation Logic
```swift
private func calculatePortfolioSnapshotsForPeriod(
    from startDate: Date,
    to endDate: Date,
    using dataModel: DataModel,
    composition: PortfolioComposition
) async -> [HistoricalPortfolioSnapshot]
```

**Algorithm:**
1. Extract all unique dates with historical price data
2. For each date:
   - Find closest price for each stock in portfolio
   - Calculate position values (price × units)
   - Convert currencies to common base (USD)
   - Sum total portfolio value
   - Calculate gains (total value - total cost)
   - Convert to preferred currency
3. Create portfolio snapshot with all position details
4. Return chronologically sorted results

## Data Flow

### Chart Data Retrieval
```swift
func getChartData(for type: ChartType, timeRange: ChartTimeRange, dataModel: DataModel?) -> [ChartDataPoint]
```

**Priority Order:**
1. **Primary**: Use stored portfolio snapshots if available
2. **Trigger**: Background calculation if data stale/missing
3. **Fallback**: Legacy real-time calculation methods
4. **Final**: Real-time snapshots for immediate display

### Background Processing Integration

#### Automatic Triggering (`DataModel.swift`)
- **1% chance** per successful stock data update
- **Startup calculation** 60 seconds after app launch
- **Smart scheduling** to avoid system overload

#### Manual Triggering
```swift
public func triggerRetroactivePortfolioCalculation()
```

## Performance Characteristics

### Memory Management
- **Maximum snapshots**: 2000 portfolio snapshots (configurable)
- **Automatic cleanup**: Removes oldest data when limit exceeded
- **Chunked processing**: Yields control every 20 calculations
- **Background queues**: Utility priority for heavy calculations

### Storage Efficiency
- **UserDefaults**: JSON encoding for cross-session persistence
- **Incremental saves**: Only save when data changes
- **Background encoding**: Heavy operations off main thread

### Currency Handling
- **USD aggregation**: All calculations normalized to USD
- **Final conversion**: Results converted to user's preferred currency
- **UK stock handling**: Automatic GBX→GBP conversion
- **Exchange rate caching**: Reuses CurrencyConverter instance

## Integration Points

### Chart System
- **Instant loading**: Pre-calculated data loads immediately
- **Fallback support**: Legacy methods remain functional
- **Progress indication**: Background calculations don't block UI

### Historical Data Collection
- **Leverages existing data**: Uses same stock price data as individual charts
- **Data validation**: Only uses prices with reasonable age (≤30 days gap)
- **Coverage requirements**: Minimum 50% of portfolio positions needed

### Error Handling
- **Graceful degradation**: Falls back to legacy methods on failure
- **Data validation**: Checks for NaN values and reasonable ranges
- **Comprehensive logging**: Detailed debug information throughout

## Configuration

### Timing Parameters
- `snapshotInterval`: 300 seconds (5 minutes) for real-time snapshots
- `maxPortfolioSnapshots`: 2000 maximum stored snapshots
- **Recalculation trigger**: 3600 seconds (1 hour) cooldown

### Data Limits
- **Date range**: Maximum 5 years of historical calculation
- **Position threshold**: 50% of portfolio positions required for valid snapshot
- **Currency conversion**: All major currencies supported

## Monitoring & Debugging

### Logging Categories
- `🔄 RETROACTIVE`: Main calculation flow
- `🔄 FULL RECALC`: Complete recalculation process
- `🔄 INCREMENTAL`: Incremental update process
- `🔄 CALC PERIOD`: Date range calculation details
- `📊`: Chart data retrieval operations

### Key Metrics
- **Calculation time**: Background processing duration
- **Data coverage**: Percentage of dates with valid portfolio data
- **Memory usage**: Number of snapshots and storage size
- **Cache hit rate**: Frequency of pre-calculated data usage

## Maintenance Operations

### Data Cleanup
```swift
func clearAllData()  // Clears all historical data including new snapshots
```

### Manual Operations
```swift
func triggerRetroactivePortfolioCalculation()  // Force recalculation
```

### Debugging Support
- **Comprehensive status**: Data coverage per symbol
- **Force snapshots**: Manual snapshot creation
- **Cache inspection**: View stored portfolio data

## Migration & Compatibility

### Backward Compatibility
- **Legacy methods preserved**: Old calculation methods remain functional
- **Gradual transition**: New system overlays existing functionality
- **Fallback support**: Automatic fallback if new system fails

### Data Migration
- **Automatic cleanup**: Clears inconsistent legacy data on startup
- **Progressive enhancement**: New features available immediately
- **Zero downtime**: No interruption to existing functionality

## Future Enhancements

### Planned Optimizations
1. **Database migration**: SQLite for complex queries
2. **Data compression**: Efficient storage for large datasets
3. **Concurrent processing**: Parallel calculation for date ranges
4. **Advanced analytics**: Sharpe ratio, drawdown analysis

### Extensibility Points
- **Multiple portfolios**: Support for different portfolio scenarios
- **Custom date ranges**: User-defined calculation periods
- **Export functionality**: CSV/PDF portfolio reports
- **Performance attribution**: Individual stock contribution analysis

## Technical Notes

### Thread Safety
- **MainActor updates**: UI updates on main thread
- **Background processing**: Heavy calculations on utility queue
- **Async/await**: Modern concurrency for reliable execution

### Error Recovery
- **Composition tracking**: Rebuilds from last known good state
- **Data validation**: Comprehensive input validation
- **Graceful fallbacks**: Multiple fallback strategies

This system provides the foundation for advanced portfolio analytics while maintaining the reliability and performance characteristics required for a production macOS application.