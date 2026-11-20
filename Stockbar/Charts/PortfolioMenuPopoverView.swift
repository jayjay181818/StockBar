import Combine
import SwiftUI

struct PortfolioMenuActions {
    let refresh: () -> Void
    let preferences: () -> Void
    let quit: () -> Void
    var openApp: () -> Void = {}

    @MainActor
    static let noop = PortfolioMenuActions(refresh: {}, preferences: {}, quit: {})
}

struct PortfolioMenuRangeChange: Equatable {
    let value: Double
    let percent: Double
}

enum PortfolioMenuPerformanceResolver {
    static func resolve(
        summary: DisplayPortfolioSummary,
        range: MenuChartTimeRange,
        chartChange: PortfolioMenuRangeChange?
    ) -> PortfolioMenuRangeChange? {
        guard range == .day else {
            return chartChange
        }

        if summary.valuationSource == .folyncProvided {
            guard summary.dayGain.isFinite, summary.dayGainPct.isFinite else {
                return nil
            }
            return PortfolioMenuRangeChange(value: summary.dayGain, percent: summary.dayGainPct)
        }

        if let chartChange {
            return chartChange
        }
        guard summary.dayGain.isFinite, summary.dayGainPct.isFinite else {
            return nil
        }
        return PortfolioMenuRangeChange(value: summary.dayGain, percent: summary.dayGainPct)
    }
}

struct PortfolioMenuDayReference: Equatable {
    let referenceValue: Double
    let currentValue: Double
    let change: PortfolioMenuRangeChange
}

enum PortfolioMenuDayReferenceResolver {
    static func resolve(
        summary: DisplayPortfolioSummary,
        range: MenuChartTimeRange
    ) -> PortfolioMenuDayReference? {
        guard range == .day,
              summary.valuationSource == .folyncProvided,
              summary.totalValue.isFinite,
              summary.totalValue > 0,
              summary.dayGain.isFinite,
              summary.dayGainPct.isFinite else {
            return nil
        }

        let referenceValue = summary.totalValue - summary.dayGain
        guard referenceValue.isFinite, referenceValue > 0 else {
            return nil
        }

        return PortfolioMenuDayReference(
            referenceValue: referenceValue,
            currentValue: summary.totalValue,
            change: PortfolioMenuRangeChange(
                value: summary.dayGain,
                percent: summary.dayGainPct
            )
        )
    }
}

/// One holding's move today in the popover's list.
struct PortfolioMenuMover: Identifiable, Equatable {
    let id: String
    let symbol: String
    /// Today's change in percent (1.5 means 1.5%); nil when unknown.
    let percent: Double?

    init(id: String, symbol: String, percent: Double?) {
        self.id = id
        self.symbol = symbol
        self.percent = percent.flatMap { $0.isFinite ? $0 : nil }
    }

    /// The change as shown, at two decimals: a move that rounds to nothing is
    /// no change, so it is never drawn as a gain or a loss.
    var displayedPercent: Double? {
        percent.map { value in
            let rounded = (value * 100).rounded() / 100
            return rounded == 0 ? 0 : rounded
        }
    }
}

/// Every holding's move today, for the popover. The list is always today's,
/// whatever range the switch shows: Folync gives a holding's change only for
/// the day and in total.
enum PortfolioMenuMovers {
    static let heading = "Today's movers"
    /// Rows shown at once before the list scrolls.
    static let visibleRows = 12
    static let rowHeight: CGFloat = 22
    /// The list never shrinks below this many rows to fit a short screen.
    static let minimumRows = 3

    /// The heading at any range: the list does not follow the range switch.
    static func heading(for range: MenuChartTimeRange) -> String { heading }

    /// Held positions only: no watch-list symbols, benchmarks or empty
    /// positions. A holding listed twice is shown once. `dayPercent` is the
    /// app's own figure for a position's day.
    static func movers(from trades: [RealTimeTrade], dayPercent: (RealTimeTrade) -> Double) -> [PortfolioMenuMover] {
        var seen = Set<String>()
        let held = trades.compactMap { trade -> (id: String, label: String, percent: Double)? in
            guard !trade.trade.isWatchlistOnly,
                  !SymbolMetadata.isBenchmarkSymbol(trade.trade.name),
                  trade.trade.position.unitSize > 0 else { return nil }
            let id = trade.sourceIdentity ?? trade.trade.name
            guard seen.insert(id).inserted else { return nil }
            return (id, trade.displayLabel ?? trade.trade.name, dayPercent(trade))
        }
        // A row has room for a ticker, not for "NVDA · Demo portfolio", which
        // is how a Folync aggregate labels a holding. Show the ticker alone,
        // unless two holdings would then read the same.
        let sharing = Dictionary(grouping: held, by: { ticker(of: $0.label) }).mapValues(\.count)
        let movers = held.map { item -> PortfolioMenuMover in
            let short = ticker(of: item.label)
            return PortfolioMenuMover(id: item.id, symbol: sharing[short] == 1 ? short : item.label, percent: item.percent)
        }
        return ordered(movers)
    }

