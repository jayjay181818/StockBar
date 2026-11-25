//
//  PortfolioAnalyticsView.swift
//  Stockbar
//
//  Created by Claude Code on 2025-10-03.
//  Allocation: a donut by sector, holding or currency, diversification, the correlation grid and attribution
//

import SwiftUI
import Charts

struct PortfolioAnalyticsView: View {
    let dataModel: DataModel

    @State private var selectedTimeRange: TimeRange = .threeMonths
    @State private var isLoading = false
    @State private var correlationMatrix: CorrelationMatrixService.CorrelationMatrix?
    @State private var diversificationMetrics: CorrelationMatrixService.DiversificationMetrics?
    @State private var sectorAllocations: [SectorAnalysisService.SectorAllocation] = []
    @State private var diversificationAnalysis: SectorAnalysisService.DiversificationAnalysis?
    @State private var topCorrelations: [CorrelationMatrixService.CorrelationPair] = []
    /// Holdings left out of the correlation for too little shared history.
    @State private var correlationExcluded: [String] = []
    @State private var bottomCorrelations: [CorrelationMatrixService.CorrelationPair] = []
    @State private var showAttributionSheet = false
    @State private var analyticsCurrency = "USD"
    @State private var analyticsCoverage = 0
    /// Holdings that should have been valued; more than `analyticsCoverage`
    /// when a price or exchange rate is missing.
    @State private var analyticsEligible = 0
    @State private var completeDayCoverage = false
    @State private var analyticsRevision = 0
    /// Bumped by portfolio updates; the debounced `.task(id:)` below reacts to it.
    @State private var portfolioUpdateTick = 0
    /// True once a calculation has produced results, so later recalculations keep them visible.
    @State private var hasLoadedOnce = false
    /// The donut's view: by sector, by holding or by currency.
    @State private var grouping: AllocationGrouping = .sector
    /// Each valued holding with the currency it is priced in, for the currency view.
    @State private var valuedHoldings: [AllocationHolding] = []
    /// The cash in Holdings' total, in the display currency, from the same calculation run.
    @State private var cash: AllocationCash = .none
    /// With a Cash row, Holdings' own total in the display currency, which every share is of.
    @State private var sourceTotal: Double?
    /// Why cash the source gives is left out of the shares, when it is.
    @State private var cashOmission: AllocationCashOmission?
    /// Slice colours for holdings and currencies, kept while the page is open.
    @State private var holdingColours = AllocationColourBook(paletteCount: StockbarPalette.allocationSlices.count)
    @State private var currencyColours = AllocationColourBook(paletteCount: StockbarPalette.allocationSlices.count)

    private let correlationService = CorrelationMatrixService()
    private let sectorService = SectorAnalysisService()

    enum TimeRange: String, CaseIterable {
        case oneMonth = "1M"
        case threeMonths = "3M"
        case sixMonths = "6M"
        case oneYear = "1Y"
        case all = "All"

        var days: Int {
            switch self {
            case .oneMonth: return 30
            case .threeMonths: return 90
            case .sixMonths: return 180
            case .oneYear: return 365
            case .all: return Int.max
            }
        }

        /// Calendar days of price history used for correlation. Never shorter than the
        /// minimum needed for `minimumCorrelationDays` trading days; "All" is bounded.
        var correlationLookbackDays: Int {
            switch self {
            case .all: return 5 * 365
            default: return max(days, PortfolioAnalyticsView.minimumLookbackCalendarDays)
            }
        }
    }

    /// 20 trading days need about a month of calendar history.
    nonisolated static let minimumLookbackCalendarDays = 30

    /// What the calculation depends on. Exchange rates are part of it, so holdings and cash
    /// left out for want of a rate appear as soon as the rates load.
    struct AnalyticsTrigger: Hashable {
        let range: TimeRange
        let currency: String
        let tick: Int
        let ratesLoadedAt: Date
        let rates: [String: Double]

