import AppKit
import Charts
import SwiftUI

struct PerformanceChartView: View {
    let historicalDataManager = HistoricalDataManager.shared
    private let calculationManager = BackgroundCalculationManager.shared
    @State var selectedTimeRange: ChartTimeRange = .month
    @State var selectedChartType: ChartType = .portfolioValue
    @State var showingMetrics = true
    @State private var hoveredDataPoint: ChartDataPoint?
    @State var showingExportOptions = false
    @State var selectedDataPoints: Set<UUID> = []
    @State var chartScale: Double = 1.0
    @State var chartOffset: CGSize = .zero
    @State var showingDataFilters = false
    @State var valueThreshold: Double = 0.0
    @State var dateFilterEnabled = false
    @State var customStartDate = Date().addingTimeInterval(-30 * 24 * 60 * 60) // 30 days ago
    @State var customEndDate = Date()
    // CRITICAL FIX: Replace caching with proper state management for UI responsiveness
    @State private var chartRequestGeneration = 0
    @State var displayableChartData: [ChartDataPoint] = []
    /// Filtered but not downsampled; exports use this so they are never silently thinned.
    @State var fullResolutionChartData: [ChartDataPoint] = []
    /// Day-only sources (Folync daily history) are stamped at UTC midnight and shown in UTC.
    @State private var seriesIsDayGranular = false
    @State private var isLoadingData = false
    @State private var silentReloadTask: Task<Void, Never>?
    /// Period metrics for the series on screen. Kept outside observed state so
    /// a hover, which redraws the view, does not recompute them.
    @State var metricsCache = PeriodMetricsCache()

    // Comparison Mode state variables
    @State var comparisonMode: Bool = false
    @State var selectedComparisonSymbols: Set<String> = []
    @State var comparisonChartData: [String: [ChartDataPoint]] = [:] // symbol -> data points
    @State var normalizedComparison: Bool = true // Normalize to percentage for fair comparison

    // Visual Styling state variables
    @State var lineThickness: Double = 2.0 // 1-3pt
    @State private var showGridLines: Bool = false
    @State private var useGradientFill: Bool = true

    // Chart visualization style
    @State var chartVisualizationStyle: ChartVisualizationStyle = .line
    @State var candlestickSettings = CandlestickChartSettings.load()
    @State var ohlcData: [OHLCDataPoint] = []
    @State var isLoadingOHLC = false
    @State var ohlcSourceStatus: FolyncSupplementalSourceStatus?
    @State var ohlcCoverageLabel: String?
    @State var ohlcRequestGeneration: Int = 0

