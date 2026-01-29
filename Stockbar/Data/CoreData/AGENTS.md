# Core Data Agents

## OVERVIEW
High-performance persistence layer for stock trades and historical data. Optimized for macOS with concurrent WAL mode and automated migration paths.

## MODEL VERSIONS
- **Current Version**: 6 (includes OHLC data)
- **Migration Policy**: Automatic lightweight migration enabled
- **Critical Points**: v3 migration triggers `needsRetroactiveCalculation` for portfolio history

## CORE ENTITIES
- `TradeEntity`: User portfolio configurations (symbol, units, cost)
- `TradingInfoEntity`: Real-time quote cache (price, change, pre/post market)
- `PriceSnapshotEntity`: 5-minute historical price points
- `PortfolioSnapshotEntity`: Total value/gains history
- `OHLCSnapshotEntity`: Candlestick data (Open, High, Low, Close, Volume)
- `PositionSnapshotEntity`: Portfolio composition at specific timestamps

## ARCHITECTURE & SERVICES
- `CoreDataStack`: Central coordinator; manages `NSPersistentContainer` and WAL lifecycle
- `BatchProcessingService`: High-throughput inserts for snapshots (chunked by 1000)
- `OHLCDataService`: Specialized actor for candlestick persistence
- `DataMigrationService`: Handles UserDefaults to Core Data transition and schema flags
- `MemoryManagementService`: Evicts old data and compresses history under pressure

## CONTEXT & CONCURRENCY
- **Reads**: Use `viewContext` for main-thread UI binding (SwiftUI)
- **Standard Writes**: Use `newBackgroundContext()` for routine CRUD
- **Batch Writes**: Use `newOptimizedBackgroundContext()` (no change tracking)
- **Merge Policy**: `NSMergeByPropertyObjectTrumpMergePolicy` (Latest update wins)

## OPERATIONAL CONSTRAINTS
- **Atomic Saves**: Always verify `hasChanges` before calling `save()`
- **Thread Safety**: Writes MUST happen on background contexts to prevent UI stalls
- **Batch Limits**: Cap batch inserts at 1000 objects to maintain memory stability
- **WAL Maintenance**: SQLite journal mode set to WAL for concurrent read/writes

## ANTI-PATTERNS
- ❌ **Main Thread Writes**: Never write to `viewContext`; it blocks the status bar refresh
- ❌ **Direct UD Access**: Don't use `UserDefaults` for historical data (use `HistoricalDataService`)
- ❌ **Unchecked Deletes**: Always check for `PositionSnapshot` cascades when removing portfolio history
- ❌ **Sync Fetches**: Avoid large synchronous fetches on the main thread; use async continuations
