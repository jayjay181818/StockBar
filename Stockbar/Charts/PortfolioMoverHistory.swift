import Foundation

/// The first and last observed prices for each holding come from a single chart series.
struct PortfolioMoverHistory {
    struct Request: Equatable {
        let symbols: Set<String>
        let range: MenuChartTimeRange
        let configuration: Int
        let priceRevision: Int
    }

    private var request: Request?
    private var changes: [String: Double] = [:]

    func percent(for symbol: String, range: MenuChartTimeRange, configuration: Int) -> Double? {
        guard request?.range == range, request?.configuration == configuration else { return nil }
        return changes[symbol]
    }

    @MainActor
    static func load(_ request: Request, history: HistoricalDataManager, now: Date = Date()) -> Self {
        let range = request.range
        let start = range.startDate(from: now)
        let folync = FolyncSettingsStore.shared.load().isSupplementalRouteActive(.historicalLineCharts)
        var result = Self(request: request)
        for symbol in request.symbols {
            let status = history.folyncSourceStatus(for: symbol, timeRange: range.chartTimeRange)
            // An active route resolves to either its own series or an explicit legacy fallback.
            let mayRead = !folync || status == .current || status == .partial || status == .legacy
            let prices = mayRead ? history.getPriceSnapshots(for: symbol, from: start, to: now, timeRange: range.chartTimeRange) : []
            let change = percentChange(prices, range: range, now: now, repairLegacyScale: !folync || status == .legacy)
            result.changes[symbol] = change
            history.requestPriceHistoryIfNeeded(for: symbol, timeRange: range.chartTimeRange, from: start, to: now,
                                                availablePointCount: prices.count, coversRange: change != nil)
        }
        return result
    }

    static func percentChange(_ prices: [PriceSnapshot], range: MenuChartTimeRange, now: Date, repairLegacyScale: Bool) -> Double? {
        let start = range.startDate(from: now)
        let inPeriod: (PriceSnapshot) -> Bool = {
            $0.timestamp >= start && $0.timestamp <= now && $0.price.isFinite && $0.price > 0
        }
        guard let first = prices.first(where: inPeriod), let last = prices.last(where: inPeriod),
              last.timestamp > first.timestamp else { return nil }
        // A five-session week returned on Friday starts on Monday. Compare calendar
        // dates so a later opening time on Monday does not exclude the whole week.
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .gmt
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: now)
        guard let firstLimit = calendar.date(byAdding: .day, value: 4, to: startDay),
              let lastLimit = calendar.date(byAdding: .day, value: -3, to: endDay),
              first.timestamp < firstLimit, last.timestamp >= lastLimit,
              last.timestamp.timeIntervalSince(first.timestamp) >= range.timeInterval * 0.5 else { return nil }
        let baseline = repairLegacyScale ? UKPriceScale.normalized(first.price, reference: last.price, symbol: first.symbol) : first.price
        let percent = (last.price - baseline) / baseline * 100
        return percent.isFinite ? percent : nil
    }
}
