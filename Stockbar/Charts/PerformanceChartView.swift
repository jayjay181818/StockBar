import SwiftUI
import Charts
import AppKit

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

struct PerformanceChartView: View {
    @ObservedObject private var historicalDataManager = HistoricalDataManager.shared
    @ObservedObject private var calculationManager = BackgroundCalculationManager.shared
    @State private var selectedTimeRange: ChartTimeRange = .month
    @State private var selectedChartType: ChartType = .portfolioValue
    @State private var showingMetrics = true
    @State private var hoveredDataPoint: ChartDataPoint?
    @State private var showingExportOptions = false
    @State private var selectedDataPoints: Set<UUID> = []
    @State private var chartScale: Double = 1.0
    @State private var chartOffset: CGSize = .zero
    @State private var showingDataFilters = false
    @State private var valueThreshold: Double = 0.0
    @State private var dateFilterEnabled = false
    @State private var customStartDate = Date().addingTimeInterval(-30 * 24 * 60 * 60) // 30 days ago
    @State private var customEndDate = Date()
    // CRITICAL FIX: Replace caching with proper state management for UI responsiveness
    @State private var displayableChartData: [ChartDataPoint] = []
    @State private var isLoadingData = false
    @State private var chartError: String? = nil

    // Comparison Mode state variables
    @State private var comparisonMode: Bool = false
    @State private var selectedComparisonSymbols: Set<String> = []
    @State private var comparisonChartData: [String: [ChartDataPoint]] = [:] // symbol -> data points
    @State private var normalizedComparison: Bool = true // Normalize to percentage for fair comparison

    // Visual Styling state variables
    @State private var lineThickness: Double = 2.0 // 1-3pt
    @State private var showGridLines: Bool = false
    @State private var useGradientFill: Bool = true

    // Chart visualization style
    @State private var chartVisualizationStyle: ChartVisualizationStyle = .line
    @State private var candlestickSettings = CandlestickChartSettings.load()
    @State private var ohlcData: [OHLCDataPoint] = []
    @State private var isLoadingOHLC = false

    let availableSymbols: [String]
    let dataModel: DataModel?
    private let exportManager = ExportManager.shared
    private let ohlcFetchService = OHLCFetchService.shared
    
    init(availableSymbols: [String] = [], dataModel: DataModel? = nil) {
        self.availableSymbols = availableSymbols
        self.dataModel = dataModel
    }
    
