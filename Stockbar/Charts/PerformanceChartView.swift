import SwiftUI
import Charts
import AppKit

struct PerformanceChartView: View {
    @ObservedObject private var historicalDataManager = HistoricalDataManager.shared
    @State private var selectedTimeRange: ChartTimeRange = .month
    @State private var selectedChartType: ChartType = .portfolioValue
    @State private var showingMetrics = true
    @State private var hoveredDataPoint: ChartDataPoint?
    
    let availableSymbols: [String]
    let dataModel: DataModel?
    
    init(availableSymbols: [String] = [], dataModel: DataModel? = nil) {
        self.availableSymbols = availableSymbols
        self.dataModel = dataModel
    }
    
    var body: some View {
        VStack(spacing: 16) {
            // Chart Type Picker
            chartTypePicker
            
            // Time Range Picker
            timeRangePicker
            
            // Chart
            chartView
            
            // Performance Metrics Toggle
            if !chartData.isEmpty {
                metricsSection
            }
            
            // Comprehensive Return Analysis
            if !chartData.isEmpty && dataModel != nil {
                returnAnalysisSection
            }
        }
        .padding()
        .frame(minWidth: 600, minHeight: 400)
        .onChange(of: showingMetrics) { _, newValue in
            adjustChartWindowSize(expanded: newValue)
        }
    }
    
