# Stockbar Data Layer Knowledge Base

**Architecture:** Actor-backed Data Coordination | **Concurrency:** Swift 6 Strict Isolation
**Domain:** Centralized application state, persistence, and network orchestration.

## OVERVIEW
The Data layer is the central source of truth for Stockbar. It manages the lifecycle of `RealTimeTrade` objects, coordinates background refreshes, and ensures persistent storage via Core Data and UserDefaults.

## CORE COMPONENTS

### DataModel & RefreshCoordinator
- **DataModel.swift (@MainActor)**: The primary `@ObservableObject` that UI binds to. It orchestrates all services and manages the `realTimeTrades` array.
- **RefreshCoordinator (Actor)**: A dedicated actor used to serialize refresh operations. It prevents race conditions during bulk updates by ensuring mutations to `realTimeTrades` occur in isolation.

### Networking Submodule (`Stockbar/Data/Networking/`)
- **NetworkService**: Protocol-based service layer for data fetching.
- **PythonNetworkService**: Implementation that executes `get_stock_data.py` via subprocess.
- **Error Handling**: Comprehensive `NetworkError` enum covering script failures and timeouts.

### CoreData Submodule (`Stockbar/Data/CoreData/`)
- **TradeDataService**: Handles CRUD operations for trades and trading info.
- **HistoricalDataService**: Manages persistent time-series data for performance charts.
- **Services**: Includes migration, memory management, and data compression services.

## DATA FLOW & PERSISTENCE
1. **Initial Hydration**: Trades are loaded from `TradeDataService` (Core Data) and `UserDefaults` on app launch.
2. **Refresh Cycle**: `RefreshService` triggers updates every 5 minutes (default).
3. **Persistence**: Changes to trades are debounced (2.0s) and saved to Core Data automatically.

## KEY CONVENTIONS & NORMALIZATION
- **Strict Concurrency**: All UI-facing data MUST stay on the `@MainActor`. Use `RefreshCoordinator` for background-to-foreground transitions.
- **GBX Normalization**: London stocks (`.L`) are normalized from GBX (pence) to GBP (pounds) early in the pipeline (÷100) to ensure consistent portfolio totals.
- **Cache Intervals**:
  - `refreshInterval`: 5 minutes (300s) default.
  - `cacheInterval`: 15 minutes (900s) for successful fetches.
  - `maxCacheAge`: 1 hour (3600s) before forced refresh.
- **Trade Update Trigger**: Use `triggerTradeUpdate()` in `DataModel` to manually sync deep property changes to the persistence pipeline.

## PERFORMANCE TARGETS
- **Memory Limit**: <200MB resident size (enforced by `MemoryManagementService`).
- **Load Time**: <500ms for initial hydration of 100+ trades.
- **Concurrency**: Zero data races (Swift 6 checked).