    var body: some View {
        VStack(spacing: 16) {
            // Chart Type Picker
            chartTypePicker
                .padding(.top, 8) // Extra top padding to prevent overlap with tab divider
            
            // Time Range Picker
            timeRangePicker

            // Custom Date Range Picker (shown when Custom is selected)
            if selectedTimeRange == .custom {
                customDateRangePicker
            }

            // Comparison Mode Controls (shown for individual stock charts)
            if case .individualStock = selectedChartType {
                comparisonModeControls
            }

            // Visual Styling Controls
            visualStylingControls

            // Progress Indicator
            if calculationManager.isCalculating {
                calculationProgressView
            }
            
            // Error Display
            if let error = calculationManager.lastError {
                errorView(error)
            }
            
            // Chart
            chartView
            
            // Performance Metrics Toggle
            if !displayableChartData.isEmpty {
                metricsSection
            }
            
            // Data Filters
            if !displayableChartData.isEmpty {
                dataFiltersSection
            }
            
            // Export Options
            if !displayableChartData.isEmpty {
                exportSection
            }
            
            // Comprehensive Return Analysis
            if !displayableChartData.isEmpty && dataModel != nil {
                switch selectedChartType {
                case .portfolioValue, .portfolioGains:
                    portfolioReturnAnalysisSection
                case .individualStock(let symbol):
                    stockReturnAnalysisSection(for: symbol)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minWidth: 600, minHeight: 450)
        .onChange(of: showingMetrics) { _, newValue in
            adjustChartWindowSize(expanded: newValue)
            // Notify PreferenceView to adjust window size
            NotificationCenter.default.post(name: .chartMetricsToggled, object: newValue)
        }
        .onChange(of: selectedDataPoints) { _, _ in
            // Update analytics when selection changes - SwiftUI will automatically update
        }
        // CRITICAL FIX: Use .task to load data asynchronously when dependencies change
        .task(id: selectedTimeRange) {
            await loadChartData()
        }
        .task(id: selectedChartType) {
            await loadChartData()
        }
        .onAppear {
            // Initialize chart interactions
            setupKeyboardShortcuts()
        }
    }
    
    private func adjustChartWindowSize(expanded: Bool) {
        // Notify the parent PreferenceView to handle window resizing
        // Auto-resizing will handle window sizing automatically
    }
    
    private var chartTypePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chartTypeChip(for: .portfolioValue, label: "Portfolio Value")
                    chartTypeChip(for: .portfolioGains, label: "Portfolio Gains")

                    ForEach(availableSymbols, id: \.self) { symbol in
                        chartTypeChip(for: .individualStock(symbol), label: symbol)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chartTypeChip(for type: ChartType, label: String) -> some View {
        let isSelected = type == selectedChartType

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedChartType = type
            }
        } label: {
            HStack(spacing: 6) {
                if case .individualStock = type {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 11, weight: .medium))
                }
                Text(label)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background(buttonBackground(for: isSelected))
            .overlay(
                Capsule()
                    .stroke(buttonBorderColor(isSelected: isSelected), lineWidth: isSelected ? 1.5 : 1)
            )
            .foregroundColor(isSelected ? Color.accentColor : Color.primary)
            .clipShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("Show \(label) chart")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func buttonBackground(for isSelected: Bool) -> some View {
        Capsule()
            .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(NSColor.controlBackgroundColor))
    }

    private func buttonBorderColor(isSelected: Bool) -> Color {
        if isSelected { return Color.accentColor }
        return Color.primary.opacity(0.25)
    }
    
    // MARK: - Progress Indicator Views
    
    private var calculationProgressView: some View {
        VStack(spacing: 8) {
            HStack {
                ProgressView(value: calculationManager.calculationProgress)
                    .progressViewStyle(LinearProgressViewStyle())
                    .frame(height: 6)
                    .cornerRadius(3)
                
                Text(calculationManager.formattedProgress)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .trailing)
            }
            
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(calculationManager.calculationStatus)
                        .font(.caption)
                        .foregroundColor(.primary)
                    
                    if !calculationManager.memoryUsage.isEmpty {
                        Text("Memory: \(calculationManager.memoryUsage)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 2) {
                    if !calculationManager.formattedTimeRemaining.isEmpty {
                        Text(calculationManager.formattedTimeRemaining)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    if calculationManager.dataPointsCount > 0 {
                        Text("\(calculationManager.dataPointsCount) points")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                Button("Cancel") {
                    calculationManager.cancelCalculation()
                }
                .buttonStyle(PlainButtonStyle())
                .font(.caption)
                .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.blue.opacity(0.3), lineWidth: 1)
        )
    }
    
    private func errorView(_ error: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            
            Text(error)
                .font(.caption)
                .foregroundColor(.primary)
            
            Spacer()
            
            Button("Dismiss") {
                calculationManager.reportError("") // Clear error
            }
            .buttonStyle(PlainButtonStyle())
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
    
    private var timeRangePicker: some View {
        Picker("Time Range", selection: $selectedTimeRange) {
            ForEach(ChartTimeRange.allCases, id: \.self) { range in
                Text(range.description).tag(range)
            }
        }
        .pickerStyle(SegmentedPickerStyle())
    }

    // MARK: - Custom Date Range Picker

    private var customDateRangePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom Date Range")
                .font(.headline)
                .foregroundColor(.primary)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Start Date")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    DatePicker("", selection: $customStartDate, displayedComponents: .date)
                        .labelsHidden()
                        .onChange(of: customStartDate) { _, _ in
                            // Validate: end date must be after start date
                            if customEndDate < customStartDate {
                                customEndDate = customStartDate
                            }
                        }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("End Date")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    DatePicker("", selection: $customEndDate, displayedComponents: .date)
                        .labelsHidden()
                        .onChange(of: customEndDate) { _, _ in
                            // Validate: end date must be after start date
                            if customEndDate < customStartDate {
                                customStartDate = customEndDate
                            }
                        }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("Selected Range")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(formattedCustomDateRange)
                        .font(.caption)
                        .foregroundColor(.primary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
    }

    private var formattedCustomDateRange: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return "\(formatter.string(from: customStartDate)) - \(formatter.string(from: customEndDate))"
    }

    // MARK: - Comparison Mode Controls

    private var comparisonModeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Comparison Mode", isOn: $comparisonMode)
                    .toggleStyle(SwitchToggleStyle())
                    .onChange(of: comparisonMode) { _, newValue in
                        if !newValue {
                            // Clear selection when disabling comparison
                            selectedComparisonSymbols.removeAll()
                            comparisonChartData.removeAll()
                        }
                    }

                Spacer()

                if comparisonMode {
                    Toggle("Normalized (%)", isOn: $normalizedComparison)
                        .toggleStyle(SwitchToggleStyle())
                        .help("Show as percentage change from start date")
                }
            }

            if comparisonMode {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Select stocks to compare (max 5)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(availableSymbols, id: \.self) { symbol in
                                comparisonSymbolChip(for: symbol)
                            }
                        }
                    }

                    if !selectedComparisonSymbols.isEmpty {
                        HStack {
                            Text("\(selectedComparisonSymbols.count) stock(s) selected")
                                .font(.caption2)
                                .foregroundColor(.secondary)

                            Spacer()

                            Button("Clear All") {
                                selectedComparisonSymbols.removeAll()
                                comparisonChartData.removeAll()
                            }
                            .font(.caption)
                            .buttonStyle(PlainButtonStyle())
                            .foregroundColor(.blue)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
        }
    }

    private func comparisonSymbolChip(for symbol: String) -> some View {
        let isSelected = selectedComparisonSymbols.contains(symbol)
        let canSelect = selectedComparisonSymbols.count < 5 || isSelected

        return Button {
            if isSelected {
                selectedComparisonSymbols.remove(symbol)
                comparisonChartData.removeValue(forKey: symbol)
            } else if canSelect {
                selectedComparisonSymbols.insert(symbol)
                // Load data for this symbol
                Task {
                    await loadComparisonData(for: symbol)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10))
                Text(symbol)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
            .foregroundColor(isSelected ? Color.accentColor : (canSelect ? Color.primary : Color.secondary))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!canSelect)
    }

    // MARK: - Visual Styling Controls

    private var visualStylingControls: some View {
        HStack(spacing: 16) {
            // Chart Style Picker (only for individual stocks)
            if case .individualStock = selectedChartType {
                Picker("Style", selection: $chartVisualizationStyle) {
                    ForEach(ChartVisualizationStyle.allCases, id: \.self) { style in
                        Label(style.rawValue, systemImage: style.icon)
                            .tag(style)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 180)
            }

            HStack(spacing: 6) {
                Text("Line:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Slider(value: $lineThickness, in: 1...3, step: 0.5)
                    .frame(width: 80)
                Text("\(Int(lineThickness))pt")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 25)
            }
            .opacity(chartVisualizationStyle == .line ? 1.0 : 0.3)

            Toggle("Grid", isOn: $showGridLines)
                .toggleStyle(SwitchToggleStyle())
                .font(.caption)

            Toggle("Gradient", isOn: $useGradientFill)
                .toggleStyle(SwitchToggleStyle())
                .font(.caption)
                .opacity(chartVisualizationStyle == .line ? 1.0 : 0.3)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }

    // MARK: - Comparison Data Loading

    private func loadComparisonData(for symbol: String) async {
        do {
            let data = await historicalDataManager.getChartData(
                for: .individualStock(symbol),
                timeRange: selectedTimeRange,
                dataModel: dataModel
            )

            await MainActor.run {
                comparisonChartData[symbol] = data
                print("📊 Loaded \(data.count) data points for comparison symbol: \(symbol)")
            }
        } catch {
            await MainActor.run {
                print("⚠️ Failed to load comparison data for \(symbol): \(error.localizedDescription)")
            }
        }
    }

    // CRITICAL FIX: Replaced synchronous computed property with async function
    private func loadChartData() async {
        isLoadingData = true
        chartError = nil
        
        do {
            // Run data fetching in background task to avoid blocking UI
            let data = await withTaskGroup(of: [ChartDataPoint].self) { group in
                group.addTask {
                    await historicalDataManager.getChartData(for: selectedChartType, timeRange: selectedTimeRange, dataModel: dataModel)
                }
                return await group.next() ?? []
            }
            
            // Apply filtering and downsampling on background task
            let processedData = await processChartData(data)
            
            // Update UI state on main actor
            await MainActor.run {
                displayableChartData = processedData
                isLoadingData = false
                print("📊 Loaded \(processedData.count) chart data points for \(selectedChartType.title) (\(selectedTimeRange.rawValue))")
            }
        } catch {
            await MainActor.run {
                chartError = "Failed to load chart data: \(error.localizedDescription)"
                isLoadingData = false
                displayableChartData = []
            }
        }
    }

    private func loadOHLCData() async {
        guard case .individualStock(let symbol) = selectedChartType else {
            return
        }

        isLoadingOHLC = true

        do {
            // Map time range to yfinance period
            let period = selectedTimeRange.yfinancePeriod
            let interval = selectedTimeRange.suggestedInterval

            // Try to load from cache first
            let cachedData = try await ohlcFetchService.getCachedOHLCData(symbol: symbol)

            if !cachedData.isEmpty {
                await MainActor.run {
                    ohlcData = cachedData
                    isLoadingOHLC = false
                }
                await Logger.shared.info("Loaded \(cachedData.count) cached OHLC data points for \(symbol)")
                return
            }

            // Fetch fresh data from yfinance
            let snapshots = try await ohlcFetchService.fetchOHLCData(
                symbol: symbol,
                period: period,
                interval: interval
            )

            // Convert to OHLCDataPoint
            let dataPoints = snapshots.map { snapshot in
                OHLCDataPoint(
                    timestamp: snapshot.timestamp,
                    open: snapshot.open,
                    high: snapshot.high,
                    low: snapshot.low,
                    close: snapshot.close,
                    volume: snapshot.volume
                )
            }

            await MainActor.run {
                ohlcData = dataPoints
                isLoadingOHLC = false
            }

            await Logger.shared.info("Loaded \(dataPoints.count) OHLC data points for \(symbol)")

        } catch {
            await MainActor.run {
                isLoadingOHLC = false
                ohlcData = []
            }
            await Logger.shared.error("Failed to load OHLC data: \(error)")
        }
    }

    // CRITICAL FIX: Move filtering and processing to background task
    private func processChartData(_ data: [ChartDataPoint]) async -> [ChartDataPoint] {
        // Capture main-actor properties before entering detached task
        let threshold = valueThreshold
        let timeRange = selectedTimeRange
        let filterEnabled = dateFilterEnabled
        let startDate = customStartDate
        let endDate = customEndDate

        return await Task.detached {
            var filtered = data

            // Apply value threshold filter
            if threshold > 0 {
                filtered = filtered.filter { abs($0.value) >= threshold }
            }

            // Apply custom date range filter when custom time range is selected
            if timeRange == .custom {
                filtered = filtered.filter { dataPoint in
                    dataPoint.date >= startDate && dataPoint.date <= endDate
                }
            } else if filterEnabled {
                // Apply additional date filter if enabled
                filtered = filtered.filter { dataPoint in
                    dataPoint.date >= startDate && dataPoint.date <= endDate
                }
            }

            // Intelligent downsampling for performance
            if filtered.count > 1000 {
                let strideValue = filtered.count / 800 // Target ~800 points for smooth rendering
                filtered = Array(stride(from: 0, to: filtered.count, by: max(1, strideValue)).map { filtered[$0] })
                print("📊 Downsampled chart data from \(data.count) to \(filtered.count) points for performance")
            }

            return filtered
        }.value
    }
    
    private var yAxisDomain: ClosedRange<Double> {
        guard !displayableChartData.isEmpty else { return 0...1 }
        
        let values = displayableChartData.map { $0.value }
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
        } else {
            return paddedMin...paddedMax
        }
    }
    
    private var chartView: some View {
        Group {
            if isLoadingData {
                ProgressView("Loading chart data...")
                    .frame(height: 300)
            } else if let error = chartError {
                Text("Error: \(error)")
                    .foregroundColor(.red)
                    .frame(height: 300)
            } else if displayableChartData.isEmpty {
                emptyChartView
            } else if comparisonMode && !selectedComparisonSymbols.isEmpty {
                // COMPARISON MODE: Multi-series chart
                comparisonChartContent
            } else if chartVisualizationStyle == .candlestick {
                // CANDLESTICK CHART: Requires OHLC data
                candlestickChartPlaceholder
            } else {
                // SINGLE SERIES: Standard line chart
                Chart(displayableChartData) { dataPoint in
                        LineMark(
                            x: .value("Date", dataPoint.date),
                            y: .value("Value", dataPoint.value)
                        )
                        .foregroundStyle(chartColor)
                        .lineStyle(StrokeStyle(lineWidth: lineThickness))

                        if useGradientFill {
                            AreaMark(
                                x: .value("Date", dataPoint.date),
                                yStart: .value("Baseline", yAxisDomain.lowerBound),
                                yEnd: .value("Value", dataPoint.value)
                            )
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [chartColor.opacity(0.3), chartColor.opacity(0.05)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        } else {
                            AreaMark(
                                x: .value("Date", dataPoint.date),
                                yStart: .value("Baseline", yAxisDomain.lowerBound),
                                yEnd: .value("Value", dataPoint.value)
                            )
                            .foregroundStyle(chartColor.opacity(0.1))
                        }

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

                        // Add selection indicators
                        if selectedDataPoints.contains(dataPoint.id) {
                            PointMark(
                                x: .value("Date", dataPoint.date),
                                y: .value("Value", dataPoint.value)
                            )
                            .foregroundStyle(.orange)
                            .symbolSize(30)
                            .symbol(.circle)
                        }

                        // Zero baseline for gains charts
                        if case .portfolioGains = selectedChartType, dataPoint.value == 0 {
                            RuleMark(y: .value("Zero", 0))
                                .foregroundStyle(Color.secondary.opacity(0.5))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 6)) { value in
                            if showGridLines {
                                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                            }
                            AxisTick()
                            AxisValueLabel(format: dateFormat)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 8)) { value in
                            if showGridLines {
                                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                            }
                            AxisTick()
                            AxisValueLabel(format: currencyValueFormat)
                        }
                    }
                    .chartYScale(domain: yAxisDomain)
                    .chartBackground { chartProxy in
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(Color.clear)
                                .contentShape(Rectangle())
                                .background(
                                    EnhancedChartInteractionView(
                                        chartData: displayableChartData,
                                        selectedDataPoints: $selectedDataPoints,
                                        hoveredDataPoint: $hoveredDataPoint,
                                        chartScale: $chartScale,
                                        chartOffset: $chartOffset,
                                        geometry: geometry,
                                        chartProxy: chartProxy,
                                        selectedTimeRange: selectedTimeRange
                                    )
                                )
                        }
                    }
                    .frame(height: max(200, 250 * chartScale))
                    .scaleEffect(chartScale)
                    .offset(chartOffset)
                    .clipped()
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

    private var candlestickChartPlaceholder: some View {
        Group {
            if isLoadingOHLC {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Loading OHLC data...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(height: 300)
            } else if ohlcData.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "chart.bar")
                        .font(.system(size: 48))
                        .foregroundColor(.accentColor)

                    Text("Candlestick Chart")
                        .font(.headline)

                    Text("Fetching OHLC data...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Button(action: {
                        Task {
                            await loadOHLCData()
                        }
                    }) {
                        Label("Load Candlestick Data", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)

                    Button(action: {
                        chartVisualizationStyle = .line
                    }) {
                        Label("Switch to Line Chart", systemImage: "chart.xyaxis.line")
                    }
                    .buttonStyle(.bordered)
                }
                .frame(height: 300)
            } else {
                CandlestickChartView(
                    data: ohlcData,
                    currency: getDisplayCurrency(),
                    settings: candlestickSettings
                )
                .frame(height: 400)
            }
        }
        .onChange(of: selectedChartType) { _ in
            if chartVisualizationStyle == .candlestick {
                Task {
                    await loadOHLCData()
                }
            }
        }
        .onChange(of: selectedTimeRange) { _ in
            if chartVisualizationStyle == .candlestick {
                Task {
                    await loadOHLCData()
                }
            }
        }
    }