    /// The part of a holding's label before the portfolio name a Folync
    /// aggregate adds ("NVDA · Demo portfolio" gives "NVDA").
    static func ticker(of label: String) -> String {
        guard let separator = label.range(of: " · ") else { return label }
        let ticker = String(label[..<separator.lowerBound])
        return ticker.isEmpty ? label : ticker
    }

    /// Biggest gain first, down to the biggest loss; unknown changes last.
    /// Equal changes, and the unknown ones, keep a stable order by symbol.
    static func ordered(_ movers: [PortfolioMenuMover]) -> [PortfolioMenuMover] {
        movers.sorted { lhs, rhs in
            switch (lhs.displayedPercent, rhs.displayedPercent) {
            case let (left?, right?) where left != right: left > right
            case (.some, nil): true
            case (nil, .some): false
            default: (lhs.symbol, lhs.id) < (rhs.symbol, rhs.id)
            }
        }
    }

    /// The bars' full length in percent: the largest move, rounded up to a
    /// whole percent, and never less than 1%.
    static func scale(for movers: [PortfolioMenuMover]) -> Double {
        let largest = movers.compactMap(\.displayedPercent).map(abs).max() ?? 0
        return max(1, largest.rounded(.up))
    }

    static func scaleText(_ scale: Double) -> String {
        "± \(Int(scale))%"
    }

    /// The share of the half-track a bar fills, 0 to 1; 0 draws no bar.
    static func barFraction(_ mover: PortfolioMenuMover, scale: Double) -> Double {
        guard let percent = mover.displayedPercent, percent != 0, scale > 0 else { return 0 }
        return min(abs(percent) / scale, 1)
    }

    /// "▲ 2.69%", "▼ 0.64%", "0.00%", or "–" when unknown.
    static func percentText(_ mover: PortfolioMenuMover, locale: Locale = .current) -> String {
        guard let percent = mover.displayedPercent else { return "–" }
        let figure = (abs(percent) / 100).formatted(.percent.precision(.fractionLength(2)).locale(locale))
        if percent > 0 { return "▲ " + figure }
        if percent < 0 { return "▼ " + figure }
        return figure
    }

    /// One sentence for VoiceOver: "NVDA, up 2.69 percent today".
    static func accessibilityText(_ mover: PortfolioMenuMover) -> String {
        guard let percent = mover.displayedPercent else { return "\(mover.symbol), change unknown" }
        if percent == 0 { return "\(mover.symbol), no change today" }
        return String(format: "%@, %@ %.2f percent today", mover.symbol, percent > 0 ? "up" : "down", abs(percent))
    }

    /// Rows that show at once: all of them up to `visibleRows`, fewer when the
    /// screen leaves less room, never fewer than `minimumRows` unless there
    /// are fewer holdings. `availableHeight` is the room for the list.
    static func shownRows(count: Int, availableHeight: CGFloat? = nil) -> Int {
        var rows = min(count, visibleRows)
        if let availableHeight, availableHeight.isFinite {
            let fitting = Int((availableHeight / rowHeight).rounded(.down))
            rows = min(rows, max(fitting, min(count, minimumRows)))
        }
        return max(rows, 0)
    }

    /// True when the list holds more rows than it shows, so it scrolls.
    static func scrolls(count: Int, availableHeight: CGFloat? = nil) -> Bool {
        count > shownRows(count: count, availableHeight: availableHeight)
    }

    static func listHeight(count: Int, availableHeight: CGFloat? = nil) -> CGFloat {
        CGFloat(shownRows(count: count, availableHeight: availableHeight)) * rowHeight
    }
}

enum PortfolioMenuPopoverHeight {
    /// Room the popover's arrow and the gap under the menu bar take.
    static let arrowAndMargin: CGFloat = 30

    /// The tallest the portfolio popover may be on a screen whose visible
    /// frame (below the menu bar, above the Dock) is `visibleHeight` tall.
    static func maximum(visibleHeight: CGFloat?) -> CGFloat? {
        guard let visibleHeight, visibleHeight.isFinite, visibleHeight > arrowAndMargin else { return nil }
        return visibleHeight - arrowAndMargin
    }
}

enum PortfolioMenuChartDataBuilder {
    static let defaultMaxPoints = 1000

    static func prepareChartPoints(
        storedPoints: [ChartDataPoint],
        currentValue: Double,
        range: MenuChartTimeRange,
        now: Date = Date(),
        maxPoints: Int = defaultMaxPoints
    ) -> [MenuChartDataPoint] {
        let observations = storedPoints.filter {
            $0.date >= range.startDate(from: now) && $0.date <= now && $0.value.isFinite && $0.value > 0
        }
        guard Set(observations.map(\.date)).count >= 2 else { return [] }
        return MenuChartDataBuilder.prepareValuePoints(
            storedPoints: storedPoints,
            currentValue: currentValue,
            symbol: "Portfolio",
            range: range,
            now: now,
            maxPoints: maxPoints
        )
    }

