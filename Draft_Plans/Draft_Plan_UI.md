# Stockbar UI/UX Improvements Plan (Draft_Plan_UI.md)

**Date**: 2025-10-02
**Version**: 2.3.0 UI Enhancement Track
**Status**: Planning Phase

---

## Overview

Comprehensive UI/UX enhancement plan covering menu bar interface customization, advanced charting capabilities, and portfolio analytics. This plan builds on the existing robust Swift 6.0/Python hybrid architecture with minimal breaking changes and full backward compatibility.

**Key Principles:**
- Maintain <5% CPU usage performance target
- Zero breaking changes to existing functionality
- Leverage existing data models and services where possible
- Incremental rollout with feature flags

---

## A. Enhanced Menu Bar Interface

### A.1 Configurable Display Modes 📊
**Priority**: High
**Duration**: 1 week
**Dependencies**: None

#### Files to Create
```
Stockbar/Models/MenuBarDisplaySettings.swift          (120 lines)
Stockbar/Services/MenuBarFormattingService.swift      (200 lines)
```

#### Files to Modify
```
Stockbar/Stockbar/StockStatusBar.swift                (add ~80 lines)
Stockbar/Stockbar/PreferenceView.swift                (add ~120 lines)
Stockbar/Stockbar/Data/DataModel.swift                (add ~30 lines)
```

#### Display Mode Options

**1. Compact Mode** (Menu bar space-saving)
```
Format: "AAPL +2.45%"
Use case: Many stocks in portfolio, limited menu bar space
```

**2. Expanded Mode** (Full information)
```
Format: "AAPL $175.23 +2.45%"
Use case: Detailed monitoring, fewer stocks
```

**3. Minimal Mode** (Symbol only)
```
Format: "AAPL ▲"
Use case: Maximum space efficiency
```

**4. Custom Template Mode** (User-defined)
```
Placeholders: {symbol}, {price}, {change}, {changePct}, {currency}
Example: "{symbol}: {changePct} ({change})"
```

#### Change Display Toggle
- Dollar amount: "+$4.29"
- Percentage: "+2.45%"
- Both: "+$4.29 (2.45%)"
- User-selectable per-symbol or global

#### Implementation Details

**MenuBarDisplaySettings Model:**
```swift
struct MenuBarDisplaySettings: Codable {
    enum DisplayMode: String, Codable, CaseIterable {
        case compact      // Symbol + %
        case expanded     // Symbol + Price + %
        case minimal      // Symbol + Indicator
        case custom       // User template
    }

    enum ChangeFormat: String, Codable, CaseIterable {
        case percentage   // +2.45%
        case dollar       // +$4.29
        case both         // +$4.29 (2.45%)
    }

    var displayMode: DisplayMode = .expanded
    var changeFormat: ChangeFormat = .percentage
    var customTemplate: String? = nil
    var showCurrency: Bool = true
    var decimalPlaces: Int = 2
    var useArrowIndicators: Bool = false
}
```

**MenuBarFormattingService Responsibilities:**
- Format stock data according to display settings
- Handle decimal rounding and currency formatting
- Generate color-coded attributes for NSAttributedString
- Template parsing and validation for custom mode
- Performance optimization (caching formatted strings)

#### UI Implementation (PreferenceView)
Add new "Menu Bar Display" section in Portfolio tab:
- Display mode picker (Compact/Expanded/Minimal/Custom)
- Change format segmented control
- Custom template text field with validation
- Live preview of formatting
- Arrow indicator toggle
- Decimal places stepper (0-4)

#### UserDefaults Keys
```swift
"menuBarDisplayMode"       // DisplayMode.rawValue
"menuBarChangeFormat"      // ChangeFormat.rawValue
"menuBarCustomTemplate"    // String?
"menuBarShowCurrency"      // Bool
"menuBarDecimalPlaces"     // Int
"menuBarUseArrows"         // Bool
```

---

### A.2 Visual Customization Options 🎨
**Priority**: Medium
**Duration**: 3-4 days

#### Features

**1. Color Scheme Customization**
- Beyond green/red: Blue/orange, purple/yellow, monochrome
- User-defined RGB/hex color picker
- Accessibility-friendly high-contrast mode
- Color intensity slider (subtle to vibrant)

**2. Icon & Indicator Options**
- Arrow indicators (▲▼ vs ⬆⬇ vs 🔺🔻)
- Emoji indicators (🟢🔴, 📈📉, ✅❌)
- Symbol-only mode with background color
- Flashing animation on significant change (opt-in)

