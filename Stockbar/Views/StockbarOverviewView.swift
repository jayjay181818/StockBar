import Charts
import SwiftUI

/// The window's quick-check surface shares its data and period semantics with the menu bar.
@MainActor
struct StockbarOverviewView: View {
    let dataModel: DataModel
    let navigationState: StockbarMainNavigationState
    @StateObject private var chartModel: PortfolioMenuChartViewModel
    @State private var selectedSymbol = ""
    /// The point under the pointer. Only written when it changes, so moving along one point does not re-render.
    @State private var hoveredPoint: MenuChartDataPoint?
    @State private var summaryCache = DisplaySummaryCache()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(dataModel: DataModel, navigationState: StockbarMainNavigationState) {
        self.dataModel = dataModel
        self.navigationState = navigationState
        let summary = dataModel.calculateDisplayPortfolioSummary()
        _chartModel = StateObject(wrappedValue: PortfolioMenuChartViewModel(
            currentValue: summary.totalValue,
            currentTrades: dataModel.realTimeTrades,
            preferredCurrency: summary.currency,
            valuationSource: summary.valuationSource,
            initialRange: .week
        ))
    }

    /// Computed once per render pass (see `DisplaySummaryCache`).
    private var summary: DisplayPortfolioSummary {
        summaryCache.summary { dataModel.calculateDisplayPortfolioSummary() }
    }
    private var holdings: [RealTimeTrade] {
        dataModel.realTimeTrades.filter {
            !$0.trade.isWatchlistOnly && !SymbolMetadata.isBenchmarkSymbol($0.trade.name)
                && $0.trade.position.unitSize > 0
        }
    }
    private var selectedHolding: RealTimeTrade? {
        holdings.first { $0.trade.name == selectedSymbol } ?? holdings.first
    }
    private var source: String {
        switch summary.valuationSource {
        case .folyncProvided: "Folync"
        case .brokerProvided: "Trading 212"
        case .localCalculationFallback, .marketDataFallback: "Local portfolio"
        }
    }
    /// Folync can return a full chart and still mark the period partial (carried or stale
    /// prices); the change is then withheld, and more local history would not bring it back.
    private var rangeChangeUnavailableHint: String {
        summary.valuationSource == .folyncProvided && chartModel.chartData.count > 1
            ? "Folync marks this period partial"
            : "Needs more stored history"
    }
    private var rangeChange: PortfolioMenuRangeChange? {
        PortfolioMenuPerformanceResolver.resolve(
            summary: summary, range: chartModel.selectedTimeRange,
            chartChange: chartModel.hasRangeCoverage && chartModel.chartData.count > 1
                ? PortfolioMenuChartDataBuilder.rangeChange(for: chartModel.chartData) : nil
        )
    }