    static func providerPoints(_ history: FolyncPortfolioHistory, scopeID: String,
                               currency: String, range: MenuChartTimeRange) -> [MenuChartDataPoint]? {
        guard history.scope.id == scopeID, history.range == range.chartTimeRange.folyncRange,
              history.currency?.uppercased() == currency.uppercased() else { return nil }
        let points = history.portfolioSeries.compactMap { point -> MenuChartDataPoint? in
            guard point.value.isFinite, point.value >= 0,
                  let date = FolyncSupplementalDateParser.instant(point.date)
                    ?? FolyncSupplementalDateParser.day(point.date) else { return nil }
            return MenuChartDataPoint(date: date, price: point.value, symbol: "Portfolio")
        }.sorted { $0.date < $1.date }
        // Preserve the provider's dates and values, including its last observation.
        return MenuChartDataBuilder.downsample(points, maxPoints: defaultMaxPoints)
    }

    static func matchingCurrencyPoints(_ values: [StoredPortfolioValue], currency: String) -> [ChartDataPoint] {
        values.filter { $0.currency.uppercased() == currency.uppercased() }
            .map { ChartDataPoint(date: $0.date, value: $0.totalValue) }
    }

    static func coversRange(_ points: [MenuChartDataPoint], range: MenuChartTimeRange, now: Date = Date()) -> Bool {
        guard let first = points.first, let last = points.last, points.count > 1 else { return false }
        // "All" starts wherever the stored history starts; it only has to be recent.
        if range == .all { return last.date >= now.addingTimeInterval(-MenuChartTimeRange.week.timeInterval) }
        let duration = now.timeIntervalSince(range.startDate(from: now))
        return first.date <= range.startDate(from: now).addingTimeInterval(duration * 0.2)
            && last.date >= now.addingTimeInterval(-duration * 0.2)
    }

    static func rangeChange(for points: [MenuChartDataPoint]) -> PortfolioMenuRangeChange? {
        guard let first = points.first,
              let last = points.last,
              first.price.isFinite,
              first.price > 0,
              last.price.isFinite else {
            return nil
        }

        let value = last.price - first.price
        return PortfolioMenuRangeChange(
            value: value,
            percent: (value / first.price) * 100
        )
    }
}

@MainActor
final class PortfolioMenuChartViewModel: ObservableObject {
    @Published var chartData: [MenuChartDataPoint] = []
    @Published private(set) var selectedTimeRange: MenuChartTimeRange = .day
    @Published var isLoading = false
    @Published var coverageLabel = ""
    @Published var hasRangeCoverage = false
    /// True when Folync did not answer and nothing was saved for this period,
    /// so the views can say so instead of asking for more stored history.
    @Published private(set) var folyncUnreachable = false
    /// True when the chart shows Folync history marked stale: a saved copy
    /// shown because Folync did not answer, or history Folync itself marks stale.
    @Published private(set) var folyncStale = false
    /// The period whose data is currently shown; drives the draw-in animation.
    @Published private(set) var loadedRange: MenuChartTimeRange?

    private let historicalDataManager = HistoricalDataManager.shared
    private let folyncCoordinator: FolyncSupplementalCoordinator
    private let folyncSettingsStore: FolyncSettingsStore
    private var currentValue: Double
    private var currentTrades: [RealTimeTrade]
    private var preferredCurrency: String
    private var valuationSource: PortfolioValuationSource
    private var cancellables = Set<AnyCancellable>()
    private var historyTask: Task<Void, Never>?
    private let reloadCoalescer = ChartReloadCoalescer()
    private var isActive = false
    private(set) var loadGeneration = 0

    /// What the shown data was loaded for. Reloads for the same context keep
    /// the current chart on screen instead of flashing a spinner.
    private struct LoadContext: Equatable {
        let range: MenuChartTimeRange
        let currency: String
        let source: PortfolioValuationSource
    }
    private var shownContext: LoadContext?

    // Capture values: RealTimeTrade instances can be edited in place.
    private struct PositionInput: Equatable {
        let trade: Trade
        let price: UInt64
        let currency: String?
        let quoteDate: Int?

        init(_ position: RealTimeTrade) {
            trade = position.trade
            price = position.realTimeInfo.getCurrentDisplayPrice().bitPattern
            currency = position.realTimeInfo.currency
            quoteDate = position.realTimeInfo.lastUpdateTime
        }
    }
    private var positionInputs: [PositionInput]

    init(
        currentValue: Double,
        currentTrades: [RealTimeTrade],
        preferredCurrency: String,
        valuationSource: PortfolioValuationSource,
        initialRange: MenuChartTimeRange = .day,
        folyncCoordinator: FolyncSupplementalCoordinator = .shared,
        folyncSettingsStore: FolyncSettingsStore = .shared
    ) {
        self.folyncCoordinator = folyncCoordinator
        self.folyncSettingsStore = folyncSettingsStore
        self.currentValue = currentValue
        self.currentTrades = currentTrades
        self.positionInputs = currentTrades.map(PositionInput.init)
        self.selectedTimeRange = initialRange
        self.preferredCurrency = preferredCurrency
        self.valuationSource = valuationSource
        ObservationPublisher.changes { [historicalDataManager] in
            _ = historicalDataManager.priceSnapshots
            _ = historicalDataManager.priceDataRevision
            _ = historicalDataManager.historicalPortfolioSnapshots
            _ = historicalDataManager.folyncSupplementalConfigurationRevision
        }
            .sink { [weak self] _ in self?.loadChartData() }
            .store(in: &cancellables)
    }

