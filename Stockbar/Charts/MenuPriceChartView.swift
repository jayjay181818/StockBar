import AppKit
import Combine
import Foundation
import SwiftUI

struct MenuPopoverMetrics {
    let exchangeName: String
    let marketValue: Double?
    let totalPnL: Double?
    let totalPnLPercent: Double?
    let dayPnL: Double?
    let dayPnLPercent: Double?
    let priceChange: Double?
    let priceChangePercent: Double?
    let units: Double
    let avgCost: Double
    let currency: String
    let updatedText: String
    let canEditUnits: Bool
    /// Set while the circuit breaker is suspending automatic updates.
    var suspensionNotice: String? = nil
}

@MainActor
final class MenuChartTimeRangeSelectionStore {
    static let shared = MenuChartTimeRangeSelectionStore()

    private let defaults: UserDefaults
    private let keyPrefix = "menuChartTimeRange."

    init(defaults: UserDefaults = StockbarRuntimeStorage.userDefaults) {
        self.defaults = defaults
    }

    func selectedTimeRange(for symbol: String) -> MenuChartTimeRange {
        guard let rawValue = defaults.string(forKey: key(for: symbol)),
              let range = MenuChartTimeRange(rawValue: rawValue) else {
            return .day
        }
        return range
    }

    func save(_ range: MenuChartTimeRange, for symbol: String) {
        defaults.set(range.rawValue, forKey: key(for: symbol))
    }

    private func key(for symbol: String) -> String {
        "\(keyPrefix)\(symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())"
    }
}

@MainActor
class MenuChartViewModel: ObservableObject {
    @Published var chartData: [MenuChartDataPoint] = []
    @Published var benchmarkData: [MenuChartDataPoint] = []
    @Published private(set) var selectedTimeRange: MenuChartTimeRange = .day
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    /// False when the chart is only the current price drawn flat across the
    /// range; period changes from such a chart are meaningless (always 0).
    @Published private(set) var hasStoredHistory = false
    /// The period whose data is currently shown; drives the draw-in animation.
    @Published private(set) var loadedRange: MenuChartTimeRange?
    
    private let symbol: String
    private var currentPrice: Double
    private let benchmarkSymbol: String?
    private let timeRangeSelectionStore: MenuChartTimeRangeSelectionStore
    private let historicalDataManager = HistoricalDataManager.shared
    private let logger = Logger.shared
    private var cancellables = Set<AnyCancellable>()
    private let reloadCoalescer = ChartReloadCoalescer()
    private var historyTask: Task<Void, Never>?
    private var isActive = false
    private(set) var loadGeneration = 0