    // MARK: - Comparison Chart Content

    private var comparisonChartContent: some View {
        VStack(spacing: 12) {
            comparisonChart
                .frame(height: 300)

            // Color Legend
            comparisonLegend
        }
    }

    private var comparisonChart: some View {
        let sortedSymbols = Array(selectedComparisonSymbols).sorted()

        return Chart {
            ForEach(sortedSymbols, id: \.self) { symbol in
                if let data = comparisonChartData[symbol] {
                    let processedData = normalizedComparison ? normalizeData(data) : data
                    let color = colorForSymbol(symbol)

                    ForEach(processedData) { dataPoint in
                        LineMark(
                            x: .value("Date", dataPoint.date),
                            y: .value("Value", dataPoint.value),
                            series: .value("Symbol", symbol)
                        )
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: lineThickness))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6))
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 8)) { value in
                AxisGridLine()
                AxisTick()
                if normalizedComparison {
                    AxisValueLabel {
                        if let doubleValue = value.as(Double.self) {
                            Text("\(Int(doubleValue * 100))%")
                        }
                    }
                } else {
                    AxisValueLabel()
                }
            }
        }
    }

    private var comparisonLegend: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Legend")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                ForEach(Array(selectedComparisonSymbols).sorted(), id: \.self) { symbol in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(colorForSymbol(symbol))
                            .frame(width: 10, height: 10)
                        Text(symbol)
                            .font(.caption)
                            .foregroundColor(.primary)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }

    // MARK: - Comparison Helper Functions

    private func normalizeData(_ data: [ChartDataPoint]) -> [ChartDataPoint] {
        guard let firstValue = data.first?.value, firstValue != 0 else { return data }

        return data.map { point in
            let percentChange = ((point.value - firstValue) / firstValue)
            return ChartDataPoint(date: point.date, value: percentChange, symbol: point.symbol)
        }
    }

    private func colorForSymbol(_ symbol: String) -> Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink]
        let sortedSymbols = Array(selectedComparisonSymbols).sorted()
        guard let index = sortedSymbols.firstIndex(of: symbol) else { return .gray }
        return colors[index % colors.count]
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
    
    private var exportSection: some View {
        VStack {
            Button(action: { showingExportOptions.toggle() }) {
                HStack {
                    Text("Export Options")
                    Spacer()
                    Image(systemName: showingExportOptions ? "chevron.up" : "chevron.down")
                }
            }
            .buttonStyle(PlainButtonStyle())
            
            if showingExportOptions {
                exportOptionsView
                    .onAppear {
                        // Auto-resizing will handle layout changes
                    }
            }
        }
    }
    
    @ViewBuilder
    private var performanceMetricsView: some View {
        if let metrics = getRelevantPerformanceMetrics() {
            VStack(alignment: .leading, spacing: 12) {
                // Basic Metrics Row
                HStack(spacing: 0) {
                    VStack(alignment: .leading) {
                        Text("Total Return")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(metrics.formattedTotalReturn)
                            .font(.headline)
                            .foregroundColor(metrics.totalReturn >= 0 ? .green : .red)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    VStack(spacing: 2) {
                        Text("Return %")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                        Text(metrics.formattedTotalReturnPercent)
                            .font(.headline)
                            .foregroundColor(metrics.totalReturnPercent >= 0 ? .green : .red)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    
                    VStack(alignment: .trailing) {
                        Text("Volatility")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(metrics.formattedVolatility)
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                
                // Advanced Analytics Row 1
                HStack(spacing: 0) {
                    VStack(alignment: .leading) {
                        Text("Sharpe Ratio")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(metrics.formattedSharpeRatio)
                            .font(.subheadline)
                            .foregroundColor(getSharpeRatioColor(metrics.sharpeRatio))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    VStack(spacing: 2) {
                        Text("Max Drawdown")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                        Text(metrics.formattedMaxDrawdown)
                            .font(.subheadline)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    
                    VStack(alignment: .trailing) {
                        Text("Win Rate")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(metrics.formattedWinRate)
                            .font(.subheadline)
                            .foregroundColor(getWinRateColor(metrics.winRate))
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                
                // Advanced Analytics Row 2
                HStack(spacing: 0) {
                    VStack(alignment: .leading) {
                        Text("Ann. Return")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(metrics.formattedAnnualizedReturn)
                            .font(.subheadline)
                            .foregroundColor(getAnnualizedReturnColor(metrics.annualizedReturn))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    VStack(spacing: 2) {
                        Text("VaR (95%)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                        Text(metrics.formattedVaR)
                            .font(.subheadline)
                            .foregroundColor(.orange)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    
                    VStack(alignment: .trailing) {
                        Text("Range")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(String(format: "%.2f", metrics.minValue)) - \(String(format: "%.2f", metrics.maxValue))")
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
    }
    
    private var portfolioReturnAnalysisSection: some View {
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
    
    @ViewBuilder
    private func stockReturnAnalysisSection(for symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stock Analysis - \(symbol)")
                .font(.headline)
                .foregroundColor(.primary)
            
            if let stockTrade = dataModel?.realTimeTrades.first(where: { $0.trade.name == symbol }) {
                HStack(alignment: .top, spacing: 20) {
                    // Left: Current Price
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Current Price")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        let currentPrice = stockTrade.realTimeInfo.currentPrice
                        let currency = stockTrade.realTimeInfo.currency ?? "USD"
                        Text(formatCurrency(currentPrice, currency: currency))
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        
                        // Day change
                        let dayChange = currentPrice - stockTrade.realTimeInfo.prevClosePrice
                        let dayChangePercent = stockTrade.realTimeInfo.prevClosePrice > 0 ? 
                            (dayChange / stockTrade.realTimeInfo.prevClosePrice) * 100 : 0
                        
                        if !dayChange.isNaN && !dayChangePercent.isNaN {
                            Text("\(String(format: "%+.2f", dayChange)) (\(String(format: "%+.2f%%", dayChangePercent)))")
                                .font(.caption)
                                .foregroundColor(dayChange >= 0 ? .green : .red)
                        }
                    }
                    
                    Spacer()
                    
                    // Center: Period Return for selected time range
                    VStack(alignment: .center, spacing: 4) {
                        Text("Period Return (\(selectedTimeRange.description))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        if let metrics = historicalDataManager.getStockPerformanceMetrics(for: symbol, timeRange: selectedTimeRange) {
                            Text(formatCurrency(metrics.totalReturn, currency: metrics.currency))
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
                    
                    // Right: Your Position (if you own this stock)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Your Position")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        let currentPrice = stockTrade.realTimeInfo.currentPrice
                        let currency = stockTrade.realTimeInfo.currency ?? "USD"
                        let units = stockTrade.trade.position.unitSize
                        let avgCost = stockTrade.trade.position.getNormalizedAvgCost(for: symbol)
                        let marketValue = currentPrice * units
                        let positionGain = marketValue - (avgCost * units)
                        
                        Text("\(Int(units)) shares")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        
                        if !positionGain.isNaN {
                            Text("\(String(format: "%+.2f", positionGain)) \(currency)")
                                .font(.caption)
                                .foregroundColor(positionGain >= 0 ? .green : .red)
                        }
                    }
                }
                
                // Additional stock insights row
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Avg Cost")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        let avgCost = stockTrade.trade.position.getNormalizedAvgCost(for: symbol)
                        let currency = stockTrade.realTimeInfo.currency ?? "USD"
                        Text(formatCurrency(avgCost, currency: currency))
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .center, spacing: 2) {
                        Text("Market Value")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        let marketValue = stockTrade.realTimeInfo.currentPrice * stockTrade.trade.position.unitSize
                        let currency = stockTrade.realTimeInfo.currency ?? "USD"
                        Text(formatCurrency(marketValue, currency: currency))
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    
                    Spacer()
                    
                    if let metrics = historicalDataManager.getStockPerformanceMetrics(for: symbol, timeRange: selectedTimeRange) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Volatility")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text(metrics.formattedVolatility)
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                    }
                }
            } else {
                Text("Stock information not available")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.7))
        .cornerRadius(12)
    }
    
    private func calculateTotalPurchaseValue() -> (amount: Double, currency: String) {
        guard let model = dataModel else { return (0, "USD") }
        
        let currencyConverter = CurrencyConverter()
        var totalCostUSD = 0.0
        
        for trade in model.realTimeTrades {
            // Use normalized average cost (handles GBX to GBP conversion automatically)
            let adjustedCost = trade.trade.position.getNormalizedAvgCost(for: trade.trade.name)
            guard !adjustedCost.isNaN, adjustedCost > 0 else { 
                continue 
            }
            
            let units = trade.trade.position.unitSize
            let currency = trade.realTimeInfo.currency ?? "USD"
            
            let totalPositionCost = adjustedCost * units
            
            // Convert to USD for aggregation using actual currency converter
            var costInUSD = totalPositionCost
            if currency == "GBP" {
                costInUSD = currencyConverter.convert(amount: totalPositionCost, from: "GBP", to: "USD")
            } else if currency != "USD" {
                costInUSD = currencyConverter.convert(amount: totalPositionCost, from: currency, to: "USD")
            }
            
            totalCostUSD += costInUSD
        }
        
        // Convert to preferred currency using actual currency converter
        let preferredCurrency = model.preferredCurrency
        var finalAmount = totalCostUSD
        
        if preferredCurrency == "GBX" || preferredCurrency == "GBp" {
            let gbpAmount = currencyConverter.convert(amount: totalCostUSD, from: "USD", to: "GBP")
            finalAmount = gbpAmount * 100.0 // Convert GBP to GBX
        } else if preferredCurrency != "USD" { // Only convert if not already USD
            finalAmount = currencyConverter.convert(amount: totalCostUSD, from: "USD", to: preferredCurrency)
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
        // For individual stock charts, don't apply currency conversion - just format with the native currency
        switch selectedChartType {
        case .individualStock(_):
            // For individual stocks, always display in the stock's native currency without conversion
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = currency == "GBX" ? "GBP" : currency
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 2
            return formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f %@", amount, currency)
            
        case .portfolioValue, .portfolioGains:
            // For portfolio charts, apply currency conversion as before
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
    }
    
    private var chartColor: Color {
        switch selectedChartType {
        case .portfolioValue:
            return .blue
        case .portfolioGains:
            return displayableChartData.last?.value ?? 0 >= 0 ? .green : .red
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
        case .custom:
            return .dateTime.month(.abbreviated).day().year()
        }
    }
    
    private var valueFormat: FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(2))
    }
    
    private var currencyValueFormat: FloatingPointFormatStyle<Double>.Currency {
        // For individual stock charts, use the stock's native currency
        // For portfolio charts, use the preferred currency
        let currency: String
        switch selectedChartType {
        case .individualStock(let symbol):
            // Find the stock's native currency
            if let trade = dataModel?.realTimeTrades.first(where: { $0.trade.name == symbol }) {
                currency = trade.realTimeInfo.currency ?? "USD"
            } else {
                currency = symbol.uppercased().hasSuffix(".L") ? "GBP" : "USD"
            }
        case .portfolioValue, .portfolioGains:
            currency = dataModel?.preferredCurrency ?? "USD"
        }
        
        let currencyCode = currency == "GBX" ? "GBP" : currency
        // Always show 2 decimal places for better precision, especially for lower value stocks
        return FloatingPointFormatStyle<Double>.Currency(code: currencyCode).precision(.fractionLength(2))
    }
    
    // MARK: - Helper Functions
    
    /// Gets the appropriate performance metrics based on the selected chart type
    private func getRelevantPerformanceMetrics() -> PerformanceMetrics? {
        switch selectedChartType {
        case .portfolioValue, .portfolioGains:
            return historicalDataManager.getPerformanceMetrics(for: selectedTimeRange)
        case .individualStock(let symbol):
            return historicalDataManager.getStockPerformanceMetrics(for: symbol, timeRange: selectedTimeRange)
        }
    }
    
    /// Gets color for Sharpe ratio display
    private func getSharpeRatioColor(_ sharpeRatio: Double?) -> Color {
        guard let ratio = sharpeRatio else { return .secondary }
        if ratio > 1.0 {
            return .green
        } else if ratio > 0.5 {
            return .orange
        } else {
            return .red
        }
    }
    
    /// Gets color for win rate display
    private func getWinRateColor(_ winRate: Double?) -> Color {
        guard let rate = winRate else { return .secondary }
        if rate >= 60.0 {
            return .green
        } else if rate >= 45.0 {
            return .orange
        } else {
            return .red
        }
    }
    
    /// Gets color for annualized return display
    private func getAnnualizedReturnColor(_ annualizedReturn: Double?) -> Color {
        guard let returnValue = annualizedReturn else { return .secondary }
        if returnValue > 10.0 {
            return .green
        } else if returnValue > 0.0 {
            return .orange
        } else {
            return .red
        }
    }
    
    /// Gets change information for a data point relative to the previous point
    private func getChangeInfo(for dataPoint: ChartDataPoint) -> (absoluteChange: Double, percentChange: Double)? {
        guard let currentIndex = displayableChartData.firstIndex(where: { $0.id == dataPoint.id }),
              currentIndex > 0 else { return nil }
        
        let previousPoint = displayableChartData[currentIndex - 1]
        let absoluteChange = dataPoint.value - previousPoint.value
        let percentChange = previousPoint.value != 0 ? (absoluteChange / previousPoint.value) * 100 : 0
        
        return (absoluteChange, percentChange)
    }
    
    /// Gets position information for a data point within the dataset
    private func getPositionInfo(for dataPoint: ChartDataPoint) -> (rank: Int, total: Int, percentile: Double)? {
        let sortedByValue = displayableChartData.sorted { $0.value > $1.value }
        guard let rank = sortedByValue.firstIndex(where: { $0.id == dataPoint.id }) else { return nil }
        
        let total = sortedByValue.count
        let percentile = total > 1 ? (1.0 - Double(rank) / Double(total - 1)) * 100 : 100
        
        return (rank + 1, total, percentile)
    }
    
    /// Sets up keyboard shortcuts for chart interactions
    private func setupKeyboardShortcuts() {
        // This would be implemented with key event handling in a full implementation
        // For now, the shortcuts are handled in the EnhancedChartView
    }
    
    @ViewBuilder
    private var dataFiltersSection: some View {
        VStack {
            Button(action: { showingDataFilters.toggle() }) {
                HStack {
                    Text("Data Filters")
                    Spacer()
                    Image(systemName: showingDataFilters ? "chevron.up" : "chevron.down")
                }
            }
            .buttonStyle(PlainButtonStyle())
            
            if showingDataFilters {
                dataFiltersView
                    .onAppear {
                        // Auto-resizing will handle layout changes
                    }
            }
        }
    }
    
    @ViewBuilder
    private var dataFiltersView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Value threshold filter
            HStack {
                Text("Value Threshold:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                TextField("0.0", value: $valueThreshold, format: .number)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 80)
                
                Button("Apply") {
                    // Filter will be applied automatically through computed property
                }
                .buttonStyle(PlainButtonStyle())
                .font(.caption)
                .foregroundColor(.blue)
            }
            
            // Date range filter
            HStack {
                Toggle("Custom Date Range", isOn: $dateFilterEnabled)
                    .font(.caption)
                
                if dateFilterEnabled {
                    DatePicker("From", selection: $customStartDate, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(CompactDatePickerStyle())
                    
                    Text("to")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    DatePicker("To", selection: $customEndDate, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(CompactDatePickerStyle())
                }
            }
            
            // Selection tools
            HStack {
                Button("Select All") {
                    selectedDataPoints = Set(displayableChartData.map { $0.id })
                }
                .buttonStyle(PlainButtonStyle())
                .font(.caption)
                .foregroundColor(.blue)
                
                Button("Clear Selection") {
                    selectedDataPoints.removeAll()
                }
                .buttonStyle(PlainButtonStyle())
                .font(.caption)
                .foregroundColor(.red)
                
                if !selectedDataPoints.isEmpty {
                    Text("\(selectedDataPoints.count) selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            // Chart zoom controls
            HStack {
                Text("Zoom:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Button("-") {
                    chartScale = max(0.5, chartScale - 0.1)
                }
                .buttonStyle(PlainButtonStyle())
                .font(.caption)
                .foregroundColor(.blue)
                
                Text(String(format: "%.0f%%", chartScale * 100))
                    .font(.caption)
                    .frame(width: 40)
                
                Button("+") {
                    chartScale = min(3.0, chartScale + 0.1)
                }
                .buttonStyle(PlainButtonStyle())
                .font(.caption)
                .foregroundColor(.blue)
                
                Button("Reset") {
                    chartScale = 1.0
                    chartOffset = .zero
                }
                .buttonStyle(PlainButtonStyle())
                .font(.caption)
                .foregroundColor(.orange)
                
                Spacer()
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
    
    @ViewBuilder
    private var exportOptionsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Chart Data")
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack(spacing: 16) {
                // CSV Export Button
                Button(action: exportToCSV) {
                    HStack {
                        Image(systemName: "doc.text")
                        Text("Export CSV")
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(6)
                .foregroundColor(.blue)
                
                // PDF Export Button
                Button(action: exportToPDF) {
                    HStack {
                        Image(systemName: "doc.richtext")
                        Text("Export PDF")
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.1))
                .cornerRadius(6)
                .foregroundColor(.green)
                
                Spacer()
            }
            
            // Additional export options for portfolio data
            if case .portfolioValue = selectedChartType, !historicalDataManager.historicalPortfolioSnapshots.isEmpty {
                HStack {
                    Button(action: exportDetailedPortfolioCSV) {
                        HStack {
                            Image(systemName: "tablecells")
                            Text("Detailed Portfolio CSV")
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(6)
                    .foregroundColor(.orange)
                    
                    Spacer()
                }
            }
            
            // Export selected data only
            if !selectedDataPoints.isEmpty {
                HStack {
                    Text("Export \(selectedDataPoints.count) selected points only")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
    
    // MARK: - Export Actions
    
    private func exportToCSV() {
        let metrics = getRelevantPerformanceMetrics()
        let dataToExport = selectedDataPoints.isEmpty ? displayableChartData : 
            displayableChartData.filter { selectedDataPoints.contains($0.id) }
        
        exportManager.exportToCSV(
            chartData: dataToExport,
            chartType: selectedChartType,
            timeRange: selectedTimeRange,
            metrics: metrics
        )
    }
    
    private func exportToPDF() {
        let metrics = getRelevantPerformanceMetrics()
        let chartImage = captureChartAsImage()
        let dataToExport = selectedDataPoints.isEmpty ? displayableChartData : 
            displayableChartData.filter { selectedDataPoints.contains($0.id) }
        
        exportManager.exportToPDF(
            chartData: dataToExport,
            chartType: selectedChartType,
            timeRange: selectedTimeRange,
            metrics: metrics,
            chartImage: chartImage
        )
    }
    
    private func exportDetailedPortfolioCSV() {
        let startDate = selectedTimeRange.startDate()
        let filteredSnapshots = historicalDataManager.historicalPortfolioSnapshots
            .filter { $0.date >= startDate }
            .sorted { $0.date < $1.date }
        
        exportManager.exportPortfolioSnapshotsToCSV(
            snapshots: filteredSnapshots,
            timeRange: selectedTimeRange
        )
    }
    
    private func captureChartAsImage() -> NSImage? {
        // For now, return nil - in a full implementation, we would capture the chart view
        // This would require rendering the chart to an image context
        return nil
    }
    
    private func getDisplayCurrency() -> String {
        switch selectedChartType {
        case .individualStock(let symbol):
            if let trade = dataModel?.realTimeTrades.first(where: { $0.trade.name == symbol }) {
                return trade.realTimeInfo.currency ?? "USD"
            } else {
                return symbol.uppercased().hasSuffix(".L") ? "GBP" : "USD"
            }
        case .portfolioValue, .portfolioGains:
            return dataModel?.preferredCurrency ?? "USD"
        }
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
                
                // Use the same currency logic as the chart axis
                Text(formatCurrency(dataPoint.value, currency: getDisplayCurrency()))
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
    
}

// MARK: - Enhanced Chart Interaction View

struct EnhancedChartInteractionView: NSViewRepresentable {
    let chartData: [ChartDataPoint]
    @Binding var selectedDataPoints: Set<UUID>
    @Binding var hoveredDataPoint: ChartDataPoint?
    @Binding var chartScale: Double
    @Binding var chartOffset: CGSize
    let geometry: GeometryProxy
    let chartProxy: ChartProxy
    let selectedTimeRange: ChartTimeRange
    
    func makeNSView(context: Context) -> NSView {
        let view = EnhancedChartView()
        view.setup(
            chartData: chartData,
            selectedDataPoints: selectedDataPoints,
            hoveredDataPoint: hoveredDataPoint,
            chartScale: chartScale,
            chartOffset: chartOffset,
            geometry: geometry,
            chartProxy: chartProxy,
            selectedTimeRange: selectedTimeRange
        )
        view.onSelectionChanged = { newSelection in
            selectedDataPoints = newSelection
        }
        view.onHoverChanged = { newHover in
            hoveredDataPoint = newHover
        }
        view.onScaleChanged = { newScale in
            chartScale = newScale
        }
        view.onOffsetChanged = { newOffset in
            chartOffset = newOffset
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        if let chartView = nsView as? EnhancedChartView {
            chartView.updateData(
                chartData: chartData,
                selectedDataPoints: selectedDataPoints,
                hoveredDataPoint: hoveredDataPoint,
                chartScale: chartScale,
                chartOffset: chartOffset
            )
        }
    }
}

class EnhancedChartView: NSView {
    var onSelectionChanged: ((Set<UUID>) -> Void)?
    var onHoverChanged: ((ChartDataPoint?) -> Void)?
    var onScaleChanged: ((Double) -> Void)?
    var onOffsetChanged: ((CGSize) -> Void)?
    
    private var trackingArea: NSTrackingArea?
    private var chartData: [ChartDataPoint] = []
    private var selectedDataPoints: Set<UUID> = []
    private var hoveredDataPoint: ChartDataPoint?
    private var chartScale: Double = 1.0
    private var chartOffset: CGSize = .zero
    private var geometry: GeometryProxy?
    private var chartProxy: ChartProxy?
    private var selectedTimeRange: ChartTimeRange = .month
    
    private var isSelecting = false
    private var selectionStartPoint: CGPoint = .zero
    private var selectionEndPoint: CGPoint = .zero
    
    func setup(
        chartData: [ChartDataPoint],
        selectedDataPoints: Set<UUID>,
        hoveredDataPoint: ChartDataPoint?,
        chartScale: Double,
        chartOffset: CGSize,
        geometry: GeometryProxy,
        chartProxy: ChartProxy,
        selectedTimeRange: ChartTimeRange
    ) {
        self.chartData = chartData
        self.selectedDataPoints = selectedDataPoints
        self.hoveredDataPoint = hoveredDataPoint
        self.chartScale = chartScale
        self.chartOffset = chartOffset
        self.geometry = geometry
        self.chartProxy = chartProxy
        self.selectedTimeRange = selectedTimeRange
    }
    
    func updateData(
        chartData: [ChartDataPoint],
        selectedDataPoints: Set<UUID>,
        hoveredDataPoint: ChartDataPoint?,
        chartScale: Double,
        chartOffset: CGSize
    ) {
        self.chartData = chartData
        self.selectedDataPoints = selectedDataPoints
        self.hoveredDataPoint = hoveredDataPoint
        self.chartScale = chartScale
        self.chartOffset = chartOffset
    }
    
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
        guard let geometry = geometry, let chartProxy = chartProxy else { return }
        
        let location = convert(event.locationInWindow, from: nil)
        updateHoveredDataPoint(at: location, in: geometry, chartProxy: chartProxy)
    }
    
    override func mouseEntered(with event: NSEvent) {
        guard let geometry = geometry, let chartProxy = chartProxy else { return }
        
        let location = convert(event.locationInWindow, from: nil)
        updateHoveredDataPoint(at: location, in: geometry, chartProxy: chartProxy)
    }
    
    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(nil)
    }
    
    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        
        if event.modifierFlags.contains(.command) {
            // Multi-selection mode
            if let clickedPoint = findDataPointAt(location: location) {
                var newSelection = selectedDataPoints
                if newSelection.contains(clickedPoint.id) {
                    newSelection.remove(clickedPoint.id)
                } else {
                    newSelection.insert(clickedPoint.id)
                }
                onSelectionChanged?(newSelection)
            }
        } else if event.modifierFlags.contains(.shift) {
            // Range selection mode
            if let clickedPoint = findDataPointAt(location: location),
               let lastSelected = chartData.first(where: { selectedDataPoints.contains($0.id) }) {
                let rangeSelection = selectDataPointsInRange(from: lastSelected, to: clickedPoint)
                onSelectionChanged?(rangeSelection)
            }
        } else {
            // Start selection rectangle
            isSelecting = true
            selectionStartPoint = location
            selectionEndPoint = location
        }
    }
    
    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        
        if isSelecting {
            selectionEndPoint = location
            needsDisplay = true
            
            // Select points within rectangle
            let selectionRect = CGRect(
                x: min(selectionStartPoint.x, selectionEndPoint.x),
                y: min(selectionStartPoint.y, selectionEndPoint.y),
                width: abs(selectionEndPoint.x - selectionStartPoint.x),
                height: abs(selectionEndPoint.y - selectionStartPoint.y)
            )
            
            let pointsInRect = findDataPointsInRect(selectionRect)
            onSelectionChanged?(Set(pointsInRect.map { $0.id }))
        } else {
            // Pan the chart
            let deltaX = location.x - selectionStartPoint.x
            let deltaY = location.y - selectionStartPoint.y
            let newOffset = CGSize(
                width: chartOffset.width + deltaX,
                height: chartOffset.height + deltaY
            )
            onOffsetChanged?(newOffset)
            selectionStartPoint = location
        }
    }
    
    override func mouseUp(with event: NSEvent) {
        isSelecting = false
        needsDisplay = true
    }
    
    override func scrollWheel(with event: NSEvent) {
        // Zoom with scroll wheel
        let zoomFactor = 1.0 + (event.deltaY * 0.01)
        let newScale = max(0.5, min(3.0, chartScale * zoomFactor))
        onScaleChanged?(newScale)
    }
    
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape key
            onSelectionChanged?(Set())
        case 0: // A key
            if event.modifierFlags.contains(.command) {
                onSelectionChanged?(Set(chartData.map { $0.id }))
            }
        default:
            super.keyDown(with: event)
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        if isSelecting {
            let selectionRect = CGRect(
                x: min(selectionStartPoint.x, selectionEndPoint.x),
                y: min(selectionStartPoint.y, selectionEndPoint.y),
                width: abs(selectionEndPoint.x - selectionStartPoint.x),
                height: abs(selectionEndPoint.y - selectionStartPoint.y)
            )
            
            NSColor.blue.withAlphaComponent(0.2).setFill()
            NSBezierPath(rect: selectionRect).fill()
            
            NSColor.blue.withAlphaComponent(0.8).setStroke()
            NSBezierPath(rect: selectionRect).stroke()
        }
    }
    
    override var acceptsFirstResponder: Bool {
        return true
    }
    
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
    
    // MARK: - Helper Methods
    
    private func updateHoveredDataPoint(at location: CGPoint, in geometry: GeometryProxy, chartProxy: ChartProxy) {
        guard let date: Date = chartProxy.value(atX: location.x) else { return }
        
        let closestDataPoint = chartData.min { dataPoint1, dataPoint2 in
            abs(dataPoint1.date.timeIntervalSince(date)) < abs(dataPoint2.date.timeIntervalSince(date))
        }
        
        if let closest = closestDataPoint {
            let timeDifference = abs(closest.date.timeIntervalSince(date))
            let tolerance: TimeInterval = {
                switch selectedTimeRange {
                case .day: return 3600
                case .week: return 21600
                case .month: return 86400
                case .threeMonths: return 259200
                case .sixMonths: return 604800
                case .year, .all: return 1209600
                case .custom: return 86400  // Default to day tolerance for custom range
                }
            }()
            
            if timeDifference <= tolerance {
                onHoverChanged?(closest)
            } else {
                onHoverChanged?(nil)
            }
        }
    }
    
    private func findDataPointAt(location: CGPoint) -> ChartDataPoint? {
        guard let _ = geometry, let chartProxy = chartProxy else { return nil }
        guard let date: Date = chartProxy.value(atX: location.x) else { return nil }
        
        return chartData.min { dataPoint1, dataPoint2 in
            abs(dataPoint1.date.timeIntervalSince(date)) < abs(dataPoint2.date.timeIntervalSince(date))
        }
    }
    
    private func findDataPointsInRect(_ rect: CGRect) -> [ChartDataPoint] {
        guard let _ = geometry, let chartProxy = chartProxy else { return [] }
        
        return chartData.filter { dataPoint in
            guard let x: CGFloat = chartProxy.position(forX: dataPoint.date),
                  let y: CGFloat = chartProxy.position(forY: dataPoint.value) else {
                return false
            }
            return rect.contains(CGPoint(x: x, y: y))
        }
    }
    
    private func selectDataPointsInRange(from start: ChartDataPoint, to end: ChartDataPoint) -> Set<UUID> {
        let sortedData = chartData.sorted { $0.date < $1.date }
        guard let startIndex = sortedData.firstIndex(where: { $0.id == start.id }),
              let endIndex = sortedData.firstIndex(where: { $0.id == end.id }) else {
            return selectedDataPoints
        }
        
        let range = min(startIndex, endIndex)...max(startIndex, endIndex)
        let rangePoints = Array(sortedData[range])
        
        var newSelection = selectedDataPoints
        for point in rangePoints {
            newSelection.insert(point.id)
        }
        
        return newSelection
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