    func activate() {
        guard !isActive else { return }
        isActive = true
        loadChartData()
    }

    func deactivate() {
        isActive = false
        reloadCoalescer.cancel()
        historyTask?.cancel()
        isLoading = false
    }

    func update(
        currentValue: Double,
        currentTrades: [RealTimeTrade],
        preferredCurrency: String,
        valuationSource: PortfolioValuationSource
    ) {
        let positions = currentTrades.map(PositionInput.init)
        let changed = self.currentValue.bitPattern != currentValue.bitPattern
            || positionInputs != positions || self.preferredCurrency != preferredCurrency
            || self.valuationSource != valuationSource
        self.currentValue = currentValue
        self.currentTrades = currentTrades
        self.positionInputs = positions
        self.preferredCurrency = preferredCurrency
        self.valuationSource = valuationSource
        if changed { loadChartData() }
    }

    func setTimeRange(_ range: MenuChartTimeRange) {
        guard range != selectedTimeRange else { return }
        selectedTimeRange = range
        loadChartData()
    }

    var showsDayReference: Bool {
        valuationSource == .folyncProvided && selectedTimeRange == .day
            && !isLoading && chartData.count < 2
    }

    func loadChartData() {
        guard isActive else { return }
        if !isLoading { isLoading = true }
        historyTask?.cancel()
        reloadCoalescer.schedule { [weak self] in self?.performChartLoad() }
    }

    private func performChartLoad() {
        guard isActive else { return }
        loadGeneration &+= 1
        isLoading = true
        let context = LoadContext(range: selectedTimeRange, currency: preferredCurrency, source: valuationSource)
        if context != shownContext {
            chartData = []
            hasRangeCoverage = false
            coverageLabel = ""
            folyncUnreachable = false
            folyncStale = false
            shownContext = nil
        }
        if valuationSource == .folyncProvided || selectedTimeRange != .day {
            let range = selectedTimeRange
            let value = currentValue
            let currency = preferredCurrency
            let source = valuationSource
            let scopeID = folyncSettingsStore.load().scopeID
            let revision = historicalDataManager.folyncSupplementalConfigurationRevision
            historyTask = Task { [weak self] in
                guard let self, !Task.isCancelled else { return }
                if source == .folyncProvided {
                    // Show the history saved last time while Folync is asked for
                    // a newer one, so the chart does not wait on the network.
                    if chartData.isEmpty,
                       let saved = await folyncCoordinator.savedPortfolioHistory(range: range.chartTimeRange.folyncRange),
                       !Task.isCancelled, chartData.isEmpty,
                       revision == historicalDataManager.folyncSupplementalConfigurationRevision,
                       let points = PortfolioMenuChartDataBuilder.providerPoints(
                           saved, scopeID: scopeID, currency: currency, range: range
                       ) {
                        chartData = points
                        loadedRange = range
                        coverageLabel = "Checking Folync · \(saved.coverage.pointCount) observations · \(saved.interval)"
                        if range == .day { coverageLabel = "Past 24 hours · " + coverageLabel }
                    }
                    guard !Task.isCancelled else { return }
                    let result = await folyncCoordinator.routePortfolioHistory(range: range.chartTimeRange.folyncRange)
                    guard !Task.isCancelled, revision == historicalDataManager.folyncSupplementalConfigurationRevision else { return }
                    switch result {
                    case .folync(let history, let status):
                        guard let points = PortfolioMenuChartDataBuilder.providerPoints(
                            history, scopeID: scopeID, currency: currency, range: range
                        ) else {
                            showUnavailable("Folync history does not match this portfolio, currency or period.", context: context)
                            return
                        }
                        chartData = points
                        folyncUnreachable = false
                        folyncStale = status == .stale
                        hasRangeCoverage = history.coverage.complete == true && history.quality == .complete && status == .current && points.count > 1
                        coverageLabel = "\(status.label) · \(history.coverage.pointCount) observations · \(history.interval)"
                        if !hasRangeCoverage { coverageLabel += " · partial history" }
                        // Folync's 1d series is rolling history; Today's P&L still uses its daily reference.
                        if range == .day { coverageLabel = "Past 24 hours · " + coverageLabel }
                    case .unreachable:
                        chartData = []
                        hasRangeCoverage = false
                        folyncUnreachable = true
                        folyncStale = false
                        coverageLabel = "Couldn't reach Folync, and nothing is saved for this period yet."
                    case .legacy, .unavailable:
                        chartData = []
                        hasRangeCoverage = false
                        folyncUnreachable = false
                        folyncStale = false
                        coverageLabel = "Folync portfolio history is unavailable for this period. Check the connection and source history."
                    }
                } else {
                    let stored = await historicalDataManager.loadPortfolioValuesFromCoreData(timeRange: range.chartTimeRange)
                    guard !Task.isCancelled else { return }
                    chartData = PortfolioMenuChartDataBuilder.prepareChartPoints(
                        storedPoints: PortfolioMenuChartDataBuilder.matchingCurrencyPoints(stored, currency: currency),
                        currentValue: value, range: range
                    )
                    hasRangeCoverage = PortfolioMenuChartDataBuilder.coversRange(chartData, range: range)
                    coverageLabel = "Local history · \(chartData.count) observations"
                    if !hasRangeCoverage { coverageLabel += " · partial history" }
                }
                markLoaded(context)
            }
            return
        }

        let storedPoints = historicalDataManager.getPortfolioMenuValues(
            for: selectedTimeRange.chartTimeRange,
            currentTrades: currentTrades,
            preferredCurrency: preferredCurrency,
            allowSyntheticPositionHistory: valuationSource != .folyncProvided
        )
        chartData = PortfolioMenuChartDataBuilder.prepareChartPoints(
            storedPoints: storedPoints,
            currentValue: currentValue,
            range: selectedTimeRange
        )
        hasRangeCoverage = PortfolioMenuChartDataBuilder.coversRange(chartData, range: selectedTimeRange)
        markLoaded(context)
    }

