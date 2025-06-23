import SwiftUI
import Charts
import Combine

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

@MainActor
class MenuChartViewModel: ObservableObject {
    @Published var chartData: [MenuChartDataPoint] = []
    @Published var selectedTimeRange: MenuChartTimeRange = .day
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    
    private let symbol: String
    private let currentPrice: Double
    private let historicalDataManager = HistoricalDataManager.shared
    private let logger = Logger.shared
    private var cancellables = Set<AnyCancellable>()
    
    init(symbol: String, currentPrice: Double) {
        self.symbol = symbol
        self.currentPrice = currentPrice
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
                
                var dataPoints = snapshots.map { snapshot in
                    MenuChartDataPoint(
                        date: snapshot.timestamp,
                        price: snapshot.price,
                        symbol: snapshot.symbol
                    )
                }.sorted { $0.date < $1.date }
                
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
                
                await MainActor.run {
                    self.chartData = dataPoints
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

struct MenuPriceChartView: View {
    @StateObject private var viewModel: MenuChartViewModel
    @State private var hoveredPoint: MenuChartDataPoint?
    
    let symbol: String
    let currentPrice: Double
    let currency: String
    
    init(symbol: String, currentPrice: Double, currency: String) {
        self.symbol = symbol
        self.currentPrice = currentPrice
        self.currency = currency
        self._viewModel = StateObject(wrappedValue: MenuChartViewModel(symbol: symbol, currentPrice: currentPrice))
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // Header with symbol and current price
            headerView
            
            // Time range picker
            timeRangePickerView
            
            // Chart content
            chartContentView
        }
        .frame(width: 280, height: 200, alignment: .center)
        .fixedSize() // Prevent SwiftUI from changing the size
        .padding(16)
        .background(Color(.controlBackgroundColor))
        .layoutPriority(1000) // High layout priority
        .onAppear {
            // Ensure proper initialization when view appears
            viewModel.loadChartData()
        }
    }
    
    private var headerView: some View {
        HStack {
            if let point = hoveredPoint {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 2) {
                        Text(currency)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(String(format: "%.2f", point.price))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                    }
                    
                    Text(formatDate(point.date))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            VStack(spacing: 2) {
                Text(symbol)
                    .font(.headline)
                    .fontWeight(.semibold)
                
                HStack(spacing: 4) {
                    Text(currency)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.2f", currentPrice))
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                }
            }
            
            Spacer()
        }
    }
    
    private var timeRangePickerView: some View {
        HStack(spacing: 6) {
            ForEach(MenuChartTimeRange.allCases, id: \.self) { range in
                Button(action: {
                    viewModel.setTimeRange(range)
                }) {
                    Text(range.rawValue)
                        .font(.caption)
                        .fontWeight(viewModel.selectedTimeRange == range ? .semibold : .medium)
                        .foregroundColor(viewModel.selectedTimeRange == range ? .white : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(viewModel.selectedTimeRange == range ? 
                                    Color.accentColor : 
                                    Color(.quaternaryLabelColor))
                        )
                }
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: 0.2), value: viewModel.selectedTimeRange)
            }
            
            Spacer()
        }
        .padding(.horizontal, 2)
    }
    
    private var chartContentView: some View {
        Group {
            if viewModel.isLoading {
                loadingView
            } else if let errorMessage = viewModel.errorMessage {
                errorView(errorMessage)
            } else if viewModel.chartData.isEmpty {
                emptyDataView
            } else {
                chartView
            }
        }
        .frame(height: 120)
    }
    