**3. Typography Options**
- Font size: Small (10pt), Medium (12pt), Large (14pt)
- Font weight: Regular, Medium, Bold
- Monospace option for price alignment

**4. Animation Options**
- Ticker scrolling for many stocks
- Fade-in/out transitions on update
- Pulse effect on major change
- Disable all animations (performance mode)

#### Files to Create
```
Stockbar/Models/MenuBarVisualSettings.swift           (90 lines)
Stockbar/Views/MenuBarCustomizationView.swift         (150 lines)
```

---

## B. Chart Enhancements

### B.1 Advanced Chart Types 📈
**Priority**: High
**Duration**: 2 weeks
**Dependencies**: Python script enhancement, Core Data schema update

#### Files to Create
```
Stockbar/Charts/CandlestickChartView.swift            (250 lines)
Stockbar/Charts/VolumeChartView.swift                 (180 lines)
Stockbar/Charts/TechnicalIndicatorView.swift          (300 lines)
Stockbar/Models/CandlestickData.swift                 (120 lines)
Stockbar/Models/TechnicalIndicatorData.swift          (200 lines)
Stockbar/Services/TechnicalIndicatorService.swift     (500 lines)
Stockbar/Services/OHLCDataService.swift               (200 lines)
```

#### Files to Modify
```
Stockbar/Charts/PerformanceChartView.swift            (add ~150 lines)
Stockbar/Data/HistoricalData.swift                    (add ~80 lines)
Stockbar/Resources/get_stock_data.py                  (add ~60 lines)
Data/CoreData/StockbarModel.xcdatamodeld              (new entity: OHLCSnapshot)
```

#### Chart Types Implementation

**1. Candlestick Charts (OHLC)**
```swift
struct OHLCSnapshot: Codable {
    let timestamp: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Int64
    let symbol: String
}
```

Features:
- Color-coded candles (green up, red down)
- Hollow/filled candle option
- Wick visualization for high/low
- Volume bars below chart
- Switchable between candlestick and OHLC bars

**2. Volume Charts**
- Overlaid bars on price chart
- Separate volume panel option
- Volume moving average overlay
- Color-code by price direction
- Logarithmic scale option

**3. Technical Indicators**

**Moving Averages:**
- SMA (Simple Moving Average): 20, 50, 200 day
- EMA (Exponential Moving Average): 12, 26 day
- Customizable periods
- Multiple MAs on same chart
- Crossover detection and highlighting

**RSI (Relative Strength Index):**
- 14-period default (customizable)
- Overbought (70) / Oversold (30) zones
- Divergence detection
- Separate panel below price chart

**MACD (Moving Average Convergence Divergence):**
- MACD line (12-26 EMA difference)
- Signal line (9-period EMA of MACD)
- Histogram (MACD - Signal)
- Bullish/bearish crossover detection

**Bollinger Bands:**
- Middle band (20-period SMA)
- Upper/lower bands (2 standard deviations)
- Bandwidth indicator
- Squeeze detection

**Additional Indicators:**
- Stochastic Oscillator (%K, %D lines)
- ATR (Average True Range) - volatility
- OBV (On-Balance Volume)
- Fibonacci Retracement levels

#### Python Script Enhancement

Modify `get_stock_data.py` to support OHLC fetching:

```python
def fetch_ohlc_data(symbol, period='1mo', interval='1d'):
    """
    Fetch OHLC data from yfinance

    period: 1d, 5d, 1mo, 3mo, 6mo, 1y, 2y, 5y, 10y, ytd, max
    interval: 1m, 2m, 5m, 15m, 30m, 60m, 90m, 1h, 1d, 5d, 1wk, 1mo, 3mo
    """
    ticker = yf.Ticker(symbol)
    hist = ticker.history(period=period, interval=interval)

    # Return OHLCV data
    return hist[['Open', 'High', 'Low', 'Close', 'Volume']].to_dict('records')
```

New endpoints:
- `--ohlc <symbol> <period> <interval>` - Fetch OHLC data
- `--batch-ohlc <symbols> <period> <interval>` - Batch OHLC fetch

#### Core Data Schema Update

New entity: `OHLCSnapshot`
```
Attributes:
- timestamp: Date
- symbol: String
- open: Double
- high: Double
- low: Double
- close: Double
- volume: Int64
```

Relationships:
- One-to-many from Trade (symbol)

#### Chart UI Implementation