    private func markLoaded(_ context: LoadContext) {
        shownContext = context
        loadedRange = context.range
        isLoading = false
    }

    private func showUnavailable(_ message: String, context: LoadContext) {
        chartData = []
        hasRangeCoverage = false
        folyncUnreachable = false
        folyncStale = false
        coverageLabel = message
        markLoaded(context)
    }
}

@MainActor
struct PortfolioMenuPopoverView: View {
    private let dataModel: DataModel
    @StateObject private var viewModel: PortfolioMenuChartViewModel
    @State private var hoveredPoint: MenuChartDataPoint?
    @State private var summaryCache = DisplaySummaryCache()
    /// Everything but the movers' list, as last laid out; the list gets what
    /// the screen leaves of `maximumHeight` after it.
    @State private var chromeHeight: CGFloat = 470
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let actions: PortfolioMenuActions
    /// The tallest the popover may be: the room below the menu bar on its screen.
    private let maximumHeight: CGFloat?
    private let chartHeight: CGFloat = 118

    init(dataModel: DataModel, actions: PortfolioMenuActions, maximumHeight: CGFloat? = nil) {
        self.dataModel = dataModel
        self.actions = actions
        self.maximumHeight = maximumHeight
        let summary = dataModel.calculateDisplayPortfolioSummary(
            preferredCurrency: dataModel.portfolioMenuBarDisplaySettings.currencyCode
        )
        self._viewModel = StateObject(
            wrappedValue: PortfolioMenuChartViewModel(
                currentValue: summary.totalValue,
                currentTrades: dataModel.realTimeTrades,
                preferredCurrency: summary.currency,
                valuationSource: summary.valuationSource
            )
        )
    }

    /// Computed once per render pass (see `DisplaySummaryCache`).
    private var summary: DisplayPortfolioSummary {
        summaryCache.summary {
            dataModel.calculateDisplayPortfolioSummary(
                preferredCurrency: dataModel.portfolioMenuBarDisplaySettings.currencyCode
            )
        }
    }

    private var displayedChange: PortfolioMenuRangeChange? {
        PortfolioMenuPerformanceResolver.resolve(
            summary: summary,
            range: viewModel.selectedTimeRange,
            chartChange: viewModel.hasRangeCoverage ? PortfolioMenuChartDataBuilder.rangeChange(for: viewModel.chartData) : nil
        )
    }

    private var dayReference: PortfolioMenuDayReference? {
        guard viewModel.showsDayReference else { return nil }
        return PortfolioMenuDayReferenceResolver.resolve(
            summary: summary,
            range: viewModel.selectedTimeRange
        )
    }

    private var updatedText: String {
        let ownedTimestamps = dataModel.realTimeTrades
            .filter { !$0.trade.isWatchlistOnly && $0.trade.position.unitSize > 0 }
            .map { $0.realTimeInfo.lastUpdateTime }

        return MenuPopoverFormatter.updatedText(from: ownedTimestamps)
    }