        @MainActor
        init(range: TimeRange, currency: String, tick: Int, converter: CurrencyConverter) {
            self.range = range
            self.currency = currency
            self.tick = tick
            ratesLoadedAt = converter.lastRefreshTime
            rates = converter.exchangeRates
        }
    }

    /// Something to show: a holding to value, or cash on its own.
    private var hasAllocationContent: Bool {
        AllocationPresentation.hasContent(eligibleHoldings: analyticsEligible, cash: cash)
    }

    private var shareBasis: AllocationShareBasis {
        AllocationShareBasis(cash: cash, omission: cashOmission)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StockbarLayout.sectionSpacing) {
                headerSection

                if !hasLoadedOnce {
                    ProgressView("Calculating portfolio analytics...")
                        .stockbarEmptyState(minHeight: 180)
                } else if !hasAllocationContent {
                    emptyStateView
                } else {
                    allocationSection.stockbarCard()
                    diversificationSection.stockbarCard()
                    correlationSection.stockbarCard()
                    attributionAnalysisSection.stockbarCard()
                }
            }
            .padding(StockbarLayout.pageInsets)
        }
        .sheet(isPresented: $showAttributionSheet) {
            AttributionAnalysisView(dataModel: dataModel)
                .padding(.top, 16)
                .frame(minWidth: 720, idealWidth: 860, minHeight: 560, idealHeight: 680)
        }
        // One task for every trigger. SwiftUI cancels the previous run when the id changes, and the
        // sleep debounces bursts of price updates. The first calculation runs immediately, and
        // earlier results stay on screen while a recalculation is in flight. The donut's view
        // switch is not a trigger: it only regroups figures already worked out.
        .task(id: AnalyticsTrigger(range: selectedTimeRange, currency: dataModel.preferredCurrency,
                                   tick: portfolioUpdateTick, converter: dataModel.currencyConverter)) {
            if hasLoadedOnce {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            await calculateAnalytics()
        }
        .onChange(of: dataModel.realTimeTradesRevision) { _, _ in
            portfolioUpdateTick += 1
        }
        .onChange(of: dataModel.folyncPortfolioSnapshot) { _, _ in
            portfolioUpdateTick += 1
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        StockbarPageHeader("Allocation", subtitle: "Where the money is") {
            StockbarSegmentedControl("Group by", selection: $grouping, options: AllocationGrouping.allCases,
                                     expands: true) { $0.rawValue }
            .frame(width: 280)
            .help("Group the allocation by sector, by holding or by the currency each holding is priced in")
        }
    }

    // MARK: - Allocation donut and list

    /// The groups for the chosen view: at most eight, then a Cash row when cash is held.
    private var displayedGroups: [AllocationGroup] {
        let groups: [AllocationGroup]
        switch grouping {
        case .sector:
            groups = AllocationPresentation.sectorGroups(sectorAllocations, showsDayChange: completeDayCoverage)
        case .holding:
            groups = AllocationPresentation.holdingGroups(sectorAllocations)
        case .currency:
            groups = AllocationPresentation.currencyGroups(valuedHoldings)
        }
        return AllocationPresentation.displayed(groups, cash: cash, sourceTotal: sourceTotal)
    }

    private var allocationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(grouping.rawValue) Allocation")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if sectorAllocations.isEmpty && cash.heldAmount <= 0 {
                Text(analyticsEligible > 0
                     ? "Sector allocation needs a price and exchange rate for at least one holding."
                     : "No sector data available")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                if analyticsCoverage < analyticsEligible {
                    Label(
                        AllocationPresentation.coverageNotice(covered: analyticsCoverage, eligible: analyticsEligible,
                                                              leavesOutCash: cashOmission == .partialCoverage),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                let groups = displayedGroups
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 28) {
                        donut(groups)
                        allocationList(groups)
                            .frame(minWidth: 420, maxWidth: 620)
                    }
                    VStack(alignment: .center, spacing: 16) {
                        donut(groups)
                        allocationList(groups)
                    }
                }

                if let line = AllocationPresentation.borrowingLine(cash, currency: analyticsCurrency)
                    ?? AllocationPresentation.omissionLine(cashOmission) {
                    Text(line)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Shown when the holdings were all valued, as before; its figure is the
                // Unclassified row's share of the same total as the rows.
                if grouping == .sector, diversificationAnalysis != nil,
                   let unclassified = AllocationPresentation.unclassifiedShare(sectorAllocations, cash: cash,
                                                                               sourceTotal: sourceTotal) {
                    Text(AllocationPresentation.unclassifiedNote(share: unclassified, basis: shareBasis))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func donut(_ groups: [AllocationGroup]) -> some View {
        let holdingCount = sectorAllocations.reduce(0) { $0 + $1.positions.count }
        let holdingsTotal = sectorAllocations.reduce(0) { $0 + $1.totalValue }
        let total = AllocationPresentation.shareTotal(holdingsTotal: holdingsTotal, cash: cash, sourceTotal: sourceTotal)
        let centre = AllocationPresentation.centreText(total: total, holdingCount: holdingCount,
                                                       currency: analyticsCurrency, includesCash: cash.heldAmount > 0)
        return ZStack {
            Chart(groups) { group in
                SectorMark(
                    angle: .value("Value", group.value),
                    innerRadius: .ratio(0.62),
                    angularInset: 1.5
                )
                .foregroundStyle(colour(for: group))
            }
            .chartLegend(.hidden)
            VStack(spacing: 2) {
                Text(centre.total)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(centre.count)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 110)
        }
        .frame(width: 210, height: 210)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(grouping.rawValue) allocation, \(centre.total), \(centre.count)")
        .accessibilityValue(groups
            .map { "\(AllocationPresentation.rowLabel($0, grouping: grouping)) \(String(format: "%.1f", $0.share)) percent" }
            .joined(separator: ", "))
    }

    private func allocationList(_ groups: [AllocationGroup]) -> some View {
        VStack(spacing: 2) {
            ForEach(groups) { group in
                HStack(spacing: 10) {
                    Circle()
                        .fill(colour(for: group))
                        .frame(width: 10, height: 10)
                    Text(AllocationPresentation.rowLabel(group, grouping: grouping))
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(HoldingsCurrencyFormatter.amount(group.value, currency: analyticsCurrency))
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                    Text(AllocationPresentation.shareText(group.share))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 54, alignment: .trailing)
                    if grouping == .sector {
                        // Unknown day change is a dash in a neutral colour, never green.
                        Text(AllocationPresentation.dayChangeText(group))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundColor(StockbarPalette.signedOnSurface(group.dayChangePercent))
                            .frame(width: 64, alignment: .trailing)
                    }
                }
                .padding(.vertical, 5)
                .modifier(AllocationRowTooltip(text: group.isCash
                    ? AllocationPresentation.cashTooltip(group, currency: analyticsCurrency) : nil))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(AllocationPresentation.spokenRow(group, grouping: grouping, currency: analyticsCurrency))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func colour(for group: AllocationGroup) -> Color {
        if group.isCash { return StockbarPalette.allocationCash }
        if group.isOther { return StockbarPalette.allocationOther }
        switch grouping {
        case .sector:
            return SectorAnalysisService.Sector(rawValue: group.key).map(Self.colorForSector) ?? StockbarPalette.allocationOther
        case .holding:
            return paletteColour(holdingColours.index(for: group.key))
        case .currency:
            return paletteColour(currencyColours.index(for: group.key))
        }
    }

    private func paletteColour(_ index: Int?) -> Color {
        guard let index else { return StockbarPalette.allocationOther }
        let palette = StockbarPalette.allocationSlices
        return palette[index % palette.count]
    }

    // MARK: - Diversification

    private var diversificationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diversification")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if cash.heldAmount > 0 {
                Text(AllocationPresentation.holdingsOnlyCaption)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let analysis = diversificationAnalysis, analysis.isAvailable {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Diversification Score")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text(AllocationPresentation.scoreText(analysis.score))
                            .font(.title2)
                            .fontWeight(.bold)
                            .monospacedDigit()
                            .foregroundColor(colorForDiversificationScore(analysis.score))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Concentration Risk")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text(analysis.concentrationRisk.rawValue)
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(colorForRiskLevel(analysis.concentrationRisk))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
                .fixedSize(horizontal: false, vertical: true)

                if analysis.unclassifiedPercentage > 0 {
                    Text(AllocationPresentation.diversificationUnclassifiedNote(
                        share: analysis.unclassifiedPercentage, basis: shareBasis))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if !analysis.recommendations.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(analysis.recommendations, id: \.self) { recommendation in
                            Text(recommendation)
                                .font(.callout)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else if let analysis = diversificationAnalysis, analysis.unclassifiedPercentage > 0 {
                Text(AllocationPresentation.diversificationUnavailableNote(
                    share: analysis.unclassifiedPercentage, basis: shareBasis))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text(analyticsCoverage == 0 ? "No valued positions available" : "Diversification unavailable: some prices or exchange rates are missing")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Correlation

    private var correlationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    correlationHeading
                    Spacer(minLength: 12)
                    rangeControl
                }
                VStack(alignment: .leading, spacing: 8) {
                    correlationHeading
                    rangeControl
                }
            }

            if let matrix = correlationMatrix {
                Text("Calculated across \(matrix.symbols.count) holdings")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Based on the last \(selectedTimeRange.correlationLookbackDays) days of shared price history.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if !correlationExcluded.isEmpty {
                    Text("Left out for having too little shared price history: \(correlationExcluded.joined(separator: ", ")).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                let symbols = AllocationPresentation.gridSymbols(matrix.symbols, values: holdingValues)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        CorrelationGridView(matrix: matrix, symbols: symbols)
                        if let metrics = diversificationMetrics {
                            VStack(spacing: 10) { correlationMetrics(metrics) }
                                .frame(width: 190)
                        }
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        CorrelationGridView(matrix: matrix, symbols: symbols)
                        if let metrics = diversificationMetrics {
                            HStack(spacing: 12) { correlationMetrics(metrics) }
                        }
                    }
                }

                if let note = AllocationPresentation.gridNote(totalHoldings: matrix.symbols.count) {
                    Text(note)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let line = AllocationPresentation.pairsLine(top: topCorrelations, bottom: bottomCorrelations) {
                    Text(line)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Past the grid's limit, some listed pairs involve holdings the grid leaves out.
                if matrix.symbols.count > AllocationPresentation.maximumGridHoldings {
                    correlationPairLists
                }
            } else {
                Text("Not enough shared price history. Correlation needs at least \(Self.minimumCorrelationDays) common trading days for two or more holdings.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var correlationHeading: some View {
        Text("How the holdings move together")
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }

    private var rangeControl: some View {
        StockbarSegmentedControl("Time range", selection: $selectedTimeRange, options: TimeRange.allCases,
                                 expands: true) { $0.rawValue }
        .frame(width: 250)
        .help("Price history window used for the correlation analysis")
    }

    /// Each holding's value in the display currency, to pick the grid's largest holdings.
    private var holdingValues: [String: Double] {
        Dictionary(sectorAllocations.flatMap(\.positions).map { ($0.symbol, $0.value) },
                   uniquingKeysWith: +)
    }

    @ViewBuilder
    private func correlationMetrics(_ metrics: CorrelationMatrixService.DiversificationMetrics) -> some View {
        metricCard(
            title: "Avg Correlation",
            value: String(format: "%.3f", metrics.averageCorrelation),
            subtitle: interpretCorrelation(metrics.averageCorrelation)
        )
        metricCard(
            title: "Effective N",
            value: String(format: "%.1f", metrics.effectiveN),
            subtitle: "Independent positions"
        )
        metricCard(
            title: "Diversification Ratio",
            value: String(format: "%.2f", metrics.diversificationRatio),
            subtitle: metrics.diversificationRatio > 1 ? "Good" : "Needs work"
        )
    }

    /// The two pair lists, shown only when the grid cannot hold every holding.
    private var correlationPairLists: some View {
        HStack(alignment: .top, spacing: 20) {
            pairList("Highest Correlations (Risk)", pairs: topCorrelations)
            pairList("Lowest Correlations (Diversification)", pairs: bottomCorrelations)
        }
    }

    private func pairList(_ title: String, pairs: [CorrelationMatrixService.CorrelationPair]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
            if pairs.isEmpty {
                Text("No data")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(pairs) { pair in
                    HStack {
                        Text("\(pair.symbol1) ↔ \(pair.symbol2)")
                            .font(.caption)
                        Spacer()
                        Text("\(pair.correlation, specifier: "%.3f")")
                            .font(.caption)
                            .fontWeight(.medium)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .stockbarSurface(.inset, cornerRadius: 4)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.pie")
                .accessibilityHidden(true)
                .font(.system(size: 60))
                .foregroundColor(.gray)

            Text("Portfolio Analytics Unavailable")
                .font(.headline)

            Text("Add a holding to your portfolio to see how it is allocated")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .padding(.vertical, 60)
        .stockbarEmptyState(minHeight: 0)
    }

    // MARK: - Helper Views

    private func metricCard(title: String, value: String, subtitle: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)

            Text(value)
                .font(.title3)
                .fontWeight(.bold)
                .monospacedDigit()

            Text(subtitle)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .stockbarSurface(.inset, cornerRadius: 8)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Color Helpers

    /// Each sector keeps the colour it had, except Healthcare, Financials, Real Estate and Basic
    /// Materials, which were red, green, pink and mint: those read as loss and gain here.
    nonisolated static func colorForSector(_ sector: SectorAnalysisService.Sector) -> Color {
        switch sector {
        case .technology: return .blue
        case .healthcare: return StockbarPalette.allocationLavender
        case .financials: return StockbarPalette.allocationSectorTeal
        case .consumerCyclical: return .purple
        case .consumerDefensive: return .orange
        case .industrials: return .brown
        case .energy: return .yellow
        case .utilities: return .cyan
        case .realEstate: return StockbarPalette.allocationSand
        case .basicMaterials: return StockbarPalette.allocationSlate
        case .communicationServices: return .indigo
        case .unknown: return StockbarPalette.allocationOther
        }
    }

    private func colorForDiversificationScore(_ score: Double) -> Color {
        if score >= 70 { return .green }
        else if score >= 50 { return .orange }
        else { return .red }
    }

    private func colorForRiskLevel(_ risk: SectorAnalysisService.DiversificationAnalysis.ConcentrationRisk) -> Color {
        switch risk {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }

    private func interpretCorrelation(_ correlation: Double) -> String {
        if correlation >= 0.7 { return "High (risky)" }
        else if correlation >= 0.4 { return "Moderate" }
        else { return "Low (good)" }
    }

    // MARK: - Analytics Calculation

    private func calculateAnalytics() async {
        let revision = analyticsRevision + 1
        analyticsRevision = revision
        isLoading = true
        defer { if analyticsRevision == revision { isLoading = false } }

        let valuation = AllocationValuation.make(from: dataModel)
        let positions = valuation.positions
        let preferredCurrency = valuation.currency

        let sectors = await sectorService.calculateSectorAllocations(
            positions: positions,
            dayChanges: valuation.dayChanges
        )

        let diversification = await sectorService.analyzeDiversification(
            sectorAllocations: sectors
        )
        let eligibleCount = valuation.eligible
        let covered = valuation.covered
        let completeCoverage = eligibleCount > 0 && covered == eligibleCount
        let completeDay = eligibleCount > 0 && valuation.dayCovered == eligibleCount
        let valuedHoldings = valuation.holdings

        await MainActor.run {
            guard self.analyticsRevision == revision else { return }
            // Show what could be valued and say what is missing, rather than
            // blanking the whole section because one holding has no price yet.
            self.sectorAllocations = sectors
            self.valuedHoldings = valuedHoldings
            // Colours are handed out here, never while drawing, and kept while the page is open.
            self.holdingColours.assign(AllocationPresentation.holdingGroups(sectors).map(\.key))
            self.currencyColours.assign(AllocationPresentation.currencyGroups(valuedHoldings).map(\.key))
            self.analyticsEligible = eligibleCount
            self.diversificationAnalysis = completeCoverage ? diversification : nil
            self.analyticsCurrency = preferredCurrency
            self.cash = valuation.cash
            self.sourceTotal = valuation.sourceTotal
            self.cashOmission = valuation.cashOmission
            self.analyticsCoverage = covered
            self.completeDayCoverage = completeCoverage && completeDay
            self.hasLoadedOnce = true
        }
        guard !Task.isCancelled else { return }

        // Correlation uses stored daily price history aligned by date.
        let symbols = dataModel.realTimeTrades
            .filter { !$0.trade.isWatchlistOnly && !SymbolMetadata.isBenchmarkSymbol($0.trade.name) }
            .map { $0.trade.name }

        let historicalData = fetchHistoricalDataForCorrelation(symbols: symbols)
        let aligned = CorrelationMatrixService.alignedDailyReturns(
            from: historicalData, minimumCommonDays: Self.minimumCorrelationDays
        )
        guard aligned.commonDays >= Self.minimumCorrelationDays, aligned.returns.count > 1 else {
            await MainActor.run {
                guard self.analyticsRevision == revision else { return }
                self.correlationMatrix = nil
                self.diversificationMetrics = nil
                self.topCorrelations = []
                self.bottomCorrelations = []
                self.correlationExcluded = []
            }
            return
        }

        let matrix = await correlationService.calculateCorrelationMatrix(returns: aligned.returns)
        let correlatedPositions = positions.filter { aligned.returns[$0.key] != nil }
        let totalValue = correlatedPositions.values.reduce(0, +)
        var weights: [String: Double] = [:]
        var volatilities: [String: Double] = [:]
        for (symbol, value) in correlatedPositions {
            weights[symbol] = totalValue > 0 ? value / totalValue : 0
            volatilities[symbol] = aligned.returns[symbol].flatMap(CorrelationMatrixService.annualizedVolatility(of:))
        }

        let metrics = await correlationService.calculateDiversificationMetrics(
            correlationMatrix: matrix,
            weights: weights,
            volatilities: volatilities
        )
        let top = await correlationService.findTopCorrelations(correlationMatrix: matrix, count: 5)
        let bottom = await correlationService.findBottomCorrelations(correlationMatrix: matrix, count: 5)

        await MainActor.run {
            guard self.analyticsRevision == revision else { return }
            self.correlationMatrix = matrix
            self.diversificationMetrics = metrics
            self.topCorrelations = top
            self.bottomCorrelations = bottom
            self.correlationExcluded = aligned.excluded
        }
    }

    private static let minimumCorrelationDays = 20

    private func fetchHistoricalDataForCorrelation(symbols: [String]) -> [String: [PriceSnapshot]] {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -selectedTimeRange.correlationLookbackDays, to: end) ?? end
        var history: [String: [PriceSnapshot]] = [:]
        for symbol in Set(symbols) {
            let snapshots = HistoricalDataManager.shared.getPriceSnapshots(for: symbol, from: start, to: end)
            if !snapshots.isEmpty {
                history[symbol] = snapshots
            }
        }
        return history
    }

    // MARK: - Attribution Analysis Section (v2.3.1)

    private var attributionAnalysisSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Performance Attribution")
                    .font(.headline)

                Spacer()

                Button(action: {
                    showAttributionSheet = true
                }) {
                    HStack {
                        Text("View Details")
                        Image(systemName: "chevron.right")
                            .accessibilityHidden(true)
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderless)
            }

            Text("Analyze individual stock and sector contributions to portfolio performance")
                .font(.caption)
                .foregroundColor(.secondary)

            // Says what the sheet holds. Three "cards" stood here before, each
            // looking like a figure but showing none and opening the same sheet.
            Text("Includes top contributors, sector attribution, and time-weighted against money-weighted return.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

/// A tooltip over the whole row, for the rows that have one (only Cash); other rows are left as they were.
private struct AllocationRowTooltip: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text {
            content.contentShape(Rectangle()).help(text)
        } else {
            content
        }
    }
}

/// What the Allocation page values, worked out once from the data model: each holding's
/// value in the display currency, its day's change, the currency it is priced in, how many
/// holdings could be valued, and the cash and total from the source that gives Holdings
/// its weights. Each holding's value is the one Holdings weighs
/// (`DataModel.weighedPositionValue(for:)`) and the total and cash come from
/// `DataModel.holdingsWeightBasis()`, so the two pages cannot drift apart.
struct AllocationValuation {
    let currency: String
    var positions: [String: Double] = [:]
    var dayChanges: [String: Double] = [:]
    /// The same values as `positions`, kept per holding with the currency it is priced in.
    var holdings: [AllocationHolding] = []
    var covered = 0
    var dayCovered = 0
    /// Holdings that should have been valued; more than `covered` when a price or rate is missing.
    var eligible = 0
    var cash: AllocationCash = .none
    /// With a Cash row, Holdings' own total in the display currency, which every share is of.
    var sourceTotal: Double?
    /// Why cash the source gives is left out, when it is.
    var cashOmission: AllocationCashOmission?

    /// How far the holdings plus cash may be from Holdings' total, as a fraction of it, for
    /// a Cash row: half the 0.1% the page shows shares to.
    static let reconciliationTolerance = 0.0005

    @MainActor
    static func make(from dataModel: DataModel) -> AllocationValuation {
        let preferredCurrency = dataModel.preferredCurrency
        var result = AllocationValuation(currency: preferredCurrency)
        let convert = { (amount: Double, from: String) in
            convertAnalyticsAmount(amount, from: from, to: preferredCurrency, converter: dataModel.currencyConverter)
        }
        let isFolync = dataModel.folyncPortfolioSnapshot != nil
        let owned = dataModel.realTimeTrades.filter {
            !$0.trade.isWatchlistOnly && !SymbolMetadata.isBenchmarkSymbol($0.trade.name)
        }
        result.eligible = owned.count
        for trade in owned {
            guard let value = dataModel.weighedPositionValue(for: trade), value.amount.isFinite, value.amount > 0,
                  let converted = convert(value.amount, value.currency), converted > 0 else { continue }
            let symbol = trade.trade.name
            // The currency view groups by the currency a holding is priced in. A Folync
            // holding's value is already in it; a broker's value is in the account's currency.
            let pricedIn = isFolync
                ? value.currency
                : (trade.realTimeInfo.currency ?? trade.trade.position.currency ?? value.currency)
            result.positions[symbol, default: 0] += converted
            result.holdings.append(AllocationHolding(symbol: symbol, value: converted,
                                                     currency: pricedIn.trimmingCharacters(in: .whitespacesAndNewlines)))
            result.covered += 1
            if let change = dayChange(of: trade, in: dataModel, isFolync: isFolync), let converted = convert(change.amount, change.currency) {
                result.dayChanges[symbol, default: 0] += converted
                result.dayCovered += 1
            }
        }
        result.decideCash(dataModel.holdingsWeightBasis(), convert: convert)
        return result
    }

    /// Today's change in the holding's value: Folync's own figure for a Folync holding,
    /// otherwise the price's move since the previous close times the units.
    @MainActor
    private static func dayChange(of trade: RealTimeTrade, in dataModel: DataModel,
                                  isFolync: Bool) -> (amount: Double, currency: String)? {
        if isFolync {
            let summary = dataModel.calculatePositionProfitLoss(for: trade)
            guard summary.dayAmount.isFinite else { return nil }
            return (summary.dayAmount, summary.currency)
        }
        let currentPrice = trade.realTimeInfo.getCurrentDisplayPrice()
        let previousClose = trade.realTimeInfo.previousClose ?? trade.realTimeInfo.prevClosePrice
        let units = trade.trade.position.unitSize
        // Prices are already in pounds for a pence-quoted listing, so pence count as pounds here, as before.
        guard currentPrice.isFinite, currentPrice > 0, previousClose.isFinite, previousClose > 0, units.isFinite,
              let currency = SymbolMetadata.normalizeCurrency(trade.realTimeInfo.currency ?? trade.trade.position.currency)
        else { return nil }
        return ((currentPrice - previousClose) * units, currency)
    }

    /// A Cash row only when its share and every holding's share are of the same total as
    /// Holdings' weights: Holdings' total covers its holdings, every holding is valued, the
    /// cash converts at a loaded rate, and holdings plus cash come to that total. Otherwise
    /// the shares are of the holdings and `cashOmission` says why.
    private mutating func decideCash(_ basis: HoldingsWeightBasis, convert: (Double, String) -> Double?) {
        cash = .none
        sourceTotal = nil
        cashOmission = nil
        if let mismatch = basis.mismatch {
            cashOmission = AllocationCashOmission(mismatch)
            return
        }
        guard let sourceCash = basis.cash, sourceCash.value != 0 else { return }
        let converted = convert(sourceCash.value, sourceCash.currency)
        // Cash that shows as zero in the display currency is zero: no row, no line.
        if let converted, HoldingsCurrencyFormatter.displayedSign(of: converted, currency: currency) == 0 { return }
        guard covered == eligible else { cashOmission = .partialCoverage; return }
        guard let converted else { cashOmission = .noExchangeRate; return }
        guard converted > 0 else { cash = .borrowing(converted); return }
        guard let total = basis.total else { cashOmission = .totalDiffers; return }
        guard let convertedTotal = convert(total.value, total.currency), convertedTotal > 0 else {
            cashOmission = .noExchangeRate
            return
        }
        let holdingsTotal = positions.values.reduce(0, +)
        guard abs(holdingsTotal + converted - convertedTotal) <= Self.reconciliationTolerance * convertedTotal else {
            cashOmission = .totalDiffers
            return
        }
        cash = .held(converted)
        sourceTotal = convertedTotal
    }

    /// Convert only with a rate from the loaded rate table; a hard-coded fallback rate is
    /// not good enough for a share of the portfolio. Nil without one.
    @MainActor
    static func convertAnalyticsAmount(_ amount: Double, from: String, to: String,
                                       converter: CurrencyConverter) -> Double? {
        converter.convertWithLoadedRates(amount: amount, from: from, to: to)
    }
}

/// The correlation matrix as a grid: one row and one column per holding, each cell its
/// figure to two decimals, shaded by it. Takes plain inputs and holds no state.
struct CorrelationGridView: View {
    let matrix: CorrelationMatrixService.CorrelationMatrix
    let symbols: [String]

    var body: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                ForEach(symbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(width: 42)
                        .accessibilityHidden(true)
                }
            }
            ForEach(symbols, id: \.self) { row in
                GridRow {
                    Text(row)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 64, alignment: .leading)
                        .help(row)
                        .accessibilityHidden(true)
                    ForEach(symbols, id: \.self) { column in
                        cell(row: row, column: column)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(row: String, column: String) -> some View {
        if row == column {
            Text("–")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 42, height: 26)
                .accessibilityHidden(true)
        } else {
            let value = matrix.correlation(between: row, between: column)
            let label = AllocationPresentation.cellLabel(row, column, value: value)
            Text(AllocationPresentation.cellText(value))
                .font(.caption.monospacedDigit().weight(.medium))
                .frame(width: 42, height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(StockbarPalette.correlationFill(AllocationPresentation.shade(value)))
                }
                .help(label)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
        }
    }
}

#Preview {
    PortfolioAnalyticsView(dataModel: DataModel())
}