Add to `PerformanceChartView`:
- Chart type picker: Line / Candlestick / OHLC Bars / Area
- Indicator selector (multi-select)
- Indicator configuration panel
- Time period selector (1D, 5D, 1M, 3M, 6M, 1Y, 5Y)
- Interval selector (1m, 5m, 15m, 1h, 1D, 1W)

---

### B.2 Interactive Chart Features 🖱️
**Priority**: Medium
**Duration**: 1 week

#### Files to Create
```
Stockbar/Charts/ChartInteractionManager.swift         (300 lines)
Stockbar/Charts/ChartAnnotationView.swift             (200 lines)
Stockbar/Charts/ChartGestureHandler.swift             (250 lines)
Stockbar/Models/ChartAnnotation.swift                 (80 lines)
```

#### Features

**1. Zoom & Pan Gestures**
- Pinch-to-zoom on macOS trackpad
- Scroll wheel zoom (vertical = Y-axis, horizontal = X-axis)
- Two-finger pan for chart navigation
- Double-click to reset zoom
- Zoom level indicator
- Smooth animations with inertia

**2. Chart Annotations**
```swift
struct ChartAnnotation: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let type: AnnotationType
    let title: String
    let description: String?
    let color: String // RGB hex

    enum AnnotationType: String, Codable {
        case earnings       // Earnings report
        case dividend       // Dividend payment
        case split          // Stock split
        case custom         // User-created
        case news           // Major news event
    }
}
```

Features:
- Vertical line marker with label
- Hover tooltip with details
- User-created annotations
- Automatic earnings/dividend detection (via yfinance)
- Import/export annotations

**3. Crosshair Tool**
- Vertical/horizontal lines on hover
- Display exact values at cursor position
- Snap to data points
- Distance measurement between two points
- Percentage change calculation

**4. Chart Export**
- Export as PNG (retina resolution)
- Export as PDF (vector)
- Export as CSV (raw data)
- Copy chart to clipboard
- Email chart directly
- Customizable export size and DPI

#### UI Implementation
- Toolbar above chart with gesture toggle buttons
- Annotation editor popover
- Export options menu
- Keyboard shortcuts (Z for zoom, P for pan, C for crosshair)

---

### B.3 Chart Data Management 💾
**Priority**: High (prerequisite for B.1)
**Duration**: 3-4 days

#### Services to Create
```
Stockbar/Services/ChartDataCacheService.swift         (280 lines)
Stockbar/Services/OHLCFetchCoordinator.swift          (250 lines)
```

#### Caching Strategy
- In-memory cache for recently viewed charts
- Core Data persistence for historical OHLC data
- Automatic cache invalidation (15-minute intervals for intraday)
- Compression for old data (>1 year)
- Cache size limit (100 MB default, configurable)

#### Data Fetching Logic
- Background fetch on app launch for portfolio symbols
- On-demand fetch for non-portfolio symbols
- Incremental updates (fetch only new data points)
- Retry logic with exponential backoff
- Rate limiting to avoid API throttling

---

## C. Portfolio Analysis Improvements

### C.1 Risk Metrics Dashboard 📉
**Priority**: High
**Duration**: 1.5 weeks

#### Files to Create
```
Stockbar/Analytics/RiskMetricsService.swift           (400 lines)
Stockbar/Analytics/PortfolioRiskAnalytics.swift       (300 lines)
Stockbar/Views/RiskAnalysisView.swift                 (350 lines)
Stockbar/Models/RiskMetrics.swift                     (150 lines)
```

#### Files to Modify
```
Stockbar/Data/HistoricalData.swift                    (add ~100 lines)
Stockbar/PreferenceView.swift                         (add new tab)
```

#### Risk Metrics Implementation

**1. VaR (Value at Risk)**
```swift
struct ValueAtRisk {
    let var95: Double  // 95% confidence interval
    let var99: Double  // 99% confidence interval
    let timeHorizon: TimeInterval // 1 day, 1 week, 1 month
    let calculationMethod: VaRMethod // Historical, Parametric, Monte Carlo

    enum VaRMethod: String {
        case historical    // Historical simulation
        case parametric    // Variance-covariance
        case monteCarlo    // Monte Carlo simulation
    }
}
```

Methods:
- Historical VaR: Use actual return distribution
- Parametric VaR: Assume normal distribution
- Monte Carlo VaR: Simulate thousands of scenarios
- Display as dollar amount and percentage