    var body: some View {
        let _ = summaryCache.beginPass()
        let movers = PortfolioMenuMovers.movers(from: dataModel.realTimeTrades) {
            dataModel.calculatePositionProfitLoss(for: $0).dayPercent
        }
        let listRoom = maximumHeight.map { $0 - chromeHeight }
        VStack(alignment: .leading, spacing: 12) {
            PortfolioMenuHeadline(
                figures: PortfolioMenuFigures(summary: summary, change: displayedChange, range: viewModel.selectedTimeRange,
                                              basis: dataModel.portfolioGainBasis),
                hoveredValue: hoveredPoint?.price,
                hoveredDate: hoveredPoint.map { MenuPopoverFormatter.date($0.date, range: viewModel.selectedTimeRange) }
            )
            .animation(StockbarMotion.animation(StockbarMotion.standard, reduceMotion: reduceMotion), value: summary.totalValue)

            chartSection

            StockbarSegmentedControl(
                "Chart period",
                selection: Binding(get: { viewModel.selectedTimeRange }, set: { range in
                    hoveredPoint = nil
                    viewModel.setTimeRange(range)
                }),
                options: MenuChartTimeRange.menuRanges,
                expands: true,
                title: PortfolioMenuFigures.rangeTitle
            )

            PortfolioMenuMoversList(movers: movers, availableHeight: listRoom)

            PortfolioMenuSummaryStrip(
                figures: PortfolioMenuFigures(summary: summary, change: displayedChange, range: viewModel.selectedTimeRange,
                                              basis: dataModel.portfolioGainBasis)
            )

            Divider()

            MenuPopoverFooter(
                updatedText: updatedText,
                onRefresh: actions.refresh,
                onOpenApp: actions.openApp,
                onPreferences: actions.preferences,
                onQuit: actions.quit
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            // The list's own height is what the movers' rule gave it last time.
            let chrome = height - PortfolioMenuMovers.listHeight(count: movers.count, availableHeight: listRoom)
            if abs(chrome - chromeHeight) > 1 { chromeHeight = chrome }
        }
        // A readout left from before a reload would describe a point no longer drawn.
        .onChange(of: viewModel.chartData) { _, _ in hoveredPoint = nil }
        .onAppear {
            viewModel.activate()
            refreshChartModel()
        }
        .onDisappear { viewModel.deactivate() }
        .onReceive(dataModel.tradeContentPublisher) { _ in
            refreshChartModel()
        }
        .onChange(of: dataModel.portfolioMenuBarDisplaySettings) { _, _ in
            refreshChartModel()
        }
        .stockbarRollingDigitsSetting()
        .stockbarPopoverText()
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let dayReference {
                    PortfolioMenuDayReferenceView(
                        reference: dayReference,
                        currency: summary.currency
                    )
                } else {
                    MenuPopoverLineChart(
                        points: viewModel.chartData,
                        isLoading: viewModel.isLoading,
                        revealTrigger: viewModel.loadedRange?.rawValue ?? "",
                        emptyMessage: viewModel.folyncUnreachable
                            ? "Couldn't reach Folync."
                            : "Portfolio history builds up while Stockbar runs.",
                        referencePrice: PortfolioMenuFigures.yesterdaysClose(summary: summary, range: viewModel.selectedTimeRange),
                        referenceLabel: "Yesterday's close",
                        lineColor: PortfolioMenuFigures.lineColor(for: viewModel.chartData),
                        hoveredPoint: $hoveredPoint
                    )
                    .accessibilityLabel("Portfolio history, \(viewModel.selectedTimeRange.description)")
                    .accessibilityValue("\(viewModel.chartData.count) observations")
                }
            }
            .frame(height: chartHeight)

            if !viewModel.coverageLabel.isEmpty {
                PortfolioMenuCoverageLine(text: viewModel.coverageLabel)
            }
        }
    }

    /// Event handlers run between renders, so they must not reuse the last render's summary.
    private func refreshChartModel() {
        summaryCache.beginPass()
        viewModel.update(
            currentValue: summary.totalValue,
            currentTrades: dataModel.realTimeTrades,
            preferredCurrency: summary.currency,
            valuationSource: summary.valuationSource
        )
    }
}

/// The popover's figures as text, in the portfolio's currency.
struct PortfolioMenuFigures: Equatable {
    let currency: String
    let header: String
    let total: String
    /// Sign of the change as shown: -1, 0 or 1; nil when the change is unknown.
    let changeSign: Int?
    /// "▲ £512.36", or "–" when unknown.
    let changeAmount: String
    /// "+0.61%", or "" when unknown.
    let changePercent: String
    /// "today", "past week", "past month".
    let changeWord: String
    let totalReturn: String
    let totalReturnSign: Int
    let totalReturnPercent: String
    /// "Net deposits", or "Cost basis" when the return is measured against cost.
    let basisLabel: String
    let basis: String

    init(summary: DisplayPortfolioSummary, change: PortfolioMenuRangeChange?, range: MenuChartTimeRange,
         basis gainBasis: PortfolioGainBasis) {
        currency = summary.currency
        let count = summary.ownedPositionCount
        header = "\(summary.currency), \(count == 1 ? "1 position" : "\(count) positions")"
        total = MenuPopoverFormatter.currencyExact(summary.totalValue, currency: summary.currency)
        if let change, change.value.isFinite {
            let shown = HoldingsCurrencyFormatter.displayedSign(of: change.value, currency: summary.currency)
            let sign = shown > 0 ? 1 : (shown < 0 ? -1 : 0)
            changeSign = sign
            let amount = HoldingsCurrencyFormatter.amount(abs(change.value), currency: summary.currency)
            changeAmount = sign > 0 ? "▲ " + amount : (sign < 0 ? "▼ " + amount : amount)
            changePercent = MenuPopoverFormatter.percent(change.percent)
        } else {
            changeSign = nil
            changeAmount = "–"
            changePercent = ""
        }
        // The popover offers only `MenuChartTimeRange.menuRanges`; the longer
        // ranges are the Overview's and are worded here for completeness.
        changeWord = switch range {
        case .day: "today"
        case .week: "past week"
        case .month: "past month"
        case .threeMonths: "past 3 months"
        case .year: "past year"
        case .all: "all time"
        }
        let totalReturn = summary.totalReturn(measuredAgainst: gainBasis)
        self.totalReturn = MenuPopoverFormatter.currencyExact(totalReturn.gain, currency: summary.currency, includeSign: true)
        let returnShown = HoldingsCurrencyFormatter.displayedSign(of: totalReturn.gain, currency: summary.currency)
        totalReturnSign = returnShown > 0 ? 1 : (returnShown < 0 ? -1 : 0)
        totalReturnPercent = MenuPopoverFormatter.percent(totalReturn.percent)
        basisLabel = totalReturn.isMeasuredAgainstNetDeposits ? "Net deposits" : "Cost basis"
        basis = MenuPopoverFormatter.currencyExact(totalReturn.basisAmount, currency: summary.currency)
    }

