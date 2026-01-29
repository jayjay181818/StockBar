# Stockbar Views Knowledge Base

## OVERVIEW
The SwiftUI presentation layer for Stockbar. It provides high-performance analytics dashboards, interactive portfolio management interfaces, and preference windows. All views are built using SwiftUI for macOS 15.4+ and adhere to strict concurrency and memory management standards.

## VIEW MODULES

### Analytics Suite
- **PortfolioAnalyticsView**: Core hub for sector allocation, diversification scoring, and correlation matrix visualization.
- **RiskAnalyticsView**: Detailed risk dashboard displaying VaR (95%/99%), Sharpe/Sortino ratios, Beta, and Maximum Drawdown analysis.
- **AttributionAnalysisView**: Performance contribution breakdown, comparing Time-Weighted Return (TWR) vs. Money-Weighted Return (MWR).

### Management & Settings
- **DataSourcesSettingsView**: Lifecycle management for API keys (Yahoo, FMP, Twelve Data) and provider verification status.
- **PriceAlertManagementView**: Interface for creating, tracking, and managing price-based notification triggers.
- **PortfolioManagement**: (Integrated in main PreferenceView) Drag-and-drop reordering and position entry.

## CORE CONVENTIONS

### Thread Safety & Concurrency
- **@MainActor Enforcement**: ALL View structs and their internal methods MUST be marked with `@MainActor`. This ensures that UI updates and data binding interactions occur safely on the main thread.
- **Async Tasks**: Use `.task` or `Task { ... }` for triggering background operations.
- **Weak References**: Always use `[weak self]` in `Task` blocks or Combine closures to prevent retain cycles, especially when accessing the `DataModel` or shared services.

### Logic Separation
- **No Heavy Logic**: Views MUST NOT contain complex calculations (e.g., Matrix math, VaR simulations). Delegate these to `Services` or `Analytics` modules.
- **No Direct Fetching**: Views should never initiate subprocesses (Python) or network requests directly. Use `DataModel` or specialized coordinator actors.
- **State Management**: Use `@State` for local UI toggles and `@ObservedObject` for shared `DataModel` access.

## UI/UX GUIDELINES
- **Native Integration**: Respect system themes (Dark/Light mode) and use standard AppKit-style spacing and padding.
- **Responsive Layouts**: Use `ScrollView` and `LazyVGrid` for analytics dashboards to ensure performance on various window sizes.
- **Hardware Acceleration**: Leverage SwiftUI's native rendering. For complex charts, refer to the specialized implementations in `Stockbar/Charts`.

## ANTI-PATTERNS
- **Retain Cycles**: Capturing `self` strongly in async blocks.
- **Main Thread Blockage**: Performing synchronous calculations or data parsing inside the view body or helper methods.
- **Hardcoded Styling**: Avoid hardcoded colors; use semantic colors (e.g., `.secondary`, `.accentColor`) to respect user preferences.
