import Charts
import SwiftUI

/// Comprehensive risk analytics dashboard displaying portfolio risk metrics
/// Shows VaR, Sharpe and Sortino ratios, maximum drawdown and volatility
struct RiskAnalyticsView: View {
    let dataModel: DataModel

    @State private var isCalculating = false
    /// Counts requests so a superseded calculation can tell it is out of date.
    @State private var requestGeneration = 0
    @State private var riskMetrics: RiskMetricsService.RiskMetrics?
    @State private var drawdownPeriods: [RiskMetricsService.DrawdownPeriod] = []
    @State private var errorMessage: String?
    /// Missing history is an expected state, not a failure.
    @State private var insufficientDataMessage: String?
    @State private var selectedTimeRange: TimeRange = .oneYear
    /// Set when snapshots recorded in another currency were converted or left out.
    @State private var currencyNotice: String?
    /// What the figures rest on, for the footnote: the number of daily returns,
    /// the first and last day, and whether the portfolio is Folync's.
    @State private var sampleTradingDays = 0
    @State private var sampleFirstDate: Date?
    @State private var sampleLastDate: Date?
    @State private var sampleIsFolync = false
    /// How far below its peak the index stood on each day, for the chart.
    @State private var drawdownSeries: [RiskMetricsService.DrawdownPoint] = []

    enum TimeRange: String, CaseIterable {
        case oneMonth = "1M"
        case threeMonths = "3M"
        case sixMonths = "6M"
        case oneYear = "1Y"
        case all = "All"

        var days: Int? {
            switch self {
            case .oneMonth: return 30
            case .threeMonths: return 90
            case .sixMonths: return 180
            case .oneYear: return 365
            case .all: return nil
            }
        }

        var description: String {
            switch self {
            case .oneMonth: return "1 month"
            case .threeMonths: return "3 months"
            case .sixMonths: return "6 months"
            case .oneYear: return "1 year"
            case .all: return "All time"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StockbarLayout.sectionSpacing) {
            headerSection

            // A recalculation keeps the previous figures on screen, dimmed,
            // so the page does not empty and jump on every range change.
            if isCalculating, riskMetrics == nil {
                ProgressView("Calculating risk metrics...")
                    .stockbarEmptyState(minHeight: 300)
            } else if let insufficientDataMessage {
                ContentUnavailableView(
                    "Not enough history",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text(insufficientDataMessage)
                )
                .stockbarEmptyState(minHeight: 300)
            } else if let error = errorMessage {
                errorView(message: error)
            } else if let metrics = riskMetrics {
                if isCalculating {
                    ProgressView("Recalculating…")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: StockbarLayout.sectionSpacing) {
                    if let currencyNotice {
                        StockbarNotice(message: currencyNotice)
                    }
                    RiskFiguresView(
                        metrics: metrics, drawdownPeriods: drawdownPeriods, drawdownSeries: drawdownSeries,
                        currency: dataModel.preferredCurrency, timeRange: selectedTimeRange,
                        sampleTradingDays: sampleTradingDays, sampleFirstDate: sampleFirstDate,
                        sampleLastDate: sampleLastDate, sampleIsFolync: sampleIsFolync
                    )
                }
                .opacity(isCalculating ? 0.5 : 1)
                .accessibilityHidden(isCalculating)
            } else {
                emptyStateView
            }
        }
        .stockbarPage()
        .onAppear {
            calculateRiskMetrics()
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        StockbarPageHeader("Risk", subtitle: "How bumpy the ride has been") {
            HStack(spacing: 12) {
                Button(action: calculateRiskMetrics) {
                    StockbarRefreshIcon(isRefreshing: isCalculating)
                }
                .buttonStyle(.borderless)
                .disabled(isCalculating)
                .help("Work the figures out again from stored history")
                .accessibilityLabel("Recalculate")
                StockbarSegmentedControl("Time range", selection: $selectedTimeRange, options: TimeRange.allCases) {
                    $0.description
                }
                .fixedSize()
                .onChange(of: selectedTimeRange) {
                    calculateRiskMetrics()
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.xaxis")
                .accessibilityHidden(true)
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No Historical Data Available")
                .font(.headline)

            Text("Risk metrics require historical portfolio data. Continue using the app to build historical data for analysis.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button("Calculate Now") {
                calculateRiskMetrics()
            }
            .buttonStyle(.borderedProminent)
        }
        .stockbarEmptyState(minHeight: 300)
    }

    // MARK: - Error View

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityHidden(true)
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Calculation Error")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button("Retry") {
                calculateRiskMetrics()
            }
            .buttonStyle(.bordered)
        }
        .stockbarEmptyState(minHeight: 300)
    }

