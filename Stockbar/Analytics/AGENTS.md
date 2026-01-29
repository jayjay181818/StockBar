# Stockbar Analytics Knowledge Base

**Domain:** Complex Financial Calculations (Risk, Correlation, Sector Attribution)
**Architecture:** Service-oriented Actor-based Architecture
**Status:** Pure Logic Layer (No UI/Network)

## OVERVIEW
The Analytics module serves as Stockbar's financial engine, providing professional-grade portfolio analysis. It transforms raw price and position data into actionable risk and performance metrics using pure mathematical processing.

## CORE SERVICES
All analytics services are implemented as Swift actors to ensure thread-safe calculations across background tasks.

- **RiskMetricsService**: Calculates VaR (95%/99%), Sharpe Ratio, Sortino Ratio, Beta, and Maximum Drawdown.
- **CorrelationMatrixService**: Generates asset-to-asset and asset-to-market correlation matrices to identify diversification gaps.
- **SectorAnalysisService**: Performs GICS sector/industry breakdown and calculates Herfindahl-based diversification scores.
- **AttributionAnalysisService**: Decomposes portfolio returns into individual stock and sector contributions.

## WHERE TO LOOK
| Component | Key Symbols | Responsibility |
|-----------|-------------|----------------|
| **Risk Metrics** | `RiskMetrics`, `VaR`, `Sharpe` | Statistical risk exposure & volatility |
| **Correlation** | `CorrelationMatrix`, `Beta` | Relationship between assets & benchmarks |
| **Sectors** | `SectorAllocation`, `GICS` | Concentration analysis & sector mapping |
| **Attribution** | `PerformanceAttribution` | Return decomposition & contribution |

## CONVENTIONS
1. **Actor Isolation**: All services MUST be defined as `actor`. Access via `await Service.shared.calculate(...)`.
2. **Pure Logic**: Services must be "pure": input data → output results. They should not fetch data from Core Data or Network directly.
3. **Data Flow**: Use `PositionSummary` and `HistoricalPortfolioSnapshot` for inputs; return immutable result structs.

## CONSTRAINTS
- **NO UI**: Never import SwiftUI or AppKit. No `View`, `Color`, or UI state storage.
- **NO Network**: Do not initiate data fetching. All required data must be passed as parameters.
- **Non-Blocking**: For heavy calculations (e.g., large correlation matrices), use `Task.yield()` to prevent executor starvation.

## PERFORMANCE TARGETS
- **Calculation Time**: <100ms for standard portfolios (up to 50 assets).
- **Memory Footprint**: Minimal; avoid large intermediate arrays for historical processing.
- **Precision**: Use `Double` for all internal financial math.