    private func adjustChartWindowSize(expanded: Bool) {
        // Only make minor adjustments for metrics expansion, don't override tab-based resizing
        DispatchQueue.main.async {
            if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.title == "Stockbar Preferences" }) {
                let currentFrame = window.frame
                let metricsHeight: CGFloat = 120 // Approximate height of the metrics section
                
                let newHeight = expanded ? 
                    currentFrame.height + metricsHeight : 
                    currentFrame.height - metricsHeight
                
                // Ensure we don't go below minimum height for charts (should be around 700)
                let finalHeight = max(newHeight, 650)
                
                let newFrame = NSRect(
                    x: currentFrame.origin.x,
                    y: currentFrame.origin.y - (finalHeight - currentFrame.height), // Adjust y to expand downward
                    width: currentFrame.width,
                    height: finalHeight
                )
                
                window.setFrame(newFrame, display: true, animate: true)
            }
        }
    }
    
    private var chartTypePicker: some View {
        Picker("Chart Type", selection: $selectedChartType) {
            Text("Portfolio Value").tag(ChartType.portfolioValue)
            Text("Portfolio Gains").tag(ChartType.portfolioGains)
            
            ForEach(availableSymbols, id: \.self) { symbol in
                Text(symbol).tag(ChartType.individualStock(symbol))
            }
        }
        .pickerStyle(SegmentedPickerStyle())
    }
    
    private var timeRangePicker: some View {
        Picker("Time Range", selection: $selectedTimeRange) {
            ForEach(ChartTimeRange.allCases, id: \.self) { range in
                Text(range.description).tag(range)
            }
        }
        .pickerStyle(SegmentedPickerStyle())
    }
    
    private var chartData: [ChartDataPoint] {
        historicalDataManager.getChartData(for: selectedChartType, timeRange: selectedTimeRange)
    }
    
    private var yAxisDomain: ClosedRange<Double> {
        guard !chartData.isEmpty else { return 0...1 }
        
        let values = chartData.map { $0.value }
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 1
        
        // Add 5% padding to top and bottom for better visualization
        let range = maxValue - minValue
        let padding = range * 0.05
        
        let paddedMin = minValue - padding
        let paddedMax = maxValue + padding
        
        // Ensure we don't have a zero range
        if paddedMin == paddedMax {
            return (paddedMin - 0.5)...(paddedMax + 0.5)
        }
        
        return paddedMin...paddedMax
    }
    
    private var chartView: some View {
        Group {
            if chartData.isEmpty {
                emptyChartView
            } else {
                Chart(chartData) { dataPoint in
                        LineMark(
                            x: .value("Date", dataPoint.date),
                            y: .value("Value", dataPoint.value)
                        )
                        .foregroundStyle(chartColor)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        
                        AreaMark(
                            x: .value("Date", dataPoint.date),
                            yStart: .value("Baseline", yAxisDomain.lowerBound),
                            yEnd: .value("Value", dataPoint.value)
                        )
                        .foregroundStyle(chartColor.opacity(0.1))
                        
                        // Add a point mark for the hovered data point
                        if let hoveredPoint = hoveredDataPoint,
                           hoveredPoint.date == dataPoint.date {
                            PointMark(
                                x: .value("Date", dataPoint.date),
                                y: .value("Value", dataPoint.value)
                            )
                            .foregroundStyle(chartColor)
                            .symbolSize(50)
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 6)) { value in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel(format: dateFormat)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 8)) { value in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel(format: valueFormat)
                        }
                    }
                    .chartYScale(domain: yAxisDomain)
                    .chartBackground { chartProxy in
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(Color.clear)
                                .contentShape(Rectangle())
                                .background(
                                    HoverTrackingView { location in
                                        if let location = location {
                                            updateHoveredDataPoint(at: location, in: geometry, chartProxy: chartProxy)
                                        } else {
                                            hoveredDataPoint = nil
                                        }
                                    }
                                )
                        }
                    }
                    .frame(height: 250)
                    .overlay(
                        // Hover tooltip as overlay - doesn't affect layout
                        Group {
                            if let hoveredPoint = hoveredDataPoint {
                                VStack {
                                    hoverTooltip(for: hoveredPoint)
                                    Spacer()
                                }
                                .allowsHitTesting(false) // Prevent tooltip from intercepting mouse events
                            }
                        },
                        alignment: .top
                    )
            }
        }
    }
    
    private var emptyChartView: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text("No Data Available")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text("Charts will appear after collecting price data")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(height: 250)
    }
    
    private var metricsSection: some View {
        VStack {
            Button(action: { showingMetrics.toggle() }) {
                HStack {
                    Text("Performance Metrics")
                    Spacer()
                    Image(systemName: showingMetrics ? "chevron.up" : "chevron.down")
                }
            }
            .buttonStyle(PlainButtonStyle())
            
            if showingMetrics {
                performanceMetricsView
            }
        }
    }
    
    @ViewBuilder
    private var performanceMetricsView: some View {
        if let metrics = historicalDataManager.getPerformanceMetrics(for: selectedTimeRange) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Total Return")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(metrics.formattedTotalReturn)
                            .font(.headline)
                            .foregroundColor(metrics.totalReturn >= 0 ? .green : .red)
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing) {
                        Text("Return %")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(metrics.formattedTotalReturnPercent)
                            .font(.headline)
                            .foregroundColor(metrics.totalReturnPercent >= 0 ? .green : .red)
                    }
                }
                
                HStack {
                    VStack(alignment: .leading) {
                        Text("Volatility")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(metrics.formattedVolatility)
                            .font(.subheadline)
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing) {
                        Text("Range")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(String(format: "%.2f", metrics.minValue)) - \(String(format: "%.2f", metrics.maxValue))")
                            .font(.subheadline)
                    }
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
    }
    
    private var returnAnalysisSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Return Analysis")
                .font(.headline)
                .foregroundColor(.primary)
            
            HStack(alignment: .top, spacing: 20) {
                // Left: Total Portfolio Return vs Purchase Price
                VStack(alignment: .leading, spacing: 4) {
                    Text("Total Portfolio Return")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if let model = dataModel {
                        let totalReturn = model.calculateNetGains()
                        Text("\(formatCurrency(totalReturn.amount, currency: totalReturn.currency))")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(totalReturn.amount >= 0 ? .green : .red)
                        
                        let totalPurchaseValue = calculateTotalPurchaseValue()
                        if totalPurchaseValue.amount > 0 {
                            let percentage = (totalReturn.amount / totalPurchaseValue.amount) * 100
                            Text("\(String(format: "%+.2f%%", percentage)) vs Purchase Price")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                // Center: Return for Selected Period
                VStack(alignment: .center, spacing: 4) {
                    Text("Period Return (\(selectedTimeRange.description))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if let metrics = historicalDataManager.getPerformanceMetrics(for: selectedTimeRange) {
                        Text(metrics.formattedTotalReturn)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(metrics.totalReturn >= 0 ? .green : .red)
                        
                        Text(metrics.formattedTotalReturnPercent)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Calculating...")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // Right: Current Value vs Average Price
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Portfolio Value")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if let model = dataModel {
                        let netValue = model.calculateNetValue()
                        Text("\(formatCurrency(netValue.amount, currency: netValue.currency))")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        
                        let avgPrice = calculateAverageCurrentPrice()
                        if avgPrice.amount > 0 {
                            Text("Avg: \(formatCurrency(avgPrice.amount, currency: avgPrice.currency))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            
            // Additional insights row
            HStack {
                if let model = dataModel {
                    let totalReturn = model.calculateNetGains()
                    let netValue = model.calculateNetValue()
                    let totalPurchase = calculateTotalPurchaseValue()
                    
                    if totalPurchase.amount > 0 && netValue.amount > 0 {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Investment Performance")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            let roiPercentage = (totalReturn.amount / totalPurchase.amount) * 100
                            Text("ROI: \(String(format: "%.2f%%", roiPercentage))")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(roiPercentage >= 0 ? .green : .red)
                        }
                        
                        Spacer()
                        
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Total Invested")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(formatCurrency(totalPurchase.amount, currency: totalPurchase.currency))")
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.7))
        .cornerRadius(12)
    }
    
    private func calculateTotalPurchaseValue() -> (amount: Double, currency: String) {
        guard let model = dataModel else { return (0, "USD") }
        
        var totalCostUSD = 0.0
        
        for trade in model.realTimeTrades {
            guard let rawCost = Double(trade.trade.position.positionAvgCostString), rawCost > 0 else { continue }
            
            let units = trade.trade.position.unitSize
            let currency = trade.realTimeInfo.currency ?? "USD"
            let symbol = trade.trade.name
            
            // Adjust cost for currency (handle UK stocks)
            var adjustedCost = rawCost
            if symbol.uppercased().hasSuffix(".L") && currency == "GBP" {
                adjustedCost = rawCost / 100.0  // Convert GBX to GBP
            }
            
            let totalPositionCost = adjustedCost * units
            
            // Convert to USD for aggregation
            var costInUSD = totalPositionCost
            if currency == "GBP" {
                // Use currency converter if available
                costInUSD = totalPositionCost * 1.27 // Approximate rate, should use actual converter
            } else if currency != "USD" {
                costInUSD = totalPositionCost * 1.0 // Fallback assumption
            }
            
            totalCostUSD += costInUSD
        }
        
        // Convert to preferred currency
        let preferredCurrency = model.preferredCurrency
        var finalAmount = totalCostUSD
        if preferredCurrency == "GBP" {
            finalAmount = totalCostUSD / 1.27 // Approximate conversion
        } else if preferredCurrency == "GBX" {
            finalAmount = (totalCostUSD / 1.27) * 100
        }
        
        return (finalAmount, preferredCurrency)
    }
    
    private func calculateAverageCurrentPrice() -> (amount: Double, currency: String) {
        guard let model = dataModel else { return (0, "USD") }
        
        var totalValue = 0.0
        var totalUnits = 0.0
        let currency = model.preferredCurrency
        
        for trade in model.realTimeTrades {
            guard !trade.realTimeInfo.currentPrice.isNaN, trade.realTimeInfo.currentPrice > 0 else { continue }
            
            let units = trade.trade.position.unitSize
            totalValue += trade.realTimeInfo.currentPrice * units
            totalUnits += units
        }
        
        let averagePrice = totalUnits > 0 ? totalValue / totalUnits : 0
        return (averagePrice, currency)
    }
    
    private func formatCurrency(_ amount: Double, currency: String) -> String {
        guard let model = dataModel else {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = currency == "GBX" ? "GBP" : currency
            formatter.maximumFractionDigits = currency == "GBX" ? 0 : 2
            return formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f %@", amount, currency)
        }
        
        let preferredCurrency = model.preferredCurrency
        let currencyConverter = CurrencyConverter()
        
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = preferredCurrency == "GBX" ? 0 : 2
        
        // Determine what currency the amount is currently in (assume USD if not specified)
        let sourceCurrency = currency.isEmpty ? "USD" : currency
        
        // Convert amount to preferred currency if needed
        var convertedAmount: Double
        if sourceCurrency == preferredCurrency || 
           (sourceCurrency == "GBP" && preferredCurrency == "GBX") ||
           (sourceCurrency == "GBX" && preferredCurrency == "GBP") {
            // Handle GBX/GBP as same currency family
            if sourceCurrency == "GBP" && preferredCurrency == "GBX" {
                convertedAmount = amount * 100.0
            } else if sourceCurrency == "GBX" && preferredCurrency == "GBP" {
                convertedAmount = amount / 100.0
            } else {
                convertedAmount = amount
            }
        } else {
            convertedAmount = currencyConverter.convert(amount: amount, from: sourceCurrency, to: preferredCurrency == "GBX" ? "GBP" : preferredCurrency)
            if preferredCurrency == "GBX" {
                convertedAmount = convertedAmount * 100.0
            }
        }
        
        // Primary display currency
        formatter.currencyCode = preferredCurrency == "GBX" ? "GBP" : preferredCurrency
        let primaryString = formatter.string(from: NSNumber(value: convertedAmount)) ?? String(format: "%.2f %@", convertedAmount, preferredCurrency)
        
        // Secondary currency in brackets (opposite of preferred)
        var secondaryString = ""
        if preferredCurrency == "USD" {
            // Show GBP in brackets
            let gbpAmount = currencyConverter.convert(amount: convertedAmount, from: "USD", to: "GBP")
            let gbpFormatter = NumberFormatter()
            gbpFormatter.numberStyle = .currency
            gbpFormatter.currencyCode = "GBP"
            gbpFormatter.maximumFractionDigits = 2
            secondaryString = gbpFormatter.string(from: NSNumber(value: gbpAmount)) ?? String(format: "%.2f GBP", gbpAmount)
        } else if preferredCurrency == "GBP" || preferredCurrency == "GBX" {
            // Show USD in brackets
            let baseAmount = preferredCurrency == "GBX" ? convertedAmount / 100.0 : convertedAmount
            let usdAmount = currencyConverter.convert(amount: baseAmount, from: "GBP", to: "USD")
            let usdFormatter = NumberFormatter()
            usdFormatter.numberStyle = .currency
            usdFormatter.currencyCode = "USD"
            usdFormatter.maximumFractionDigits = 2
            secondaryString = usdFormatter.string(from: NSNumber(value: usdAmount)) ?? String(format: "%.2f USD", usdAmount)
        }
        
        if !secondaryString.isEmpty {
            return "\(primaryString) (\(secondaryString))"
        } else {
            return primaryString
        }
    }
    
    private var chartColor: Color {
        switch selectedChartType {
        case .portfolioValue:
            return .blue
        case .portfolioGains:
            return chartData.last?.value ?? 0 >= 0 ? .green : .red
        case .individualStock:
            return .purple
        }
    }
    
    private var dateFormat: Date.FormatStyle {
        switch selectedTimeRange {
        case .day:
            return .dateTime.hour().minute()
        case .week:
            return .dateTime.weekday(.abbreviated).day()
        case .month:
            return .dateTime.day().month(.abbreviated)
        case .threeMonths, .sixMonths:
            return .dateTime.month(.abbreviated).day()
        case .year, .all:
            return .dateTime.month(.abbreviated).year()
        }
    }
    
    private var valueFormat: FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(2))
    }
    
    // MARK: - Hover Functions
    
    private func hoverTooltip(for dataPoint: ChartDataPoint) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Date")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(dataPoint.date, format: .dateTime.day().month().year())
                    .font(.caption)
                    .fontWeight(.medium)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Time")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(dataPoint.date, format: .dateTime.hour().minute())
                    .font(.caption)
                    .fontWeight(.medium)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Value")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(String(format: "%.2f", dataPoint.value))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(chartColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .shadow(radius: 2)
    }
    
    private func updateHoveredDataPoint(at location: CGPoint, in geometry: GeometryProxy, chartProxy: ChartProxy) {
        // Convert the location to a date value
        guard let date: Date = chartProxy.value(atX: location.x) else { return }
        
        // Find the closest data point to the hovered date
        let closestDataPoint = chartData.min { dataPoint1, dataPoint2 in
            abs(dataPoint1.date.timeIntervalSince(date)) < abs(dataPoint2.date.timeIntervalSince(date))
        }
        
        // Only update if the closest point is within a reasonable distance
        if let closest = closestDataPoint {
            let timeDifference = abs(closest.date.timeIntervalSince(date))
            // Allow some tolerance based on the time range (more tolerance for longer ranges)
            let tolerance: TimeInterval = {
                switch selectedTimeRange {
                case .day: return 3600 // 1 hour
                case .week: return 21600 // 6 hours
                case .month: return 86400 // 1 day
                case .threeMonths: return 259200 // 3 days
                case .sixMonths: return 604800 // 1 week
                case .year, .all: return 1209600 // 2 weeks
                }
            }()
            
            if timeDifference <= tolerance {
                hoveredDataPoint = closest
            } else {
                hoveredDataPoint = nil
            }
        }
    }
}

// MARK: - Hover Tracking View

struct HoverTrackingView: NSViewRepresentable {
    let onLocationChanged: (CGPoint?) -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = HoverView()
        view.onLocationChanged = onLocationChanged
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        if let hoverView = nsView as? HoverView {
            hoverView.onLocationChanged = onLocationChanged
        }
    }
}

class HoverView: NSView {
    var onLocationChanged: ((CGPoint?) -> Void)?
    private var trackingArea: NSTrackingArea?
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        
        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }
        
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .mouseMoved,
            .activeInKeyWindow
        ]
        
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: options,
            owner: self,
            userInfo: nil
        )
        
        if let trackingArea = trackingArea {
            addTrackingArea(trackingArea)
        }
    }
    
    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onLocationChanged?(location)
    }
    
    override func mouseEntered(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onLocationChanged?(location)
    }
    
    override func mouseExited(with event: NSEvent) {
        onLocationChanged?(nil)
    }
    
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
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

struct PerformanceChartView_Previews: PreviewProvider {
    static var previews: some View {
        PerformanceChartView(availableSymbols: ["AAPL", "GOOGL", "MSFT"])
    }
}