**2. Maximum Drawdown (Enhanced)**
Already started in `PortfolioAnalytics`, enhance with:
- Drawdown duration tracking
- Recovery time analysis
- Underwater plot (visual)
- Top 5 worst drawdowns
- Current drawdown status

**3. Sharpe Ratio (Enhanced)**
Already started, enhance with:
```swift
func calculateSharpeRatio(
    returns: [Double],
    riskFreeRate: Double = 0.02,  // 2% annual default
    annualizationFactor: Double = 252  // Trading days
) -> Double {
    let excessReturns = returns.map { $0 - (riskFreeRate / annualizationFactor) }
    let meanExcessReturn = excessReturns.reduce(0, +) / Double(excessReturns.count)
    let stdDev = standardDeviation(excessReturns)

    return (meanExcessReturn / stdDev) * sqrt(annualizationFactor)
}
```

Features:
- Configurable risk-free rate
- Time-period selection
- Comparison to benchmark (S&P 500)
- Historical Sharpe ratio chart

**4. Beta (Market Correlation)**
```swift
struct BetaAnalysis {
    let beta: Double              // Portfolio beta
    let correlation: Double       // Correlation coefficient
    let rSquared: Double          // R² (explanatory power)
    let alpha: Double             // Jensen's alpha
    let benchmarkSymbol: String   // e.g., "^GSPC" for S&P 500
}
```

Implementation:
- Fetch benchmark index data (S&P 500, NASDAQ, etc.)
- Calculate covariance and variance
- Rolling beta over time
- Individual stock betas
- Beta-weighted portfolio construction

**5. Standard Deviation / Volatility (Enhanced)**
Already calculated, enhance with:
- Annualized volatility
- Rolling volatility (30-day, 60-day, 90-day)
- Volatility cone (historical range)
- Comparison to market volatility (VIX)

**6. Sortino Ratio (Downside Risk)**
```swift
func calculateSortinoRatio(
    returns: [Double],
    targetReturn: Double = 0.0,
    annualizationFactor: Double = 252
) -> Double {
    let excessReturns = returns.map { $0 - targetReturn }
    let meanExcessReturn = excessReturns.reduce(0, +) / Double(excessReturns.count)

    // Only consider downside volatility
    let downsideReturns = excessReturns.filter { $0 < 0 }
    let downsideDeviation = sqrt(
        downsideReturns.map { $0 * $0 }.reduce(0, +) / Double(downsideReturns.count)
    )

    return (meanExcessReturn / downsideDeviation) * sqrt(annualizationFactor)
}
```

**7. Additional Risk Metrics**
- Information Ratio (vs. benchmark)
- Treynor Ratio (return per unit of systematic risk)
- Calmar Ratio (return / max drawdown)
- Ulcer Index (drawdown severity)
- Tail Risk measures (skewness, kurtosis)

#### UI Implementation

New "Risk Analysis" tab in Preferences:

**Summary Panel:**
- Risk score (0-100, color-coded)
- Key metrics grid (VaR, Sharpe, Beta, Volatility)
- Risk gauge visualization

**Detailed Metrics:**
- Expandable sections for each metric
- Historical trend charts
- Benchmark comparisons
- Interpretation guidance ("What does this mean?")

**Risk Scenarios:**
- Stress testing (market crash scenarios)
- What-if analysis (position size changes)
- Correlation breakdown during crises

---

### C.2 Sector/Industry Breakdown 🏢
**Priority**: Medium
**Duration**: 1 week

#### Files to Create
```
Stockbar/Analytics/SectorAnalysisService.swift        (350 lines)
Stockbar/Models/SectorAllocation.swift                (180 lines)
Stockbar/Views/SectorBreakdownView.swift              (300 lines)
Stockbar/Services/SectorDataFetcher.swift             (200 lines)
```

#### Sector Classification

**Data Source:**
Use yfinance to fetch sector/industry metadata:
```python
import yfinance as yf

ticker = yf.Ticker("AAPL")
info = ticker.info

sector = info.get('sector', 'Unknown')        # e.g., "Technology"
industry = info.get('industry', 'Unknown')    # e.g., "Consumer Electronics"
```

**Sector Model:**
```swift
struct SectorAllocation: Identifiable {
    let id = UUID()
    let sector: String
    let industryBreakdown: [IndustryAllocation]
    let totalValue: Double
    let percentageOfPortfolio: Double
    let dayChange: Double
    let dayChangePercent: Double
    let positions: [PositionSummary]
}

struct IndustryAllocation {
    let industry: String
    let value: Double
    let percentage: Double
    let positions: [String] // Symbols
}

struct PositionSummary {
    let symbol: String
    let value: Double
    let percentageOfSector: Double
}
```

