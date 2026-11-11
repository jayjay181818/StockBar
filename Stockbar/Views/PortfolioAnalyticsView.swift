//
//  PortfolioAnalyticsView.swift
//  Stockbar
//
//  Created by Claude Code on 2025-10-03.
//  Comprehensive portfolio analytics with correlation matrix and sector allocation
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

    private struct AnalyticsTrigger: Hashable {
        let range: TimeRange
        let currency: String
        let tick: Int
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                headerSection

                if isLoading && !hasLoadedOnce {
                    ProgressView("Calculating portfolio analytics...")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                } else if dataModel.realTimeTrades.count < 2 {
                    emptyStateView
                } else {
                    // Sector Allocation Section
                    sectorAllocationSection

                    Divider()

                    // Diversification Section
                    diversificationSection

                    Divider()

                    // Correlation Matrix Section
                    correlationMatrixSection

                    Divider()

                    // Correlation Insights Section
                    correlationInsightsSection

                    Divider()

                    // Attribution Analysis Section (v2.3.1)
                    attributionAnalysisSection
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
        // earlier results stay on screen while a recalculation is in flight.
        .task(id: AnalyticsTrigger(range: selectedTimeRange, currency: dataModel.preferredCurrency, tick: portfolioUpdateTick)) {
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
        VStack(alignment: .leading, spacing: 8) {
            StockbarPageHeader("Allocation", subtitle: "Sector allocation, diversification, correlation and attribution.") {
                // Time Range Picker
                Picker("Time Range", selection: $selectedTimeRange) {
                    ForEach(TimeRange.allCases, id: \.self) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 250)
                .help("Price history window used for the correlation analysis")
            }
        }
    }

    // MARK: - Sector Allocation

    private var sectorAllocationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sector Allocation")
                .font(.headline)

            if sectorAllocations.isEmpty {
                Text(analyticsEligible > 0
                     ? "Sector allocation needs a price and exchange rate for at least one holding."
                     : "No sector data available")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                if analyticsCoverage < analyticsEligible {
                    Label(
                        "Based on \(analyticsCoverage) of \(analyticsEligible) holdings. The rest have no price or exchange rate yet, so the percentages are of the valued part only.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                // Pie Chart
                Chart(sectorAllocations) { allocation in
                    SectorMark(
                        angle: .value("Value", allocation.totalValue),
                        innerRadius: .ratio(0.5),
                        angularInset: 1.5
                    )
                    .foregroundStyle(by: .value("Sector", sectorLabel(allocation.sector)))
                }
                // Same colours as the breakdown table below.
                .chartForegroundStyleScale(
                    domain: sectorAllocations.map { sectorLabel($0.sector) },
                    range: sectorAllocations.map { colorForSector($0.sector) }
                )
                .frame(height: 300)
                .chartLegend(position: .trailing)
                .accessibilityLabel("Sector allocation")
                .accessibilityValue(sectorAllocations
                    .map { "\(sectorLabel($0.sector)) \(String(format: "%.1f", $0.percentageOfPortfolio)) percent" }
                    .joined(separator: ", "))

                // Sector Breakdown Table
                VStack(spacing: 4) {
                    ForEach(sectorAllocations) { allocation in
                        HStack {
                            Circle()
                                .fill(colorForSector(allocation.sector))
                                .frame(width: 10, height: 10)

                            Text(sectorLabel(allocation.sector))
                                .font(.subheadline)

                            Spacer()

                            VStack(alignment: .trailing, spacing: 2) {
                                Text(HoldingsCurrencyFormatter.amount(allocation.totalValue, currency: analyticsCurrency))
                                    .monospacedDigit()
                                    .font(.subheadline)
                                    .fontWeight(.medium)

                                Text("\(allocation.percentageOfPortfolio, specifier: "%.1f")%")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            // Unknown day change is a dash in a neutral colour, never green.
                            Text(completeDayCoverage ? AttributionFormat.signedPercent(allocation.dayChangePercent) : "—")
                                .font(.caption)
                                .foregroundColor(StockbarPalette.signed(completeDayCoverage ? allocation.dayChangePercent : nil))
                                .frame(width: 70, alignment: .trailing)
                                .accessibilityLabel(completeDayCoverage
                                    ? "Day change \(AttributionFormat.spokenPercent(allocation.dayChangePercent))"
                                    : "Day change unavailable")
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(StockbarPalette.faintFill)
                        .cornerRadius(6)
                    }
                }

                if let unclassified = diversificationAnalysis?.unclassifiedPercentage, unclassified > 0 {
                    Text("\(unclassified, specifier: "%.1f")% of the portfolio is in holdings with no known sector (shown as Unclassified).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Diversification

    private var diversificationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diversification Analysis")
                .font(.headline)

            if let analysis = diversificationAnalysis, analysis.isAvailable {
                // Diversification Score
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Diversification Score")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Text("\(analysis.score, specifier: "%.1f")/100")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(colorForDiversificationScore(analysis.score))
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Concentration Risk")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Text(analysis.concentrationRisk.rawValue)
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundColor(colorForRiskLevel(analysis.concentrationRisk))
                    }
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(10)

                if analysis.unclassifiedPercentage > 0 {
                    Text("\(analysis.unclassifiedPercentage, specifier: "%.1f")% of the portfolio has no known sector and is excluded from this score.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Recommendations
                if !analysis.recommendations.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recommendations")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        ForEach(analysis.recommendations, id: \.self) { recommendation in
                            HStack(alignment: .top, spacing: 8) {
                                Text("•")
                                    .foregroundColor(.blue)
                                Text(recommendation)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding()
                    .background(StockbarPalette.faintFill)
                    .cornerRadius(8)
                }
            } else if let analysis = diversificationAnalysis, analysis.unclassifiedPercentage > 0 {
                Text("Diversification unavailable: \(analysis.unclassifiedPercentage, specifier: "%.0f")% of the portfolio has no known sector.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text(analyticsCoverage == 0 ? "No valued positions available" : "Diversification unavailable: some prices or exchange rates are missing")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Correlation Matrix

    private var correlationMatrixSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Correlation Summary")
                .font(.headline)

            if let matrix = correlationMatrix {
                // Correlation Summary
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

                if let metrics = diversificationMetrics {
                    HStack(spacing: 20) {
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
                }
            } else {
                Text("Not enough shared price history. Correlation needs at least \(Self.minimumCorrelationDays) common trading days for two or more holdings.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Correlation Insights

    private var correlationInsightsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Correlation Insights")
                .font(.headline)

            HStack(alignment: .top, spacing: 20) {
                // Highest Correlations
                VStack(alignment: .leading, spacing: 8) {
                    Text("Highest Correlations (Risk)")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.red)

                    if topCorrelations.isEmpty {
                        Text("No data")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(topCorrelations) { pair in
                            HStack {
                                Text("\(pair.symbol1) ↔ \(pair.symbol2)")
                                    .font(.caption)
                                Spacer()
                                Text("\(pair.correlation, specifier: "%.3f")")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.red)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(4)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                // Lowest Correlations
                VStack(alignment: .leading, spacing: 8) {
                    Text("Lowest Correlations (Diversification)")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.green)

                    if bottomCorrelations.isEmpty {
                        Text("No data")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(bottomCorrelations) { pair in
                            HStack {
                                Text("\(pair.symbol1) ↔ \(pair.symbol2)")
                                    .font(.caption)
                                Spacer()
                                Text("\(pair.correlation, specifier: "%.3f")")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.green)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(4)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.pie")
                .font(.system(size: 60))
                .foregroundColor(.gray)

            Text("Portfolio Analytics Unavailable")
                .font(.headline)

            Text("Add at least 2 stocks to your portfolio to see correlation and sector analysis")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity)
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

            Text(subtitle)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(StockbarPalette.faintFill)
        .cornerRadius(8)
    }

    // MARK: - Color Helpers

    private func sectorLabel(_ sector: SectorAnalysisService.Sector) -> String {
        sector == .unknown ? "Unclassified" : sector.displayName
    }

    private func colorForSector(_ sector: SectorAnalysisService.Sector) -> Color {
        switch sector {
        case .technology: return .blue
        case .healthcare: return .red
        case .financials: return .green
        case .consumerCyclical: return .purple
        case .consumerDefensive: return .orange
        case .industrials: return .brown
        case .energy: return .yellow
        case .utilities: return .cyan
        case .realEstate: return .pink
        case .basicMaterials: return .mint
        case .communicationServices: return .indigo
        case .unknown: return .gray
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

        // Calculate sector allocations
        var positions: [String: Double] = [:]
        var dayChanges: [String: Double] = [:]

        let preferredCurrency = dataModel.preferredCurrency
        var covered = 0
        var dayCovered = 0
        let eligibleCount: Int
        if let snapshot = dataModel.folyncPortfolioSnapshot {
            eligibleCount = snapshot.displayHoldings.count
        } else {
            eligibleCount = dataModel.realTimeTrades.filter {
                !$0.trade.isWatchlistOnly && !SymbolMetadata.isBenchmarkSymbol($0.trade.name)
            }.count
        }
        if let snapshot = dataModel.folyncPortfolioSnapshot {
            for holding in snapshot.displayHoldings {
                guard let value = holding.marketValue, value.isFinite, value > 0 else { continue }
                let sourceCurrency = holding.resolvedValueCurrency.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sourceCurrency.isEmpty,
                      let converted = convertAnalyticsAmount(value, from: sourceCurrency, to: preferredCurrency), converted > 0 else { continue }
                positions[holding.resolvedDisplayTicker, default: 0] += converted
                if let dayGain = holding.dayGain,
                   let convertedDayGain = convertAnalyticsAmount(dayGain, from: sourceCurrency, to: preferredCurrency) {
                    dayChanges[holding.resolvedDisplayTicker, default: 0] += convertedDayGain
                    dayCovered += 1
                }
                covered += 1
            }
        } else {
          for trade in dataModel.realTimeTrades {
            guard !trade.trade.isWatchlistOnly,
                  !SymbolMetadata.isBenchmarkSymbol(trade.trade.name) else { continue }
            let currentPrice = trade.realTimeInfo.getCurrentDisplayPrice()
            let previousClose = trade.realTimeInfo.previousClose ?? trade.realTimeInfo.prevClosePrice
            let units = trade.trade.position.unitSize
            guard currentPrice.isFinite, currentPrice > 0, units.isFinite, units > 0 else { continue }
            guard let rawCurrency = trade.realTimeInfo.currency ?? trade.trade.position.currency,
                  let sourceCurrency = SymbolMetadata.normalizeCurrency(rawCurrency),
                  !sourceCurrency.isEmpty else { continue }
            guard let currentValue = convertAnalyticsAmount(currentPrice * units, from: sourceCurrency, to: preferredCurrency), currentValue > 0 else { continue }
            positions[trade.trade.name, default: 0] += currentValue
            if previousClose.isFinite, previousClose > 0 {
                let rawChange = (currentPrice - previousClose) * units
                if let convertedChange = convertAnalyticsAmount(rawChange, from: sourceCurrency, to: preferredCurrency) {
                    dayChanges[trade.trade.name, default: 0] += convertedChange
                    dayCovered += 1
                }
            }
            covered += 1
          }
        }

        let sectors = await sectorService.calculateSectorAllocations(
            positions: positions,
            dayChanges: dayChanges
        )

        let diversification = await sectorService.analyzeDiversification(
            sectorAllocations: sectors
        )
        let completeCoverage = eligibleCount > 0 && covered == eligibleCount
        let completeDay = eligibleCount > 0 && dayCovered == eligibleCount

        await MainActor.run {
            guard self.analyticsRevision == revision else { return }
            // Show what could be valued and say what is missing, rather than
            // blanking the whole section because one holding has no price yet.
            self.sectorAllocations = sectors
            self.analyticsEligible = eligibleCount
            self.diversificationAnalysis = completeCoverage ? diversification : nil
            self.analyticsCurrency = preferredCurrency
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

    /// Convert only with a current, known FX rate; fallback constants are not suitable for allocation claims.
    private func convertAnalyticsAmount(_ amount: Double, from: String, to: String) -> Double? {
        guard amount.isFinite else { return nil }
        let info = dataModel.currencyConverter.getExchangeRateInfo(from: from, to: to)
        guard info.rate.isFinite, !info.isFallback else { return nil }
        let converted = dataModel.currencyConverter.convert(amount: amount, from: from, to: to)
        return converted.isFinite ? converted : nil
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

#Preview {
    PortfolioAnalyticsView(dataModel: DataModel())
}
