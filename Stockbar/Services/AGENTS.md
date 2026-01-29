# Stockbar Services Layer Knowledge Base

**Architecture:** Service/Coordinator/Scheduler Patterns | **Concurrency:** Swift 6 Actors
**Domain:** Business logic, data refresh orchestration, and analytical processing.

## OVERVIEW
The Services layer contains the application's business logic, separated into functional units that handle data refreshing, historical data collection, technical analysis, and UI formatting. It acts as the bridge between the Data layer and the UI.

## CORE PATTERNS

### 1. Services (`*Service`)
Stateless or stateful logic providers focused on a specific domain.
- **RefreshService**: Manages the batch/staggered refresh cycle. Subscribes to `ConnectivityMonitor` to pause/resume based on network status.
- **PortfolioCalculationService**: Handles complex financial math (net gains, total value) with multi-currency support.
- **MenuBarFormattingService**: Generates `NSAttributedString` for the status bar with an internal 5s cache to minimize UI churn.

### 2. Coordinators (`*Coordinator`)
Stateful actors that manage complex data flows and synchronization.
- **CacheCoordinator (Actor)**: Manages TTL (15min) and retry policies.
  - **Circuit Breaker**: Suspends symbols after 5 consecutive failures for 1 hour to prevent unnecessary network overhead.
  - **Exponential Backoff**: Uses progressive intervals (1m, 2m, 5m, 10m) for failed fetches.
- **HistoricalDataCoordinator**: Manages multi-year chunk fetching and persistence of time-series data.

### 3. Schedulers (`*Scheduler`)
Time-based or event-driven task orchestrators.
- **BackfillScheduler**: Detects gaps in historical data and schedules background tasks for gap-filling.

## KEY WORKFLOWS

### Refresh Flow
1. **Trigger**: `RefreshService` timer (default 5m) or manual user action.
2. **Policy Check**: `RefreshService` queries `CacheCoordinator.shouldRefresh(symbol:)`.
3. **Execution**: If expired or in retry window, `NetworkService` fetches batch data.
4. **Update**: `RefreshCoordinator` (via `RefreshService`) ensures thread-safe mutation of `DataModel` on the `@MainActor`.

## CONVENTIONS
- **Actor Usage**: All stateful services (e.g., `CacheCoordinator`) MUST be implemented as `actor` to ensure thread safety under Swift 6.
- **Singleton Pattern**: Services use `static let shared` for global access where appropriate.
- **Loose Coupling**: `RefreshService` holds a `weak` reference to `DataModel` to prevent retain cycles.

## ANTI-PATTERNS
- **Main Thread Logic**: Never perform heavy calculations or IO in services without moving to a background context/actor.
- **Circuit Breaker Ignorance**: Do not bypass `CacheCoordinator` checks; hammering failed APIs leads to rate-limiting.
- **Logic in Views**: Keep all formatting and analytical logic in `MenuBarFormattingService` or `TechnicalIndicatorService`.