    /// The range switch's segments.
    static func rangeTitle(_ range: MenuChartTimeRange) -> String {
        switch range {
        case .day: "Today"
        case .week: "1 week"
        case .month: "1 month"
        case .threeMonths: "3 months"
        case .year: "1 year"
        case .all: "All"
        }
    }

    /// Yesterday's close, for the dotted line on the Today graph; nil on other
    /// ranges and whenever the day's change is not known.
    static func yesterdaysClose(summary: DisplayPortfolioSummary, range: MenuChartTimeRange) -> Double? {
        guard range == .day, summary.totalValue.isFinite, summary.dayGain.isFinite,
              summary.dayGain != 0, summary.dayGainPct.isFinite else { return nil }
        let close = summary.totalValue - summary.dayGain
        return close.isFinite && close > 0 ? close : nil
    }

    /// Green when the graph ended higher than it started, red when lower, in
    /// the popover's colours.
    static func lineColor(for points: [MenuChartDataPoint]) -> Color {
        guard let first = points.first?.price, let last = points.last?.price,
              first.isFinite, last.isFinite, last != first else { return .accentColor }
        return StockbarPalette.signedOnPopover(last - first, neutral: .accentColor)
    }
}

/// Under the graph: where its history came from and how complete it is.
private struct PortfolioMenuCoverageLine: View {
    let text: String
    @Environment(\.stockbarPopoverText) private var textStyle

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(textStyle.secondary)
            .lineLimit(2)
    }
}

/// Header line, the total and the change on the selected range.
struct PortfolioMenuHeadline: View {
    let figures: PortfolioMenuFigures
    var hoveredValue: Double?
    var hoveredDate: String?
    @Environment(\.stockbarPopoverText) private var textStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Portfolio")
                    .font(.system(size: 14, weight: .medium))
                Spacer(minLength: 8)
                Text(figures.header)
                    .font(.system(size: 13))
            }
            .foregroundStyle(textStyle.secondary)
            .accessibilityElement(children: .combine)

            StockbarSplitFigure(
                text: hoveredValue.map { MenuPopoverFormatter.currencyExact($0, currency: figures.currency) } ?? figures.total
            )
            .stockbarRollingDigits()
            .minimumScaleFactor(0.6)
            .padding(.top, 2)

            changeLine
                .frame(minHeight: 22, alignment: .leading)
        }
    }

    @ViewBuilder
    private var changeLine: some View {
        if let hoveredDate {
            Text(hoveredDate)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(textStyle.secondary)
                .monospacedDigit()
        } else {
            let tint = StockbarPalette.signedOnPopover(figures.changeSign.map(Double.init), neutral: .primary)
            HStack(spacing: 8) {
                Text(figures.changeAmount)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .stockbarRollingDigits()
                if !figures.changePercent.isEmpty {
                    Text(figures.changePercent)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                        .stockbarPill(tint: figures.changeSign == 0 ? nil : tint)
                }
                Text(figures.changeWord)
                    .font(.system(size: 14))
                    .foregroundStyle(textStyle.secondary)
            }
            .monospacedDigit()
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(changeAccessibility)
        }
    }

    private var changeAccessibility: String {
        guard let sign = figures.changeSign else { return "Change \(figures.changeWord) unknown" }
        let amount = figures.changeAmount.replacingOccurrences(of: "▲ ", with: "").replacingOccurrences(of: "▼ ", with: "")
        let direction = sign > 0 ? "Up" : (sign < 0 ? "Down" : "Unchanged,")
        return "\(direction) \(amount), \(figures.changePercent) \(figures.changeWord)"
    }
}

/// "Today's movers": one row per holding, with a bar from the centre line.
struct PortfolioMenuMoversList: View {
    let movers: [PortfolioMenuMover]
    /// Room left for the list on the screen; nil when unbounded.
    var availableHeight: CGFloat?
    @Environment(\.stockbarPopoverText) private var textStyle

