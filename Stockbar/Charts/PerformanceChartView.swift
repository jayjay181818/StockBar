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
    
    init(availableSymbols: [String] = []) {
        self.availableSymbols = availableSymbols
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
        }
        .padding()
        .frame(minWidth: 600, minHeight: 400)
        .onChange(of: showingMetrics) { _, newValue in
            adjustWindowSize(expanded: newValue)
        }
    }
    
    private func adjustWindowSize(expanded: Bool) {
        // Find the parent window
        DispatchQueue.main.async {
            if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.title == "Stockbar Preferences" }) {
                let currentFrame = window.frame
                let metricsHeight: CGFloat = 120 // Approximate height of the metrics section
                
                let newHeight = expanded ? 
                    currentFrame.height + metricsHeight : 
                    currentFrame.height - metricsHeight
                
                // Ensure we don't go below minimum height
                let finalHeight = max(newHeight, 400)
                
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
                            y: .value("Value", dataPoint.value)
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