    init(
        symbol: String,
        currentPrice: Double,
        benchmarkSymbol: String?,
        timeRangeSelectionStore: MenuChartTimeRangeSelectionStore = .shared
    ) {
        self.symbol = symbol
        self.currentPrice = currentPrice
        self.benchmarkSymbol = benchmarkSymbol
        self.timeRangeSelectionStore = timeRangeSelectionStore
        self.selectedTimeRange = timeRangeSelectionStore.selectedTimeRange(for: symbol)
        Publishers.Merge(
            historicalDataManager.$priceSnapshots.dropFirst().map { _ in () },
            historicalDataManager.$priceDataRevision.dropFirst().map { _ in () }
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadChartData()
            }
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

    func setTimeRange(_ range: MenuChartTimeRange) {
        guard range != selectedTimeRange else { return }
        selectedTimeRange = range
        timeRangeSelectionStore.save(range, for: symbol)
        loadChartData()
    }

    func updateCurrentPrice(_ price: Double) {
        guard price.bitPattern != currentPrice.bitPattern else { return }
        currentPrice = price
        loadChartData()
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
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        let range = selectedTimeRange
        let latestPrice = currentPrice
        
        historyTask = Task { [weak self] in
                guard let self, !Task.isCancelled else { return }
                let endDate = Date()
                let startDate = range.startDate(from: endDate)
                
                // Get price snapshots for the symbol within the time range
                let snapshots = historicalDataManager.getPriceSnapshots(for: symbol, from: startDate, to: endDate)
                historicalDataManager.requestPriceHistoryIfNeeded(
                    for: symbol, timeRange: range.chartTimeRange, from: startDate, to: endDate,
                    availablePointCount: snapshots.count
                )
                let validSnapshots = snapshots.filter { $0.price.isFinite && $0.price > 0 }
                
                var dataPoints = validSnapshots.map { snapshot in
                    MenuChartDataPoint(
                        date: snapshot.timestamp,
                        price: snapshot.price,
                        symbol: snapshot.symbol
                    )
                }.sorted { $0.date < $1.date }

                if let normalizedPoints = self.normalizeChartDataIfNeeded(dataPoints, currentPrice: latestPrice),
                   normalizedPoints.count == dataPoints.count {
                    dataPoints = normalizedPoints
                }

                dataPoints = MenuChartDataBuilder.preparePricePoints(
                    storedPoints: dataPoints,
                    currentPrice: latestPrice,
                    symbol: symbol,
                    range: range,
                    now: endDate
                )

                if !latestPrice.isFinite || latestPrice <= 0 {
                    await logger.debug("📊 Invalid current price for \(symbol): \(latestPrice) - chart may not display properly")
                }

                if dataPoints.count < 2 {
                    dataPoints = []
                    await logger.debug("📊 Insufficient valid points for \(symbol); skipping chart render")
                }

                guard !Task.isCancelled else { return }
                var benchmarkPoints: [MenuChartDataPoint] = []
                if let benchmarkSymbol {
                    let benchmarkSnapshots = historicalDataManager.getPriceSnapshots(for: benchmarkSymbol, from: startDate, to: endDate)
                    historicalDataManager.requestPriceHistoryIfNeeded(
                        for: benchmarkSymbol, timeRange: range.chartTimeRange, from: startDate, to: endDate,
                        availablePointCount: benchmarkSnapshots.count
                    )
                    let validBenchmarkSnapshots = benchmarkSnapshots.filter { $0.price.isFinite && $0.price > 0 }
                    benchmarkPoints = validBenchmarkSnapshots.map { snapshot in
                        MenuChartDataPoint(
                            date: snapshot.timestamp,
                            price: snapshot.price,
                            symbol: snapshot.symbol
                        )
                    }.sorted { $0.date < $1.date }

                    if let first = benchmarkPoints.first {
                        if first.date > startDate {
                            benchmarkPoints.insert(
                                MenuChartDataPoint(date: startDate, price: first.price, symbol: first.symbol),
                                at: 0
                            )
                        }
                        if let last = benchmarkPoints.last, last.date < endDate {
                            benchmarkPoints.append(MenuChartDataPoint(date: endDate, price: last.price, symbol: last.symbol))
                        } else if benchmarkPoints.count == 1 {
                            benchmarkPoints.append(MenuChartDataPoint(date: endDate, price: first.price, symbol: first.symbol))
                        }
                    }
                }
                
                await MainActor.run {
                    guard !Task.isCancelled, self.isActive, generation == self.loadGeneration else { return }
                    self.chartData = dataPoints
                    self.benchmarkData = benchmarkPoints
                    self.hasStoredHistory = !validSnapshots.isEmpty && !dataPoints.isEmpty
                    self.loadedRange = range
                    self.isLoading = false
                    
                    let logger = self.logger
                    let symbol = self.symbol
                    let snapshotCount = snapshots.count
                    let renderedCount = dataPoints.count
                    Task {
                        if snapshotCount == 0 {
                            await logger.debug("📊 Using interpolated data for \(symbol) (current price: \(latestPrice)) - no historical snapshots available yet")
                        } else {
                            await logger.debug("📊 Using \(snapshotCount) real price snapshots for \(symbol), rendering \(renderedCount) menu chart points")
                        }
                    }
                }
        }
    }
}

private extension MenuChartViewModel {
    func normalizeChartDataIfNeeded(_ points: [MenuChartDataPoint], currentPrice: Double) -> [MenuChartDataPoint]? {
        guard !points.isEmpty,
              SymbolMetadata.isUKSymbol(symbol),
              currentPrice.isFinite,
              currentPrice > 0 else {
            return nil
        }

        var adjusted = false
        let normalizedPoints = points.map { point in
            let price = UKPriceScale.normalized(point.price, reference: currentPrice, symbol: symbol)
            if price.bitPattern != point.price.bitPattern {
                adjusted = true
            }
            return MenuChartDataPoint(date: point.date, price: price, symbol: point.symbol)
        }

        guard adjusted else { return nil }

        Task {
            await logger.warning("📊 Chart scale normalization for \(symbol): adjusted UK snapshot scale to match current price (stored data should already be repaired)")
        }
        return normalizedPoints
    }
}

struct MenuPriceChartView: View {
    @StateObject private var viewModel: MenuChartViewModel
    @State private var hoveredPoint: MenuChartDataPoint?
    @State private var isEditingUnits = false
    @State private var unitsInput = ""
    @State private var unitsInputError: String?
    @AppStorage("menu.benchmarkComparisonEnabled", store: StockbarRuntimeStorage.userDefaults) private var benchmarkEnabled: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let symbol: String
    let currentPrice: Double
    let currency: String
    let metrics: MenuPopoverMetrics
    let onUnitsSave: ((Double) -> Void)?
    let onRetry: (() -> Void)?

