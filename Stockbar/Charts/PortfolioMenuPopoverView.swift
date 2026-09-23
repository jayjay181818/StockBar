import Combine
import SwiftUI

struct PortfolioMenuActions {
    let refresh: () -> Void
    let preferences: () -> Void
    let quit: () -> Void

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

    static func matchingCurrencyPoints(_ snapshots: [HistoricalPortfolioSnapshot], currency: String) -> [ChartDataPoint] {
        snapshots.filter { $0.currency.uppercased() == currency.uppercased() }
            .map { ChartDataPoint(date: $0.date, value: $0.totalValue) }
    }

    static func coversRange(_ points: [MenuChartDataPoint], range: MenuChartTimeRange, now: Date = Date()) -> Bool {
        guard let first = points.first, let last = points.last, points.count > 1 else { return false }
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
        Publishers.MergeMany([
            historicalDataManager.$priceSnapshots.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            historicalDataManager.$priceDataRevision.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            historicalDataManager.$historicalPortfolioSnapshots.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            historicalDataManager.$folyncSupplementalConfigurationRevision.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ])
            .receive(on: DispatchQueue.main)
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
        chartData = []
        hasRangeCoverage = false
        coverageLabel = ""
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
                    let result = await folyncCoordinator.routePortfolioHistory(range: range.chartTimeRange.folyncRange)
                    guard !Task.isCancelled, revision == historicalDataManager.folyncSupplementalConfigurationRevision else { return }
                    switch result {
                    case .folync(let history, let status):
                        guard let points = PortfolioMenuChartDataBuilder.providerPoints(
                            history, scopeID: scopeID, currency: currency, range: range
                        ) else {
                            coverageLabel = "Folync history does not match this portfolio, currency or period."
                            isLoading = false
                            return
                        }
                        chartData = points
                        hasRangeCoverage = history.coverage.complete == true && history.quality == .complete && status == .current && points.count > 1
                        coverageLabel = "\(status.label) · \(history.coverage.pointCount) observations · \(history.interval)"
                        if !hasRangeCoverage { coverageLabel += " · partial history" }
                        // Folync's 1d series is rolling history; Today's P&L still uses its daily reference.
                        if range == .day { coverageLabel = "Past 24 hours · " + coverageLabel }
                    case .legacy, .unavailable:
                        coverageLabel = "Folync portfolio history is unavailable for this period. Check the connection and source history."
                    }
                } else {
                    let snapshots = await historicalDataManager.loadPortfolioSnapshotsFromCoreData(timeRange: range.chartTimeRange)
                    guard !Task.isCancelled else { return }
                    chartData = PortfolioMenuChartDataBuilder.prepareChartPoints(
                        storedPoints: PortfolioMenuChartDataBuilder.matchingCurrencyPoints(snapshots, currency: currency),
                        currentValue: value, range: range
                    )
                    hasRangeCoverage = PortfolioMenuChartDataBuilder.coversRange(chartData, range: range)
                    coverageLabel = "Local history · \(chartData.count) observations"
                    if !hasRangeCoverage { coverageLabel += " · partial history" }
                }
                isLoading = false
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
        isLoading = false
    }
}

@MainActor
struct PortfolioMenuPopoverView: View {
    @ObservedObject private var dataModel: DataModel
    @StateObject private var viewModel: PortfolioMenuChartViewModel
    @State private var hoveredPoint: MenuChartDataPoint?
    @Namespace private var animationNamespace

    private let actions: PortfolioMenuActions
    private let chartHeight: CGFloat = 168

    init(dataModel: DataModel, actions: PortfolioMenuActions) {
        self.dataModel = dataModel
        self.actions = actions
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

    private var summary: DisplayPortfolioSummary {
        dataModel.calculateDisplayPortfolioSummary(
            preferredCurrency: dataModel.portfolioMenuBarDisplaySettings.currencyCode
        )
    }

    private var currentDisplayValue: String {
        MenuPopoverFormatter.currencyExact(hoveredPoint?.price ?? summary.totalValue, currency: summary.currency)
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
        VStack(spacing: 0) {
            headerView
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 14)

            ZStack(alignment: .topTrailing) {
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
                            hoveredPoint: $hoveredPoint
                        )
                        .accessibilityLabel("Portfolio history, \(viewModel.selectedTimeRange.description)")
                        .accessibilityValue("\(viewModel.chartData.count) observations")
                    }
                }
                .frame(height: chartHeight)
                .clipShape(Rectangle())

