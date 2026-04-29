import Combine
import Foundation
import SwiftUI
import AppKit

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
}

@MainActor
class MenuChartViewModel: ObservableObject {
    @Published var chartData: [MenuChartDataPoint] = []
    @Published var benchmarkData: [MenuChartDataPoint] = []
    @Published var selectedTimeRange: MenuChartTimeRange = .day
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    
    private let symbol: String
    private let currentPrice: Double
    private let benchmarkSymbol: String?
    private let historicalDataManager = HistoricalDataManager.shared
    private let logger = Logger.shared
    private var cancellables = Set<AnyCancellable>()

    init(symbol: String, currentPrice: Double, benchmarkSymbol: String?) {
        self.symbol = symbol
        self.currentPrice = currentPrice
        self.benchmarkSymbol = benchmarkSymbol
        loadChartData()
    }
    
    func setTimeRange(_ range: MenuChartTimeRange) {
        selectedTimeRange = range
        loadChartData()
    }
    
    func loadChartData() {
        isLoading = true
        errorMessage = nil
        
        Task {
                let endDate = Date()
                let startDate = selectedTimeRange.startDate(from: endDate)
                
                // Get price snapshots for the symbol within the time range
                let snapshots = historicalDataManager.getPriceSnapshots(for: symbol, from: startDate, to: endDate)
                let validSnapshots = snapshots.filter { $0.price.isFinite && $0.price > 0 }
                
                var dataPoints = validSnapshots.map { snapshot in
                    MenuChartDataPoint(
                        date: snapshot.timestamp,
                        price: snapshot.price,
                        symbol: snapshot.symbol
                    )
                }.sorted { $0.date < $1.date }

                if let normalizedPoints = self.normalizeChartDataIfNeeded(dataPoints),
                   normalizedPoints.count == dataPoints.count {
                    dataPoints = normalizedPoints
                }
                
                // If we have very little historical data, add a simple line to current price
                if dataPoints.count < 2 && currentPrice.isFinite && currentPrice > 0 {
                    // If we have no data, create a simple two-point line
                    if dataPoints.isEmpty {
                        dataPoints = [
                            MenuChartDataPoint(date: startDate, price: currentPrice, symbol: symbol),
                            MenuChartDataPoint(date: endDate, price: currentPrice, symbol: symbol)
                        ]
                    } else {
                        // If we have some data, add current price as endpoint
                        dataPoints.append(MenuChartDataPoint(date: endDate, price: currentPrice, symbol: symbol))
                    }
                    
                    await logger.debug("📊 Added current price endpoint for \(symbol) - using \(dataPoints.count) data points")
                } else if !currentPrice.isFinite || currentPrice <= 0 {
                    await logger.debug("📊 Invalid current price for \(symbol): \(currentPrice) - chart may not display properly")
                }

                if dataPoints.count < 2 {
                    dataPoints = []
                    await logger.debug("📊 Insufficient valid points for \(symbol); skipping chart render")
                }

                var benchmarkPoints: [MenuChartDataPoint] = []
                if let benchmarkSymbol {
                    let benchmarkSnapshots = historicalDataManager.getPriceSnapshots(for: benchmarkSymbol, from: startDate, to: endDate)
                    
                    if benchmarkSnapshots.count < 2 {
                        // Capture values to avoid actor isolation issues in detached task
                        let fetchRange = selectedTimeRange.chartTimeRange
                        Task.detached(priority: .background) {
                            await HistoricalDataManager.shared.triggerHistoricalDataFetch(
                                for: benchmarkSymbol,
                                timeRange: fetchRange,
                                startDate: startDate
                            )
                        }
                    }
                    
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
                    self.chartData = dataPoints
                    self.benchmarkData = benchmarkPoints
                    self.isLoading = false
                    
                    if snapshots.isEmpty {
                        Task { await logger.debug("📊 Using interpolated data for \(symbol) (current price: \(currentPrice)) - no historical snapshots available yet") }
                    } else {
                        Task { await logger.debug("📊 Using \(snapshots.count) real price snapshots for \(symbol)") }
                    }
                    
                    Task { 
                        let minPrice = self.chartData.map { $0.price }.min() ?? 0
                        let maxPrice = self.chartData.map { $0.price }.max() ?? 0
                        await logger.debug("📊 Chart data for \(symbol): range \(String(format: "%.2f", minPrice)) - \(String(format: "%.2f", maxPrice)) (\(self.chartData.count) points)") 
                    }
                }
        }
    }
    
}

