import Combine
import Combine
import Foundation
import SwiftUI
import AppKit

enum MenuChartTimeRange: String, CaseIterable {
    case day = "1D"
    case week = "1W"
    case month = "1M"
    
    var description: String {
        switch self {
        case .day: return "1 Day"
        case .week: return "1 Week"
        case .month: return "1 Month"
        }
    }
    
    var timeInterval: TimeInterval {
        switch self {
        case .day: return 24 * 60 * 60
        case .week: return 7 * 24 * 60 * 60
        case .month: return 30 * 24 * 60 * 60
        }
    }

    var chartTimeRange: ChartTimeRange {
        switch self {
        case .day: return .day
        case .week: return .week
        case .month: return .month
        }
    }
    
    func startDate(from endDate: Date = Date()) -> Date {
        return endDate.addingTimeInterval(-timeInterval)
    }
}

struct MenuChartDataPoint: Identifiable {
    let id = UUID()
    let date: Date
    let price: Double
    let symbol: String
}

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
            do {
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
                
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.errorMessage = "Failed to load chart data: \(error.localizedDescription)"
                }
                await logger.error("❌ Failed to load chart data for \(symbol): \(error)")
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
        return formatCurrency(val, currency: metrics.currency)
    }
    private var totalPnL: String { formatCurrency(metrics.totalPnL, currency: metrics.currency, includeSign: true) }
    private var totalPnLPercent: String { formatPercent(metrics.totalPnLPercent) }
    private var priceChangePercent: Double? { metrics.priceChangePercent }
    private var units: String { formatUnits(metrics.units) }
    private var avgCost: String { formatCurrency(metrics.avgCost, currency: metrics.currency) }

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
        return MenuPriceChartView.benchmarkDisplayName(for: benchmark)
    }

    init(symbol: String, currentPrice: Double, currency: String, metrics: MenuPopoverMetrics, onUnitsSave: ((Double) -> Void)? = nil) {
        self.symbol = symbol
        self.currentPrice = currentPrice
        self.currency = currency
        self.metrics = metrics
        self.onUnitsSave = onUnitsSave
        let benchmark = MenuPriceChartView.benchmarkSymbol(for: symbol)
        self._viewModel = StateObject(wrappedValue: MenuChartViewModel(symbol: symbol, currentPrice: currentPrice, benchmarkSymbol: benchmark))
        self._unitsInput = State(initialValue: formatUnits(metrics.units))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            ZStack(alignment: .topTrailing) {
                chartContentView
                    .frame(height: chartHeight)
                    .clipShape(Rectangle())
                
                floatingTimeRangePicker
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
                    .tracking(-0.5)

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
                    Text(formatDate(point.date))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                }
            }
        }
    }
    
    private var floatingTimeRangePicker: some View {
        HStack(spacing: 0) {
            ForEach(MenuChartTimeRange.allCases, id: \.self) { range in
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        viewModel.setTimeRange(range)
                    }
                }) {
                    Text(range.rawValue)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(viewModel.selectedTimeRange == range ? .black : .white.opacity(0.8))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background {
                            if viewModel.selectedTimeRange == range {
                                Capsule()
                                    .fill(Color.white)
                                    .matchedGeometryEffect(id: "activeTab", in: animationNamespace)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 0.5))
        )
        .shadow(color: Color.black.opacity(0.2), radius: 4, x: 0, y: 2)
    }
    
    private var chartContentView: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if viewModel.isLoading {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.chartData.count >= 2 {
                    chartView
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let x = value.location.x
                                    let width = geometry.size.width
                                    let percentage = max(0, min(1, x / width))
                                    let index = Int(Double(viewModel.chartData.count - 1) * percentage)
                                    if index >= 0 && index < viewModel.chartData.count {
                                        hoveredPoint = viewModel.chartData[index]
                                    }
                                }
                                .onEnded { _ in
                                    hoveredPoint = nil
                                }
                        )
                } else if viewModel.chartData.isEmpty {
                     Text("No Data")
                        .foregroundColor(.white.opacity(0.3))
                        .font(.caption)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if let benchmarkLabel {
                    Text("vs \(benchmarkLabel)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(Color.black.opacity(0.35))
                        )
                        .padding(.leading, 16)
                        .padding(.top, 12)
                }
            }
        }
    }
    
    private var chartView: some View {
        Canvas { context, size in
            let points = viewModel.chartData
            guard points.count >= 2 else { return }

            let benchmarkPoints = benchmarkEnabled ? viewModel.benchmarkData : []

            guard let minDate = points.first?.date.timeIntervalSince1970,
                  let maxDate = points.last?.date.timeIntervalSince1970 else { return }

            let dateRange = maxDate - minDate
            let safeDateRange = dateRange == 0 ? 1.0 : dateRange

            func percentSeries(_ series: [MenuChartDataPoint]) -> [(time: TimeInterval, value: Double)] {
                guard let first = series.first else { return [] }
                let baseline = first.price
                return series.map { point in
                    let percent = baseline.isFinite && baseline != 0 ? (point.price / baseline) - 1.0 : 0.0
                    return (point.date.timeIntervalSince1970, percent)
                }
            }

            let stockPercentSeries = percentSeries(points)
            let benchmarkPercentSeries = percentSeries(benchmarkPoints)
            let combinedValues = stockPercentSeries.map { $0.value } + benchmarkPercentSeries.map { $0.value }
            let minValue = combinedValues.min() ?? 0
            let maxValue = combinedValues.max() ?? 0
            let range = max(maxValue - minValue, 0.0001)

            let bottomInset = size.height * 0.06

            // Dynamic top inset: Avoid overlap with time range picker (top-right)
            // Picker occupies approx top 45pt in the right 40% of the chart
            let pickerHeight: CGFloat = 45.0
            let dangerZoneThreshold = minDate + (safeDateRange * 0.60)
            let baseTopInset = size.height * 0.16

            func calculateRequiredInset(_ series: [(time: TimeInterval, value: Double)]) -> CGFloat {
                var maxInset = baseTopInset
                for point in series where point.time > dangerZoneThreshold {
                    let v = CGFloat((point.value - minValue) / range)
                    if v > 0.05 {
                        // Solve for TopInset (T) to ensure point is below PickerHeight:
                        // y = (H-B)*(1-v) + v*T >= PickerHeight
                        // T >= (PickerHeight - (H-B)*(1-v)) / v
                        let hMinusB = size.height - bottomInset
                        let req = (pickerHeight - hMinusB * (1.0 - v)) / v
                        if req > maxInset { maxInset = req }
                    }
                }
                return maxInset
            }

            let topInset = min(
                max(calculateRequiredInset(stockPercentSeries), calculateRequiredInset(benchmarkPercentSeries)),
                size.height * 0.45
            )

            let usableHeight = max(size.height - topInset - bottomInset, 1)

            func normalize(_ series: [(time: TimeInterval, value: Double)]) -> [CGPoint] {
                series.map { item in
                    let normalizedX = (item.time - minDate) / safeDateRange
                    let normalizedY = (item.value - minValue) / range
                    return CGPoint(
                        x: normalizedX * size.width,
                        y: size.height - bottomInset - (normalizedY * usableHeight)
                    )
                }
            }

            let seriesPoints = normalize(stockPercentSeries)
            let benchmarkSeriesPoints = normalize(benchmarkPercentSeries)

            func smoothedPath(_ points: [CGPoint]) -> Path? {
                guard let first = points.first else { return nil }
                var path = Path()
                path.move(to: first)
                for index in 1..<points.count {
                    let current = points[index]
                    let previous = points[index - 1]
                    let midX = previous.x + (current.x - previous.x) / 2
                    let control1 = CGPoint(x: midX, y: previous.y)
                    let control2 = CGPoint(x: midX, y: current.y)
                    path.addCurve(to: current, control1: control1, control2: control2)
                }
                return path
            }

            if let benchmarkPath = smoothedPath(benchmarkSeriesPoints), !benchmarkSeriesPoints.isEmpty {
                context.stroke(
                    benchmarkPath,
                    with: .color(.white.opacity(0.25)),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )
            }

            guard let linePath = smoothedPath(seriesPoints) else { return }

            var fillPath = linePath
            fillPath.addLine(to: CGPoint(x: size.width, y: size.height))
            fillPath.addLine(to: CGPoint(x: 0, y: size.height))
            fillPath.closeSubpath()

            context.fill(
                fillPath,
                with: .linearGradient(
                    Gradient(colors: [chartColor.opacity(0.5), chartColor.opacity(0.0)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )

            context.stroke(
                linePath,
                with: .color(chartColor.opacity(0.35)),
                style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
            )

            context.stroke(
                linePath,
                with: .color(chartColor),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )

            if let hovered = hoveredPoint,
               let index = points.firstIndex(where: { $0.id == hovered.id }),
               index < seriesPoints.count {
                let pt = seriesPoints[index]

                var cursorPath = Path()
                cursorPath.move(to: CGPoint(x: pt.x, y: 0))
                cursorPath.addLine(to: CGPoint(x: pt.x, y: size.height))

                context.stroke(
                    cursorPath,
                    with: .color(.white.opacity(0.25)),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )

                let dotRect = CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8)
                context.fill(Path(ellipseIn: dotRect), with: .color(.white))
                context.stroke(Path(ellipseIn: dotRect), with: .color(chartColor), lineWidth: 2)
            }
        }
    }
    
    private var bentoStatsGrid: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                statBox(label: "Market Value", value: marketValue)
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 1)
                
                let totalColor: Color = (metrics.totalPnL ?? 0) >= 0 ? .green : .red
                statBox(label: "Total P&L", value: totalPnL, subValue: totalPnLPercent, valueColor: totalColor)
            }
            
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)
            
            HStack(spacing: 0) {
                let rangeValue = formatCurrency(rangePnL.value, currency: metrics.currency, includeSign: true)
                let rangePctStr = formatPercent(rangePnL.percent)
                let rangeColor: Color = (rangePnL.value ?? 0) >= 0 ? .green : .red
                let rangeLabel = "\(viewModel.selectedTimeRange.rawValue) P&L"
                
                statBox(label: rangeLabel, value: rangeValue, subValue: rangePctStr, valueColor: rangeColor)
                
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
    
    private func statBox(label: String, value: String, subValue: String? = nil, valueColor: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack(spacing: 4) {
                Text(value)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(valueColor)
                
                if let sub = subValue, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(valueColor.opacity(0.8))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
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
                    unitsInput = formatUnits(metrics.units)
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
        ZStack {
            Button(action: {
                NotificationCenter.default.post(name: .refreshRequested, object: nil)
            }) {
                HStack(spacing: 6) {
                    Text(metrics.updatedText)
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            
            HStack {
                Button(action: {
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                }) {
                    Text("Preferences")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Text("Quit")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    private var chartColor: Color {
        guard let first = viewModel.chartData.first?.price,
              let last = viewModel.chartData.last?.price else { return .blue }
        return last >= first ? Color(red: 0.2, green: 0.85, blue: 0.5) : Color(red: 1.0, green: 0.3, blue: 0.3)
    }
    
    private var chartYAxisRange: ClosedRange<Double> {
        guard !viewModel.chartData.isEmpty else { return 0...100 }
        let prices = viewModel.chartData.map { $0.price }
        let minPrice = prices.min() ?? 0
        let maxPrice = prices.max() ?? 100
        let buffer = max((maxPrice - minPrice) * 0.1, 0.01)
        return (minPrice - buffer)...(maxPrice + buffer)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = viewModel.selectedTimeRange == .day ? "HH:mm" : "MMM d, HH:mm"
        return formatter.string(from: date)
    }

    private func formatCurrency(_ value: Double?, currency: String, includeSign: Bool = false) -> String {
        guard let value = value, value.isFinite else { return "—" }
        let displayValue = currency == "GBX" ? (value / 100.0) : value
        let symbol: String
        switch currency {
        case "USD": symbol = "$"
        case "GBP", "GBX": symbol = "£"
        case "EUR": symbol = "€"
        case "JPY": symbol = "¥"
        case "CAD": symbol = "C$"
        case "AUD": symbol = "A$"
        default: symbol = currency
        }
        let format: String
        if abs(displayValue) >= 10000 {
            format = includeSign ? "%+.0f" : "%.0f"
        } else if abs(displayValue) >= 1000 {
            format = includeSign ? "%+.1f" : "%.1f"
        } else {
            format = includeSign ? "%+.2f" : "%.2f"
        }
        return String(format: format, displayValue) + symbol
    }

    private func formatPercent(_ value: Double?) -> String {
        guard let value = value, value.isFinite else { return "" }
        return String(format: "%+.2f%%", value)
    }

    private func formatUnits(_ value: Double) -> String {
        value.isFinite ? String(format: "%.0f", value) : "—"
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