    private let chartHeight: CGFloat = 140

    private var marketValue: String {
        let val = currentPrice * metrics.units
        if val.isNaN || val.isInfinite { return "—" }
        return MenuPopoverFormatter.currencyExact(val, currency: metrics.currency)
    }
    private var totalPnL: String { MenuPopoverFormatter.currencyExact(metrics.totalPnL, currency: metrics.currency, includeSign: true) }
    private var totalPnLPercent: String { MenuPopoverFormatter.percent(metrics.totalPnLPercent) }
    private var priceChangePercent: Double? { metrics.priceChangePercent }
    private var units: String { MenuPopoverFormatter.units(metrics.units) }
    private var avgCost: String { MenuPopoverFormatter.currencyExact(metrics.avgCost, currency: metrics.currency) }

    /// Only real stored history is drawn; a flat line at today's price would
    /// look like a chart without being one.
    private var chartPoints: [MenuChartDataPoint] {
        viewModel.hasStoredHistory ? viewModel.chartData : []
    }

    private var rangePriceChange: (value: Double, percent: Double)? {
        guard viewModel.hasStoredHistory,
              let first = viewModel.chartData.first,
              let last = viewModel.chartData.last,
              first.price.isFinite,
              last.price.isFinite,
              first.price != 0 else {
            return nil
        }
        let change = last.price - first.price
        let percent = (change / first.price) * 100
        return (change, percent)
    }

    private var rangePnL: (value: Double?, percent: Double?) {
        guard let rangePriceChange, metrics.units.isFinite else {
            return (metrics.dayPnL, metrics.dayPnLPercent)
        }
        return (rangePriceChange.value * metrics.units, rangePriceChange.percent)
    }

    private var benchmarkName: String? {
        guard benchmarkEnabled,
              let benchmark = MenuPriceChartView.benchmarkSymbol(for: symbol) else {
            return nil
        }
        return MenuPriceChartView.benchmarkDisplayName(for: benchmark)
    }

    init(
        symbol: String,
        currentPrice: Double,
        currency: String,
        metrics: MenuPopoverMetrics,
        onUnitsSave: ((Double) -> Void)? = nil,
        onRetry: (() -> Void)? = nil
    ) {
        self.symbol = symbol
        self.currentPrice = currentPrice
        self.currency = currency
        self.metrics = metrics
        self.onUnitsSave = onUnitsSave
        self.onRetry = onRetry
        let benchmark = MenuPriceChartView.benchmarkSymbol(for: symbol)
        self._viewModel = StateObject(wrappedValue: MenuChartViewModel(symbol: symbol, currentPrice: currentPrice, benchmarkSymbol: benchmark))
        self._unitsInput = State(initialValue: MenuPopoverFormatter.editableUnits(metrics.units))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerView

            MenuPopoverTimeRangePicker(
                selectedRange: Binding(get: { viewModel.selectedTimeRange }, set: { viewModel.setTimeRange($0) })
            ) { _ in
                hoveredPoint = nil
            }

            VStack(alignment: .leading, spacing: 6) {
                MenuPopoverLineChart(
                    points: chartPoints,
                    comparisonPoints: benchmarkName != nil && !chartPoints.isEmpty ? viewModel.benchmarkData : [],
                    isLoading: viewModel.isLoading,
                    revealTrigger: viewModel.loadedRange?.rawValue ?? "",
                    emptyMessage: "Stockbar stores \(symbol)'s price as it runs; the chart fills in over time.",
                    hoveredPoint: $hoveredPoint
                )
                .frame(height: chartHeight)
                .accessibilityLabel("\(symbol) price, \(viewModel.selectedTimeRange.description)")
                .accessibilityValue(rangePriceChange.map { String(format: "%+.2f percent", $0.percent) } ?? "No history")

                if let benchmarkName, !chartPoints.isEmpty, !viewModel.benchmarkData.isEmpty {
                    MenuPopoverChartLegend(
                        primaryLabel: symbol,
                        primaryColor: MenuPopoverLineChart.color(for: chartPoints),
                        comparisonLabel: benchmarkName
                    )
                }
            }

            statsGrid

            if let notice = metrics.suspensionNotice {
                suspensionBanner(notice)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()

            footerView
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .frame(width: 330)
        .fixedSize(horizontal: false, vertical: true)
        .animation(StockbarMotion.animation(StockbarMotion.standard, reduceMotion: reduceMotion), value: metrics.suspensionNotice)
        .onAppear { viewModel.activate() }
        .onDisappear { viewModel.deactivate() }
        .onChange(of: currentPrice) { _, newValue in
            viewModel.updateCurrentPrice(newValue)
        }
    }

    private var headerView: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(symbol)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(metrics.exchangeName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(MenuPopoverFormatter.currencyExact(hoveredPoint?.price ?? currentPrice, currency: currency))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                    .animation(StockbarMotion.animation(StockbarMotion.standard, reduceMotion: reduceMotion), value: currentPrice)

                if let point = hoveredPoint {
                    Text(MenuPopoverFormatter.date(point.date, range: viewModel.selectedTimeRange))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    StockbarChangeBadge(percent: rangePriceChange?.percent ?? priceChangePercent)
                }
            }
        }
    }

