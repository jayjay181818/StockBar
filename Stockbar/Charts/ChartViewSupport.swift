import Foundation
import SwiftUI

// MARK: - Chart Visualization Style

enum ChartVisualizationStyle: String, CaseIterable {
    case line = "Line"
    case candlestick = "Candlestick"

    var icon: String {
        switch self {
        case .line: return "chart.xyaxis.line"
        case .candlestick: return "chart.bar"
        }
    }
}

// Extension to make ChartType Equatable for picker
extension ChartType: Equatable {
    static func == (lhs: ChartType, rhs: ChartType) -> Bool {
        switch (lhs, rhs) {
        case (.portfolioValue, .portfolioValue):
            return true
        case (.portfolioGains, .portfolioGains):
            return true
        case (.individualStock(let lhsSymbol), .individualStock(let rhsSymbol)):
            return lhsSymbol == rhsSymbol
        default:
            return false
        }
    }
}

// Extension to make ChartType Hashable for picker
extension ChartType: Hashable {
    func hash(into hasher: inout Hasher) {
        switch self {
        case .portfolioValue:
            hasher.combine("portfolioValue")
        case .portfolioGains:
            hasher.combine("portfolioGains")
        case .individualStock(let symbol):
            hasher.combine("individualStock")
            hasher.combine(symbol)
        }
    }
}

/// Remembers the last period metrics computed for a key.
@MainActor
final class PeriodMetricsCache {
    private var key: String?
    private var metrics: PerformanceMetrics?

    func value(for key: String, compute: () -> PerformanceMetrics?) -> PerformanceMetrics? {
        if self.key != key {
            self.key = key
            metrics = compute()
        }
        return metrics
    }
}

/// The chart, period and style last shown, kept between sessions.
struct ChartViewSelection: Equatable {
    /// "value", "gains" or "stock:SYMBOL".
    var chart = "value"
    var timeRange = ChartTimeRange.month
    var style = ChartVisualizationStyle.line

    private static let chartKey = "chartSelectionChart"
    private static let rangeKey = "chartSelectionRange"
    private static let styleKey = "chartSelectionStyle"

    init() {}

    init(chartType: ChartType, timeRange: ChartTimeRange, style: ChartVisualizationStyle) {
        switch chartType {
        case .portfolioValue: chart = "value"
        case .portfolioGains: chart = "gains"
        case .individualStock(let symbol): chart = "stock:" + symbol
        }
        // Custom dates are not kept, so a Custom range would reopen on dates
        // the user never chose.
        self.timeRange = timeRange == .custom ? .month : timeRange
        self.style = style
    }

    /// A stock no longer in the portfolio falls back to the portfolio chart.
    func chartType(among symbols: [String]) -> ChartType {
        if chart == "gains" { return .portfolioGains }
        if chart.hasPrefix("stock:") {
            let symbol = String(chart.dropFirst("stock:".count))
            if symbols.contains(symbol) { return .individualStock(symbol) }
        }
        return .portfolioValue
    }

    static func load(from store: UserDefaults = StockbarRuntimeStorage.userDefaults) -> ChartViewSelection {
        var selection = ChartViewSelection()
        if let chart = store.string(forKey: chartKey) { selection.chart = chart }
        if let range = store.string(forKey: rangeKey).flatMap(ChartTimeRange.init(rawValue:)), range != .custom {
            selection.timeRange = range
        }
        if let style = store.string(forKey: styleKey).flatMap(ChartVisualizationStyle.init(rawValue:)) {
            selection.style = style
        }
        return selection
    }

    func save(to store: UserDefaults = StockbarRuntimeStorage.userDefaults) {
        store.set(chart, forKey: Self.chartKey)
        store.set(timeRange.rawValue, forKey: Self.rangeKey)
        store.set(style.rawValue, forKey: Self.styleKey)
    }
}