private extension MenuChartViewModel {
    func normalizeChartDataIfNeeded(_ points: [MenuChartDataPoint]) -> [MenuChartDataPoint]? {
        guard !points.isEmpty,
              SymbolMetadata.isUKSymbol(symbol),
              currentPrice.isFinite,
              currentPrice > 0 else {
            return nil
        }

        let upperThreshold = currentPrice * 20.0
        let lowerThreshold = currentPrice / 20.0
        var adjusted = false

        let normalizedPoints = points.map { point in
            var price = point.price
            if price.isFinite, price > 0 {
                if price > upperThreshold {
                    price /= 100.0
                    adjusted = true
                } else if price < lowerThreshold {
                    price *= 100.0
                    adjusted = true
                }
            }
            return MenuChartDataPoint(date: point.date, price: price, symbol: point.symbol)
        }

        guard adjusted else { return nil }

        Task {
            await logger.warning("📊 Chart scale normalization for \(symbol): adjusted legacy UK snapshot scale to match current price")
        }
        return normalizedPoints
    }
}

struct MenuPriceChartView: View {
    @StateObject private var viewModel: MenuChartViewModel
    @State private var hoveredPoint: MenuChartDataPoint?
    @Namespace private var animationNamespace
    @State private var isEditingUnits = false
    @State private var unitsInput = ""
    @AppStorage("menu.benchmarkComparisonEnabled") private var benchmarkEnabled: Bool = true

    let symbol: String
    let currentPrice: Double
    let currency: String
    let metrics: MenuPopoverMetrics
    let onUnitsSave: ((Double) -> Void)?

    private let chartHeight: CGFloat = 160

    private var marketValue: String {
        let val = currentPrice * metrics.units
        if val.isNaN || val.isInfinite { return "—" }
        return MenuPopoverFormatter.currency(val, currency: metrics.currency)
    }
    private var totalPnL: String { MenuPopoverFormatter.currency(metrics.totalPnL, currency: metrics.currency, includeSign: true) }
    private var totalPnLPercent: String { MenuPopoverFormatter.percent(metrics.totalPnLPercent) }
    private var priceChangePercent: Double? { metrics.priceChangePercent }
    private var units: String { MenuPopoverFormatter.units(metrics.units) }
    private var avgCost: String { MenuPopoverFormatter.currency(metrics.avgCost, currency: metrics.currency) }

    private var rangePriceChange: (value: Double, percent: Double)? {
        guard let first = viewModel.chartData.first,
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

    private var benchmarkLabel: String? {
        guard benchmarkEnabled,
              let benchmark = MenuPriceChartView.benchmarkSymbol(for: symbol) else {
            return nil
        }
        return "vs \(MenuPriceChartView.benchmarkDisplayName(for: benchmark))"
    }

    init(symbol: String, currentPrice: Double, currency: String, metrics: MenuPopoverMetrics, onUnitsSave: ((Double) -> Void)? = nil) {
        self.symbol = symbol
        self.currentPrice = currentPrice
        self.currency = currency
        self.metrics = metrics
        self.onUnitsSave = onUnitsSave
        let benchmark = MenuPriceChartView.benchmarkSymbol(for: symbol)
        self._viewModel = StateObject(wrappedValue: MenuChartViewModel(symbol: symbol, currentPrice: currentPrice, benchmarkSymbol: benchmark))
        self._unitsInput = State(initialValue: MenuPopoverFormatter.units(metrics.units))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            ZStack(alignment: .topTrailing) {
                MenuPopoverLineChart(
                    points: viewModel.chartData,
                    comparisonPoints: benchmarkEnabled ? viewModel.benchmarkData : [],
                    comparisonLabel: benchmarkLabel,
                    isLoading: viewModel.isLoading,
                    hoveredPoint: $hoveredPoint
                )
                    .frame(height: chartHeight)
                    .clipShape(Rectangle())
                
                MenuPopoverTimeRangePicker(
                    selectedRange: $viewModel.selectedTimeRange,
                    namespace: animationNamespace
                ) { range in
                    viewModel.setTimeRange(range)
                }
                    .padding(.top, 12)
                    .padding(.trailing, 16)
            }
            .background(
                LinearGradient(
                    colors: [Color.black.opacity(0.2), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            bentoStatsGrid
                .padding(16)

            Divider()
                .overlay(Color.white.opacity(0.1))

            footerView
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 330)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .onAppear {
            viewModel.loadChartData()
        }
    }
    
    private var headerView: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(symbol)
                    .font(.system(size: 24, weight: .bold, design: .default))
                    .foregroundColor(.white)

                Text(metrics.exchangeName)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            
            Spacer()
            
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let point = hoveredPoint {
                    Text(String(format: "%.2f", point.price))
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .contentTransition(.numericText())
                } else {
                    Text(String(format: "%.2f", currentPrice))
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }

                if hoveredPoint == nil {
                    let rangePercent = rangePriceChange?.percent
                    let changePercent = rangePercent ?? priceChangePercent ?? 0
                    let isPositive = changePercent >= 0
                    
                    HStack(spacing: 2) {
                        Image(systemName: isPositive ? "arrow.up" : "arrow.down")
                            .font(.system(size: 8, weight: .bold))
                        Text("\(String(format: "%.2f", abs(changePercent)))%")
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
                } else if let point = hoveredPoint {
                    Text(MenuPopoverFormatter.date(point.date, range: viewModel.selectedTimeRange))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                }
            }
        }
    }
    
    private var bentoStatsGrid: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                MenuPopoverStatBox(label: "Market Value", value: marketValue)
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 1)
                