    private var statsGrid: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                MenuPopoverStatBox(label: "Market Value", value: marketValue)
                MenuPopoverStatBox(label: "Total P&L", value: totalPnL, subValue: totalPnLPercent,
                                   valueColor: Self.signColor(metrics.totalPnL))
            }
            GridRow {
                let rangeLabel = rangePriceChange == nil ? "Today's P&L" : "\(viewModel.selectedTimeRange.description) P&L"
                MenuPopoverStatBox(
                    label: rangeLabel,
                    value: MenuPopoverFormatter.currencyExact(rangePnL.value, currency: metrics.currency, includeSign: true),
                    subValue: MenuPopoverFormatter.percent(rangePnL.percent),
                    valueColor: Self.signColor(rangePnL.value)
                )
                unitsBox
            }
        }
    }

    private var unitsBox: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Units")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if metrics.canEditUnits {
                    Button {
                        isEditingUnits.toggle()
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .background(StockbarPalette.hoverFill, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Edit units")
                    .accessibilityLabel("Edit units")
                    .popover(isPresented: $isEditingUnits, arrowEdge: .top) {
                        unitsEditor
                    }
                } else {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .help("Units come from the linked source and are read-only")
                        .accessibilityLabel("Units are read-only")
                }
            }

            Text(units)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())

            Text("at \(avgCost)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .menuPopoverTile()
    }

    private var unitsEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit Units")
                .font(.headline)
            Text(symbol)
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Units", text: $unitsInput)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .frame(width: 180)
                .onSubmit(saveUnits)
                .onChange(of: unitsInput) { _, _ in unitsInputError = nil }

            if let unitsInputError {
                Label(unitsInputError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(width: 180, alignment: .leading)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") {
                    unitsInput = MenuPopoverFormatter.editableUnits(metrics.units)
                    unitsInputError = nil
                    isEditingUnits = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Save", action: saveUnits)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .frame(width: 180)
        }
        .padding(16)
    }

    private func suspensionBanner(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.orange)
            Text(notice)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let onRetry {
                Button("Retry Now", action: onRetry)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func saveUnits() {
        guard metrics.canEditUnits else {
            isEditingUnits = false
            return
        }
        guard let newUnits = MenuPopoverFormatter.parseUnits(unitsInput) else {
            unitsInputError = "Enter a number greater than zero."
            return
        }
        onUnitsSave?(newUnits)
        unitsInputError = nil
        isEditingUnits = false
    }

    private var footerView: some View {
        MenuPopoverFooter(
            updatedText: metrics.updatedText,
            onRefresh: {
                NotificationCenter.default.post(name: .refreshRequested, object: nil)
            },
            onOpenApp: {
                NSApp.sendAction(#selector(AppDelegate.showStockbarWindow(_:)), to: NSApp.delegate, from: nil)
            },
            onPreferences: {
                NSApp.sendAction(#selector(AppDelegate.showPreferences(_:)), to: NSApp.delegate, from: nil)
            },
            onQuit: {
                NSApplication.shared.terminate(nil)
            }
        )
    }

    static func signColor(_ value: Double?) -> Color {
        StockbarPalette.signed(value, neutral: .primary)
    }

    static func benchmarkSymbol(for symbol: String) -> String? {
        let uppercased = symbol.uppercased()
        if SymbolMetadata.isUKSymbol(uppercased) {
            return "^FTSE"
        }
        if !uppercased.contains(".") {
            return "^GSPC"
        }
        return nil
    }

    static func benchmarkDisplayName(for symbol: String) -> String {
        switch symbol {
        case "^FTSE":
            return "FTSE 100"
        case "^GSPC":
            return "S&P 500"
        default:
            return symbol
        }
    }
}