    // Interaction features (v2.3.1)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let availableSymbols: [String]
    let dataModel: DataModel?
    let exportManager = ExportManager.shared
    let ohlcFetchService = OHLCFetchService.shared
    
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
        /// A portfolio chart is Folync's series while Folync is connected and
        /// the local one otherwise. Without this, a chart opened before
        /// Folync connected kept the local series under the Folync caption.
        let folyncPortfolioActive: Bool
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
            filterToExclusive: usesDates ? range.toExclusive : nil,
            folyncPortfolioActive: dataModel?.isFolyncPortfolioActive ?? false
        )
    }

    /// Custom dates cover whole days: start of the first day up to the start of the day after the last.
    var customQueryRange: (from: Date, toExclusive: Date) {
        ChartSeriesProcessing.normalizedCustomRange(start: customStartDate, end: customEndDate)
    }

    var queryCustomFrom: Date? { selectedTimeRange == .custom ? customQueryRange.from : nil }
    var queryCustomTo: Date? { selectedTimeRange == .custom ? customQueryRange.toExclusive : nil }

    private var isComparisonActive: Bool {
        guard case .individualStock = selectedChartType else { return false }
        return comparisonMode
    }

    var isCandlestickActive: Bool {
        guard case .individualStock = selectedChartType else { return false }
        return chartVisualizationStyle == .candlestick
    }

    private var isLocalPortfolioChart: Bool {
        switch selectedChartType {
        case .portfolioValue, .portfolioGains: return !isFolyncPortfolioChart
        case .individualStock: return false
        }
    }

    func reloadAllSeries(showsLoading: Bool) async {
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
        .background(StockbarPalette.panelFill)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.blue.opacity(0.3), lineWidth: 1)
        )
    }
    
    private func errorView(_ error: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityHidden(true)
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
            .background(StockbarPalette.panelFill)
            .cornerRadius(8)
        }
    }

    private var formattedCustomDateRange: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return "\(formatter.string(from: customStartDate)) - \(formatter.string(from: customEndDate))"
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
        .background(StockbarPalette.sheetHeaderFill)
        .cornerRadius(6)
    }

    // MARK: - Data Loading

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
        let compression = timeCompression
        let shown = displayableChartData
            .filter { visible.contains(compression.plotDate(for: $0.date)) }
            .map(\.value)
        return ChartSeriesProcessing.paddedDomain(shown.isEmpty ? displayableChartData.map(\.value) : shown)
    }

    /// On the 1D and 1W ranges, nights and weekends are squeezed so the hours
    /// with prices fill the chart. Longer ranges are drawn to scale.
    private var timeCompression: ChartTimeCompression {
        switch selectedTimeRange {
        case .day, .week:
            return ChartTimeCompression(dates: displayableChartData.map(\.date))
        case .month, .threeMonths, .sixMonths, .year, .all, .custom:
            return .identity
        }
    }

    /// The part of the x-axis on screen when zoomed in, or nil at normal size.
    /// In plot times: see `timeCompression`.
    private var visibleXDomain: ClosedRange<Date>? {
        guard let first = displayableChartData.first?.date, let last = displayableChartData.last?.date else {
            return nil
        }
        let compression = timeCompression
        return ChartSeriesProcessing.zoomedDomain(
            first: compression.plotDate(for: first),
            last: compression.plotDate(for: last),
            scale: chartScale,
            panFraction: Double(chartOffset.width)
        )
    }

    /// X-axis marks for a squeezed axis: one per session when that gives a
    /// sensible number, otherwise evenly spaced. Nil leaves the choice to the chart.
    private func compressedAxisMarks(_ compression: ChartTimeCompression) -> [Date]? {
        guard !compression.isIdentity,
              let first = displayableChartData.first?.date,
              let last = displayableChartData.last?.date else { return nil }
        let shown = visibleXDomain
            ?? compression.plotDate(for: first)...compression.plotDate(for: max(first, last))
        // One mark per day: a break in the middle of a day would repeat its label.
        var calendar = Calendar.current
        if seriesIsDayGranular { calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt }
        var daysMarked = Set<Date>()
        let sessions = compression.sessionStarts.filter { start in
            shown.contains(start)
                && daysMarked.insert(calendar.startOfDay(for: compression.realDate(forPlot: start))).inserted
        }
        if (3...8).contains(sessions.count) { return sessions }
        let span = shown.upperBound.timeIntervalSince(shown.lowerBound)
        guard span > 0 else { return nil }
        let realSpan = compression.realDate(forPlot: shown.upperBound)
            .timeIntervalSince(compression.realDate(forPlot: shown.lowerBound))
        // Evenly spaced across the chart, then moved to the nearest round
        // time so the labels read 14:30, not 14:24.
        let step: TimeInterval
        switch realSpan {
        case ..<7_200: step = 300
        case ..<21_600: step = 900
        case ..<129_600: step = 1_800
        default: step = 3_600
        }
        var marks: [Date] = []
        for index in 0..<6 {
            let even = shown.lowerBound.addingTimeInterval(span * (Double(index) + 0.5) / 6)
            let real = compression.realDate(forPlot: even).timeIntervalSinceReferenceDate
            let rounded = Date(timeIntervalSinceReferenceDate: (real / step).rounded() * step)
            let mark = compression.plotDate(for: rounded)
            if shown.contains(mark), marks.last.map({ mark > $0 }) ?? true { marks.append(mark) }
        }
        return marks.isEmpty ? nil : marks
    }
    
    private var chartView: some View {
        Group {
            if isCandlestickActive && !(isComparisonActive && !selectedComparisonSymbols.isEmpty) {
                // OHLC has its own loading and empty states, independent of line history.
                candlestickChartPlaceholder
            } else if (isLoadingData || historicalDataManager.folyncPortfolioHistoryRequestsInFlight > 0)
                        && displayableChartData.isEmpty {
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
                let compression = timeCompression
                let axisMarks = compressedAxisMarks(compression)
                let axisDateFormat = dateFormat
                Chart(displayableChartData) { dataPoint in
                        let plotDate = compression.plotDate(for: dataPoint.date)
                        LineMark(
                            x: .value("Date", plotDate),
                            y: .value("Value", dataPoint.value)
                        )
                        .foregroundStyle(chartColor)
                        .lineStyle(StrokeStyle(lineWidth: lineThickness))

                        if useGradientFill {
                            AreaMark(
                                x: .value("Date", plotDate),
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
                                x: .value("Date", plotDate),
                                yStart: .value("Baseline", domain.lowerBound),
                                yEnd: .value("Value", dataPoint.value)
                            )
                            .foregroundStyle(chartColor.opacity(0.1))
                        }

                        // Add a point mark for the hovered data point
                        if let hoveredPoint = hoveredDataPoint,
                           hoveredPoint.date == dataPoint.date {
                            PointMark(
                                x: .value("Date", plotDate),
                                y: .value("Value", dataPoint.value)
                            )
                            .foregroundStyle(chartColor)
                            .symbolSize(50)
                        }

                        // Add selection indicators
                        if selectedDataPoints.contains(dataPoint.id) {
                            PointMark(
                                x: .value("Date", plotDate),
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
                        if let axisMarks {
                            // The axis is in plot times; label each mark with the real time there.
                            AxisMarks(values: axisMarks) { value in
                                if showGridLines {
                                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                                }
                                AxisTick()
                                AxisValueLabel {
                                    if let plotted = value.as(Date.self) {
                                        Text(compression.realDate(forPlot: plotted), format: axisDateFormat)
                                    }
                                }
                            }
                        } else {
                            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                                if showGridLines {
                                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                                }
                                AxisTick()
                                AxisValueLabel(format: axisDateFormat)
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                            if showGridLines {
                                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                            }
                            AxisTick()
                            AxisValueLabel(format: currencyValueFormat(spanning: domain))
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
                                        selectedTimeRange: selectedTimeRange,
                                        timeCompression: compression
                                    )
                                )
                        }
                    }
                    // The chart's own spoken description reads positions along
                    // the axis as dates, which are wrong on a squeezed axis.
                    .chartAccessibilityChildrenHidden(!compression.isIdentity)
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

    /// Money for the chart's labels, written the same way as the holdings table.
    /// A single holding is shown in its own currency; portfolio figures are
    /// converted to the preferred currency, with the other of pounds and dollars
    /// in brackets.
    func formatCurrency(_ amount: Double, currency: String) -> String {
        guard amount.isFinite else { return "—" }
        if case .individualStock = selectedChartType {
            return HoldingsCurrencyFormatter.amount(amount, currency: currency)
        }
        guard let model = dataModel else {
            return HoldingsCurrencyFormatter.amount(amount, currency: currency)
        }

        let converter = CurrencyConverter.shared
        let preferredCurrency = model.preferredCurrency
        let prefersPence = CurrencyConverter.isPenceCurrency(preferredCurrency)
        let preferredMajor = prefersPence ? "GBP" : preferredCurrency
        let sourceCurrency = currency.isEmpty ? "USD" : currency
        let sourceIsPence = CurrencyConverter.isPenceCurrency(sourceCurrency)
        let sourceMajor = sourceIsPence ? "GBP" : sourceCurrency

        // Work in whole units, then put pence back only for display.
        let sourceMajorAmount = sourceIsPence ? amount / 100.0 : amount
        let majorAmount = sourceMajor == preferredMajor
            ? sourceMajorAmount
            : converter.convert(amount: sourceMajorAmount, from: sourceMajor, to: preferredMajor)
        guard majorAmount.isFinite else { return "—" }

        let primary = HoldingsCurrencyFormatter.amount(
            prefersPence ? majorAmount * 100.0 : majorAmount,
            currency: preferredCurrency
        )

        let secondaryCurrency: String
        switch preferredMajor {
        case "USD": secondaryCurrency = "GBP"
        case "GBP": secondaryCurrency = "USD"
        default: return primary
        }
        let secondaryAmount = converter.convert(amount: majorAmount, from: preferredMajor, to: secondaryCurrency)
        guard secondaryAmount.isFinite else { return primary }
        return "\(primary) (\(HoldingsCurrencyFormatter.amount(secondaryAmount, currency: secondaryCurrency)))"
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
        // The zoomed domain is in plot times; the label format goes by real time.
        let compression = timeCompression
        let shown = visibleXDomain.map { visible -> ClosedRange<Date> in
            let start = compression.realDate(forPlot: visible.lowerBound)
            return start...max(start, compression.realDate(forPlot: visible.upperBound))
        } ?? displayableChartData.first.flatMap { first in
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
    
    /// Axis labels show pence only when the axis is fine enough to need them:
    /// "£10,000.00" on a portfolio axis is noise, "£0.79" on a share price is not.
    private func currencyValueFormat(spanning domain: ClosedRange<Double>) -> FloatingPointFormatStyle<Double>.Currency {
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
        let wholeUnits = domain.upperBound - domain.lowerBound >= 100
        return FloatingPointFormatStyle<Double>.Currency(code: currencyCode)
            .precision(.fractionLength(wholeUnits ? 0 : 2))
    }
    
    // MARK: - Helper Functions
    
    /// Gets the appropriate performance metrics based on the selected chart type
    var isFolyncPortfolioChart: Bool {
        guard dataModel?.isFolyncPortfolioActive == true else { return false }
        switch selectedChartType {
        case .portfolioValue, .portfolioGains: return true
        case .individualStock: return false
        }
    }

    
    
    /// Sets up keyboard shortcuts for chart interactions
    private func setupKeyboardShortcuts() {
        // This would be implemented with key event handling in a full implementation
        // For now, the shortcuts are handled in the EnhancedChartView
    }
    
    func getDisplayCurrency() -> String {
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
        .background(StockbarPalette.panelFill)
        .cornerRadius(8)
        .shadow(radius: 2)
    }
}

private extension View {
    /// Presents the chart to assistive technology as one element, without
    /// the per-mark children, when `hidden` is true.
    @ViewBuilder
    func chartAccessibilityChildrenHidden(_ hidden: Bool) -> some View {
        if hidden {
            accessibilityElement(children: .ignore)
        } else {
            self
        }
    }

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