    // MARK: - Calculation Logic

    private func calculateRiskMetrics() {
        // Two ranges picked quickly run two calculations; only the latest may
        // write its answer, or the slower, older one would overwrite it.
        requestGeneration += 1
        let generation = requestGeneration
        Task {
            await MainActor.run {
                isCalculating = true
                errorMessage = nil
                insufficientDataMessage = nil
            }

            // Convert TimeRange to ChartTimeRange
            let chartTimeRange: ChartTimeRange
            switch selectedTimeRange {
            case .oneMonth:
                chartTimeRange = .month
            case .threeMonths:
                chartTimeRange = .threeMonths
            case .sixMonths:
                chartTimeRange = .sixMonths
            case .oneYear:
                chartTimeRange = .year
            case .all:
                chartTimeRange = .all
            }

            // Get portfolio snapshots from HistoricalDataManager
            let snapshots = HistoricalDataManager.shared.getHistoricalPortfolioSnapshots(timeRange: chartTimeRange)

            guard !snapshots.isEmpty else {
                await MainActor.run {
                    guard generation == requestGeneration else { return }
                    insufficientDataMessage = "Risk metrics appear once Stockbar has recorded portfolio values for this time range."
                    riskMetrics = nil
                    isCalculating = false
                }
                return
            }

            // One close per calendar day, with buys/sells excluded from returns
            // (previous day's holdings revalued at the new prices).
            let preferredCurrency = dataModel.preferredCurrency
            let converter = dataModel.currencyConverter

            // Each snapshot was recorded in the currency that was preferred at the time. Convert
            // them to today's currency, or leave out those that cannot be converted.
            let normalized = RiskMetricsService.normalizingSnapshotCurrencies(
                snapshots, to: preferredCurrency,
                convert: { converter.convert(amount: $0, from: $1, to: $2) }
            )
            var notices: [String] = []
            if normalized.convertedCount > 0 {
                notices.append("\(normalized.convertedCount) recorded snapshot(s) were in another currency and were converted to \(preferredCurrency) at today's exchange rate.")
            }
            if normalized.droppedCount > 0 {
                notices.append("\(normalized.droppedCount) snapshot(s) in another currency were left out because no exchange rate is available.")
            }
            let notice = notices.isEmpty ? nil : notices.joined(separator: " ")

            guard let series = RiskMetricsService.flowAdjustedDailySeries(
                snapshots: normalized.snapshots,
                convert: { converter.convert(amount: $0, from: $1, to: preferredCurrency) }
            ) else {
                await MainActor.run {
                    guard generation == requestGeneration else { return }
                    insufficientDataMessage = "Risk metrics need portfolio values from at least two different days."
                    riskMetrics = nil
                    isCalculating = false
                }
                return
            }

            let minimum = RiskMetricsService.minimumDailyReturns
            guard series.returns.count >= minimum else {
                await MainActor.run {
                    guard generation == requestGeneration else { return }
                    insufficientDataMessage = "Risk metrics need at least \(minimum) trading days of history in this time range. "
                        + "There are \(series.returns.count) so far."
                    riskMetrics = nil
                    isCalculating = false
                }
                return
            }
            let tradingDays = series.returns.count
            let firstDate = series.dates.first
            let lastDate = series.dates.last
            // The main chart shows Folync's series; these figures do not.
            let isFolync = dataModel.isFolyncPortfolioActive
            // The same values and dates the maximum drawdown is worked out from.
            let drawdowns = RiskMetricsService.drawdownSeries(values: series.values, dates: series.dates)

            // Calculate comprehensive risk metrics
            if let metrics = await RiskMetricsService.shared.calculateComprehensiveRiskMetrics(
                series: series,
                riskFreeRate: RiskMetricsService.annualRiskFreeRate
            ) {
                // Find significant drawdown periods
                let periods = await RiskMetricsService.shared.findDrawdownPeriods(
                    portfolioValues: series.values,
                    dates: series.dates,
                    threshold: 0.05
                )

                await MainActor.run {
                    guard generation == requestGeneration else { return }
                    self.riskMetrics = metrics
                    self.drawdownPeriods = periods
                    self.currencyNotice = notice
                    self.sampleTradingDays = tradingDays
                    self.sampleFirstDate = firstDate
                    self.sampleLastDate = lastDate
                    self.sampleIsFolync = isFolync
                    self.drawdownSeries = drawdowns
                    self.isCalculating = false
                }
            } else {
                await MainActor.run {
                    guard generation == requestGeneration else { return }
                    insufficientDataMessage = "At least two recorded portfolio values are needed in this time range."
                    riskMetrics = nil
                    isCalculating = false
                }
            }
        }
    }
}

// MARK: - Figures

/// The page once its figures are worked out: the strip, the chart, the bad-day
/// figures, the falls and the footnote, each figure said once.
struct RiskFiguresView: View {
    let metrics: RiskMetricsService.RiskMetrics
    let drawdownPeriods: [RiskMetricsService.DrawdownPeriod]
    let drawdownSeries: [RiskMetricsService.DrawdownPoint]
    /// The display currency the value-at-risk amounts are in.
    let currency: String
    let timeRange: RiskAnalyticsView.TimeRange
    let sampleTradingDays: Int
    let sampleFirstDate: Date?
    let sampleLastDate: Date?
    let sampleIsFolync: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: StockbarLayout.sectionSpacing) {
            metricStrip(metrics: metrics)
            drawdownChartSection(metrics: metrics)
            badDaySection(metrics: metrics)
            fallsSection
            footnoteSection(metrics: metrics)
        }
    }

    // MARK: - Strip

    private func metricStrip(metrics: RiskMetricsService.RiskMetrics) -> some View {
        StockbarMetricStrip {
            StockbarMetricTile(title: "Volatility", value: RiskText.percent(metrics.volatility),
                               detail: RiskText.volatilityDetail(metrics.volatility))
            StockbarMetricTile(title: "Sharpe ratio", value: RiskText.ratio(metrics.sharpeRatio),
                               detail: RiskText.sharpeDetail(metrics.sharpeRatio))
            StockbarMetricTile(title: "Sortino ratio", value: RiskText.ratio(metrics.sortinoRatio),
                               detail: RiskText.sortinoDetail(metrics.sortinoRatio))
            StockbarMetricTile(title: "Worst fall", value: RiskText.fall(metrics.maxDrawdown),
                               detail: RiskText.worstFallDetail(fall: metrics.maxDrawdown,
                                                                duration: metrics.maxDrawdownDuration),
                               valueColor: metrics.maxDrawdown.isFinite && metrics.maxDrawdown > 0
                                   ? StockbarPalette.loss : .primary)
        }
    }

    // MARK: - Drawdown chart

    private func drawdownChartSection(metrics: RiskMetricsService.RiskMetrics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            StockbarSectionTitle(title: "How far below its peak")
            RiskDrawdownChart(series: drawdownSeries, revealTrigger: timeRange)
                .frame(height: 200)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("How far below its peak, \(timeRange.description)")
                .accessibilityValue(RiskText.chartAccessibility(drawdownSeries))
            if metrics.maxDrawdown.isFinite, metrics.maxDrawdown > 0 {
                Text(RiskText.recoveryNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .stockbarCard()
    }

    // MARK: - On a bad day

    private func badDaySection(metrics: RiskMetricsService.RiskMetrics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            StockbarSectionTitle(title: "On a bad day")
            HStack(alignment: .top, spacing: 18) {
                badDayFigure(lead: RiskText.oneDayIn20,
                             amount: RiskText.amount(metrics.valueAtRisk95, currency: currency),
                             caption: RiskText.valueAtRisk95)
                Divider()
                badDayFigure(lead: RiskText.oneDayIn100,
                             amount: RiskText.amount(metrics.valueAtRisk99, currency: currency),
                             caption: RiskText.valueAtRisk99)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .stockbarCard()
    }

    private func badDayFigure(lead: String, amount: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(lead)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(amount)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RiskText.badDaySentence(lead: lead, amount: amount, caption: caption))
    }

    // MARK: - Falls of more than 5%

    private var fallsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            StockbarSectionTitle(title: RiskText.fallsTitle)
            if drawdownPeriods.isEmpty {
                Text(RiskText.noFalls)
                    .foregroundStyle(.secondary)
            } else {
                if let note = RiskText.fallsShownNote(shown: min(drawdownPeriods.count, 5), total: drawdownPeriods.count) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 6) {
                    ForEach(drawdownPeriods.prefix(5), id: \.startDate) { period in
                        fallRow(period)
                    }
                }
            }
        }
        .stockbarCard()
    }

    private func fallRow(_ period: RiskMetricsService.DrawdownPeriod) -> some View {
        HStack(spacing: 16) {
            Text(RiskText.fall(period.drawdownPercent))
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(StockbarPalette.loss)
                .frame(minWidth: 70, alignment: .leading)
            Text(RiskText.dateRange(period.startDate, period.endDate))
            Spacer(minLength: 12)
            Text(RiskText.fallLength(period.durationDays))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RiskText.fallAccessibility(period))
    }

    // MARK: - Footnote

    private func footnoteSection(metrics: RiskMetricsService.RiskMetrics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(RiskText.downsideDeviationTitle)
                Text(RiskText.percent(metrics.downsideDeviation))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text(RiskText.downsideDeviationNote)
            }
            .accessibilityElement(children: .combine)
            Text(RiskText.footnote(tradingDays: sampleTradingDays, first: sampleFirstDate, last: sampleLastDate,
                                   isFolyncPortfolio: sampleIsFolync, riskFreeRate: RiskMetricsService.annualRiskFreeRate))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

}