    var body: some View {
        let _ = summaryCache.beginPass()
        GeometryReader { geometry in
            let showsSideInspector = geometry.size.width >= 1000
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: StockbarLayout.sectionSpacing) {
                        header
                        hero
                        chartCard
                        summaryCard
                        if !showsSideInspector {
                            inspector.stockbarCard()
                        }
                    }
                    .padding(StockbarLayout.pageInsets)
                }
                if showsSideInspector {
                    Divider()
                        .ignoresSafeArea(edges: .top)
                    ScrollView {
                        inspector
                            .padding(.horizontal, 22)
                            .padding(.top, 14)
                            .padding(.bottom, StockbarLayout.pagePadding)
                    }
                    .frame(width: 270)
                    .background {
                        StockbarPalette.cardFill.ignoresSafeArea(edges: .top)
                    }
                }
            }
        }
        .onAppear { updateChart(); chartModel.activate() }
        .onDisappear { chartModel.deactivate() }
        .onReceive(dataModel.tradeContentPublisher) { _ in updateChart() }
        .onChange(of: summary.totalValue) { _, _ in updateChart() }
        .onChange(of: summary.currency) { _, _ in updateChart() }
        .onChange(of: summary.valuationSource) { _, _ in updateChart() }
        .onChange(of: chartModel.selectedTimeRange) { _, _ in hoveredPoint = nil }
    }

    private var header: some View {
        StockbarPageHeader(
            "Overview",
            subtitle: dataModel.isFolyncPortfolioActive ? "Read-only portfolio summary from \(source)." : "Your portfolio at a glance."
        ) {
            Picker("Time range", selection: Binding(
                get: { chartModel.selectedTimeRange },
                set: { range in
                    withAnimation(StockbarMotion.animation(StockbarMotion.quick, reduceMotion: reduceMotion)) {
                        chartModel.setTimeRange(range)
                    }
                }
            )) {
                ForEach(MenuChartTimeRange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            .help("Chart period")
        }
    }

    private var hero: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 36) {
                portfolioValue
                changeMetrics
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 18) {
                portfolioValue
                changeMetrics
            }
        }
    }

    private var changeMetrics: some View {
        HStack(alignment: .top, spacing: 30) {
            changeMetric("Today", amount: summary.dayGain, percent: summary.dayGainPct,
                         unavailableHint: "Waiting for today's prices")
            if chartModel.selectedTimeRange != .day {
                changeMetric("\(chartModel.selectedTimeRange.description) change",
                             amount: rangeChange?.value ?? .nan, percent: rangeChange?.percent ?? .nan,
                             unavailableHint: rangeChangeUnavailableHint)
                    .transition(.opacity)
            }
        }
    }

    private var portfolioValue: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Total value · \(summary.currency)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(HoldingsCurrencyFormatter.amount(summary.totalValue, currency: summary.currency))
                .font(.system(size: 42, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .stockbarRollingDigits()
                .animation(StockbarMotion.animation(StockbarMotion.standard, reduceMotion: reduceMotion), value: summary.totalValue)
                .fixedSize()
                .accessibilityLabel("Total portfolio value \(HoldingsCurrencyFormatter.amount(summary.totalValue, currency: summary.currency))")
        }
    }

    private func changeMetric(_ title: String, amount: Double, percent: Double, unavailableHint: String) -> some View {
        let isAvailable = amount.isFinite && percent.isFinite
        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if isAvailable {
                HStack(spacing: 8) {
                    Text(HoldingsCurrencyFormatter.signedAmount(amount, currency: summary.currency))
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(StockbarPalette.signed(amount, neutral: .primary))
                        .stockbarRollingDigits()
                    StockbarChangeBadge(percent: percent)
                }
            } else {
                Text("—")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .help(unavailableHint)
                Text(unavailableHint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            chart
                .frame(height: 280)
            if !chartModel.coverageLabel.isEmpty {
                Text(chartModel.coverageLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .stockbarCard()
    }

    private var chartTint: Color {
        StockbarPalette.signed(rangeChange?.value, neutral: .accentColor)
    }

    private var chartYDomain: ClosedRange<Double> {
        let values = chartModel.chartData.map(\.price).filter(\.isFinite)
        guard let minimum = values.min(), let maximum = values.max() else { return 0...1 }
        let padding = max((maximum - minimum) * 0.12, maximum * 0.002, 0.01)
        return (minimum - padding)...(maximum + padding)
    }

    /// Maps the chart's selected x position to the nearest stored point.
    private var hoverSelection: Binding<Date?> {
        Binding(
            get: { hoveredPoint?.date },
            set: { date in
                let data = chartModel.chartData
                let nearest = date
                    .flatMap { ChartSeriesProcessing.nearestIndex(in: data.map(\.date), to: $0) }
                    .map { data[$0] }
                if nearest?.id != hoveredPoint?.id { hoveredPoint = nearest }
            }
        )
    }

    @ViewBuilder private var chart: some View {
        if chartModel.isLoading && chartModel.chartData.count < 2 {
            ProgressView("Loading portfolio history…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if chartModel.chartData.count > 1 {
            let domain = chartYDomain
            Chart {
                ForEach(chartModel.chartData) { point in
                    AreaMark(
                        x: .value("Date", point.date),
                        yStart: .value(summary.currency, domain.lowerBound),
                        yEnd: .value(summary.currency, point.price)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(
                        colors: [chartTint.opacity(0.28), chartTint.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    LineMark(x: .value("Date", point.date), y: .value(summary.currency, point.price))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(chartTint)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                if let hoveredPoint {
                    RuleMark(x: .value("Date", hoveredPoint.date))
                        .foregroundStyle(Color.secondary.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, spacing: 4,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            chartCallout(for: hoveredPoint)
                        }
                    PointMark(x: .value("Date", hoveredPoint.date), y: .value(summary.currency, hoveredPoint.price))
                        .symbolSize(60)
                        .foregroundStyle(chartTint)
                }
            }
            .chartYScale(domain: domain)
            .chartXSelection(value: hoverSelection)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(HoldingsCurrencyFormatter.compactAmount(amount, currency: summary.currency))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    AxisValueLabel(format: chartModel.selectedTimeRange == .day
                                   ? .dateTime.hour().minute()
                                   : .dateTime.day().month(.abbreviated))
                }
            }
            .chartReveal(trigger: chartRevealKey)
            .accessibilityLabel("Portfolio value over \(chartModel.selectedTimeRange.description), in \(summary.currency)")
            .accessibilityValue(rangeChange.map { String(format: "%+.2f percent", $0.percent) } ?? "Change unavailable")
        } else {
            ContentUnavailableView(
                chartModel.selectedTimeRange == .day && summary.valuationSource == .folyncProvided
                    ? "Daily result from Folync" : "Not enough history yet",
                systemImage: "chart.xyaxis.line",
                description: Text(chartModel.selectedTimeRange == .day && summary.valuationSource == .folyncProvided
                                  ? "Folync has not supplied enough intraday history to draw a chart. Today's result uses its daily reference."
                                  : "The chart appears once Stockbar has stored at least two portfolio values for this period. Leave it running and history builds up.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Identifies a distinct data set so the chart only redraws in on real changes.
    private var chartRevealKey: String {
        "\(chartModel.selectedTimeRange.rawValue)-\(chartModel.chartData.count)-\(chartModel.chartData.first?.date.timeIntervalSince1970 ?? 0)"
    }

    private func chartCallout(for point: MenuChartDataPoint) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(HoldingsCurrencyFormatter.amount(point.price, currency: summary.currency))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
            Text(point.date, format: chartModel.selectedTimeRange == .day
                 ? .dateTime.hour().minute()
                 : .dateTime.day().month(.abbreviated).hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StockbarPalette.cardStroke))
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            StockbarSectionTitle(title: "Summary")
                .padding(.bottom, 4)
            StockbarDetailRow(label: "Portfolio value", value: HoldingsCurrencyFormatter.amount(summary.totalValue, currency: summary.currency))
            StockbarDetailRow(
                label: "Unrealised P&L",
                value: summary.totalGain.isFinite
                    ? "\(HoldingsCurrencyFormatter.signedAmount(summary.totalGain, currency: summary.currency)) (\(MenuPopoverFormatter.percent(summary.totalGainPct)))"
                    : "—",
                valueColor: StockbarPalette.signed(summary.totalGain, neutral: .primary)
            )
            StockbarDetailRow(label: "Cost basis", value: HoldingsCurrencyFormatter.amount(summary.totalCost, currency: summary.currency))
            let cash = dataModel.isFolyncPortfolioActive ? dataModel.folyncPortfolioSnapshot?.cash : nil
            StockbarDetailRow(label: "Positions", value: "\(summary.ownedPositionCount)", showsDivider: cash != nil)
            if let cash {
                StockbarDetailRow(
                    label: "Cash",
                    value: HoldingsCurrencyFormatter.amount(cash.value ?? .nan, currency: cash.currency ?? summary.currency),
                    showsDivider: false
                )
            }
        }
        .stockbarCard()
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Selected Position")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let trade = selectedHolding {
                Picker("Position", selection: Binding(
                    get: { selectedHolding?.trade.name ?? "" },
                    set: { symbol in
                        withAnimation(StockbarMotion.animation(StockbarMotion.quick, reduceMotion: reduceMotion)) {
                            selectedSymbol = symbol
                        }
                    }
                )) {
                    ForEach(holdings, id: \.trade.name) { Text($0.displayLabel ?? $0.trade.name).tag($0.trade.name) }
                }
                .labelsHidden()

                VStack(alignment: .leading, spacing: 2) {
                    Text(trade.displayLabel ?? trade.trade.name)
                        .font(.title3.weight(.semibold))
                    let name = trade.realTimeInfo.shortName
                    if !name.isEmpty && name != trade.trade.name {
                        Text(name).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                }

                VStack(spacing: 0) {
                    let value = dataModel.calculatePositionValue(for: trade)
                    StockbarDetailRow(label: "Market value", value: HoldingsCurrencyFormatter.amount(value.amount, currency: value.currency))
                    StockbarDetailRow(label: "Units", value: MenuPopoverFormatter.units(trade.trade.position.unitSize))
                    StockbarDetailRow(label: "Price", value: HoldingsCurrencyFormatter.amount(
                        trade.realTimeInfo.getCurrentDisplayPrice(), currency: trade.realTimeInfo.currency ?? ""
                    ))
                    // Formatted like the price above it, not as the raw text that was typed in.
                    StockbarDetailRow(label: "Average cost", value: HoldingsCurrencyFormatter.amount(
                        trade.trade.position.positionAvgCost,
                        currency: trade.trade.position.displayCostCurrency(for: trade.trade.name)
                    ))
                    let profit = dataModel.calculatePositionProfitLoss(for: trade)
                    StockbarDetailRow(
                        label: "Today",
                        value: HoldingsCurrencyFormatter.signedAmount(profit.dayAmount, currency: profit.currency),
                        valueColor: StockbarPalette.signed(profit.dayAmount, neutral: .primary)
                    )
                    StockbarDetailRow(
                        label: "Total P&L",
                        value: HoldingsCurrencyFormatter.signedAmount(profit.totalAmount, currency: profit.currency),
                        valueColor: StockbarPalette.signed(profit.totalAmount, neutral: .primary),
                        showsDivider: false
                    )
                    .help("Unrealised gain or loss against the average cost. Sales and dividends are not included.")
                }
                .id(trade.trade.name)
                .transition(.opacity)
            } else {
                Text("Add a holding or connect a portfolio to see position details.")
                    .foregroundStyle(.secondary)
            }
            Button { navigationState.selectedSection = .holdings } label: {
                Label("Open Holdings", systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)
            Button("View data health") { navigationState.selectedSection = .dataHealth }
                .buttonStyle(.link)
                .frame(maxWidth: .infinity)
        }
    }

    private func updateChart() {
        // Called from event handlers between renders, so don't reuse the last render's summary.
        summaryCache.beginPass()
        chartModel.update(currentValue: summary.totalValue, currentTrades: dataModel.realTimeTrades,
                          preferredCurrency: summary.currency, valuationSource: summary.valuationSource)
    }
}