    var body: some View {
        let scale = PortfolioMenuMovers.scale(for: movers)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(PortfolioMenuMovers.heading)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(textStyle.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !movers.isEmpty {
                    Text(PortfolioMenuMovers.scaleText(scale))
                        .font(.system(size: 12))
                        .foregroundStyle(textStyle.tertiary)
                        .accessibilityLabel("Bars to plus or minus \(Int(scale)) percent")
                }
            }
            if movers.isEmpty {
                Text("No holdings to show.")
                    .font(.system(size: 13))
                    .foregroundStyle(textStyle.secondary)
            } else {
                let rows = LazyVStack(spacing: 0) {
                    ForEach(movers) { mover in
                        PortfolioMenuMoverRow(mover: mover, scale: scale)
                            .frame(height: PortfolioMenuMovers.rowHeight)
                    }
                }
                if PortfolioMenuMovers.scrolls(count: movers.count, availableHeight: availableHeight) {
                    // The popover sizes to its content, so the scrolling list
                    // takes an explicit height.
                    ScrollView { rows }
                        .frame(height: PortfolioMenuMovers.listHeight(count: movers.count, availableHeight: availableHeight))
                } else {
                    rows
                }
            }
        }
    }
}

struct PortfolioMenuMoverRow: View {
    let mover: PortfolioMenuMover
    let scale: Double

    var body: some View {
        let tint = StockbarPalette.signedOnPopover(mover.displayedPercent, neutral: .secondary)
        HStack(spacing: 10) {
            Text(mover.symbol)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 84, alignment: .leading)
            bar(tint: tint)
            Text(PortfolioMenuMovers.percentText(mover))
                .font(.system(size: 14, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .frame(width: 80, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PortfolioMenuMovers.accessibilityText(mover))
    }

    private func bar(tint: Color) -> some View {
        GeometryReader { proxy in
            let half = proxy.size.width / 2
            let length = PortfolioMenuMovers.barFraction(mover, scale: scale) * half
            let gains = (mover.displayedPercent ?? 0) >= 0
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 1)
                    .offset(x: half)
                if length > 0 {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(length, 3), height: 8)
                        .offset(x: gains ? half : half - max(length, 3))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}

/// Total return and the amount it is measured against.
struct PortfolioMenuSummaryStrip: View {
    let figures: PortfolioMenuFigures
    @Environment(\.stockbarPopoverText) private var textStyle

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Total return")
                    .font(.system(size: 13))
                    .foregroundStyle(textStyle.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(figures.totalReturn)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StockbarPalette.signedOnPopover(Double(figures.totalReturnSign), neutral: .primary))
                        .stockbarRollingDigits()
                        .minimumScaleFactor(0.75)
                        .layoutPriority(1)
                    // The amount keeps its room; the percentage gives way first.
                    Text(figures.totalReturnPercent)
                        .font(.system(size: 12))
                        .foregroundStyle(textStyle.secondary)
                        .minimumScaleFactor(0.7)
                }
                .monospacedDigit()
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .accessibilityElement(children: .combine)

            Divider().frame(height: 34).padding(.horizontal, 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(figures.basisLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(textStyle.secondary)
                Text(figures.basis)
                    .font(.system(size: 16, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .stockbarRollingDigits()
            }
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .combine)
        }
        .padding(.top, 10)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct PortfolioMenuDayReferenceView: View {
    let reference: PortfolioMenuDayReference
    let currency: String

    private var chartColor: Color {
        StockbarPalette.signed(reference.change.value, neutral: .accentColor)
    }

    var body: some View {
        GeometryReader { geometry in
            let isFlat = abs(reference.currentValue - reference.referenceValue) < 0.000_001
            let referenceY = isFlat
                ? geometry.size.height * 0.52
                : geometry.size.height * (reference.currentValue >= reference.referenceValue ? 0.68 : 0.30)
            let currentY = isFlat
                ? referenceY
                : geometry.size.height * (reference.currentValue >= reference.referenceValue ? 0.30 : 0.68)
            let markerX = geometry.size.width * 0.72

            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [chartColor.opacity(0.12), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )

                Path { path in
                    path.move(to: CGPoint(x: 0, y: referenceY))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: referenceY))
                }
                .stroke(
                    Color.primary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 5])
                )

                Path { path in
                    path.move(to: CGPoint(x: markerX, y: referenceY))
                    path.addLine(to: CGPoint(x: markerX, y: currentY))
                }
                .stroke(chartColor.opacity(0.8), lineWidth: 2)

                Circle()
                    .fill(chartColor)
                    .frame(width: 8, height: 8)
                    .position(x: markerX, y: currentY)

                Text("Folync day reference")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 4)
                    .stockbarPill()
                    .padding(.leading, 4)
                    .padding(.top, 4)

                HStack(spacing: 12) {
                    referenceLabel(
                        title: "Reference",
                        value: reference.referenceValue,
                        alignment: .leading
                    )
                    Spacer(minLength: 8)
                    referenceLabel(
                        title: "Current",
                        value: reference.currentValue,
                        alignment: .trailing
                    )
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Folync day reference")
        .accessibilityValue(
            "\(MenuPopoverFormatter.currencyExact(reference.referenceValue, currency: currency)) reference, " +
            "\(MenuPopoverFormatter.currencyExact(reference.currentValue, currency: currency)) current"
        )
    }

    private func referenceLabel(
        title: String,
        value: Double,
        alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(MenuPopoverFormatter.currencyExact(value, currency: currency))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