    private var chartView: some View {
        Chart(viewModel.chartData) { dataPoint in
            LineMark(
                x: .value("Time", dataPoint.date),
                y: .value("Price", dataPoint.price)
            )
            .foregroundStyle(chartColor)
            .lineStyle(StrokeStyle(lineWidth: 2.0))
            
            if let hoveredPoint = hoveredPoint, hoveredPoint.id == dataPoint.id {
                PointMark(
                    x: .value("Time", dataPoint.date),
                    y: .value("Price", dataPoint.price)
                )
                .foregroundStyle(chartColor)
                .symbol(.circle)
                .symbolSize(40)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.secondary.opacity(0.3))
                AxisTick()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(formatXAxisDate(date))
                            .font(.caption2)
                    }
                }
            }
        }
        .chartYScale(domain: chartYAxisRange)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .stride(by: chartYAxisStride)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.secondary.opacity(0.3))
                AxisTick()
                AxisValueLabel {
                    if let price = value.as(Double.self) {
                        Text(String(format: "%.2f", price))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .chartPlotStyle { plotArea in
            plotArea
                .background(.clear)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .onTapGesture { location in
            // Simple tap gesture for point selection
            let chartWidth: CGFloat = 264 // Adjusted for padding (280 - 16)
            let relativeProgress = location.x / chartWidth
            
            if relativeProgress >= 0 && relativeProgress <= 1 {
                let dataIndex = Int(relativeProgress * Double(viewModel.chartData.count - 1))
                if dataIndex >= 0 && dataIndex < viewModel.chartData.count {
                    hoveredPoint = viewModel.chartData[dataIndex]
                }
            }
        }
    }
    
    private var chartColor: Color {
        guard let firstPrice = viewModel.chartData.first?.price,
              let lastPrice = viewModel.chartData.last?.price else {
            return .accentColor
        }
        
        return lastPrice >= firstPrice ? .green : .red
    }
    
    // Calculate tight Y-axis range based on actual data with +/-5% buffer
    private var chartYAxisRange: ClosedRange<Double> {
        guard !viewModel.chartData.isEmpty else {
            return 0...100 // Default range if no data
        }
        
        let prices = viewModel.chartData.map { $0.price }
        let minPrice = prices.min() ?? 0
        let maxPrice = prices.max() ?? 100
        
        // Calculate 5% buffer above and below the actual data range
        let priceRange = maxPrice - minPrice
        let buffer = max(priceRange * 0.05, (maxPrice + minPrice) / 2 * 0.01) // At least 1% of average price
        
        let adjustedMin = max(0, minPrice - buffer) // Don't go below 0
        let adjustedMax = maxPrice + buffer
        
        return adjustedMin...adjustedMax
    }
    
    // Calculate appropriate stride for Y-axis labels
    private var chartYAxisStride: Double {
        let range = chartYAxisRange.upperBound - chartYAxisRange.lowerBound
        
        // Aim for 3-4 axis marks
        let targetMarks = 3.0
        let rawStride = range / targetMarks
        
        // Round to nice numbers
        if rawStride >= 10 {
            return (rawStride / 10).rounded() * 10
        } else if rawStride >= 1 {
            return rawStride.rounded()
        } else if rawStride >= 0.1 {
            return (rawStride * 10).rounded() / 10
        } else {
            return (rawStride * 100).rounded() / 100
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.7)
                .tint(.accentColor)
            Text("Loading chart...")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
    
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .foregroundColor(.secondary)
                .font(.title3)
            Text(message)
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
    
    private var emptyDataView: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.xyaxis.line")
                .foregroundColor(.secondary)
                .font(.title3)
            
            if !currentPrice.isFinite || currentPrice <= 0 {
                Text("Price data unavailable")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Text("No historical data")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        
        switch viewModel.selectedTimeRange {
        case .day:
            formatter.dateFormat = "HH:mm"
        case .week:
            formatter.dateFormat = "MMM d, HH:mm"
        case .month:
            formatter.dateFormat = "MMM d"
        }
        
        return formatter.string(from: date)
    }
    
    private func formatXAxisDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        
        switch viewModel.selectedTimeRange {
        case .day:
            formatter.dateFormat = "HH:mm"
        case .week:
            formatter.dateFormat = "MMM d"
        case .month:
            formatter.dateFormat = "MMM d"
        }
        
        return formatter.string(from: date)
    }
}

// MARK: - NSHostingView Wrapper for Menu Integration

class MenuPriceChartHostingView: NSHostingView<MenuPriceChartView> {
    private let fixedSize = NSSize(width: 280, height: 200)
    
    init(symbol: String, currentPrice: Double, currency: String) {
        let chartView = MenuPriceChartView(
            symbol: symbol,
            currentPrice: currentPrice,
            currency: currency
        )
        super.init(rootView: chartView)
        
        // Configure the hosting view for menu integration
        self.translatesAutoresizingMaskIntoConstraints = false
        
        // Set fixed frame to prevent sizing issues
        self.frame = NSRect(origin: .zero, size: fixedSize)
        
        // Add constraints to ensure consistent sizing
        self.widthAnchor.constraint(equalToConstant: fixedSize.width).isActive = true
        self.heightAnchor.constraint(equalToConstant: fixedSize.height).isActive = true
        
        // Apply rounded corners at the AppKit level
        self.wantsLayer = true
        self.layer?.cornerRadius = 32
        self.layer?.masksToBounds = true
        
        // Ensure the view invalidates intrinsic content size properly
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
    
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        // Force layout when added to superview
        self.needsLayout = true
        self.layoutSubtreeIfNeeded()
    }
    
    override var fittingSize: NSSize {
        return fixedSize
    }
}