**Standard Sectors:**
1. Technology
2. Healthcare
3. Financials
4. Consumer Cyclical
5. Consumer Defensive
6. Industrials
7. Energy
8. Utilities
9. Real Estate
10. Basic Materials
11. Communication Services

#### Features

**1. Sector Allocation Visualization**
- Pie chart (SwiftUI Pie Chart)
- Bar chart (horizontal, sorted by value)
- Treemap (hierarchical: sector → industry → stocks)
- Toggle between value and percentage

**2. Sector Performance**
- Day/week/month/YTD performance by sector
- Best/worst performing sectors
- Sector momentum (accelerating/decelerating)
- Contribution to portfolio return

**3. Diversification Analysis**
```swift
struct DiversificationScore {
    let score: Double              // 0-100 (100 = perfectly diversified)
    let sectorConcentration: Double // Herfindahl index
    let recommendations: [String]   // "Consider diversifying into Healthcare"
    let riskLevel: RiskLevel       // Low, Medium, High

    enum RiskLevel {
        case low      // <25% in any sector
        case medium   // 25-50% in any sector
        case high     // >50% in single sector
    }
}
```

**4. Sector Comparison**
- Performance vs. sector benchmark ETFs (XLK, XLV, etc.)
- Sector correlation matrix
- Sector rotation indicators

#### UI Implementation

New "Sector Analysis" section in Charts tab:

**Allocation View:**
- Interactive pie chart (click to drill into industry)
- Sector summary cards
- Top holdings per sector
- Export to CSV

**Performance View:**
- Sector performance comparison chart
- Attribution analysis
- Historical sector weights over time

**Diversification Dashboard:**
- Diversification score with visualization
- Concentration risk alerts
- Rebalancing suggestions

---

### C.3 Performance Attribution 🎯
**Priority**: Medium
**Duration**: 4-5 days

#### Files to Create
```
Stockbar/Analytics/AttributionAnalysisService.swift   (350 lines)
Stockbar/Views/AttributionAnalysisView.swift          (280 lines)
Stockbar/Models/AttributionData.swift                 (150 lines)
```

#### Attribution Analysis Types

**1. Individual Stock Contribution**
```swift
struct StockAttribution {
    let symbol: String
    let totalReturn: Double              // $ amount contributed to portfolio
    let percentContribution: Double      // % of total portfolio return
    let weight: Double                   // % of portfolio value
    let weightedReturn: Double           // weight × return
}
```

Calculation:
```
Stock Contribution = Stock Weight × Stock Return
Portfolio Return = Σ(Stock Contributions)
```

Visualization:
- Waterfall chart showing each stock's contribution
- Color-coded by positive/negative contribution
- Sortable by contribution, return, or weight

**2. Sector Contribution**
- Aggregate individual stocks by sector
- Sector allocation effect vs. stock selection effect
- Brinson attribution model

**3. Time-Weighted Return (TWR) vs. Money-Weighted Return (MWR)**

**TWR** (measures investment performance):
```swift
func calculateTWR(
    portfolioValues: [PortfolioSnapshot],
    cashFlows: [CashFlow]
) -> Double {
    // Geometric linking of sub-period returns
    // Not affected by timing of deposits/withdrawals
}
```