                MenuPopoverTimeRangePicker(
                    selectedRange: Binding(get: { viewModel.selectedTimeRange }, set: { viewModel.setTimeRange($0) }),
                    namespace: animationNamespace
                ) { _ in
                    hoveredPoint = nil
                }
                .padding(.top, 12)
                .padding(.trailing, 16)
            }
            .background(Color.black.opacity(0.12))

            if !viewModel.coverageLabel.isEmpty {
                Text(viewModel.coverageLabel).font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 18).padding(.top, 8)
            }

            statsGrid
                .padding(.horizontal, 18)
                .padding(.vertical, 16)

            Divider()
                .overlay(Color.white.opacity(0.12))

            MenuPopoverFooter(
                updatedText: updatedText,
                onRefresh: actions.refresh,
                onPreferences: actions.preferences,
                onQuit: actions.quit
            )
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
        }
        .frame(width: 360)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.white.opacity(0.13), lineWidth: 1)
        )
        .onAppear {
            viewModel.activate()
            viewModel.update(
                currentValue: summary.totalValue,
                currentTrades: dataModel.realTimeTrades,
                preferredCurrency: summary.currency,
                valuationSource: summary.valuationSource
            )
        }
        .onDisappear { viewModel.deactivate() }
        .onReceive(dataModel.tradeContentPublisher) { _ in
            viewModel.update(
                currentValue: summary.totalValue,
                currentTrades: dataModel.realTimeTrades,
                preferredCurrency: summary.currency,
                valuationSource: summary.valuationSource
            )
        }
        .onReceive(dataModel.$portfolioMenuBarDisplaySettings.dropFirst()) { _ in
            viewModel.update(
                currentValue: summary.totalValue,
                currentTrades: dataModel.realTimeTrades,
                preferredCurrency: summary.currency,
                valuationSource: summary.valuationSource
            )
        }
    }

    private var headerView: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Portfolio")
                    .font(.system(size: 22, weight: .bold, design: .default))
                    .foregroundColor(.white)

                HStack(spacing: 6) {
                    Text("\(summary.currency) • \(positionCountText)")
                    Circle()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: 3, height: 3)
                    Text(selectedRangeLabel)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
            }

            Spacer()

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(currentDisplayValue)
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

                if let point = hoveredPoint {
                    Text(MenuPopoverFormatter.date(point.date, range: viewModel.selectedTimeRange))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                } else if let displayedChange {
                    performancePill(percent: displayedChange.percent)
                }
            }
        }
    }

    private var statsGrid: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                MenuPopoverStatBox(
                    label: "Market Value",
                    value: MenuPopoverFormatter.currencyExact(summary.totalValue, currency: summary.currency)
                )

                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 1)

                let totalColor: Color = summary.totalGain >= 0 ? .green : .red
                MenuPopoverStatBox(
                    label: "Total P&L",
                    value: MenuPopoverFormatter.currencyExact(summary.totalGain, currency: summary.currency, includeSign: true),
                    subValue: MenuPopoverFormatter.percent(summary.totalGainPct),
                    valueColor: totalColor
                )
            }

            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)

            HStack(spacing: 0) {
                let change = displayedChange
                let rangeColor: Color = (change?.value ?? 0) >= 0 ? .green : .red
                MenuPopoverStatBox(
                    label: "\(selectedRangeLabel) P&L",
                    value: MenuPopoverFormatter.currencyExact(change?.value, currency: summary.currency, includeSign: true),
                    subValue: MenuPopoverFormatter.percent(change?.percent),
                    valueColor: rangeColor
                )

                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 1)

                MenuPopoverStatBox(
                    label: "Cost Basis",
                    value: MenuPopoverFormatter.currencyExact(summary.totalCost, currency: summary.currency)
                )
            }
        }
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    private var positionCountText: String {
        summary.ownedPositionCount == 1 ? "1 position" : "\(summary.ownedPositionCount) positions"
    }

    private var selectedRangeLabel: String {
        viewModel.selectedTimeRange == .day ? "Today" : viewModel.selectedTimeRange.description
    }

    private func performancePill(percent: Double) -> some View {
        let safePercent = percent.isFinite ? percent : 0
        let isPositive = safePercent >= 0

        return HStack(spacing: 2) {
            Image(systemName: isPositive ? "arrow.up" : "arrow.down")
                .font(.system(size: 8, weight: .bold))
            Text("\(String(format: "%.2f", abs(safePercent)))%")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(isPositive ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
        )
        .foregroundColor(isPositive ? .green : .red)
        .overlay(
            Capsule()
                .strokeBorder(isPositive ? Color.green.opacity(0.3) : Color.red.opacity(0.3), lineWidth: 1)
        )
    }
}

private struct PortfolioMenuDayReferenceView: View {
    let reference: PortfolioMenuDayReference
    let currency: String

    private var chartColor: Color {
        reference.change.value >= 0
            ? Color(red: 0.2, green: 0.85, blue: 0.5)
            : Color(red: 1.0, green: 0.3, blue: 0.3)
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
                    Color.white.opacity(0.35),
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
                    .foregroundColor(.white.opacity(0.65))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.black.opacity(0.25)))
                    .padding(.leading, 16)
                    .padding(.top, 12)

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
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
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
                .foregroundColor(.white.opacity(0.45))
            Text(MenuPopoverFormatter.currencyExact(value, currency: currency))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
        }
    }
}