// MARK: - Drawdown chart

/// The drawdown over the range as an area and a line from 0% downward, with the
/// lowest point marked and labelled. Its text for VoiceOver is set by the page.
private struct RiskDrawdownChart: View {
    let series: [RiskMetricsService.DrawdownPoint]
    let revealTrigger: RiskAnalyticsView.TimeRange

    var body: some View {
        let lowest = RiskMetricsService.lowestPoint(of: series)
        let floor = min((lowest?.drawdown ?? 0) * 1.25, -0.01)
        Chart {
            RuleMark(y: .value("Peak", 0))
                .foregroundStyle(Color.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1))
            ForEach(series, id: \.date) { point in
                AreaMark(
                    x: .value("Date", point.date),
                    yStart: .value("Peak", 0),
                    yEnd: .value("Below peak", point.drawdown)
                )
                .foregroundStyle(StockbarPalette.loss.opacity(0.18))
                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Below peak", point.drawdown)
                )
                .foregroundStyle(StockbarPalette.loss)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            if let lowest, lowest.drawdown < 0 {
                PointMark(
                    x: .value("Date", lowest.date),
                    y: .value("Below peak", lowest.drawdown)
                )
                .foregroundStyle(StockbarPalette.loss)
                .symbolSize(40)
                .annotation(position: .bottom, alignment: .center, spacing: 4,
                            overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                    Text(RiskText.lowestPointLabel(lowest))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
            }
        }
        // A little room above 0% so its label is not cut off at the top.
        .chartYScale(domain: floor...(-floor * 0.06))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel(format: FloatingPointFormatStyle<Double>.Percent.percent.precision(.fractionLength(0)))
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                // Under about two months the months alone would repeat.
                if let first = series.first?.date, let last = series.last?.date,
                   last.timeIntervalSince(first) < 70 * 86_400 {
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                } else {
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                }
            }
        }
        .chartReveal(trigger: revealTrigger)
    }
}

// MARK: - Preview

#Preview {
    RiskAnalyticsView(dataModel: DataModel())
        .frame(width: 800, height: 1000)
}
