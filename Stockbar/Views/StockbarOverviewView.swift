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
    /// "Next up", from saved data only: opening the Overview asks nothing.
    @State private var nextUp = StockbarNextUpModel()
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
    private var rangeChangeUnavailableHint: String {
        Self.rangeChangeUnavailableHint(
            source: summary.valuationSource, isLoading: chartModel.isLoading,
            unreachable: chartModel.folyncUnreachable, stale: chartModel.folyncStale,
            pointCount: chartModel.chartData.count, hasCoverage: chartModel.hasRangeCoverage
        )
    }
    private var rangeChange: PortfolioMenuRangeChange? {
        PortfolioMenuPerformanceResolver.resolve(
            summary: summary, range: chartModel.selectedTimeRange,
            chartChange: chartModel.hasRangeCoverage && chartModel.chartData.count > 1
                ? PortfolioMenuChartDataBuilder.rangeChange(for: chartModel.chartData) : nil
        )
    }

    /// The composition card's figures, or nil when the card is not shown.
    private var composition: PortfolioTotalComposition? {
        PortfolioTotalComposition.overview(
            summary: summary,
            snapshot: dataModel.folyncPortfolioSnapshot,
            netDeposits: dataModel.folyncNetDeposits
        )
    }
    private var notice: String? {
        Self.unreachableNotice(
            state: dataModel.folyncConnectionState,
            hasSnapshot: dataModel.folyncPortfolioSnapshot != nil,
            failureCategory: dataModel.folyncLastPollFailureCategory,
            savedAt: savedFiguresDate
        )
    }
    /// When the figures on screen were last known good: Folync's last answer,
    /// or the time the saved snapshot was generated.
    private var savedFiguresDate: Date? {
        let generated = dataModel.folyncPortfolioSnapshot.flatMap { FolyncSupplementalDateParser.instant($0.generatedAt) }
        return [dataModel.folyncLastCheckedAt, generated].compactMap { $0 }.max()
    }

    var body: some View {
        let _ = summaryCache.beginPass()
        GeometryReader { geometry in
            let showsSideInspector = geometry.size.width >= 1000
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: StockbarLayout.sectionSpacing) {
                        header
                        if let notice {
                            StockbarNotice(message: notice, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                                .accessibilityAddTraits(.isStaticText)
                        }
                        hero
                        chartCard
                        if let composition {
                            compositionCard(composition)
                        } else {
                            summaryCard
                        }
                        if !nextUp.rows.isEmpty {
                            StockbarNextUpCards(rows: nextUp.rows, today: nextUp.today)
                        }
                        if !showsSideInspector {
                            inspector.stockbarCard()
                        }
                    }
                    .padding(StockbarLayout.pageInsets)
                }
                if showsSideInspector {
                    // The inspector is a card in its own column.
                    ScrollView {
                        inspector
                            .stockbarCard(padding: 18)
                            .padding(.top, StockbarLayout.pageInsets.top)
                            .padding(.trailing, 20)
                            .padding(.bottom, StockbarLayout.pagePadding)
                    }
                    .scrollIndicators(.never)
                    .frame(width: 290)
                }
            }
        }
        .onAppear { updateChart(); chartModel.activate(); reloadNextUp() }
        .onDisappear { chartModel.deactivate() }
        .onReceive(dataModel.tradeContentPublisher) { _ in updateChart(); reloadNextUp() }
        .onChange(of: summary.totalValue) { _, _ in updateChart() }
        .onChange(of: summary.currency) { _, _ in updateChart() }
        .onChange(of: summary.valuationSource) { _, _ in updateChart() }
        .onChange(of: chartModel.selectedTimeRange) { _, _ in hoveredPoint = nil }
    }

    /// Reads "Next up" again from what is saved. Makes no request.
    private func reloadNextUp() {
        let target = dataModel.preferredCurrency
        let converter = dataModel.currencyConverter
        nextUp.reload(.current(dataModel), currency: target) { amount, from in
            converter.convertWithLoadedRates(amount: amount, from: from, to: target)
        }
    }

    private var offeredRanges: [MenuChartTimeRange] { Self.offeredRanges(for: summary.valuationSource) }

    private var header: some View {
        StockbarPageHeader(
            "Overview",
            subtitle: dataModel.isFolyncPortfolioActive ? "\(source) portfolio, read-only" : "Your portfolio at a glance."
        ) {
            // The switch animates the change itself, and not under Reduce Motion.
            StockbarSegmentedControl(
                "Time range",
                selection: Binding(
                    get: { chartModel.selectedTimeRange },
                    set: { chartModel.setTimeRange($0) }
                ),
                options: offeredRanges
            ) { $0.rawValue }
            .fixedSize()
            .help("Chart period")
        }
    }

    private var hero: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 24) {
                portfolioValue
                Spacer(minLength: 0)
                changeRows
            }
            VStack(alignment: .leading, spacing: 14) {
                portfolioValue
                changeRows
            }
        }
    }

    /// Today's change and the selected range's, stacked: label, amount, badge.
    private var changeRows: some View {
        Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 8) {
            changeRow("Today", amount: summary.dayGain, percent: summary.dayGainPct,
                      unavailableHint: "Waiting for today's prices")
            if chartModel.selectedTimeRange != .day {
                changeRow(Self.rangeTitle(chartModel.selectedTimeRange),
                          amount: rangeChange?.value ?? .nan, percent: rangeChange?.percent ?? .nan,
                          unavailableHint: rangeChangeUnavailableHint)
            }
        }
        .fixedSize()
        .padding(.bottom, 6)
    }

    private func changeRow(_ title: String, amount: Double, percent: Double, unavailableHint: String) -> some View {
        let isAvailable = amount.isFinite
        return GridRow {
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
                .accessibilityHidden(true)
            VStack(alignment: .trailing, spacing: 2) {
                Text(isAvailable ? HoldingsCurrencyFormatter.signedAmount(amount, currency: summary.currency) : Self.unknownFigure)
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isAvailable ? StockbarPalette.signedOnSurface(amount, neutral: .primary) : .secondary)
                    .stockbarRollingDigits()
                if !isAvailable {
                    Text(unavailableHint)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .help(isAvailable ? "" : unavailableHint)
            // A grid row is not one element: the amount carries the row's name.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isAvailable
                ? "\(title), \(HoldingsCurrencyFormatter.signedAmount(amount, currency: summary.currency))"
                : "\(title), unknown, \(unavailableHint)")
            StockbarChangeBadge(percent: isAvailable ? percent : nil, onSurface: true)
        }
    }

    private var portfolioValue: some View {
        let total = HoldingsCurrencyFormatter.amount(PortfolioTotalComposition.displayed(summary.totalValue), currency: summary.currency)
        return VStack(alignment: .leading, spacing: 2) {
            Text(Self.totalValueTitle(currency: summary.currency, savedAt: notice == nil ? nil : savedFiguresDate))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            StockbarHeroFigure(text: total, size: 52)
                .stockbarRollingDigits()
                .animation(StockbarMotion.animation(StockbarMotion.standard, reduceMotion: reduceMotion), value: summary.totalValue)
                .fixedSize()
                .accessibilityLabel("Total portfolio value \(total)")
        }
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The chart's key: the portfolio's line only. The coverage note sits on the right.
            HStack(spacing: 8) {
                Capsule().fill(chartTint).frame(width: 18, height: 3)
                    .accessibilityHidden(true)
                Text("Your portfolio")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                if !chartModel.coverageLabel.isEmpty {
                    Text(chartModel.coverageLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
            chart
                .frame(height: 260)
        }
        .stockbarCard(padding: 16)
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
            // Room for the last "Nov 2026" label inside the plot.
            .chartXScale(range: .plotDimension(endPadding: chartModel.selectedTimeRange == .all ? 28 : 0))
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
                    AxisValueLabel(format: Self.axisDateFormat(chartModel.selectedTimeRange))
                }
            }
            .chartReveal(trigger: chartRevealKey)
            .accessibilityLabel("Portfolio value over \(chartModel.selectedTimeRange.description), in \(summary.currency)")
            .accessibilityValue(rangeChange.map { String(format: "%+.2f percent", $0.percent) } ?? "Change unavailable")
        } else if summary.valuationSource == .folyncProvided && chartModel.folyncUnreachable {
            ContentUnavailableView(
                "Couldn't reach Folync",
                systemImage: "wifi.exclamationmark",
                description: Text("Folync didn't answer, and nothing is saved for this period yet. The chart appears once Folync answers.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Text(MenuPopoverFormatter.date(point.date, range: chartModel.selectedTimeRange))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .stockbarCallout()
    }

    /// "+£1,234.00 (5.20%)", or the amount alone when there is no percentage.
    private static func amountWithPercent(_ amount: Double, percent: Double, currency: String) -> String {
        let signed = HoldingsCurrencyFormatter.signedAmount(amount, currency: currency)
        let percentText = MenuPopoverFormatter.percent(percent)
        return percentText.isEmpty ? signed : "\(signed) (\(percentText))"
    }

    private func compositionCard(_ composition: PortfolioTotalComposition) -> some View {
        StockbarOverviewCompositionCard(
            composition: composition,
            returnText: Self.compositionReturnText(
                composition, totalReturn: summary.totalReturn(measuredAgainst: dataModel.portfolioGainBasis)
            ),
            footnote: Self.compositionFootnote(
                cash: dataModel.folyncPortfolioSnapshot?.cash, positions: summary.ownedPositionCount,
                currency: composition.currency
            )
        )
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            StockbarSectionTitle(title: "Summary")
                .padding(.bottom, 4)
            StockbarDetailRow(label: "Portfolio value", value: HoldingsCurrencyFormatter.amount(summary.totalValue, currency: summary.currency))
            let totalReturn = summary.totalReturn(measuredAgainst: dataModel.portfolioGainBasis)
            if totalReturn.isMeasuredAgainstNetDeposits {
                StockbarDetailRow(
                    label: "Total P&L",
                    value: totalReturn.gain.isFinite
                        ? Self.amountWithPercent(totalReturn.gain, percent: totalReturn.percent, currency: summary.currency)
                        : "—",
                    valueColor: StockbarPalette.signedOnSurface(totalReturn.gain, neutral: .primary)
                )
                .help("Portfolio value, cash included, less net deposits. Sales, dividends, interest and fees all count.")
                StockbarDetailRow(label: "Net deposits", value: HoldingsCurrencyFormatter.amount(totalReturn.basisAmount, currency: summary.currency))
                    .help("Money paid in less money taken out, from Folync.")
            }
            StockbarDetailRow(
                label: "Unrealised P&L",
                value: summary.totalGain.isFinite
                    ? "\(HoldingsCurrencyFormatter.signedAmount(summary.totalGain, currency: summary.currency)) (\(MenuPopoverFormatter.percent(summary.totalGainPct)))"
                    : "—",
                valueColor: StockbarPalette.signedOnSurface(summary.totalGain, neutral: .primary)
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
                        valueColor: StockbarPalette.signedOnSurface(profit.dayAmount, neutral: .primary)
                    )
                    StockbarDetailRow(
                        label: "Total P&L",
                        value: HoldingsCurrencyFormatter.signedAmount(profit.totalAmount, currency: profit.currency),
                        valueColor: StockbarPalette.signedOnSurface(profit.totalAmount, neutral: .primary),
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

    // MARK: - What the page says

    /// An unknown figure.
    static let unknownFigure = "–"
    static let positivePartsNote = "The bar shows the positive parts only."

    /// The ranges the graph can draw for a portfolio source, in the switch's
    /// order. Folync's history route serves every one of them (it has no
    /// year-to-date range), and so does Stockbar's own store of portfolio
    /// values for a local or Trading 212 portfolio.
    static func offeredRanges(for source: PortfolioValuationSource) -> [MenuChartTimeRange] {
        switch source {
        case .folyncProvided, .brokerProvided, .localCalculationFallback, .marketDataFallback:
            [.day, .week, .month, .threeMonths, .year, .all]
        }
    }

    /// "1 week", "3 months", "all time".
    static func rangeTitle(_ range: MenuChartTimeRange) -> String {
        range.description.lowercased()
    }

    /// Why the range's change is not shown. Folync can return a full chart and
    /// still mark the period partial (carried or stale prices); the change is
    /// then withheld, and more local history would not bring it back.
    static func rangeChangeUnavailableHint(source: PortfolioValuationSource, isLoading: Bool,
                                           unreachable: Bool, stale: Bool, pointCount: Int,
                                           hasCoverage: Bool = false) -> String {
        guard source == .folyncProvided else { return "Needs more stored history" }
        if isLoading { return "Checking Folync" }
        if unreachable { return "Couldn't reach Folync" }
        if stale { return "No current history from Folync" }
        guard pointCount > 1 else { return "Needs more stored history" }
        // A full period whose first value is zero: there is nothing to measure from.
        return hasCoverage ? "No starting value for this period" : "Folync marks this period partial"
    }

    static func axisDateFormat(_ range: MenuChartTimeRange) -> Date.FormatStyle {
        switch range {
        case .day: .dateTime.hour().minute()
        case .week, .month, .threeMonths: .dateTime.day().month(.abbreviated)
        // A year back from today needs no year; "All" can span several.
        case .year: .dateTime.month(.abbreviated)
        case .all: .dateTime.month(.abbreviated).year()
        }
    }

    /// The amber bar's text while Folync is not answering and saved figures are
    /// shown, or nil. Uses the connection state the app already keeps.
    static func unreachableNotice(state: FolyncConnectionState, hasSnapshot: Bool, failureCategory: String?,
                                  savedAt: Date?, now: Date = Date(),
                                  locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        guard hasSnapshot, case .offlineCached = state else { return nil }
        // Any failed check with a snapshot on screen is `.offlineCached`: only
        // a connection failure is called unreachable.
        let unreachable = failureCategory.map(FolyncSupplementalCoordinator.isUnreachable(category:)) ?? false
        let lead = unreachable ? "Couldn't reach Folync." : "Folync didn't send new figures."
        guard let savedAt else { return "\(lead) Showing the figures saved earlier." }
        return "\(lead) Showing the figures saved \(savedTime(savedAt, now: now, locale: locale, timeZone: timeZone))."
    }

    /// "at 14:10" today, "on 19 Nov at 14:10" otherwise.
    static func savedTime(_ date: Date, now: Date, locale: Locale, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar)
        time.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) { return "at \(date.formatted(time))" }
        var day = Date.FormatStyle(locale: locale, calendar: calendar).day().month(.abbreviated)
        day.timeZone = timeZone
        return "on \(date.formatted(day)) at \(date.formatted(time))"
    }

    /// "Total value, GBP", and ", as of 14:10" while saved figures are shown.
    static func totalValueTitle(currency: String, savedAt: Date?, now: Date = Date(),
                                locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        guard let savedAt else { return "Total value, \(currency)" }
        let time = savedTime(savedAt, now: now, locale: locale, timeZone: timeZone)
        // "at 14:10" or "on 19 Nov at 14:10", without its first word.
        return "Total value, \(currency), as of \(time.drop { $0 != " " }.dropFirst())"
    }

    static func compositionHeading(_ composition: PortfolioTotalComposition) -> String {
        "What \(HoldingsCurrencyFormatter.amount(composition.total, currency: composition.currency)) is made of"
    }

    /// "total return +£15,902.11 (+23.25%)": the total less net deposits, from the
    /// figures the card shows. Against cost, the P&L Stockbar shows elsewhere.
    static func compositionReturnText(_ composition: PortfolioTotalComposition, totalReturn: PortfolioTotalReturn) -> String {
        guard totalReturn.isMeasuredAgainstNetDeposits else {
            guard totalReturn.gain.isFinite else { return "" }
            return "P&L against cost \(amountWithPercent(totalReturn.gain, percent: totalReturn.percent, currency: composition.currency))"
        }
        return "total return \(amountWithPercent(composition.gainOnDeposits, percent: totalReturn.percent, currency: composition.currency))"
    }

    /// Net deposits as an amount; the gains and the remainder signed.
    static func legendFigure(_ part: PortfolioTotalComposition.Part, currency: String) -> String {
        part.kind == .netDeposits
            ? HoldingsCurrencyFormatter.amount(part.amount, currency: currency)
            : HoldingsCurrencyFormatter.signedAmount(part.amount, currency: currency)
    }

    /// "Net deposits, £68,408.36"; "Realised gains, minus £120.00, partial".
    static func accessibilityLabel(_ part: PortfolioTotalComposition.Part, currency: String) -> String {
        let magnitude = HoldingsCurrencyFormatter.amount(abs(part.amount), currency: currency)
        return "\(part.kind.title), \(part.minorUnits < 0 ? "minus " : "")\(magnitude)\(part.isPartial ? ", partial" : "")"
    }

    /// "Cash £2,940.18 · 9 positions". Cash keeps the currency Folync gives it in.
    static func compositionFootnote(cash: FolyncFinancialMetric?, positions: Int, currency: String) -> String {
        var items: [String] = []
        if let cash {
            items.append("Cash " + (cash.value.map { HoldingsCurrencyFormatter.amount($0, currency: cash.currency ?? currency) } ?? unknownFigure))
        }
        items.append(positions == 1 ? "1 position" : "\(positions) positions")
        return items.joined(separator: " · ")
    }
}

/// "What £84,310.47 is made of": the heading with the total return, the bar,
/// and each part's figure. Built from values only, so it can be hosted alone.
struct StockbarOverviewCompositionCard: View {
    let composition: PortfolioTotalComposition
    /// "total return +£15,902.11 (+23.25%)", or empty.
    let returnText: String
    /// "Cash £2,940.18 · 9 positions".
    let footnote: String

    /// What VoiceOver reads, in order: the heading (with the total return),
    /// then one label per part. The bar itself is decorative and hidden.
    struct Exposure: Equatable {
        let heading: String
        let parts: [String]
    }

    static func accessibility(_ composition: PortfolioTotalComposition, returnText: String) -> Exposure {
        let heading = StockbarOverviewView.compositionHeading(composition)
        return Exposure(
            heading: returnText.isEmpty ? heading : "\(heading), \(returnText)",
            parts: composition.parts.map { StockbarOverviewView.accessibilityLabel($0, currency: composition.currency) }
        )
    }

    var body: some View {
        let heading = StockbarOverviewView.compositionHeading(composition)
        let exposure = Self.accessibility(composition, returnText: returnText)
        VStack(alignment: .leading, spacing: 14) {
            Group {
                if returnText.isEmpty {
                    Text(heading).fontWeight(.semibold)
                } else {
                    Text("\(Text(heading).fontWeight(.semibold))\(Text(" · \(returnText)").foregroundStyle(.secondary))")
                }
            }
            .font(.system(size: 16))
            .monospacedDigit()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(exposure.heading)
            .accessibilityAddTraits(.isHeader)
            StockbarCompositionBar(composition: composition)
            if composition.barShowsPositivePartsOnly {
                Text(StockbarOverviewView.positivePartsNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { legend(0..<4, exposure) }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow { legend(0..<2, exposure) }
                    GridRow { legend(2..<4, exposure) }
                }
            }
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .stockbarCard()
    }

    private func legend(_ indices: Range<Int>, _ exposure: Exposure) -> some View {
        ForEach(indices, id: \.self) { index in
            let part = composition.parts[index]
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(StockbarPalette.compositionFill(part.kind))
                        .frame(width: 9, height: 9)
                    Text(part.kind.title)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(StockbarOverviewView.legendFigure(part, currency: composition.currency))
                    .font(.system(size: 17, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(part.minorUnits < 0 ? StockbarPalette.loss : Color.primary)
                    .stockbarRollingDigits()
                if part.isPartial {
                    Text("Partial")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(exposure.parts[index])
            .accessibilityAddTraits(.isStaticText)
        }
    }
}

// The states the acceptance copy cannot show while its stand-in answers.
// Invented figures.
#Preview("Notice and a negative part") {
    VStack(alignment: .leading, spacing: StockbarLayout.sectionSpacing) {
        StockbarNotice(message: "Couldn't reach Folync. Showing the figures saved at 14:10.")
        if let composition = PortfolioTotalComposition(
            currency: "GBP",
            total: .init(value: 84_310.47, currency: "GBP"),
            netDeposits: .init(value: 68_408.36, currency: "GBP"),
            unrealised: .init(value: 16_122.11, currency: "GBP"),
            realised: .init(value: -1_611.86, currency: "GBP", isPartial: true)
        ) {
            StockbarOverviewCompositionCard(
                composition: composition,
                returnText: "total return +£15,902.11 (+23.25%)",
                footnote: "Cash £2,940.18 · 9 positions"
            )
        }
    }
    .padding(28)
    .frame(width: 900)
}