**MWR** (measures investor's personal return):
```swift
func calculateMWR(
    portfolioValues: [PortfolioSnapshot],
    cashFlows: [CashFlow]
) -> Double {
    // IRR (Internal Rate of Return) calculation
    // Affected by timing of deposits/withdrawals
}

struct CashFlow {
    let date: Date
    let amount: Double  // Positive = deposit, Negative = withdrawal
}
```

**4. Best/Worst Performers**
- Top 5 / Bottom 5 by return
- Top 5 / Bottom 5 by contribution
- Time range selector (1D, 1W, 1M, 3M, YTD, 1Y, All)
- Comparison to portfolio average return

#### UI Implementation

New "Attribution" view in Charts tab:

**Contribution Waterfall:**
- Animated waterfall chart
- Hover tooltips with details
- Toggle between $ and %

**Return Comparison:**
- TWR vs. MWR gauge
- Explanation of difference
- Cash flow timeline

**Leaderboard:**
- Top/bottom performers table
- Sortable columns
- Click to view stock details

---

### C.4 Correlation Analysis 🔗
**Priority**: Low
**Duration**: 3-4 days

#### Files to Create
```
Stockbar/Analytics/CorrelationMatrixService.swift     (300 lines)
Stockbar/Views/CorrelationHeatmapView.swift           (250 lines)
Stockbar/Models/CorrelationData.swift                 (100 lines)
```

#### Correlation Matrix

**Calculation:**
```swift
func calculateCorrelationMatrix(
    returns: [[Double]]  // Each inner array = stock's return series
) -> [[Double]] {
    let n = returns.count
    var correlationMatrix = Array(repeating: Array(repeating: 0.0, count: n), count: n)

    for i in 0..<n {
        for j in 0..<n {
            if i == j {
                correlationMatrix[i][j] = 1.0  // Perfect correlation with self
            } else {
                correlationMatrix[i][j] = pearsonCorrelation(returns[i], returns[j])
            }
        }
    }

    return correlationMatrix
}

func pearsonCorrelation(_ x: [Double], _ y: [Double]) -> Double {
    let n = Double(x.count)
    let sumX = x.reduce(0, +)
    let sumY = y.reduce(0, +)
    let sumXY = zip(x, y).map(*).reduce(0, +)
    let sumX2 = x.map { $0 * $0 }.reduce(0, +)
    let sumY2 = y.map { $0 * $0 }.reduce(0, +)

    let numerator = n * sumXY - sumX * sumY
    let denominator = sqrt((n * sumX2 - sumX * sumX) * (n * sumY2 - sumY * sumY))

    return numerator / denominator
}
```

**Heatmap Visualization:**
- Color gradient: Dark red (-1) → White (0) → Dark green (+1)
- Symmetric matrix (mirror diagonal)
- Interactive: click cell to see details
- Cluster similar correlations

**Diversification Score:**
```swift
struct DiversificationMetrics {
    let averageCorrelation: Double      // Mean of all pairs
    let maxCorrelation: Double          // Highest pairwise correlation
    let clusterCount: Int               // Number of correlation clusters
    let diversificationRatio: Double    // Portfolio vol / weighted avg vol
    let effectiveN: Double              // Effective number of independent bets
}
```

**Correlation to Market:**
- Fetch S&P 500 / NASDAQ data
- Calculate portfolio correlation to market
- Market-correlated vs. uncorrelated positions
- Hedging opportunities

#### UI Implementation

New "Correlation" section in Charts tab:

**Heatmap:**
- Color-coded correlation matrix
- Symbol labels on axes
- Click to highlight row/column

**Insights Panel:**
- Highest correlated pairs (risk concentration)
- Lowest correlated pairs (diversification)
- Correlation to market indices

**Time Evolution:**
- Rolling correlation over time
- Correlation breakdown during market stress
- Correlation stability score

---

## Implementation Roadmap

### Phase 1: Foundation (Week 1-2)
**Goal**: Core infrastructure for all features

**Tasks:**
1. Create MenuBarDisplaySettings and formatting service
2. Enhance Python script for OHLC data fetching
3. Extend Core Data schema for OHLC storage
4. Implement base chart interaction framework
5. Create risk metrics calculation service

**Deliverables:**
- Menu bar customization functional
- OHLC data pipeline working
- Basic risk metrics calculated

---

### Phase 2: Chart Enhancements (Week 3-4)
**Goal**: Advanced charting capabilities

**Tasks:**
1. Implement candlestick chart view
2. Add volume chart overlay
3. Create moving average indicators
4. Implement RSI and MACD
5. Add Bollinger Bands
6. Implement zoom and pan gestures
7. Create annotation system

**Deliverables:**
- All chart types functional
- 5 technical indicators working
- Interactive chart controls

---

### Phase 3: Risk Analytics (Week 5-6)
**Goal**: Comprehensive risk analysis

**Tasks:**
1. Implement VaR calculations (all methods)
2. Enhance drawdown analysis
3. Calculate Sharpe and Sortino ratios
4. Implement beta calculation with benchmark
5. Create risk analysis UI
6. Add stress testing scenarios

**Deliverables:**
- Risk dashboard complete
- All risk metrics calculated
- Benchmark comparison working

---

### Phase 4: Portfolio Analytics (Week 7-8)
**Goal**: Sector and attribution analysis

**Tasks:**
1. Implement sector classification service
2. Create sector allocation views
3. Build attribution analysis
4. Calculate TWR vs. MWR
5. Implement correlation matrix
6. Create heatmap visualization

**Deliverables:**
- Sector breakdown functional
- Attribution analysis complete
- Correlation heatmap working

---

### Phase 5: Polish & Testing (Week 9-10)
**Goal**: Refinement and validation

**Tasks:**
1. Performance optimization
2. Unit tests for all services
3. UI/UX refinement
4. Accessibility improvements
5. Documentation
6. Beta testing

**Deliverables:**
- All features polished
- Test coverage >80%
- User documentation complete
- Performance targets met

---

## Technical Architecture

### Data Flow

```
User Interaction (Menu Bar / Charts)
         ↓
   DataModel (Main Actor)
         ↓
 Service Layer (Actors)
  ├─ MenuBarFormattingService
  ├─ TechnicalIndicatorService
  ├─ RiskMetricsService
  ├─ SectorAnalysisService
  ├─ AttributionAnalysisService
  └─ CorrelationMatrixService
         ↓
  Data Sources
  ├─ Core Data (Historical OHLC)
  ├─ In-Memory Cache (Recent data)
  └─ Python Script (Network fetch)
         ↓
  External APIs
  ├─ Yahoo Finance (yfinance)
  └─ Market Index Data
```

### Concurrency Model

**Swift 6 Actors:**
- All calculation services as isolated actors
- Main actor for UI updates
- Background actors for data fetching
- Coordinator actors for complex workflows

**Performance Targets:**
- Menu bar update: <50ms
- Chart rendering: <100ms (60 FPS target)
- Risk calculation: <500ms (background)
- Correlation matrix: <1s (up to 50 stocks)
- CPU usage: <5% average, <20% peak

### Data Storage Strategy

**Core Data Entities:**
```
OHLCSnapshot
├─ Attributes: timestamp, symbol, open, high, low, close, volume
└─ Relationship: belongsToTrade (Trade entity)

TechnicalIndicatorCache
├─ Attributes: symbol, indicatorType, period, timestamp, value
└─ Optimization: Index on (symbol, indicatorType, timestamp)

SectorMetadata
├─ Attributes: symbol, sector, industry, lastUpdated
└─ Cached for 7 days, refresh weekly
```

**Caching Layers:**
1. **L1 Cache (Memory)**: Recent data, hot paths
2. **L2 Cache (Core Data)**: Historical data, calculated metrics
3. **L3 Cache (File System)**: Compressed old data (>1 year)

**Cache Invalidation:**
- OHLC: 15 minutes for intraday, daily for historical
- Indicators: Recalculate on new OHLC data
- Risk metrics: Recalculate on portfolio change
- Sector metadata: 7-day TTL

### Dependencies

**Existing (No new dependencies):**
- Swift Charts (built-in)
- Accelerate (matrix operations, already in macOS)
- Foundation (statistics)
- Core Data (persistence)

**Python Libraries (existing):**
- yfinance (already used)
- pandas (dependency of yfinance)

### Testing Strategy

**Unit Tests:**
- All calculation services (TDD approach)
- Menu bar formatting logic
- Data model transformations
- Cache management

**Integration Tests:**
- Data flow from Python to UI
- Chart rendering with real data
- Core Data migrations

**UI Tests:**
- Menu bar customization flows
- Chart interactions
- Preference pane navigation

**Performance Tests:**
- Chart rendering benchmarks
- Risk calculation speed tests
- Memory usage under load
- CPU usage monitoring

**Validation Tests:**
- Financial calculation accuracy
- Compare to known correct values
- Cross-reference with financial websites

---

## Success Metrics

### Adoption Metrics
- ✅ 70%+ users customize menu bar display
- ✅ 60%+ users view advanced charts weekly
- ✅ 40%+ users check risk metrics monthly
- ✅ 30%+ users utilize sector analysis

### Performance Metrics
- ✅ <5% average CPU usage maintained
- ✅ <100ms chart render time (60 FPS)
- ✅ <200 MB memory footprint
- ✅ <1s risk calculation for 50-stock portfolio

### Quality Metrics
- ✅ >80% test coverage
- ✅ Zero crashes in production
- ✅ <2% calculation error rate vs. benchmarks
- ✅ 4.5+ star user rating

### User Satisfaction
- ✅ Positive feedback on customization options
- ✅ Increased engagement with analytics
- ✅ Reduction in support requests about missing features
- ✅ Growth in active user base

---

## Risk Mitigation

### Technical Risks

**Risk 1: Performance Degradation**
- **Mitigation**: Background calculation, aggressive caching, lazy loading
- **Fallback**: Feature flags to disable expensive features

**Risk 2: Data Accuracy Issues**
- **Mitigation**: Validation against known datasets, unit tests with real data
- **Fallback**: Display confidence intervals, allow manual verification

**Risk 3: API Rate Limiting**
- **Mitigation**: Efficient caching, batch requests, exponential backoff
- **Fallback**: Graceful degradation, stale data display with timestamps

**Risk 4: Memory Issues with Large Portfolios**
- **Mitigation**: Pagination, data compression, old data archival
- **Fallback**: Configurable data retention limits

### User Experience Risks

**Risk 1: Feature Overwhelm**
- **Mitigation**: Progressive disclosure, tooltips, onboarding flow
- **Fallback**: "Simple mode" toggle to hide advanced features

**Risk 2: Learning Curve**
- **Mitigation**: In-app help, tooltips, example explanations
- **Fallback**: Link to external resources, video tutorials

**Risk 3: Compatibility Issues**
- **Mitigation**: Thorough testing on macOS 15+, graceful fallbacks
- **Fallback**: Feature availability checks, warn on unsupported OS

---

## Future Enhancements (Post-2.3.0)

### Advanced Analytics
- **Machine Learning Predictions**: Price forecasting (LSTM, ARIMA)
- **Sentiment Analysis**: News sentiment integration
- **Event Detection**: Automatic anomaly detection
- **Portfolio Optimization**: Modern Portfolio Theory (MPT) suggestions

### Alert System
- **Technical Indicator Alerts**: RSI overbought/oversold, MACD crossover
- **Risk Threshold Alerts**: VaR breach, drawdown limits
- **Performance Alerts**: Unusual returns, correlation changes

### Backtesting
- **Strategy Testing**: Test hypothetical trades on historical data
- **Performance Simulation**: What-if scenarios
- **Optimization**: Find optimal indicator parameters

### Multi-Portfolio Support
- **Portfolio Groups**: Track multiple portfolios separately
- **Comparison**: Side-by-side performance comparison
- **Aggregation**: Combined view of all portfolios

### Social Features
- **Portfolio Sharing**: Export performance charts for sharing
- **Benchmarking**: Anonymous comparison to other users
- **Leaderboard**: Community performance rankings (opt-in)

### Advanced Customization
- **Custom Indicators**: User-defined formulas
- **Chart Templates**: Save/load chart configurations
- **Dashboard Builder**: Drag-and-drop custom layouts

---

## Documentation Plan

### Developer Documentation
- Architecture overview
- Service API documentation
- Data model specifications
- Calculation algorithm explanations
- Testing guidelines

### User Documentation
- Feature overview guide
- Menu bar customization tutorial
- Chart interaction guide
- Risk metrics explained (plain language)
- Sector analysis walkthrough
- FAQ and troubleshooting

### Release Notes
- Feature highlights with screenshots
- Migration guide (if applicable)
- Known issues and workarounds
- Performance improvements

---

## Appendix

### Glossary of Financial Terms

**Alpha**: Excess return relative to benchmark (Jensen's alpha)
**Beta**: Measure of systematic risk (correlation to market)
**Sharpe Ratio**: Risk-adjusted return (excess return / volatility)
**Sortino Ratio**: Downside risk-adjusted return
**VaR**: Value at Risk (maximum expected loss at confidence level)
**Drawdown**: Peak-to-trough decline
**Volatility**: Standard deviation of returns
**Correlation**: Statistical relationship between two assets
**RSI**: Relative Strength Index (momentum oscillator)
**MACD**: Moving Average Convergence Divergence
**Bollinger Bands**: Volatility bands around moving average

### References

**Academic Papers:**
- Markowitz, H. (1952). Portfolio Selection. *Journal of Finance*
- Sharpe, W. (1966). Mutual Fund Performance. *Journal of Business*
- Sortino, F. (1994). Performance Measurement in a Downside Risk Framework

**Industry Standards:**
- CFA Institute: Global Investment Performance Standards (GIPS)
- ISO 31000: Risk Management Guidelines

**Technical Resources:**
- Yahoo Finance API Documentation
- Swift Charts Framework (Apple)
- Core Data Programming Guide (Apple)

---

**Document Version**: 1.0
**Last Updated**: 2025-10-02
**Author**: Development Planning Team
**Status**: Ready for Implementation Review
