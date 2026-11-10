import AppKit
import Charts
import SwiftUI

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
    private let historicalDataManager = HistoricalDataManager.shared
    private let calculationManager = BackgroundCalculationManager.shared
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
    @State private var chartRequestGeneration = 0
    @State private var displayableChartData: [ChartDataPoint] = []
    /// Filtered but not downsampled; exports use this so they are never silently thinned.
    @State private var fullResolutionChartData: [ChartDataPoint] = []
    /// Day-only sources (Folync daily history) are stamped at UTC midnight and shown in UTC.
    @State private var seriesIsDayGranular = false
    @State private var isLoadingData = false
    @State private var silentReloadTask: Task<Void, Never>?
    /// Period metrics for the series on screen. Kept outside observed state so
    /// a hover, which redraws the view, does not recompute them.
    @State private var metricsCache = PeriodMetricsCache()

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
    @State private var ohlcSourceStatus: FolyncSupplementalSourceStatus?
    @State private var ohlcCoverageLabel: String?
    @State private var ohlcRequestGeneration: Int = 0

    // Interaction features (v2.3.1)
    @StateObject private var interactionManager = ChartInteractionManager()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let availableSymbols: [String]
    let dataModel: DataModel?
    private let exportManager = ExportManager.shared
    private let ohlcFetchService = OHLCFetchService.shared
    
    init(availableSymbols: [String] = [], dataModel: DataModel? = nil) {
        // The same ticker held twice would give two picker rows one identity.
        var seen = Set<String>()
        self.availableSymbols = availableSymbols.filter { seen.insert($0).inserted }
        self.dataModel = dataModel

        // Reopen on the chart, period and style last used.
        let saved = ChartViewSelection.load()
        let chartType = saved.chartType(among: self.availableSymbols)
        _selectedChartType = State(initialValue: chartType)
        _selectedTimeRange = State(initialValue: saved.timeRange)
        if case .individualStock = chartType {
            _chartVisualizationStyle = State(initialValue: saved.style)
        }
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
                if isFolyncPortfolioChart {
                    Text("Folync valuation history. Return and risk metrics are unavailable here; local snapshot metrics do not apply to this series.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    metricsSection
                }
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
                    if !isFolyncPortfolioChart { portfolioReturnAnalysisSection }
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
        // One load per input change: the task restarts (cancelling the previous load) whenever the
        // range, chart type or an applied filter changes.
        .task(id: loadKey) {
            await reloadAllSeries(showsLoading: true)
        }
        .onChange(of: selectedChartType) { _, newType in
            // The previous series must not linger under the new title, and stock-only modes
            // must not carry over to portfolio charts.
            displayableChartData = []
            fullResolutionChartData = []
            selectedDataPoints = []
            hoveredDataPoint = nil
            // Candles belong to one symbol; drop them so they never show under another title.
            resetOHLCState()
            defer { saveSelection() }
            if case .individualStock = newType { return }
            comparisonMode = false
            chartVisualizationStyle = .line
        }
        .onChange(of: selectedTimeRange) { _, _ in
            resetOHLCState()
            saveSelection()
        }
        .onChange(of: chartVisualizationStyle) { _, _ in
            saveSelection()
            // The candlestick view's own reload hooks only exist once it is on screen, so
            // switching to it must start the first load.
            guard isCandlestickActive, ohlcData.isEmpty else { return }
            Task { await loadOHLCData() }
        }
        .onReceive(historicalDataManager.priceDataChanges) { changed in
            // Reload quietly, and only when a shown or compared symbol changed: the chart
            // stays visible and is only replaced when the loaded series actually differs.
            guard case .individualStock(let symbol) = selectedChartType else { return }
            let shown = [symbol] + (isComparisonActive ? selectedComparisonSymbols.sorted() : [])
            guard historicalDataManager.priceDataChange(changed, affects: shown) else { return }
            scheduleSilentReload()
        }
        .onChange(of: historicalDataManager.historicalPortfolioSnapshots.last?.date) { _, _ in
            guard isLocalPortfolioChart else { return }
            scheduleSilentReload()
        }
        .onChange(of: historicalDataManager.portfolioSnapshots.last?.timestamp) { _, _ in
            guard isLocalPortfolioChart else { return }
            scheduleSilentReload()
        }
        .onChange(of: historicalDataManager.portfolioHistoryRevision) { _, _ in
            guard isFolyncPortfolioChart else { return }
            scheduleSilentReload()
        }
        .onChange(of: historicalDataManager.folyncSupplementalConfigurationRevision) { _, _ in
            Task { await loadChartData() }
            ohlcRequestGeneration &+= 1
            ohlcData = []
            ohlcSourceStatus = nil
            ohlcCoverageLabel = nil
            isLoadingOHLC = false
            if isCandlestickActive {
                Task { await loadOHLCData() }
            }
        }
        .onAppear {
            // Initialize chart interactions
            setupKeyboardShortcuts()
        }
        .onDisappear {
            silentReloadTask?.cancel()
            silentReloadTask = nil
        }
    }

    private func saveSelection() {
        ChartViewSelection(
            chartType: selectedChartType, timeRange: selectedTimeRange, style: chartVisualizationStyle
        ).save()
    }

    private struct ChartLoadKey: Hashable {
        let timeRange: ChartTimeRange
        let chartType: ChartType
        let valueThreshold: Double
        let dateFilterEnabled: Bool
        let filterFrom: Date?
        let filterToExclusive: Date?
    }

    /// Everything that changes which points the chart shows.
    private var loadKey: ChartLoadKey {
        let usesDates = selectedTimeRange == .custom || dateFilterEnabled
        let range = customQueryRange
        return ChartLoadKey(
            timeRange: selectedTimeRange,
            chartType: selectedChartType,
            valueThreshold: valueThreshold,
            dateFilterEnabled: dateFilterEnabled,
            filterFrom: usesDates ? range.from : nil,
            filterToExclusive: usesDates ? range.toExclusive : nil
        )
    }

    /// Custom dates cover whole days: start of the first day up to the start of the day after the last.
    private var customQueryRange: (from: Date, toExclusive: Date) {
        ChartSeriesProcessing.normalizedCustomRange(start: customStartDate, end: customEndDate)
    }

    private var queryCustomFrom: Date? { selectedTimeRange == .custom ? customQueryRange.from : nil }
    private var queryCustomTo: Date? { selectedTimeRange == .custom ? customQueryRange.toExclusive : nil }

    private var isComparisonActive: Bool {
        guard case .individualStock = selectedChartType else { return false }
        return comparisonMode
    }

    private var isCandlestickActive: Bool {
        guard case .individualStock = selectedChartType else { return false }
        return chartVisualizationStyle == .candlestick
    }

    private var isLocalPortfolioChart: Bool {
        switch selectedChartType {
        case .portfolioValue, .portfolioGains: return !isFolyncPortfolioChart
        case .individualStock: return false
        }
    }

    private func reloadAllSeries(showsLoading: Bool) async {
        await loadChartData(showsLoading: showsLoading)
        guard isComparisonActive else { return }
        for symbol in selectedComparisonSymbols.sorted() {
            guard !Task.isCancelled else { return }
            await loadComparisonData(for: symbol)
        }
    }

    /// Coalesces bursts of data-change notifications (one per updated symbol) into one quiet reload.
    private func scheduleSilentReload() {
        silentReloadTask?.cancel()
        silentReloadTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await reloadAllSeries(showsLoading: false)
        }
    }
    
    private func adjustChartWindowSize(expanded: Bool) {
        // Notify the parent PreferenceView to handle window resizing
        // Auto-resizing will handle window sizing automatically
    }
    
    private var chartTypePicker: some View {
        HStack {
            Picker("Chart", selection: $selectedChartType) {
                Text("Portfolio Value").tag(ChartType.portfolioValue)
                Text("Portfolio Gains").tag(ChartType.portfolioGains)
                ForEach(availableSymbols, id: \.self) { symbol in
                    Text(symbol).tag(ChartType.individualStock(symbol))
                }
            }
            .frame(maxWidth: 340)
            Spacer()
        }
    }

    private func chartTypeChip(for type: ChartType, label: String) -> some View {
        let isSelected = type == selectedChartType

        return Button {
            withAnimation(StockbarMotion.animation(.easeInOut(duration: 0.15), reduceMotion: reduceMotion)) {
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
                            refreshCustomRangeIfNeeded()
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
                            refreshCustomRangeIfNeeded()
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
                        } else if case .individualStock(let symbol) = selectedChartType,
                                  availableSymbols.contains(symbol) {
                            // The stock on screen is the one being compared against.
                            selectedComparisonSymbols.insert(symbol)
                            Task { await loadComparisonData(for: symbol) }
                        }
                    }

                Spacer()

                if comparisonMode {
                    Toggle("Normalized (%)", isOn: Binding(
                        get: { usesNormalizedComparison },
                        set: { normalizedComparison = $0 }
                    ))
                        .toggleStyle(SwitchToggleStyle())
                        .disabled(comparisonMixesCurrencies)
                        .help(comparisonMixesCurrencies
                            ? "These stocks trade in different currencies, so only percentage change can be compared"
                            : "Show as percentage change from the first date all selected stocks have")
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
        .accessibilityLabel("Compare \(symbol)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(canSelect ? "" : "Up to 5 stocks can be compared")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
                .labelsHidden()
                .frame(width: 180)
            }

            Menu("Chart options") {
                Toggle("Grid lines", isOn: $showGridLines)
                Toggle("Gradient fill", isOn: $useGradientFill)
                    .disabled(chartVisualizationStyle != .line)
                Picker("Line width", selection: $lineThickness) {
                    ForEach([1.0, 1.5, 2.0, 2.5, 3.0], id: \.self) { width in
                        Text("\(width, specifier: "%.1f") pt").tag(width)
                    }
                }.disabled(chartVisualizationStyle != .line)
            }.fixedSize()

            Spacer()
            if let status = selectedSeriesSourceStatus {
                Label(status.label, systemImage: sourceIcon(status))
                    .font(.caption)
                    .foregroundStyle(status == .unavailable ? .red : .secondary)
            }
            if let coverage = selectedSeriesCoverage {
                Text(coverage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }

    // MARK: - Comparison Data Loading

    private func loadComparisonData(for symbol: String) async {
        let data = historicalDataManager.getChartData(
            for: .individualStock(symbol),
            timeRange: selectedTimeRange,
            dataModel: dataModel,
            customFrom: queryCustomFrom,
            customTo: queryCustomTo
        )

        guard !Task.isCancelled, selectedComparisonSymbols.contains(symbol) else { return }
        if let existing = comparisonChartData[symbol], ChartSeriesProcessing.isSameSeries(existing, data) { return }
        comparisonChartData[symbol] = data
        await Logger.shared.debug("📊 Loaded \(data.count) data points for comparison symbol: \(symbol)")
    }

    /// Loads the selected series. `showsLoading` is false for background refreshes, which keep the
    /// current chart on screen and only replace it when the loaded series really differs.
    private func loadChartData(showsLoading: Bool = true) async {
        chartRequestGeneration &+= 1
        let generation = chartRequestGeneration
        if showsLoading { isLoadingData = true }

        let data = historicalDataManager.getChartData(
            for: selectedChartType,
            timeRange: selectedTimeRange,
            dataModel: dataModel,
            customFrom: queryCustomFrom,
            customTo: queryCustomTo
        )

        // Filtering and downsampling run off the main actor.
        let processed = await processChartData(data)

        let chartTypeTitle = selectedChartType.title
        let timeRangeLabel = selectedTimeRange.rawValue
        guard !Task.isCancelled, generation == chartRequestGeneration else { return }
        if showsLoading || !ChartSeriesProcessing.isSameSeries(processed.display, displayableChartData) {
            let previous = displayableChartData
            displayableChartData = processed.display
            fullResolutionChartData = processed.full
            seriesIsDayGranular = ChartSeriesProcessing.isDayGranular(processed.full)
            // Point ids change on every load; carry the selection over by date.
            selectedDataPoints = ChartSeriesProcessing.remapSelection(
                selected: selectedDataPoints,
                oldData: previous,
                newData: processed.display
            )
            hoveredDataPoint = nil
        }
        isLoadingData = false
        await Logger.shared.debug("📊 Loaded \(processed.display.count) chart data points for \(chartTypeTitle) (\(timeRangeLabel))")
    }

    private func loadOHLCData() async {
        ohlcRequestGeneration &+= 1
        let requestGeneration = ohlcRequestGeneration
        let configurationRevision = historicalDataManager.folyncSupplementalConfigurationRevision
        guard case .individualStock(let symbol) = selectedChartType else {
            ohlcData = []
            ohlcSourceStatus = nil
            ohlcCoverageLabel = nil
            isLoadingOHLC = false
            return
        }

        isLoadingOHLC = true

        do {
            // Map time range to yfinance period
            let period = selectedTimeRange.yfinancePeriod
            let interval = selectedTimeRange.suggestedInterval

            let useFolyncRoute = FolyncSettingsStore.shared.load().isSupplementalRouteActive(.candlestickCharts)
            // A custom range has no fixed period to validate the cache against, so it always refetches.
            if !useFolyncRoute, selectedTimeRange != .custom {
                // Existing local OHLC remains untouched and is used whenever the Folync route is off.
                let cachedData = try await ohlcFetchService.getCachedOHLCData(
                    symbol: symbol,
                    period: period,
                    interval: interval
                )

                if !cachedData.isEmpty {
                    await MainActor.run {
                        guard requestGeneration == ohlcRequestGeneration,
                              configurationRevision == historicalDataManager.folyncSupplementalConfigurationRevision else { return }
                        ohlcData = ChartSeriesProcessing.aggregatedCandles(cachedData)
                        ohlcSourceStatus = .legacy
                        ohlcCoverageLabel = "\(cachedData.count) points · \(interval) · local cache"
                        isLoadingOHLC = false
                    }
                    await Logger.shared.info("Loaded \(cachedData.count) cached OHLC data points for \(symbol)")
                    return
                }
            }

            // Fetch fresh data from yfinance
            let result = try await ohlcFetchService.fetchOHLCDataWithSource(
                symbol: symbol,
                period: period,
                interval: interval,
                from: queryCustomFrom,
                to: queryCustomTo
            )

            // Convert to OHLCDataPoint
            let dataPoints = result.snapshots.map { snapshot in
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
                guard requestGeneration == ohlcRequestGeneration,
                      configurationRevision == historicalDataManager.folyncSupplementalConfigurationRevision else { return }
                ohlcData = ChartSeriesProcessing.aggregatedCandles(dataPoints)
                ohlcSourceStatus = result.sourceStatus
                ohlcCoverageLabel = result.coverageLabel
                isLoadingOHLC = false
            }

            await Logger.shared.info("Loaded \(dataPoints.count) OHLC data points for \(symbol)")
        } catch {
            // Offline or provider failure: older local candles beat an empty chart.
            let staleData: [OHLCDataPoint]
            if !FolyncSettingsStore.shared.load().isSupplementalRouteActive(.candlestickCharts),
               selectedTimeRange != .custom {
                staleData = (try? await ohlcFetchService.getCachedOHLCData(
                    symbol: symbol,
                    period: selectedTimeRange.yfinancePeriod,
                    interval: selectedTimeRange.suggestedInterval,
                    allowStale: true
                )) ?? []
            } else {
                staleData = []
            }
            await MainActor.run {
                guard requestGeneration == ohlcRequestGeneration,
                      configurationRevision == historicalDataManager.folyncSupplementalConfigurationRevision else { return }
                isLoadingOHLC = false
                if !staleData.isEmpty {
                    ohlcData = ChartSeriesProcessing.aggregatedCandles(staleData)
                    ohlcSourceStatus = .legacy
                    ohlcCoverageLabel = "\(staleData.count) points · \(selectedTimeRange.suggestedInterval) · stale local cache"
                    return
                }
                ohlcData = []
                if FolyncSettingsStore.shared.load().isSupplementalRouteActive(.candlestickCharts) {
                    ohlcSourceStatus = .unavailable
                    ohlcCoverageLabel = nil
                }
            }
            if error is CancellationError {
                await Logger.shared.debug("OHLC load cancelled for \(symbol)")
            } else {
                await Logger.shared.warning("Failed to load OHLC data for \(symbol): \(error)")
            }
        }
    }

    /// Discards loaded candles and invalidates any load still in flight.
    private func resetOHLCState() {
        ohlcRequestGeneration &+= 1
        ohlcData = []
        ohlcSourceStatus = nil
        ohlcCoverageLabel = nil
        isLoadingOHLC = false
    }

    /// Line and comparison series reload through the load task; candles need an explicit reload.
    private func refreshCustomRangeIfNeeded() {
        guard selectedTimeRange == .custom, isCandlestickActive else { return }
        Task { await loadOHLCData() }
    }

    private var selectedSeriesSourceStatus: FolyncSupplementalSourceStatus? {
        if isCandlestickActive {
            return ohlcSourceStatus
        }
        switch selectedChartType {
        case .individualStock(let symbol):
            return historicalDataManager.folyncSourceStatus(
                for: symbol,
                timeRange: selectedTimeRange,
                customFrom: queryCustomFrom,
                customTo: queryCustomTo
            )
        case .portfolioValue:
            return historicalDataManager.folyncPortfolioSourceStatus(
                kind: "portfolio-value",
                timeRange: selectedTimeRange,
                customFrom: queryCustomFrom,
                customTo: queryCustomTo
            )
        case .portfolioGains:
            return historicalDataManager.folyncPortfolioSourceStatus(
                kind: "portfolio-gain",
                timeRange: selectedTimeRange,
                customFrom: queryCustomFrom,
                customTo: queryCustomTo
            )
        }
    }

    private var selectedSeriesCoverage: String? {
        if isCandlestickActive {
            return ohlcCoverageLabel
        }
        switch selectedChartType {
        case .individualStock(let symbol):
            return historicalDataManager.folyncCoverage(
                for: symbol,
                timeRange: selectedTimeRange,
                customFrom: queryCustomFrom,
                customTo: queryCustomTo
            )
        case .portfolioValue:
            return historicalDataManager.folyncPortfolioCoverage(
                kind: "portfolio-value",
                timeRange: selectedTimeRange,
                customFrom: queryCustomFrom,
                customTo: queryCustomTo
            )
        case .portfolioGains:
            return historicalDataManager.folyncPortfolioCoverage(
                kind: "portfolio-gain",
                timeRange: selectedTimeRange,
                customFrom: queryCustomFrom,
                customTo: queryCustomTo
            )
        }
    }

    private func sourceIcon(_ status: FolyncSupplementalSourceStatus) -> String {
        switch status {
        case .current: "checkmark.circle"
        case .partial: "circle.lefthalf.filled"
        case .stale: "clock.badge.exclamationmark"
        case .unavailable: "exclamationmark.triangle"
        case .legacy: "internaldrive"
        }
    }

    /// Applies the filters, then downsamples for display. `full` keeps every filtered point for export.
    private func processChartData(_ data: [ChartDataPoint]) async -> (full: [ChartDataPoint], display: [ChartDataPoint]) {
        let threshold = valueThreshold
        let window: (from: Date, toExclusive: Date)? =
            (selectedTimeRange == .custom || dateFilterEnabled) ? customQueryRange : nil

        let result = await Task.detached {
            let full = ChartSeriesProcessing.applyFilters(data, valueThreshold: threshold, dateWindow: window)
            return (full: full, display: ChartSeriesProcessing.downsample(full))
        }.value
        if result.display.count < result.full.count {
            await Logger.shared.debug("📊 Downsampled chart data from \(result.full.count) to \(result.display.count) points for performance")
        }
        return result
    }

    private var yAxisDomain: ClosedRange<Double> {
        guard let visible = visibleXDomain else {
            return ChartSeriesProcessing.paddedDomain(displayableChartData.map(\.value))
        }
        let shown = displayableChartData.filter { visible.contains($0.date) }.map(\.value)
        return ChartSeriesProcessing.paddedDomain(shown.isEmpty ? displayableChartData.map(\.value) : shown)
    }

    /// The dates on screen when zoomed in, or nil at normal size.
    private var visibleXDomain: ClosedRange<Date>? {
        guard let first = displayableChartData.first?.date, let last = displayableChartData.last?.date else {
            return nil
        }
        return ChartSeriesProcessing.zoomedDomain(
            first: first, last: last, scale: chartScale, panFraction: Double(chartOffset.width)
        )
    }
    
    private var chartView: some View {
        Group {
            if isCandlestickActive && !(isComparisonActive && !selectedComparisonSymbols.isEmpty) {
                // OHLC has its own loading and empty states, independent of line history.
                candlestickChartPlaceholder
            } else if isLoadingData && displayableChartData.isEmpty {
                ProgressView("Loading chart data...")
                    .frame(height: 300)
            } else if displayableChartData.isEmpty {
                emptyChartView
            } else if isComparisonActive && !selectedComparisonSymbols.isEmpty {
                // COMPARISON MODE: Multi-series chart
                comparisonChartContent
            } else {
                // SINGLE SERIES: Standard line chart
                let domain = yAxisDomain
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
                                yStart: .value("Baseline", domain.lowerBound),
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
                                yStart: .value("Baseline", domain.lowerBound),
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
                        // Drawn once, wherever the range crosses zero; it used to
                        // appear only when a point was exactly zero.
                        if case .portfolioGains = selectedChartType,
                           dataPoint.id == displayableChartData.first?.id,
                           domain.contains(0) {
                            RuleMark(y: .value("Zero", 0))
                                .foregroundStyle(Color.secondary.opacity(0.5))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                            if showGridLines {
                                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                            }
                            AxisTick()
                            AxisValueLabel(format: dateFormat)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                            if showGridLines {
                                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                            }
                            AxisTick()
                            AxisValueLabel(format: currencyValueFormat)
                        }
                    }
                    .chartYScale(domain: domain)
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
                                        chartProxy: chartProxy,
                                        plotOrigin: chartProxy.plotFrame.map { geometry[$0].origin } ?? .zero,
                                        selectedTimeRange: selectedTimeRange
                                    )
                                )
                        }
                    }
                    .accessibilityLabel("\(selectedChartType.title), \(selectedTimeRange.description)")
                    .accessibilityValue(chartAccessibilitySummary)
                    // Zooming narrows the dates shown and redraws at full
                    // sharpness; it used to magnify a clipped picture of the chart.
                    .chartXDomain(visibleXDomain)
                    .chartPlotStyle { $0.clipped() }
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
        .overlay(alignment: .topTrailing) {
            if isLoadingData && !displayableChartData.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .accessibilityLabel("Refreshing chart")
            }
        }
    }

    /// Spoken summary of the plotted series; the chart itself is a graphic.
    private var chartAccessibilitySummary: String {
        guard let first = displayableChartData.first, let last = displayableChartData.last else { return "No data" }
        let values = displayableChartData.map(\.value)
        let low = values.filter(\.isFinite).min() ?? first.value
        let high = values.filter(\.isFinite).max() ?? last.value
        let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(2))
        return "\(displayableChartData.count) points. Latest \(last.value.formatted(style)). Low \(low.formatted(style)), high \(high.formatted(style))."
    }
    
    private var emptyChartView: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
                .accessibilityHidden(true)

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

                    Text("No candlestick data is available for this selection.")
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
                    settings: candlestickSettings,
                    symbol: {
                        if case .individualStock(let symbol) = selectedChartType {
                            return symbol
                        }
                        return nil
                    }()
                )
                .frame(height: 400)
            }
        }
        .onChange(of: selectedChartType) {
            if isCandlestickActive {
                Task {
                    await loadOHLCData()
                }
            }
        }
        .onChange(of: selectedTimeRange) {
            if isCandlestickActive {
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
        let normalized = usesNormalizedComparison
        let selected = comparisonChartData.filter { selectedComparisonSymbols.contains($0.key) }
        let series = normalized ? ChartSeriesProcessing.rebasedToCommonStart(selected) : selected

        return Chart {
            ForEach(sortedSymbols, id: \.self) { symbol in
                if let processedData = series[symbol] {
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
        .accessibilityLabel("Comparison of \(sortedSymbols.joined(separator: ", ")), \(selectedTimeRange.description)")
        .accessibilityValue(normalized ? "Normalised to percentage change" : "Absolute prices")
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6))
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 8)) { value in
                AxisGridLine()
                AxisTick()
                if normalized {
                    AxisValueLabel {
                        if let doubleValue = value.as(Double.self) {
                            Text(doubleValue.formatted(.percent.precision(.fractionLength(0))))
                        }
                    }
                } else {
                    AxisValueLabel()
                }
            }
        }
    }

    private var comparisonLegend: some View {
        // Read once for the legend, not once per entry.
        let lineRouteActive = FolyncSettingsStore.shared.load().isSupplementalRouteActive(.historicalLineCharts)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Legend")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                ForEach(Array(selectedComparisonSymbols).sorted(), id: \.self) { symbol in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(colorForSymbol(symbol))
                            .frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(symbol)
                                .font(.caption)
                                .foregroundColor(.primary)
                            if let status = comparisonSourceStatus(for: symbol, lineRouteActive: lineRouteActive) {
                                Text(status.label)
                                    .font(.caption2)
                                    .foregroundStyle(status == .unavailable ? .red : .secondary)
                            } else {
                                Text("Folync · loading")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if let coverage = historicalDataManager.folyncCoverage(
                                for: symbol,
                                timeRange: selectedTimeRange,
                                customFrom: queryCustomFrom,
                                customTo: queryCustomTo
                            ) {
                                Text(coverage)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }

    // MARK: - Comparison Helper Functions

    private func comparisonSourceStatus(for symbol: String, lineRouteActive: Bool) -> FolyncSupplementalSourceStatus? {
        if let status = historicalDataManager.folyncSourceStatus(
            for: symbol,
            timeRange: selectedTimeRange,
            customFrom: queryCustomFrom,
            customTo: queryCustomTo
        ) {
            return status
        }
        guard lineRouteActive,
              dataModel?.folyncCapabilities?.isTrackedOrAllowlisted(symbol) == true else {
            return .legacy
        }
        return nil
    }

    /// Prices in different currencies cannot share one axis.
    private var comparisonMixesCurrencies: Bool {
        Set(selectedComparisonSymbols.map { symbol in
            dataModel?.realTimeTrades.first { $0.trade.name == symbol }?.realTimeInfo.currency
                ?? SymbolMetadata.defaultCurrency(for: symbol)
        }).count > 1
    }

    private var usesNormalizedComparison: Bool { normalizedComparison || comparisonMixesCurrencies }


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
                    
                    if let metrics = portfolioPerformanceMetrics {
                        Text(metrics.formattedTotalReturn)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(metrics.totalReturn >= 0 ? .green : .red)
                        
                        Text(metrics.formattedTotalReturnPercent)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Not enough history")
                            .font(.title3)
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
                        
                        if let metrics = stockPerformanceMetrics(for: symbol) {
                            Text(formatCurrency(metrics.totalReturn, currency: metrics.currency))
                                .font(.title2)
                                .fontWeight(.semibold)
                                .foregroundColor(metrics.totalReturn >= 0 ? .green : .red)
                            
                            Text(metrics.formattedTotalReturnPercent)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Not enough history")
                                .font(.title3)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    // Right: Your Position (if you own this stock)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Your Position")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        // The linked source's own profit figure when there is one,
                        // as in the Holdings table.
                        let units = stockTrade.trade.position.unitSize
                        let profitLoss = dataModel?.calculatePositionProfitLoss(for: stockTrade)
                        let positionGain = profitLoss?.totalAmount ?? .nan
                        let currency = profitLoss?.currency ?? stockTrade.realTimeInfo.currency ?? "USD"
                        
                        Text("\(units.formatted(.number.precision(.fractionLength(0...4)))) \(units == 1 ? "share" : "shares")")
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
                    
                    if let metrics = stockPerformanceMetrics(for: symbol) {
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
        
        let currencyConverter = CurrencyConverter.shared
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
    
    private func formatCurrency(_ amount: Double, currency: String) -> String {
        guard amount.isFinite else { return "Unavailable" }
        // For individual stock charts, don't apply currency conversion - just format with the native currency
        switch selectedChartType {
        case .individualStock:
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
            let currencyConverter = CurrencyConverter.shared
            
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
                    convertedAmount *= 100.0
                }
            }
            
            // Primary display currency
            guard convertedAmount.isFinite else { return "Unavailable" }
            formatter.currencyCode = preferredCurrency == "GBX" ? "GBP" : preferredCurrency
            let primaryString = formatter.string(from: NSNumber(value: convertedAmount)) ?? String(format: "%.2f %@", convertedAmount, preferredCurrency)
            
            // Secondary currency in brackets (opposite of preferred)
            var secondaryString = ""
            if preferredCurrency == "USD" {
                // Show GBP in brackets
                let gbpAmount = currencyConverter.convert(amount: convertedAmount, from: "USD", to: "GBP")
                guard gbpAmount.isFinite else { return primaryString }
                let gbpFormatter = NumberFormatter()
                gbpFormatter.numberStyle = .currency
                gbpFormatter.currencyCode = "GBP"
                gbpFormatter.maximumFractionDigits = 2
                secondaryString = gbpFormatter.string(from: NSNumber(value: gbpAmount)) ?? String(format: "%.2f GBP", gbpAmount)
            } else if preferredCurrency == "GBP" || preferredCurrency == "GBX" {
                // Show USD in brackets
                let baseAmount = preferredCurrency == "GBX" ? convertedAmount / 100.0 : convertedAmount
                let usdAmount = currencyConverter.convert(amount: baseAmount, from: "GBP", to: "USD")
                guard usdAmount.isFinite else { return primaryString }
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
        var style = baseDateFormat
        if seriesIsDayGranular { style.timeZone = TimeZone(identifier: "UTC") ?? .gmt }
        return style
    }

    /// Chosen from the dates actually on screen. The selected range is a poor
    /// guide: "All" may hold two weeks of history, and zooming shortens any range.
    private var baseDateFormat: Date.FormatStyle {
        let shown = visibleXDomain ?? displayableChartData.first.flatMap { first in
            displayableChartData.last.map { first.date...max(first.date, $0.date) }
        }
        guard let shown else { return .dateTime.day().month(.abbreviated) }
        let days = shown.upperBound.timeIntervalSince(shown.lowerBound) / 86_400
        switch days {
        case ..<1.5:
            return .dateTime.hour().minute()
        case ..<10:
            return .dateTime.weekday(.abbreviated).day()
        case ..<200:
            return .dateTime.day().month(.abbreviated)
        default:
            return .dateTime.month(.abbreviated).year()
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
                currency = SymbolMetadata.defaultCurrency(for: symbol)
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
    private var isFolyncPortfolioChart: Bool {
        guard dataModel?.isFolyncPortfolioActive == true else { return false }
        switch selectedChartType {
        case .portfolioValue, .portfolioGains: return true
        case .individualStock: return false
        }
    }

    /// Changes whenever the range or the loaded series does.
    private func metricsKey(_ subject: String) -> String {
        let range = selectedTimeRange == .custom
            ? "\(customQueryRange.from.timeIntervalSince1970)-\(customQueryRange.toExclusive.timeIntervalSince1970)"
            : selectedTimeRange.rawValue
        let last = fullResolutionChartData.last
        return [
            subject, range, dataModel?.preferredCurrency ?? "",
            String(fullResolutionChartData.count),
            String(last?.date.timeIntervalSince1970 ?? 0), String(last?.value ?? 0)
        ].joined(separator: "|")
    }

    /// Period metrics over the same range the portfolio chart shows.
    private var portfolioPerformanceMetrics: PerformanceMetrics? {
        metricsCache.value(for: metricsKey("portfolio")) {
            historicalDataManager.getPerformanceMetrics(
                for: selectedTimeRange,
                customFrom: queryCustomFrom,
                customTo: queryCustomTo,
                currency: dataModel?.preferredCurrency
            )
        }
    }

    private func stockPerformanceMetrics(for symbol: String) -> PerformanceMetrics? {
        metricsCache.value(for: metricsKey("stock:" + symbol)) {
            historicalDataManager.getStockPerformanceMetrics(
                for: symbol,
                timeRange: selectedTimeRange,
                customFrom: queryCustomFrom,
                customTo: queryCustomTo
            )
        }
    }

    private func getRelevantPerformanceMetrics() -> PerformanceMetrics? {
        // Legacy snapshot metrics are not returns on the authoritative Folync series.
        guard !isFolyncPortfolioChart else { return nil }
        switch selectedChartType {
        case .portfolioValue, .portfolioGains:
            return portfolioPerformanceMetrics
        case .individualStock(let symbol):
            return stockPerformanceMetrics(for: symbol)
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
                    // The load task also restarts when the threshold changes; Apply makes it explicit.
                    Task { await reloadAllSeries(showsLoading: false) }
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
                    chartScale = max(1.0, chartScale - 0.25)
                    if chartScale <= 1 { chartOffset = .zero }
                }
                .buttonStyle(PlainButtonStyle())
                .font(.caption)
                .foregroundColor(.blue)
                .disabled(chartScale <= 1)
                .accessibilityLabel("Zoom out")
                
                Text(String(format: "%.0f%%", chartScale * 100))
                    .font(.caption)
                    .frame(width: 44)
                    .accessibilityLabel("Zoom \(Int((chartScale * 100).rounded())) percent")
                
                Button("+") {
                    chartScale = min(ChartSeriesProcessing.maxZoom, chartScale + 0.25)
                }
                .buttonStyle(PlainButtonStyle())
                .font(.caption)
                .foregroundColor(.blue)
                .disabled(chartScale >= ChartSeriesProcessing.maxZoom)
                .accessibilityLabel("Zoom in")
                
                Button("Reset") {
                    chartScale = 1.0
                    chartOffset = .zero
                }
                .buttonStyle(PlainButtonStyle())
                .font(.caption)
                .foregroundColor(.orange)
                .disabled(chartScale <= 1)
                .accessibilityLabel("Reset zoom")
                .help("Option-scroll or pinch to zoom, Option-drag to move")
                
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
    
    /// Full-resolution, filtered series (never the downsampled display copy), narrowed to the selection.
    private func exportSeries() -> [ChartDataPoint] {
        ChartSeriesProcessing.exportSeries(
            full: fullResolutionChartData,
            displayed: displayableChartData,
            selected: selectedDataPoints
        )
    }

    /// Notes the filters that narrowed the exported series, so a file is never
    /// mistaken for the full history.
    private var exportFilterNotes: [String] {
        ExportManager.filterNotes(
            valueThreshold: valueThreshold,
            dateWindow: (selectedTimeRange == .custom || dateFilterEnabled) ? customQueryRange : nil,
            selectedPoints: selectedDataPoints.count
        )
    }

    private func exportToCSV() {
        let metrics = getRelevantPerformanceMetrics()
        let dataToExport = exportSeries()
        
        exportManager.exportToCSV(
            chartData: dataToExport,
            chartType: selectedChartType,
            timeRange: selectedTimeRange,
            metrics: metrics,
            filterNotes: exportFilterNotes
        )
    }
    
    private func exportToPDF() {
        let metrics = getRelevantPerformanceMetrics()
        let chartImage = captureChartAsImage()
        let dataToExport = exportSeries()
        
        exportManager.exportToPDF(
            chartData: dataToExport,
            chartType: selectedChartType,
            timeRange: selectedTimeRange,
            metrics: metrics,
            chartImage: chartImage,
            filterNotes: exportFilterNotes
        )
    }
    
    private func exportDetailedPortfolioCSV() {
        let startDate = queryCustomFrom ?? selectedTimeRange.startDate()
        let endDate = queryCustomTo ?? Date()
        let timeRange = selectedTimeRange
        Task {
            // Read every stored snapshot: the in-memory history keeps only one per
            // day for older dates.
            let snapshots = await historicalDataManager.fetchHistoricalPortfolioSnapshots(from: startDate, to: endDate)
                .sorted { $0.date < $1.date }
            exportManager.exportPortfolioSnapshotsToCSV(snapshots: snapshots, timeRange: timeRange)
        }
    }
    
    /// A plain line chart of the exported series for the PDF.
    private func captureChartAsImage() -> NSImage? {
        let points = exportSeries().filter { $0.value.isFinite }
        guard points.count > 1 else { return nil }
        let domain = ChartSeriesProcessing.paddedDomain(points.map(\.value))
        let snapshot = Chart(points) { point in
            LineMark(x: .value("Date", point.date), y: .value("Value", point.value))
                .foregroundStyle(Color.blue)
        }
        .chartYScale(domain: domain)
        .frame(width: 720, height: 320)
        .padding(12)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: snapshot)
        renderer.scale = 2
        return renderer.nsImage
    }
    
    private func getDisplayCurrency() -> String {
        switch selectedChartType {
        case .individualStock(let symbol):
            if let trade = dataModel?.realTimeTrades.first(where: { $0.trade.name == symbol }) {
                return trade.realTimeInfo.currency ?? "USD"
            } else {
                return SymbolMetadata.defaultCurrency(for: symbol)
            }
        case .portfolioValue, .portfolioGains:
            return dataModel?.preferredCurrency ?? "USD"
        }
    }
    
    // MARK: - Hover Functions

    private var tooltipDateStyle: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.day().month().year()
        if seriesIsDayGranular { style.timeZone = TimeZone(identifier: "UTC") ?? .gmt }
        return style
    }
    
    private func hoverTooltip(for dataPoint: ChartDataPoint) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Date")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(dataPoint.date, format: tooltipDateStyle)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            
            if !seriesIsDayGranular {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Time")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(dataPoint.date, format: .dateTime.hour().minute())
                        .font(.caption)
                        .fontWeight(.medium)
                }
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
    let chartProxy: ChartProxy
    /// Origin of the plot area inside the interaction view; `ChartProxy` positions are relative to it.
    let plotOrigin: CGPoint
    let selectedTimeRange: ChartTimeRange
    
    func makeNSView(context: Context) -> NSView {
        let view = EnhancedChartView()
        view.setup(
            chartData: chartData,
            selectedDataPoints: selectedDataPoints,
            hoveredDataPoint: hoveredDataPoint,
            chartScale: chartScale,
            chartOffset: chartOffset,
            chartProxy: chartProxy,
            plotOrigin: plotOrigin,
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
            if newScale <= 1 { chartOffset = .zero }
        }
        view.onOffsetChanged = { newOffset in
            // Width is the pan as a fraction of the visible span; there is
            // nothing to pan to beyond the ends of the series.
            let limit = max(0, (chartScale - 1) / 2)
            chartOffset = CGSize(width: max(-limit, min(limit, newOffset.width)), height: 0)
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
            chartView.updateProxy(chartProxy: chartProxy, plotOrigin: plotOrigin)
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
    private var chartProxy: ChartProxy?
    private var plotOrigin: CGPoint = .zero
    private var selectedTimeRange: ChartTimeRange = .month

    /// SwiftUI and `ChartProxy` use a top-left origin; match it so box selection is not upside down.
    override var isFlipped: Bool { true }
    
    private var isSelecting = false
    private var isPanning = false
    private var selectionStartPoint: CGPoint = .zero
    private var selectionEndPoint: CGPoint = .zero
    
    func setup(
        chartData: [ChartDataPoint],
        selectedDataPoints: Set<UUID>,
        hoveredDataPoint: ChartDataPoint?,
        chartScale: Double,
        chartOffset: CGSize,
        chartProxy: ChartProxy,
        plotOrigin: CGPoint,
        selectedTimeRange: ChartTimeRange
    ) {
        self.plotOrigin = plotOrigin
        self.chartData = chartData
        self.selectedDataPoints = selectedDataPoints
        self.hoveredDataPoint = hoveredDataPoint
        self.chartScale = chartScale
        self.chartOffset = chartOffset
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
    
    /// The proxy and plot frame change whenever the chart relays out; a stale one maps to the wrong point.
    func updateProxy(chartProxy: ChartProxy, plotOrigin: CGPoint) {
        self.chartProxy = chartProxy
        self.plotOrigin = plotOrigin
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
        guard let chartProxy = chartProxy else { return }
        
        let location = convert(event.locationInWindow, from: nil)
        updateHoveredDataPoint(at: location, chartProxy: chartProxy)
    }
    
    override func mouseEntered(with event: NSEvent) {
        guard let chartProxy = chartProxy else { return }
        
        let location = convert(event.locationInWindow, from: nil)
        updateHoveredDataPoint(at: location, chartProxy: chartProxy)
    }
    
    override func mouseExited(with event: NSEvent) {
        guard hoveredDataPoint != nil else { return }
        hoveredDataPoint = nil
        onHoverChanged?(nil)
    }
    
    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        
        // Always the start of this gesture; a stale point made the first drag jump.
        selectionStartPoint = location
        selectionEndPoint = location
        isSelecting = false
        isPanning = false

        if event.modifierFlags.contains(.option) {
            isPanning = chartScale > 1
        } else if event.modifierFlags.contains(.command) {
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
        } else if isPanning, bounds.width > 0 {
            // Option-drag pans a zoomed chart, as a fraction of what is visible.
            let deltaX = location.x - selectionStartPoint.x
            onOffsetChanged?(CGSize(width: chartOffset.width + deltaX / bounds.width, height: 0))
            selectionStartPoint = location
        }
    }
    
    override func mouseUp(with event: NSEvent) {
        isSelecting = false
        isPanning = false
        needsDisplay = true
    }
    
    override func scrollWheel(with event: NSEvent) {
        // A plain scroll belongs to the page; only Option+scroll zooms the chart.
        guard event.modifierFlags.contains(.option), event.scrollingDeltaY != 0 else {
            super.scrollWheel(with: event)
            return
        }
        let zoomFactor = 1.0 + (event.scrollingDeltaY * 0.01)
        onScaleChanged?(max(1.0, min(ChartSeriesProcessing.maxZoom, chartScale * zoomFactor)))
    }

    override func magnify(with event: NSEvent) {
        // Trackpad pinch
        onScaleChanged?(max(1.0, min(ChartSeriesProcessing.maxZoom, chartScale * (1.0 + event.magnification))))
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
    
    private func updateHoveredDataPoint(at location: CGPoint, chartProxy: ChartProxy) {
        guard let closest = findDataPointAt(location: location) else { return }
        let plotX = ChartHitTesting.plotPoint(fromViewPoint: location, plotOrigin: plotOrigin).x
        guard let pointerDate: Date = chartProxy.value(atX: plotX) else { return }

        let timeDifference = abs(closest.date.timeIntervalSince(pointerDate))
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

        // Only report a change when the hovered point actually changes; mouse-moved events are frequent.
        if timeDifference <= tolerance {
            guard hoveredDataPoint?.id != closest.id else { return }
            hoveredDataPoint = closest
            onHoverChanged?(closest)
        } else if hoveredDataPoint != nil {
            hoveredDataPoint = nil
            onHoverChanged?(nil)
        }
    }
    
    private func findDataPointAt(location: CGPoint) -> ChartDataPoint? {
        guard let chartProxy = chartProxy else { return nil }
        let plotX = ChartHitTesting.plotPoint(fromViewPoint: location, plotOrigin: plotOrigin).x
        guard let date: Date = chartProxy.value(atX: plotX),
              let index = ChartSeriesProcessing.nearestIndex(in: chartData.map(\.date), to: date) else { return nil }
        return chartData[index]
    }
    
    private func findDataPointsInRect(_ rect: CGRect) -> [ChartDataPoint] {
        guard let chartProxy = chartProxy else { return [] }

        let positions: [(id: UUID, point: CGPoint)] = chartData.compactMap { dataPoint in
            guard let x: CGFloat = chartProxy.position(forX: dataPoint.date),
                  let y: CGFloat = chartProxy.position(forY: dataPoint.value) else {
                return nil
            }
            return (dataPoint.id, CGPoint(x: x, y: y))
        }
        let ids = ChartHitTesting.selectedIDs(inViewRect: rect, plotOrigin: plotOrigin, positions: positions)
        return chartData.filter { ids.contains($0.id) }
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

/// Remembers the last period metrics computed for a key.
@MainActor
final class PeriodMetricsCache {
    private var key: String?
    private var metrics: PerformanceMetrics?

    func value(for key: String, compute: () -> PerformanceMetrics?) -> PerformanceMetrics? {
        if self.key != key {
            self.key = key
            metrics = compute()
        }
        return metrics
    }
}

private extension View {
    /// Pins the x-axis to `domain`, or leaves it automatic when nil.
    @ViewBuilder
    func chartXDomain(_ domain: ClosedRange<Date>?) -> some View {
        if let domain {
            chartXScale(domain: domain)
        } else {
            self
        }
    }
}

/// The chart, period and style last shown, kept between sessions.
struct ChartViewSelection: Equatable {
    /// "value", "gains" or "stock:SYMBOL".
    var chart = "value"
    var timeRange = ChartTimeRange.month
    var style = ChartVisualizationStyle.line

    private static let chartKey = "chartSelectionChart"
    private static let rangeKey = "chartSelectionRange"
    private static let styleKey = "chartSelectionStyle"

    init() {}

    init(chartType: ChartType, timeRange: ChartTimeRange, style: ChartVisualizationStyle) {
        switch chartType {
        case .portfolioValue: chart = "value"
        case .portfolioGains: chart = "gains"
        case .individualStock(let symbol): chart = "stock:" + symbol
        }
        // Custom dates are not kept, so a Custom range would reopen on dates
        // the user never chose.
        self.timeRange = timeRange == .custom ? .month : timeRange
        self.style = style
    }

    /// A stock no longer in the portfolio falls back to the portfolio chart.
    func chartType(among symbols: [String]) -> ChartType {
        if chart == "gains" { return .portfolioGains }
        if chart.hasPrefix("stock:") {
            let symbol = String(chart.dropFirst("stock:".count))
            if symbols.contains(symbol) { return .individualStock(symbol) }
        }
        return .portfolioValue
    }

    static func load(from store: UserDefaults = StockbarRuntimeStorage.userDefaults) -> ChartViewSelection {
        var selection = ChartViewSelection()
        if let chart = store.string(forKey: chartKey) { selection.chart = chart }
        if let range = store.string(forKey: rangeKey).flatMap(ChartTimeRange.init(rawValue:)), range != .custom {
            selection.timeRange = range
        }
        if let style = store.string(forKey: styleKey).flatMap(ChartVisualizationStyle.init(rawValue:)) {
            selection.style = style
        }
        return selection
    }

    func save(to store: UserDefaults = StockbarRuntimeStorage.userDefaults) {
        store.set(chart, forKey: Self.chartKey)
        store.set(timeRange.rawValue, forKey: Self.rangeKey)
        store.set(style.rawValue, forKey: Self.styleKey)
    }
}