                let totalColor: Color = (metrics.totalPnL ?? 0) >= 0 ? .green : .red
                MenuPopoverStatBox(label: "Total P&L", value: totalPnL, subValue: totalPnLPercent, valueColor: totalColor)
            }
            
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)
            
            HStack(spacing: 0) {
                let rangeValue = formatCurrency(rangePnL.value, currency: metrics.currency, includeSign: true)
                let rangePctStr = MenuPopoverFormatter.percent(rangePnL.percent)
                let rangeColor: Color = (rangePnL.value ?? 0) >= 0 ? .green : .red
                let rangeLabel = "\(viewModel.selectedTimeRange.rawValue) P&L"
                
                MenuPopoverStatBox(label: rangeLabel, value: rangeValue, subValue: rangePctStr, valueColor: rangeColor)
                
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 1)
                
                unitsBox
            }
        }
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }
    
    private var unitsBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Units")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: {
                    guard metrics.canEditUnits else { return }
                    isEditingUnits.toggle()
                }) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .foregroundColor(metrics.canEditUnits ? .white.opacity(0.6) : .white.opacity(0.2))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isEditingUnits, arrowEdge: .top) {
                    unitsEditor
                }
            }

            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(units)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)

                Text("@ \(avgCost)")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
    
    private var unitsEditor: some View {
        VStack(spacing: 12) {
            Text("Edit Units")
                .font(.headline)
            
            TextField("Units", text: $unitsInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .frame(width: 160)
            
            HStack(spacing: 12) {
                Button("Cancel") {
                    unitsInput = MenuPopoverFormatter.units(metrics.units)
                    isEditingUnits = false
                }
                
                Button("Save") {
                    if let newUnits = Double(unitsInput), newUnits.isFinite, newUnits > 0 {
                        onUnitsSave?(newUnits)
                    }
                    isEditingUnits = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }
    
    private var footerView: some View {
        MenuPopoverFooter(
            updatedText: metrics.updatedText,
            onRefresh: {
                NotificationCenter.default.post(name: .refreshRequested, object: nil)
            },
            onPreferences: {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            },
            onQuit: {
                NSApplication.shared.terminate(nil)
            }
        )
    }

    private func formatCurrency(_ value: Double?, currency: String, includeSign: Bool = false) -> String {
        MenuPopoverFormatter.currency(value, currency: currency, includeSign: includeSign)
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

class MenuPriceChartHostingView: NSHostingView<MenuPriceChartView> {
    private let fixedSize = NSSize(width: 330, height: 410)

    init(symbol: String, currentPrice: Double, currency: String, metrics: MenuPopoverMetrics, onUnitsSave: ((Double) -> Void)? = nil) {
        let chartView = MenuPriceChartView(
            symbol: symbol,
            currentPrice: currentPrice,
            currency: currency,
            metrics: metrics,
            onUnitsSave: onUnitsSave
        )
        super.init(rootView: chartView)
        
        self.translatesAutoresizingMaskIntoConstraints = false
        self.frame = NSRect(origin: .zero, size: fixedSize)
        
        self.widthAnchor.constraint(equalToConstant: fixedSize.width).isActive = true
        self.heightAnchor.constraint(equalToConstant: fixedSize.height).isActive = true
        
        self.invalidateIntrinsicContentSize()
    }

    required init(rootView: MenuPriceChartView) {
        super.init(rootView: rootView)
        self.frame = NSRect(origin: .zero, size: fixedSize)
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        return fixedSize
    }
    
    override var fittingSize: NSSize {
        return fixedSize
    }
}
