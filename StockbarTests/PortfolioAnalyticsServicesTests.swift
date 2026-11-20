import XCTest
@testable import Stockbar

final class PortfolioAnalyticsServicesTests: XCTestCase {
    func testAttributionExcludesBenchmarksFromPositionContributions() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(86400)
        func snapshot(at date: Date, price: Double) -> HistoricalPortfolioSnapshot {
            let composition = ["AAPL", "^GSPC", "^FTSE"].reduce(into: [String: PositionSnapshot]()) { result, symbol in
                result[symbol] = PositionSnapshot(symbol: symbol, units: 1, priceAtDate: price,
                                                  valueAtDate: price, currency: "USD")
            }
            return HistoricalPortfolioSnapshot(date: date, totalValue: price, totalGains: price - 100,
                                               totalCost: 100, currency: "USD", portfolioComposition: composition)
        }
        let result = await AttributionAnalysisService.shared.calculateAttributionFromHistorical(
            startDate: start, endDate: end,
            historicalSnapshots: [snapshot(at: start, price: 100), snapshot(at: end, price: 110)]
        )
        let attribution = try XCTUnwrap(result)
        XCTAssertEqual(attribution.stockContributions.map(\.symbol), ["AAPL"])
        XCTAssertEqual(attribution.stockContributions[0].dollarContribution, 10, accuracy: 0.001)
    }

    private func attributionSnapshot(
        _ date: Date, total: Double, currency: String = "GBP", positions: [PositionSnapshot]
    ) -> HistoricalPortfolioSnapshot {
        HistoricalPortfolioSnapshot(
            date: date, totalValue: total, totalGains: 0, totalCost: total, currency: currency,
            portfolioComposition: Dictionary(positions.map { ($0.symbol, $0) }, uniquingKeysWith: { first, _ in first })
        )
    }

    // 1 GBP = 1.25 USD, GBX is pence.
    private let attributionConvert: @Sendable (Double, String, String) -> Double = { amount, from, to in
        func toGBP(_ value: Double, _ code: String) -> Double {
            switch code {
            case "USD": return value / 1.25
            case "GBX": return value / 100
            default: return value
            }
        }
        return from == to ? amount : toGBP(amount, from)
    }

    func testAttributionCountsHoldingsOpenedOrClosedInsideThePeriod() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func day(_ n: Double) -> Date { start.addingTimeInterval(n * 86400) }
        func position(_ symbol: String, _ price: Double) -> PositionSnapshot {
            PositionSnapshot(symbol: symbol, units: 10, priceAtDate: price, valueAtDate: 10 * price, currency: "GBP")
        }
        // KEEP is held throughout (+10 a share). SOLD falls 20 a share and is gone by
        // the last day. NEW is bought on day 1 and gains 5 a share afterwards.
        let snapshots = [
            attributionSnapshot(day(0), total: 2000, positions: [position("KEEP", 100), position("SOLD", 100)]),
            attributionSnapshot(day(1), total: 2900, positions: [position("KEEP", 105), position("SOLD", 80), position("NEW", 100)]),
            attributionSnapshot(day(2), total: 2150, positions: [position("KEEP", 110), position("NEW", 105)])
        ]
        let result = await AttributionAnalysisService.shared.calculateAttributionFromHistorical(
            startDate: day(0), endDate: day(2), historicalSnapshots: snapshots, convert: attributionConvert
        )
        let attribution = try XCTUnwrap(result)
        let bySymbol = Dictionary(uniqueKeysWithValues: attribution.stockContributions.map { ($0.symbol, $0) })
        XCTAssertEqual(try XCTUnwrap(bySymbol["KEEP"]).dollarContribution, 100, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(bySymbol["SOLD"]).dollarContribution, -200, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(bySymbol["NEW"]).dollarContribution, 50, accuracy: 0.001)
        // SOLD carries no weight at the end and NEW none at the start.
        XCTAssertEqual(try XCTUnwrap(bySymbol["SOLD"]).weight, 25, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(bySymbol["NEW"]).weight, (1050.0 / 2150.0) * 100 / 2, accuracy: 0.001)
    }

    func testAttributionConvertsMixedCurrenciesBeforeWeighting() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(86400)
        // GBP total: 1000 USD = 800, 100 GBP-stock = 100... VOD 10_000p = 100 GBP, SAP-like GBP 100.
        func positions(usd: Double, gbx: Double, gbp: Double) -> [PositionSnapshot] {
            [PositionSnapshot(symbol: "AAPL", units: 10, priceAtDate: usd, valueAtDate: 10 * usd, currency: "USD"),
             PositionSnapshot(symbol: "VOD.L", units: 100, priceAtDate: gbx, valueAtDate: 100 * gbx, currency: "GBX"),
             PositionSnapshot(symbol: "ULVR", units: 1, priceAtDate: gbp, valueAtDate: gbp, currency: "GBP")]
        }
        // Start: 1000 USD = 800 GBP, 100 * 100p = 100 GBP, 100 GBP -> 1000 GBP total.
        let startSnapshot = attributionSnapshot(start, total: 1000, positions: positions(usd: 100, gbx: 100, gbp: 100))
        // End: AAPL +10% (+80 GBP), VOD +10% (+10 GBP), ULVR flat. Total 1090.
        let endSnapshot = attributionSnapshot(end, total: 1090, positions: positions(usd: 110, gbx: 110, gbp: 100))

        let result = await AttributionAnalysisService.shared.calculateAttributionFromHistorical(
            startDate: start, endDate: end, historicalSnapshots: [startSnapshot, endSnapshot], convert: attributionConvert)
        let attribution = try XCTUnwrap(result)
        let bySymbol = Dictionary(attribution.stockContributions.map { ($0.symbol, $0) }, uniquingKeysWith: { first, _ in first })

        XCTAssertEqual(try XCTUnwrap(bySymbol["AAPL"]).dollarContribution, 80, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(bySymbol["VOD.L"]).dollarContribution, 10, accuracy: 0.01, "GBX must be converted from pence")
        XCTAssertEqual(try XCTUnwrap(bySymbol["ULVR"]).dollarContribution, 0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(bySymbol["AAPL"]).weight, 80, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(bySymbol["VOD.L"]).weight, 10, accuracy: 0.5)
        XCTAssertEqual(attribution.sectorContributions.map(\.dollarContribution).reduce(0, +), 90, accuracy: 0.01)
        XCTAssertEqual(attribution.portfolioReturn, 9, accuracy: 0.01)
        let waterfallSum = attribution.waterfallData.filter { !$0.isSummary }.map(\.value).reduce(0, +)
        XCTAssertEqual(1000 + waterfallSum, 1090, accuracy: 0.01)
    }

    func testAttributionIgnoresNewMoneyInAFlatPeriod() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(86400)
        let before = PositionSnapshot(symbol: "AAPL", units: 100, priceAtDate: 100, valueAtDate: 10_000, currency: "GBP")
        let after = PositionSnapshot(symbol: "AAPL", units: 150, priceAtDate: 100, valueAtDate: 15_000, currency: "GBP")

        let result = await AttributionAnalysisService.shared.calculateAttributionFromHistorical(
            startDate: start, endDate: end,
            historicalSnapshots: [attributionSnapshot(start, total: 10_000, positions: [before]),
                                  attributionSnapshot(end, total: 15_000, positions: [after])],
            convert: attributionConvert)
        let attribution = try XCTUnwrap(result)

        XCTAssertEqual(attribution.portfolioReturn, 0, accuracy: 0.0001)
        XCTAssertEqual(attribution.stockContributions[0].dollarContribution, 0, accuracy: 0.0001)
        XCTAssertNil(attribution.twrMwrComparison, "TWR/MWR are hidden without cash-flow data")
        XCTAssertNil(attribution.netCashFlow)
    }

    func testCorrelationMatrix_WithPerfectCorrelation() async throws {
        // Given: Two identical return series.
        let service = CorrelationMatrixService()
        let returns = [
            "AAPL": [0.01, 0.02, -0.01, 0.03, 0.00],
            "MSFT": [0.01, 0.02, -0.01, 0.03, 0.00]
        ]

        // When: Calculating correlations.
        let matrix = await service.calculateCorrelationMatrix(returns: returns)

        // Then: The pair is perfectly correlated.
        let correlation = try XCTUnwrap(matrix.correlation(between: "AAPL", between: "MSFT"))
        XCTAssertEqual(correlation, 1.0, accuracy: 0.001)
    }

    func testCorrelationMatrix_WithMultipleSymbols_IsSquareAndSymmetric() async throws {
        // Given: Multiple symbols with varied returns.
        let service = CorrelationMatrixService()
        let returns = [
            "AAPL": [0.01, 0.02, -0.01, 0.03, 0.00, 0.02],
            "MSFT": [0.01, 0.015, -0.005, 0.025, 0.005, 0.015],
            "TSLA": [0.05, -0.03, 0.02, -0.01, 0.04, -0.02],
            "GOOGL": [0.02, 0.01, 0.00, 0.02, 0.01, 0.01]
        ]

        // When: Calculating the matrix.
        let matrix = await service.calculateCorrelationMatrix(returns: returns)

        // Then: The matrix is square, symmetric, and has self-correlation on the diagonal.
        XCTAssertEqual(matrix.symbols.count, 4)
        XCTAssertEqual(matrix.matrix.count, 4)
        for row in matrix.matrix {
            XCTAssertEqual(row.count, 4)
        }
        for row in 0..<matrix.matrix.count {
            for column in 0..<matrix.matrix[row].count {
                XCTAssertEqual(try XCTUnwrap(matrix.matrix[row][column]),
                               try XCTUnwrap(matrix.matrix[column][row]), accuracy: 0.001)
            }
            XCTAssertEqual(try XCTUnwrap(matrix.matrix[row][row]), 1.0, accuracy: 0.001)
        }
    }

    func testDiversificationMetrics_WithConcentratedWeights_ShowsHighConcentration() async throws {
        // Given: Highly correlated positions with concentrated weights.
        let service = CorrelationMatrixService()
        let returns = [
            "AAPL": [0.01, 0.02, -0.01, 0.03],
            "MSFT": [0.01, 0.02, -0.01, 0.03],
            "GOOGL": [0.01, 0.02, -0.01, 0.03]
        ]
        let weights = ["AAPL": 0.80, "MSFT": 0.10, "GOOGL": 0.10]

        // When: Calculating diversification metrics with the current API.
        let metrics = await diversificationMetrics(service: service, returns: returns, weights: weights)

        // Then: Concentration and correlation are both high.
        XCTAssertGreaterThan(metrics.averageCorrelation, 0.9)
        XCTAssertGreaterThan(metrics.concentrationScore, 0.65)
        XCTAssertLessThan(metrics.diversificationScore, 50)
        XCTAssertEqual(metrics.riskLevel, .high)
    }

    func testDiversificationMetrics_WithEqualWeights_HasMultipleEffectivePositions() async throws {
        // Given: Equal weights across several symbols.
        let service = CorrelationMatrixService()
        let returns = [
            "AAPL": [0.01, 0.02, -0.01, 0.03, 0.00],
            "TSLA": [0.02, -0.01, 0.03, -0.02, 0.01],
            "GOOGL": [-0.01, 0.01, 0.02, 0.00, -0.01],
            "NVDA": [0.03, 0.00, -0.02, 0.01, 0.02],
            "AMD": [-0.02, 0.02, 0.01, -0.01, 0.00]
        ]
        let weights = ["AAPL": 0.2, "TSLA": 0.2, "GOOGL": 0.2, "NVDA": 0.2, "AMD": 0.2]

        // When: Calculating metrics.
        let metrics = await diversificationMetrics(service: service, returns: returns, weights: weights)

        // Then: The effective number reflects broad weighting and the score stays bounded.
        XCTAssertGreaterThan(metrics.effectiveN, 4.9)
        XCTAssertGreaterThanOrEqual(metrics.diversificationScore, 0)
        XCTAssertLessThanOrEqual(metrics.diversificationScore, 100)
    }

    func testFindTopCorrelations_ReturnsSortedPairs() async throws {
        // Given: A calculated correlation matrix.
        let service = CorrelationMatrixService()
        let matrix = await service.calculateCorrelationMatrix(returns: [
            "AAPL": [0.01, 0.02, -0.01, 0.03, 0.00],
            "MSFT": [0.01, 0.02, -0.01, 0.03, 0.00],
            "TSLA": [0.05, -0.03, 0.02, -0.01, 0.04],
            "GOOGL": [0.02, 0.01, 0.00, 0.02, 0.01]
        ])

        // When: Asking for top correlations.
        let pairs = await service.findTopCorrelations(correlationMatrix: matrix, count: 3)

        // Then: Pairs are capped and sorted descending.
        XCTAssertGreaterThan(pairs.count, 0)
        XCTAssertLessThanOrEqual(pairs.count, 3)
        if pairs.count >= 2 {
            XCTAssertGreaterThanOrEqual(pairs[0].correlation, pairs[1].correlation)
        }
    }

    func testSectorClassification_KnownAndUnknownSymbols() {
        // Given/When/Then: Static sector classification handles known and unknown symbols.
        XCTAssertEqual(SectorAnalysisService.Sector.forSymbol("AAPL"), .technology)
        XCTAssertEqual(SectorAnalysisService.Sector.forSymbol("JPM"), .financials)
        XCTAssertEqual(SectorAnalysisService.Sector.forSymbol("UNKNOWN123"), .unknown)
    }

    func testSectorAllocations_CalculatesPercentagesAndSortsByValue() async throws {
        // Given: Portfolio values across sectors.
        let service = SectorAnalysisService()
        let positions = [
            "AAPL": 10_000.0,
            "MSFT": 10_000.0,
            "JPM": 5_000.0,
            "JNJ": 5_000.0
        ]

        // When: Calculating sector allocations.
        let allocations = await service.calculateSectorAllocations(positions: positions, dayChanges: [:])

        // Then: Technology is largest and percentages sum to 100.
        let technology = try XCTUnwrap(allocations.first(where: { $0.sector == .technology }))
        XCTAssertEqual(technology.totalValue, 20_000, accuracy: 0.01)
        XCTAssertGreaterThan(technology.percentageOfPortfolio, 60)
        let totalPercentage = allocations.reduce(0.0) { $0 + $1.percentageOfPortfolio }
        XCTAssertEqual(totalPercentage, 100.0, accuracy: 0.1)
        XCTAssertEqual(allocations.first?.sector, .technology)
    }

    func testSectorAllocations_WithEmptyPortfolio_ReturnsEmpty() async {
        // Given: No positions.
        let service = SectorAnalysisService()

        // When: Calculating allocations.
        let allocations = await service.calculateSectorAllocations(positions: [:], dayChanges: [:])

        // Then: No allocations are emitted.
        XCTAssertTrue(allocations.isEmpty)
    }

    func testSectorAllocations_ExcludesNonFiniteAndNonPositiveValues() async {
        let service = SectorAnalysisService()
        let allocations = await service.calculateSectorAllocations(
            positions: ["AAPL": 100, "MSFT": .nan, "JPM": .infinity, "TSLA": 0, "GSK": -10],
            dayChanges: [:]
        )

        XCTAssertEqual(allocations.count, 1)
        XCTAssertEqual(allocations[0].totalValue, 100, accuracy: 0.001)
        XCTAssertEqual(allocations[0].percentageOfPortfolio, 100, accuracy: 0.001)
    }

    func testSectorDiversification_WithEmptyAllocations_IsUnavailable() async {
        let service = SectorAnalysisService()
        let analysis = await service.analyzeDiversification(sectorAllocations: [])

        XCTAssertFalse(analysis.isAvailable)
        XCTAssertTrue(analysis.score.isNaN)
    }

    func testSectorDiversification_WithDominantSector_ProducesRecommendations() async throws {
        // Given: One dominant sector.
        let service = SectorAnalysisService()
        let allocations = await service.calculateSectorAllocations(
            positions: [
                "AAPL": 15_000,
                "MSFT": 10_000,
                "GOOGL": 8_000,
                "JPM": 5_000
            ],
            dayChanges: [:]
        )

        // When: Analyzing diversification.
        let analysis = await service.analyzeDiversification(sectorAllocations: allocations)

        // Then: The concentration risk and recommendations identify the issue.
        XCTAssertEqual(analysis.concentrationRisk, .high)
        XCTAssertTrue(analysis.topHeavySectors.contains(.technology))
        XCTAssertTrue(analysis.recommendations.contains { $0.contains("Technology") })
    }

    func testSectorDiversification_WithBroadSectors_HasHighScore() async {
        // Given: Equal exposure across several sectors.
        let service = SectorAnalysisService()
        let allocations = await service.calculateSectorAllocations(
            positions: [
                "AAPL": 5_000,
                "JPM": 5_000,
                "JNJ": 5_000,
                "XOM": 5_000,
                "WMT": 5_000,
                "CAT": 5_000
            ],
            dayChanges: [:]
        )

        // When: Analyzing diversification.
        let analysis = await service.analyzeDiversification(sectorAllocations: allocations)

        // Then: The score is high and bounded.
        XCTAssertGreaterThan(analysis.score, 60)
        XCTAssertLessThanOrEqual(analysis.score, 100)
    }

    func testDiversificationMetrics_WithSingleStock() async throws {
        // Given: A single-stock portfolio.
        let service = CorrelationMatrixService()
        let returns = ["AAPL": [0.01, 0.02, -0.01, 0.03]]
        let weights = ["AAPL": 1.0]

        // When: Calculating metrics.
        let metrics = await diversificationMetrics(service: service, returns: returns, weights: weights)

        // Then: Effective N and concentration reflect one position.
        XCTAssertEqual(metrics.effectiveN, 1.0, accuracy: 0.1)
        XCTAssertEqual(metrics.concentrationScore, 1.0, accuracy: 0.1)
    }

    private func diversificationMetrics(
        service: CorrelationMatrixService,
        returns: [String: [Double]],
        weights: [String: Double]
    ) async -> CorrelationMatrixService.DiversificationMetrics {
        let matrix = await service.calculateCorrelationMatrix(returns: returns)
        let volatilities = returns.mapValues(standardDeviation)
        return await service.calculateDiversificationMetrics(
            correlationMatrix: matrix,
            weights: weights,
            volatilities: volatilities
        )
    }

    private func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count - 1)
        return sqrt(variance)
    }

    func testAlignedDailyReturnsUsesOnlySharedDays() {
        let calendar = Calendar(identifier: .gregorian)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func day(_ offset: Int, hour: Double = 12) -> Date {
            calendar.startOfDay(for: start).addingTimeInterval(Double(offset) * 86_400 + hour * 3_600)
        }
        let history: [String: [PriceSnapshot]] = [
            "AAA": [
                PriceSnapshot(timestamp: day(0), price: 100, previousClose: 100, symbol: "AAA"),
                PriceSnapshot(timestamp: day(1, hour: 10), price: 999, previousClose: 100, symbol: "AAA"),
                PriceSnapshot(timestamp: day(1, hour: 16), price: 110, previousClose: 100, symbol: "AAA"),
                PriceSnapshot(timestamp: day(2), price: 121, previousClose: 110, symbol: "AAA"),
                PriceSnapshot(timestamp: day(3), price: 0, previousClose: 121, symbol: "AAA")
            ],
            "BBB": [
                PriceSnapshot(timestamp: day(0), price: 50, previousClose: 50, symbol: "BBB"),
                PriceSnapshot(timestamp: day(1), price: 55, previousClose: 50, symbol: "BBB"),
                PriceSnapshot(timestamp: day(2), price: 60.5, previousClose: 55, symbol: "BBB"),
                PriceSnapshot(timestamp: day(3), price: 70, previousClose: 60.5, symbol: "BBB")
            ]
        ]

        let aligned = CorrelationMatrixService.alignedDailyReturns(from: history, calendar: calendar)

        XCTAssertEqual(aligned.commonDays, 3)
        XCTAssertEqual(aligned.returns["AAA"]?.count, 2)
        XCTAssertEqual(aligned.returns["AAA"]?.first ?? .nan, 0.1, accuracy: 1e-9)
        XCTAssertEqual(aligned.returns["BBB"]?.last ?? .nan, 0.1, accuracy: 1e-9)
    }

    func testAHoldingWithTooLittleSharedHistoryIsLeftOutInsteadOfBlankingTheRest() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        // Monday 5 January 2026 onwards, skipping weekends.
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 12)))
        let weekdays = (0..<80).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
            .filter { !calendar.isDateInWeekend($0) }
        func series(_ symbol: String, _ days: ArraySlice<Date>) -> [PriceSnapshot] {
            days.enumerated().map {
                PriceSnapshot(timestamp: $1, price: 100 + Double($0), previousClose: 100, symbol: symbol)
            }
        }
        let history = [
            "AAA": series("AAA", weekdays[0..<30]),
            "BBB": series("BBB", weekdays[0..<30]),
            "NEW": series("NEW", weekdays[25..<30]),
            // Enough days of its own, but only five shared with the others.
            "LATE": series("LATE", weekdays[25..<50])
        ]

        let all = CorrelationMatrixService.alignedDailyReturns(from: history, calendar: calendar)
        XCTAssertEqual(all.commonDays, 5, "Without a minimum, the newest holding limits everyone")
        XCTAssertEqual(all.excluded, [])

        let aligned = CorrelationMatrixService.alignedDailyReturns(
            from: history, calendar: calendar, minimumCommonDays: 20
        )
        XCTAssertEqual(aligned.excluded, ["LATE", "NEW"])
        XCTAssertEqual(aligned.commonDays, 30)
        XCTAssertEqual(Set(aligned.returns.keys), ["AAA", "BBB"])
        XCTAssertEqual(aligned.returns["AAA"]?.count, 29)
    }

    func testAnnualizedVolatilityRejectsTooShortSeries() {
        XCTAssertNil(CorrelationMatrixService.annualizedVolatility(of: [0.01]))
        XCTAssertEqual(
            CorrelationMatrixService.annualizedVolatility(of: [0.01, -0.01]) ?? .nan,
            0.01414213562 * sqrt(252),
            accuracy: 1e-6
        )
    }

    // MARK: - Sector table (F61, F62, F115)

    func testSectorLookupKeepsUKSuffixSoItCannotCollideWithUSTickers() {
        typealias Sector = SectorAnalysisService.Sector
        // Tesco vs Tractor Supply share the letters TSCO.
        XCTAssertEqual(Sector.forSymbol("TSCO"), .consumerCyclical)
        XCTAssertEqual(Sector.forSymbol("TSCO.L"), .consumerDefensive)
        XCTAssertEqual(Sector.forSymbol("tsco.lon"), .consumerDefensive)
        // Reckitt vs a US ticker with the same letters: a bare symbol never matches a UK entry.
        XCTAssertEqual(Sector.forSymbol("RKT.L"), .consumerDefensive)
        XCTAssertEqual(Sector.forSymbol("RKT"), .unknown)
        XCTAssertEqual(Sector.forSymbol("AUTO"), .unknown)
        XCTAssertEqual(Sector.forSymbol("AUTO.L"), .communicationServices)
        XCTAssertEqual(Sector.forSymbol("SAGE"), .healthcare, "SAGE is Sage Therapeutics")
        XCTAssertEqual(Sector.forSymbol("SGE.L"), .technology, "Sage Group trades as SGE")
    }

    func testSectorTableCorrectsKnownUKMisclassifications() {
        typealias Sector = SectorAnalysisService.Sector
        XCTAssertEqual(Sector.forSymbol("BATS.L"), .consumerDefensive)
        XCTAssertEqual(Sector.forSymbol("OCDO.L"), .consumerDefensive)
        XCTAssertEqual(Sector.forSymbol("AAF.L"), .communicationServices)
        XCTAssertEqual(Sector.forSymbol("BNZL.L"), .industrials)
        XCTAssertEqual(Sector.forSymbol("EZJ.L"), .industrials)
        XCTAssertEqual(Sector.forSymbol("PSN.L"), .consumerCyclical)
        XCTAssertEqual(Sector.forSymbol("OSCR"), .healthcare)
        XCTAssertEqual(Sector.forSymbol("SMSD.L"), .technology)
        XCTAssertEqual(Sector.forSymbol("CARD.L"), .consumerCyclical)
        XCTAssertEqual(Sector.forSymbol("COPG.L"), .basicMaterials)
        XCTAssertEqual(Sector.forSymbol("HELP"), .healthcare)
        XCTAssertEqual(Sector.forSymbol("DFTX"), .healthcare)
        XCTAssertEqual(Sector.forSymbol("VOD.L"), .communicationServices)
    }

    func testAttributionSharesTheSectorTable() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(86400)
        func positions(_ price: Double) -> [PositionSnapshot] {
            ["META", "TSCO.L", "NEE"].map {
                PositionSnapshot(symbol: $0, units: 1, priceAtDate: price, valueAtDate: price, currency: "GBP")
            }
        }
        let result = await AttributionAnalysisService.shared.calculateAttributionFromHistorical(
            startDate: start, endDate: end,
            historicalSnapshots: [attributionSnapshot(start, total: 300, positions: positions(100)),
                                  attributionSnapshot(end, total: 330, positions: positions(110))],
            convert: attributionConvert)
        let bySymbol = Dictionary(firstValuesFor: try XCTUnwrap(result).stockContributions.map { ($0.symbol, $0.sector) })
        XCTAssertEqual(bySymbol["META"], "Communication Services")
        XCTAssertEqual(bySymbol["TSCO.L"], "Consumer Defensive")
        XCTAssertEqual(bySymbol["NEE"], "Utilities")
    }

    func testDiversificationScoreIgnoresUnknownSectorAndReportsUnclassifiedShare() async {
        let service = SectorAnalysisService()
        // Two equal classified sectors (80) plus 20 unknown.
        let allocations = await service.calculateSectorAllocations(
            positions: ["AAPL": 40, "JPM": 40, "ZZZZ": 20], dayChanges: [:])
        let analysis = await service.analyzeDiversification(sectorAllocations: allocations)

        XCTAssertTrue(analysis.isAvailable)
        XCTAssertEqual(analysis.unclassifiedPercentage, 20, accuracy: 0.001)
        // Score matches the same two sectors without the unknown holding.
        let classifiedOnly = await service.calculateSectorAllocations(
            positions: ["AAPL": 40, "JPM": 40], dayChanges: [:])
        let reference = await service.analyzeDiversification(sectorAllocations: classifiedOnly)
        XCTAssertEqual(analysis.score, reference.score, accuracy: 0.001)
        XCTAssertFalse(analysis.recommendations.contains { $0.contains("Unknown") })
    }

    func testDiversificationIsUnavailableWhenMostOfThePortfolioIsUnclassified() async {
        let service = SectorAnalysisService()
        let allocations = await service.calculateSectorAllocations(
            positions: ["AAPL": 30, "ZZZZ": 70], dayChanges: [:])
        let analysis = await service.analyzeDiversification(sectorAllocations: allocations)

        XCTAssertFalse(analysis.isAvailable)
        XCTAssertTrue(analysis.score.isNaN)
        XCTAssertEqual(analysis.unclassifiedPercentage, 70, accuracy: 0.001)

        let allUnknown = await service.calculateSectorAllocations(positions: ["ZZZZ": 10], dayChanges: [:])
        let unknownAnalysis = await service.analyzeDiversification(sectorAllocations: allUnknown)
        XCTAssertFalse(unknownAnalysis.isAvailable)
        XCTAssertEqual(unknownAnalysis.unclassifiedPercentage, 100, accuracy: 0.001)
    }

    // MARK: - Numeric edge cases (F114)

    func testAttributionSkipsNonFinitePositionData() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(86400)
        let good = PositionSnapshot(symbol: "AAPL", units: 10, priceAtDate: 100, valueAtDate: 1000, currency: "GBP")
        let goodEnd = PositionSnapshot(symbol: "AAPL", units: 10, priceAtDate: 110, valueAtDate: 1100, currency: "GBP")
        let badStart = PositionSnapshot(symbol: "MSFT", units: .nan, priceAtDate: 100, valueAtDate: 1000, currency: "GBP")
        let badEnd = PositionSnapshot(symbol: "MSFT", units: 10, priceAtDate: 110, valueAtDate: .infinity, currency: "GBP")

        let result = await AttributionAnalysisService.shared.calculateAttributionFromHistorical(
            startDate: start, endDate: end,
            historicalSnapshots: [attributionSnapshot(start, total: 2000, positions: [good, badStart]),
                                  attributionSnapshot(end, total: 2100, positions: [goodEnd, badEnd])],
            convert: attributionConvert)
        let attribution = try XCTUnwrap(result)

        XCTAssertEqual(attribution.stockContributions.map(\.symbol), ["AAPL"])
        XCTAssertTrue(attribution.portfolioReturn.isFinite)
        XCTAssertTrue(attribution.waterfallData.allSatisfy { $0.value.isFinite && $0.cumulativeValue.isFinite })
    }

    func testCorrelationOfAZeroVarianceSeriesIsUndefinedNotZero() async throws {
        let service = CorrelationMatrixService()
        let matrix = await service.calculateCorrelationMatrix(returns: [
            "FLAT": [0.01, 0.01, 0.01, 0.01, 0.01],
            "AAPL": [0.01, 0.02, -0.01, 0.03, 0.00],
            "MSFT": [0.012, 0.018, -0.008, 0.031, 0.002]
        ])

        XCTAssertNil(matrix.correlation(between: "FLAT", between: "AAPL"))
        XCTAssertNil(matrix.correlation(between: "AAPL", between: "FLAT"))
        XCTAssertNotNil(matrix.correlation(between: "AAPL", between: "MSFT"))

        let pairs = await service.findTopCorrelations(correlationMatrix: matrix, count: 10)
        XCTAssertEqual(pairs.count, 1, "undefined pairs are not ranked")
        let bottom = await service.findBottomCorrelations(correlationMatrix: matrix, count: 10)
        XCTAssertEqual(bottom.count, 1)
    }

    func testCorrelationRejectsMismatchedOrNonFiniteSeries() {
        XCTAssertNil(CorrelationMatrixService.pearsonCorrelation([1, 2, 3], [1, 2]))
        XCTAssertNil(CorrelationMatrixService.pearsonCorrelation([1, .nan, 3], [1, 2, 3]))
        XCTAssertEqual(try XCTUnwrap(CorrelationMatrixService.pearsonCorrelation([1, 2, 3], [2, 4, 6])), 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(CorrelationMatrixService.pearsonCorrelation([1, 2, 3], [3, 2, 1])), -1, accuracy: 1e-9)
    }

    func testDiversificationScoreIsClampedToZeroToOneHundred() {
        let negativeCorrelation = CorrelationMatrixService.DiversificationMetrics(
            averageCorrelation: -1, maxCorrelation: 0, minCorrelation: -1,
            effectiveN: 40, diversificationRatio: 3, concentrationScore: 0)
        XCTAssertEqual(negativeCorrelation.diversificationScore, 100, accuracy: 0.0001)

        let degenerate = CorrelationMatrixService.DiversificationMetrics(
            averageCorrelation: 5, maxCorrelation: 5, minCorrelation: 5,
            effectiveN: -3, diversificationRatio: 1, concentrationScore: 4)
        XCTAssertEqual(degenerate.diversificationScore, 0, accuracy: 0.0001)

        let nonFinite = CorrelationMatrixService.DiversificationMetrics(
            averageCorrelation: .nan, maxCorrelation: 0, minCorrelation: 0,
            effectiveN: 1, diversificationRatio: 1, concentrationScore: 1)
        XCTAssertTrue((0...100).contains(nonFinite.diversificationScore))
    }
}

final class CSVExportFormatterTests: XCTestCase {
    func testExportNotesEveryActiveFilter() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let from = Date(timeIntervalSince1970: 1_793_750_400) // 2026-11-04
        let toExclusive = from.addingTimeInterval(3 * 86_400)  // through 2026-11-06

        XCTAssertEqual(
            ExportManager.filterNotes(valueThreshold: 0, dateWindow: nil, selectedPoints: 0, calendar: calendar),
            [],
            "An unfiltered export carries no filter notes"
        )
        XCTAssertEqual(
            ExportManager.filterNotes(valueThreshold: 1500, dateWindow: (from, toExclusive), selectedPoints: 12, calendar: calendar),
            ["values below 1500 excluded", "dates 2026-11-04 to 2026-11-06", "only the 12 selected point(s)"]
        )
    }

    func testDatesAreISO8601UTCWithoutCommasRegardlessOfLocale() {
        let date = Date(timeIntervalSince1970: 1_793_788_200) // 2026-11-04T10:30:00Z
        let formatted = CSVExportFormatter.isoDate(date)

        XCTAssertEqual(formatted, "2026-11-04T10:30:00Z")
        XCTAssertFalse(formatted.contains(","))
    }

    func testChartDataRowsUseISODatesAndPosixNumbers() {
        let points = [
            ChartDataPoint(date: Date(timeIntervalSince1970: 1_793_788_200), value: 1234.5),
            ChartDataPoint(date: Date(timeIntervalSince1970: 1_793_874_600), value: .nan)
        ]

        let rows = CSVExportFormatter.chartDataRows(points)

        XCTAssertEqual(rows, "2026-11-04T10:30:00Z,1234.5\r\n2026-11-05T10:30:00Z,\r\n")
    }

    func testTextCellsAreQuotedPerRFC4180() {
        XCTAssertEqual(CSVExportFormatter.text("plain"), "plain")
        XCTAssertEqual(CSVExportFormatter.text("a,b"), "\"a,b\"")
        XCTAssertEqual(CSVExportFormatter.text("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(CSVExportFormatter.text("two\nlines"), "\"two\nlines\"")
    }

    func testTextCellsStartingWithFormulaCharactersAreEscaped() {
        for payload in ["=1+1", "+SUM(A1)", "-2+3", "@cmd", "\t=1"] {
            XCTAssertTrue(CSVExportFormatter.text(payload).hasPrefix("'"), "\(payload) must be neutralised")
        }
        XCTAssertEqual(CSVExportFormatter.text("=HYPERLINK(\"x\",\"y\")"), "\"'=HYPERLINK(\"\"x\"\",\"\"y\"\")\"")
        // Numbers are written by `number`, so a negative value stays numeric.
        XCTAssertEqual(CSVExportFormatter.number(-12.5), "-12.5")
    }

    func testPortfolioSnapshotsCSVHasStableColumnsAndEscapedSymbols() {
        let date = Date(timeIntervalSince1970: 1_793_788_200)
        let snapshot = HistoricalPortfolioSnapshot(
            date: date, totalValue: 1000.25, totalGains: -5, totalCost: 1005.25, currency: "GBP",
            portfolioComposition: [
                "=EVIL": PositionSnapshot(symbol: "=EVIL", units: 2, priceAtDate: 10, valueAtDate: 20, currency: "GBP")
            ])

        let lines = CSVExportFormatter.portfolioSnapshotsCSV([snapshot]).components(separatedBy: "\r\n")

        XCTAssertEqual(lines[0], "Date,Total Value,Total Gains,Total Cost,Currency,'=EVIL Units,'=EVIL Price,'=EVIL Value")
        XCTAssertEqual(lines[1], "2026-11-04T10:30:00Z,1000.25,-5.0,1005.25,GBP,2.0,10.0,20.0")
    }
}

final class AttributionPresentationTests: XCTestCase {
    func testWaterfallBarsFloatFromRunningTotalsAndStartAndEndAreSummaries() {
        let data = [
            WaterfallDataPoint(label: "Starting Value", value: 1000, cumulativeValue: 1000, isSummary: true),
            WaterfallDataPoint(label: "AAPL", value: 80, cumulativeValue: 1080),
            WaterfallDataPoint(label: "VOD.L", value: -30, cumulativeValue: 1050),
            WaterfallDataPoint(label: "Trades & Other", value: 40, cumulativeValue: 1090),
            WaterfallDataPoint(label: "Ending Value", value: 1090, cumulativeValue: 1090, isSummary: true)
        ]

        let bars = WaterfallBars.make(from: data)

        XCTAssertEqual(bars.map(\.label), ["Starting Value", "AAPL", "VOD.L", "Trades & Other", "Ending Value"])
        XCTAssertEqual(bars[0].end, 1000, accuracy: 0.0001)
        XCTAssertTrue(bars[0].isSummary)
        XCTAssertEqual(bars[1].start, 1000, accuracy: 0.0001)
        XCTAssertEqual(bars[1].end, 1080, accuracy: 0.0001)
        XCTAssertEqual(bars[2].start, 1080, accuracy: 0.0001, "a loss starts at the previous running total")
        XCTAssertEqual(bars[2].end, 1050, accuracy: 0.0001)
        XCTAssertEqual(bars[3].start, 1050, accuracy: 0.0001)
        XCTAssertEqual(bars[3].end, 1090, accuracy: 0.0001)
        XCTAssertEqual(bars[4].end, 1090, accuracy: 0.0001, "ending bar is the total, not a contribution")
    }

    func testWaterfallDomainMakesSmallContributionsVisibleAndSkipsNonFinitePoints() {
        let data = [
            WaterfallDataPoint(label: "Start", value: 10_000, cumulativeValue: 10_000, isSummary: true),
            WaterfallDataPoint(label: "A", value: 50, cumulativeValue: 10_050),
            WaterfallDataPoint(label: "Bad", value: .nan, cumulativeValue: .nan),
            WaterfallDataPoint(label: "End", value: 10_050, cumulativeValue: 10_050, isSummary: true)
        ]
        let bars = WaterfallBars.make(from: data)
        XCTAssertEqual(bars.count, 3)

        let domain = WaterfallBars.yDomain(for: bars)
        XCTAssertGreaterThan(domain.lowerBound, 9_000, "axis must not start at zero")
        XCTAssertLessThan(domain.lowerBound, 10_000)
        XCTAssertGreaterThan(domain.upperBound, 10_050)
        XCTAssertEqual(WaterfallBars.yDomain(for: []), 0...1)
    }

    func testAttributionFormatsCarrySignAndWordingNotJustColour() {
        XCTAssertEqual(AttributionFormat.signedPercent(2.5), "+2.50%")
        XCTAssertEqual(AttributionFormat.signedPercent(-1.234), "-1.23%")
        XCTAssertEqual(AttributionFormat.signedPercent(0), "0.00%")
        XCTAssertEqual(AttributionFormat.signedPercent(.nan), "—")
        XCTAssertEqual(AttributionFormat.spokenPercent(2.5), "up 2.50 percent")
        XCTAssertEqual(AttributionFormat.spokenPercent(-2.5), "down 2.50 percent")
        XCTAssertEqual(AttributionFormat.direction(5), "gain")
        XCTAssertEqual(AttributionFormat.direction(-5), "loss")
        XCTAssertEqual(AttributionFormat.direction(0), "no change")
    }

    func testAllocationRangeDrivesTheCorrelationLookbackAndNeverDropsBelowTheMinimum() {
        typealias Range = PortfolioAnalyticsView.TimeRange
        XCTAssertEqual(Range.threeMonths.correlationLookbackDays, 90)
        XCTAssertEqual(Range.sixMonths.correlationLookbackDays, 180)
        XCTAssertEqual(Range.oneYear.correlationLookbackDays, 365)
        XCTAssertGreaterThanOrEqual(Range.oneMonth.correlationLookbackDays, PortfolioAnalyticsView.minimumLookbackCalendarDays)
        XCTAssertLessThan(Range.all.correlationLookbackDays, Int.max, "All must be a bounded lookback")
        XCTAssertGreaterThan(Range.all.correlationLookbackDays, Range.oneYear.correlationLookbackDays)
        let lookbacks = Range.allCases.map(\.correlationLookbackDays)
        XCTAssertEqual(lookbacks, lookbacks.sorted(), "a longer range never means a shorter window")
    }
}

// MARK: - Income page (invented figures)

/// Stands in for `FolyncSupplementalCoordinator`: records every call and
/// answers from a queue. With `holds` on, each call waits until `release()`.
private actor IncomeRouterStandIn: StockbarIncomeRouting {
    struct Call: Equatable {
        let query: FolyncDividendsQuery
        let forceRefresh: Bool
        let cursor: String?
    }

    private(set) var calls: [Call] = []
    private var answers: [FolyncRoutedDividendsResult] = []
    private var holds = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func answer(_ results: FolyncRoutedDividendsResult...) { answers += results }
    func hold(_ on: Bool) { holds = on }
    func release() {
        waiting.forEach { $0.resume() }
        waiting = []
    }
    var waitingCount: Int { waiting.count }
    func releaseLast() {
        if !waiting.isEmpty { waiting.removeLast().resume() }
    }

    func routeDividends(_ query: FolyncDividendsQuery, forceRefresh: Bool) async -> FolyncRoutedDividendsResult {
        await record(Call(query: query, forceRefresh: forceRefresh, cursor: nil))
    }

    func loadMoreDividends(_ query: FolyncDividendsQuery, after continuation: FolyncLedgerContinuation) async
        -> FolyncRoutedDividendsResult {
        await record(Call(query: query, forceRefresh: true, cursor: continuation.cursor))
    }

    private func record(_ call: Call) async -> FolyncRoutedDividendsResult {
        calls.append(call)
        let answer = answers.isEmpty ? FolyncRoutedDividendsResult.unavailable : answers.removeFirst()
        if holds { await withCheckedContinuation { waiting.append($0) } }
        return answer
    }
}

private enum IncomeFixture {
    /// Friday 20 November 2026, noon UTC.
    static let now = Date(timeIntervalSince1970: 1_795_176_000)
    static let today = FolyncLedgerDay(year: 2026, month: 11, day: 20)
    static let utc = TimeZone(identifier: "UTC") ?? .gmt
    static let britishEnglish = Locale(identifier: "en_GB")

    static func identity(_ ticker: String) -> FolyncInstrumentIdentity {
        FolyncInstrumentIdentity(assetId: "asset_\(ticker)", canonicalTicker: ticker, displayTicker: ticker,
                                 quoteSymbol: "\(ticker).L", aliases: [ticker], isin: nil)
    }

    static func metric(_ value: Double?, currency: String = "GBP",
                       quality: FolyncFinancialQuality = .complete) -> FolyncFinancialMetric {
        FolyncFinancialMetric(value: value, currency: currency, quality: quality, reasonCodes: [], asOfDate: nil)
    }

    static func discovery(_ id: String, amount: String, date: String) -> FolyncDividendEventDiscovery {
        FolyncDividendEventDiscovery(
            eventId: id, exDate: nil, declarationDate: nil, recordDate: nil,
            amountCertainty: FolyncOpenEnum(rawValue: amount), dateCertainty: FolyncOpenEnum(rawValue: date),
            source: nil, lastCheckedAt: nil, entitlementBasis: nil, quantity: nil, originalCurrency: nil,
            perShare: nil, fxAsOfDate: nil, fxEstimated: nil, receiptStatus: nil, issues: nil
        )
    }

    static func event(_ id: String, _ ticker: String, pay: String, ex: String? = nil, status: String = "upcoming",
                      gbp: Double?, quality: FolyncFinancialQuality = .complete, metricCurrency: String = "GBP",
                      own: Double? = nil, ownCurrency: String = "GBP",
                      certainty: (amount: String, date: String)? = nil) -> FolyncDividendEvent {
        FolyncDividendEvent(
            eventId: id, portfolioId: "pf_demo", portfolioName: "Demo", assetId: "asset_\(ticker)",
            identity: identity(ticker), transactionId: nil, exDate: ex, payDate: pay,
            status: FolyncOpenEnum(rawValue: status), amount: own ?? gbp, currency: ownCurrency,
            portfolioAmount: metric(gbp, currency: metricCurrency, quality: quality),
            discovery: certainty.map { discovery(id, amount: $0.amount, date: $0.date) }
        )
    }

    static let base: FolyncDividendsResponse = {
        let json = """
        {"schemaVersion":2,"sourceRevision":"rev","generatedAt":"2026-11-20T10:05:00.000Z",
         "scope":{"id":"all","name":"Demo","kind":"aggregate","currency":"GBP"},"currency":"GBP",
         "quality":"complete","reasonCodes":[],
         "freshness":{"responseGeneratedAt":"2026-11-20T10:05:00.000Z","asOf":"2026-11-20","status":"current","reasonCodes":[],
          "sources":{"snapshots":{"asOfDate":"2026-11-20","status":"clean","generation":1,"dirtySince":null,
          "rebuildStartedAt":null,"failedAt":null,"completedAt":"2026-11-20T10:00:00.000Z"},
          "prices":{"asOfDate":"2026-11-20","ageSeconds":60,"missingCount":0},
          "fx":{"asOfDate":"2026-11-20","ageSeconds":60,"missingCount":0},
          "provider":{"lastSuccessfulSyncAt":"2026-11-20T10:00:00.000Z","ageSeconds":60,"requiredCount":1,"coveredCount":1,"missingCount":0}}},
         "valuation":{"value":5000,"currency":"GBP","quality":"complete","reasonCodes":[],"asOfDate":"2026-11-20"},
         "holdingCoverage":{"totalHoldings":9,"valuedHoldings":9,"missingHoldings":0,
          "marketValue":{"value":5000,"currency":"GBP","quality":"complete","reasonCodes":[],"asOfDate":"2026-11-20"}},
         "summary":{"receivedIncome":321.5,"grossIncome":330,"withholdingTax":8.5,"fees":0,"netIncome":321.5,
          "withholdingProvenance":"actual","declaredIncome":100.25,"estimatedIncome":null,"knownProjectedIncome":400,
          "incomplete":true,"projectedAnnualIncome":456.78,"yoyChangePct":null,"portfolioYieldTTMPct":2.5,
          "yieldOnCostTTMPct":null,"avgMonthlyIncome":null,"avgDailyIncome":null,"dividendPayingAssets":8},
         "events":[],
         "page":{"limit":200,"hasMore":false,"nextCursor":null,"collectionRevision":"rev-a"}}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(FolyncDividendsResponse.self, from: Data(json.utf8))
    }()

    static func response(_ events: [FolyncDividendEvent], cursor: String? = nil, revision: String = "rev-a",
                         quality: FolyncFinancialQuality = .complete, reasons: [String] = []) -> FolyncDividendsResponse {
        let base = base
        return FolyncDividendsResponse(
            schemaVersion: base.schemaVersion, sourceRevision: base.sourceRevision, generatedAt: base.generatedAt,
            scope: base.scope, currency: base.currency, quality: quality, reasonCodes: reasons,
            freshness: base.freshness, valuation: base.valuation, holdingCoverage: base.holdingCoverage,
            summary: base.summary, discovery: nil, events: events,
            page: FolyncReadPage(limit: 200, hasMore: cursor != nil, nextCursor: cursor, collectionRevision: revision)
        )
    }
}

@MainActor
final class StockbarIncomePageTests: XCTestCase {
    private typealias F = IncomeFixture

    private func makeModel(_ router: IncomeRouterStandIn) -> StockbarIncomeModel {
        StockbarIncomeModel(router: router, now: { F.now }, timeZone: F.utc)
    }

    /// Lets queued main-actor work run until `condition` holds, or fails.
    private func settle(_ condition: @MainActor () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("condition never held", file: file, line: line)
    }

    /// Gives any stray work plenty of turns to run.
    private func drain() async {
        for _ in 0..<200 { await Task.yield() }
    }

    // MARK: When it asks

    func testNoRequestUntilThePageIsSelected() async {
        let router = IncomeRouterStandIn()
        let model = makeModel(router)
        await drain()
        let calls = await router.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(model.phase, .idle)
    }

    func testNoRequestForAPortfolioThatIsNotFolyncs() async {
        let router = IncomeRouterStandIn()
        let model = makeModel(router)
        model.activate(isFolyncPortfolio: false)
        model.refresh()
        model.loadMore()
        await drain()
        let calls = await router.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(model.phase, .needsFolync)
        XCTAssertEqual(StockbarIncomeModel.needsFolyncReason, "Needs a Folync portfolio")
    }

    func testOneRequestOnActivateNoneOnASecondAndReopeningLeavesReuseToThePolicy() async throws {
        let router = IncomeRouterStandIn()
        await router.answer(.folync(F.response([]), status: .current, paging: .firstPage),
                            .folync(F.response([]), status: .current, paging: .firstPage))
        let model = makeModel(router)
        model.activate(isFolyncPortfolio: true)
        model.activate(isFolyncPortfolio: true)
        await settle { model.phase == .loaded }
        var calls = await router.calls
        XCTAssertEqual(calls.count, 1, "one request serves all three views")
        let call = try XCTUnwrap(calls.first)
        XCTAssertFalse(call.forceRefresh, "opening the page lets the fetch policy reuse a recent answer")
        XCTAssertEqual(call.query, IncomeFigures.query(today: F.today))

        model.deactivate()
        model.activate(isFolyncPortfolio: true)
        await settle { await router.calls.count == 2 }
        calls = await router.calls
        XCTAssertFalse(calls[1].forceRefresh, "reopening never bypasses the policy's five-minute reuse")
    }

    func testSwitchingViewsMakesNoRequest() async {
        let router = IncomeRouterStandIn()
        await router.answer(.folync(F.response([]), status: .current, paging: .firstPage))
        let model = makeModel(router)
        model.activate(isFolyncPortfolio: true)
        await settle { model.phase == .loaded }
        for view in [StockbarIncomeModel.View.history, .byHolding, .outlook, .history] {
            model.view = view
        }
        await drain()
        let count = await router.calls.count
        XCTAssertEqual(count, 1)
    }

    func testTheRefreshControlAsksWithForceRefresh() async {
        let router = IncomeRouterStandIn()
        await router.answer(.folync(F.response([]), status: .current, paging: .firstPage),
                            .folync(F.response([]), status: .current, paging: .firstPage))
        let model = makeModel(router)
        model.activate(isFolyncPortfolio: true)
        await settle { model.phase == .loaded }
        model.refresh()
        await settle { await router.calls.count == 2 }
        let calls = await router.calls
        XCTAssertEqual(calls.map(\.forceRefresh), [false, true])
        XCTAssertEqual(calls[0].query, calls[1].query)
    }

    func testTheQueryCoversTwelveMonthsEachWayAtTheLargestPage() {
        let query = IncomeFigures.query(today: F.today)
        XCTAssertEqual(query.status, .all)
        XCTAssertEqual(query.from, FolyncLedgerDay(year: 2025, month: 11, day: 20))
        XCTAssertEqual(query.to, FolyncLedgerDay(year: 2027, month: 11, day: 20))
        XCTAssertEqual(query.limit, FolyncDividendsQuery.maximumLimit)
        let leap = IncomeFigures.query(today: FolyncLedgerDay(year: 2028, month: 2, day: 29))
        XCTAssertEqual(leap.from, FolyncLedgerDay(year: 2027, month: 2, day: 28), "a short month keeps its last day")
    }

    // MARK: States

    func testEachStateTheAnswerCanPutThePageIn() async {
        let saved = F.response([F.event("e1", "ULVR", pay: "2026-10-01", status: "received", gbp: 10)])
        let cases: [(FolyncRoutedDividendsResult, StockbarIncomeModel.Phase, Bool)] = [
            (.folync(F.response([]), status: .current, paging: .firstPage), .loaded, true),
            (.folync(F.response([], quality: .partial, reasons: ["fx_stale"]), status: .partial, paging: .firstPage), .loaded, true),
            (.folync(saved, status: .stale, paging: .firstPage),
             .saved(savedAt: FolyncSupplementalDateParser.instant(saved.generatedAt)), true),
            (.unreachable, .unreachable, false),
            (.unavailable, .unavailable, false),
            (.disabled, .switchedOff, false)
        ]
        for (result, phase, hasContent) in cases {
            let router = IncomeRouterStandIn()
            await router.hold(true)
            await router.answer(result)
            let model = makeModel(router)
            model.activate(isFolyncPortfolio: true)
            XCTAssertEqual(model.phase, .loading, "loading for the first time")
            await settle { await router.waitingCount == 1 }
            await router.release()
            await settle { model.phase != .loading }
            XCTAssertEqual(model.phase, phase)
            XCTAssertEqual(model.hasContent, hasContent)
        }
    }

    func testTheSavedCopyAndPartialNoticesSayWhatTheyAre() {
        let savedAt = Date(timeIntervalSince1970: 1_795_169_400) // 10:10 UTC on 20 Nov 2026
        XCTAssertEqual(IncomeText.savedNotice(savedAt: savedAt, now: F.now, locale: F.britishEnglish, timeZone: F.utc),
                       "Couldn't get new figures from Folync. Showing the income saved at 10:10.")
        XCTAssertNil(IncomeText.partialNotice(F.response([])))
        XCTAssertEqual(IncomeText.partialNotice(F.response([], quality: .partial, reasons: ["fx_stale", "prices_stale"])),
                       "Folync marks these figures partial: fx stale, prices stale.")
    }

    // MARK: Load more

    func testLoadMoreAppendsTheNextPageOfTheSameQuery() async throws {
        let router = IncomeRouterStandIn()
        await router.answer(
            .folync(F.response([F.event("e1", "ULVR", pay: "2026-12-11", gbp: 58.4)], cursor: "c1"), status: .current, paging: .firstPage),
            .folync(F.response([F.event("e2", "HSBA", pay: "2026-11-24", gbp: 38.2)]), status: .current, paging: .nextPage)
        )
        let model = makeModel(router)
        model.activate(isFolyncPortfolio: true)
        await settle { model.phase == .loaded }
        XCTAssertEqual(model.chart?.isIncomplete, true, "more events exist than the first page holds")
        model.loadMore()
        await settle { model.events.count == 2 }
        let calls = await router.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[1].cursor, "c1")
        XCTAssertEqual(calls[1].query, calls[0].query, "the cursor is bound to the query that made it")
        XCTAssertEqual(model.events.map(\.eventId), ["e1", "e2"])
        XCTAssertNil(model.continuation)
        XCTAssertEqual(model.chart?.isIncomplete, false)
    }

    func testARestartedResultDropsTheRowsGathered() async {
        let router = IncomeRouterStandIn()
        await router.answer(
            .folync(F.response([F.event("e1", "ULVR", pay: "2026-12-11", gbp: 58.4)], cursor: "c1"), status: .current, paging: .firstPage),
            .folync(F.response([F.event("n1", "LGEN", pay: "2027-01-08", gbp: 112.6)], revision: "rev-b"),
                    status: .current, paging: .restarted)
        )
        let model = makeModel(router)
        model.activate(isFolyncPortfolio: true)
        await settle { model.phase == .loaded }
        model.loadMore()
        await settle { model.events.first?.eventId == "n1" }
        XCTAssertEqual(model.events.map(\.eventId), ["n1"])
        XCTAssertNil(model.continuation)
    }

    func testALoadMoreThatFailsKeepsTheRows() async {
        let router = IncomeRouterStandIn()
        await router.answer(
            .folync(F.response([F.event("e1", "ULVR", pay: "2026-12-11", gbp: 58.4)], cursor: "c1"), status: .current, paging: .firstPage),
            .unreachable
        )
        let model = makeModel(router)
        model.activate(isFolyncPortfolio: true)
        await settle { model.phase == .loaded }
        model.loadMore()
        await settle { model.loadMoreFailed }
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.events.map(\.eventId), ["e1"])
        XCTAssertNotNil(model.continuation, "Load more can be tried again")
    }

    // MARK: Superseded and cancelled work

    func testARefreshCancelsTheLoadItSupersedesAndThatResultIsNeverApplied() async {
        let router = IncomeRouterStandIn()
        await router.hold(true)
        await router.answer(.unavailable, // the superseded call; must never reach the screen
                            .folync(F.response([F.event("e1", "ULVR", pay: "2026-12-11", gbp: 58.4)]),
                                    status: .current, paging: .firstPage))
        let model = makeModel(router)
        model.activate(isFolyncPortfolio: true)
        await settle { await router.waitingCount == 1 }
        model.refresh()
        await settle { await router.waitingCount == 2 }
        await router.releaseLast() // the refresh answers first
        await settle { model.phase == .loaded }
        await router.release() // then the superseded call's .unavailable arrives
        await drain()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.events.map(\.eventId), ["e1"])
        let calls = await router.calls
        XCTAssertEqual(calls.map(\.forceRefresh), [false, true])
    }

    func testAResultForAPageNoLongerSelectedIsNeverApplied() async {
        let router = IncomeRouterStandIn()
        await router.hold(true)
        await router.answer(.unavailable)
        let model = makeModel(router)
        model.activate(isFolyncPortfolio: true)
        await settle { await router.waitingCount == 1 }
        model.deactivate()
        await router.release()
        await drain()
        XCTAssertNotEqual(model.phase, .unavailable, "a cancelled caller's .unavailable never reaches the screen")
        XCTAssertFalse(model.hasContent)
    }

    func testARefreshWhileOneIsInFlightIsIgnored() async {
        let router = IncomeRouterStandIn()
        await router.answer(.folync(F.response([]), status: .current, paging: .firstPage))
        let model = makeModel(router)
        model.activate(isFolyncPortfolio: true)
        await settle { model.phase == .loaded }
        await router.hold(true)
        model.refresh()
        model.refresh()
        await settle { await router.waitingCount == 1 }
        await drain()
        let count = await router.calls.count
        XCTAssertEqual(count, 2)
        await router.release()
    }

    // MARK: Derived values

    func testDaysAreReadAsCalendarDaysWithNoTimeZoneShift() {
        XCTAssertEqual(FolyncLedgerDay(string: "2026-11-30"), FolyncLedgerDay(year: 2026, month: 11, day: 30))
        XCTAssertEqual(FolyncLedgerDay(string: "2026-11-30T23:30:00-08:00"), FolyncLedgerDay(year: 2026, month: 11, day: 30))
        XCTAssertNil(FolyncLedgerDay(string: "2026-13-01"))
        XCTAssertNil(FolyncLedgerDay(string: "30/11/2026"))
        XCTAssertEqual(FolyncLedgerDay(year: 2026, month: 12, day: 31).next, FolyncLedgerDay(year: 2027, month: 1, day: 1))
    }

    func testEventsGoInTheMonthOfTheirPayDate() {
        let events = [
            F.event("a", "ULVR", pay: "2026-05-31", status: "received", gbp: 1), // before the chart
            F.event("b", "ULVR", pay: "2026-06-01", status: "received", gbp: 2),
            F.event("c", "ULVR", pay: "2026-11-30", status: "received", gbp: 4),
            F.event("d", "ULVR", pay: "2026-12-01", gbp: 8, certainty: ("published", "published")),
            F.event("e", "ULVR", pay: "2027-05-31", gbp: 16, certainty: ("estimated", "estimated")),
            F.event("f", "ULVR", pay: "2027-06-01", gbp: 32, certainty: ("estimated", "estimated")) // after it
        ]
        let chart = IncomeFigures.chart(events: events, currency: "GBP", today: F.today, isIncomplete: false)
        XCTAssertEqual(chart.months.map(\.month), (0..<12).map { IncomeMonth(year: 2026, month: 6).adding($0) })
        XCTAssertEqual(chart.months.first?.month, IncomeMonth(year: 2026, month: 6))
        XCTAssertEqual(chart.months.last?.month, IncomeMonth(year: 2027, month: 5))
        XCTAssertEqual(chart.currentIndex, 5)
        XCTAssertEqual(chart.months.map(\.total), [2, 0, 0, 0, 0, 4, 8, 0, 0, 0, 0, 16])
    }

    func testABarHasItsReceivedDeclaredAndEstimatedParts() throws {
        let events = [
            F.event("r", "ULVR", pay: "2026-11-05", status: "received", gbp: 100,
                    certainty: ("published", "published")), // received wins over any discovery detail
            F.event("d", "HSBA", pay: "2026-11-24", gbp: 38.2, certainty: ("published", "published")),
            F.event("e", "LGEN", pay: "2026-11-27", gbp: 12.5, certainty: ("estimated", "published")),
            F.event("u", "MSFT", pay: "2026-11-28", gbp: 6, certainty: ("unknown", "published")),
            F.event("n", "SHEL", pay: "2026-11-29", gbp: 4), // no discovery detail
            F.event("x", "AZN", pay: "2026-11-30", status: "announced_later", gbp: 2,
                    certainty: ("estimated", "estimated")) // a status this build does not know
        ]
        let chart = IncomeFigures.chart(events: events, currency: "GBP", today: F.today, isIncomplete: false)
        let november = try XCTUnwrap(chart.months.first { $0.month == IncomeMonth(year: 2026, month: 11) })
        XCTAssertEqual(november.received, 100, accuracy: 1e-9)
        XCTAssertEqual(november.declared, 38.2, accuracy: 1e-9)
        XCTAssertEqual(november.estimated, 14.5, accuracy: 1e-9)
        XCTAssertEqual(november.toCome, 10, accuracy: 1e-9, "not marked either way is neither declared nor estimated")
        XCTAssertEqual(chart.partsShown, [.received, .declared, .estimated, .toCome])
    }

    func testAPaymentWithNoAmountAddsNothingAndIsCounted() throws {
        let events = [
            F.event("a", "AZN", pay: "2026-12-10", gbp: nil, quality: .unavailable, certainty: ("unknown", "estimated")),
            F.event("b", "AZN", pay: "2026-12-11", gbp: 5, quality: .unavailable),
            F.event("c", "AAPL", pay: "2026-12-12", gbp: 7, metricCurrency: "USD"),
            F.event("d", "ULVR", pay: "2026-12-13", gbp: 9, quality: .partial, certainty: ("published", "published"))
        ]
        let chart = IncomeFigures.chart(events: events, currency: "GBP", today: F.today, isIncomplete: false)
        let december = try XCTUnwrap(chart.months.first { $0.month == IncomeMonth(year: 2026, month: 12) })
        XCTAssertEqual(december.total, 9, accuracy: 1e-9, "a partial amount is still Folync's amount")
        XCTAssertEqual(december.missingAmounts, 3, "no value, unavailable, or another currency")
        XCTAssertEqual(december.partialAmounts, 1)
        XCTAssertEqual(IncomeText.missingAmountsNote(chart.missingAmounts), "3 payments with no amount yet")
        XCTAssertEqual(IncomeText.missingAmountsNote(1), "1 payment with no amount yet")
        XCTAssertNil(IncomeText.missingAmountsNote(0))
    }

    func testTheChartIsIncompleteOnlyWhileMorePagesExist() async {
        let router = IncomeRouterStandIn()
        await router.answer(.folync(F.response([], cursor: "c1"), status: .current, paging: .firstPage))
        let model = makeModel(router)
        model.activate(isFolyncPortfolio: true)
        await settle { model.phase == .loaded }
        XCTAssertEqual(model.chart?.isIncomplete, true)
        XCTAssertEqual(IncomeFigures.chart(events: [], currency: "GBP", today: F.today, isIncomplete: false).isIncomplete, false)
    }

    func testWhatIsComingIsSoonestFirstWithExDatesBeforePayments() {
        let events = [
            F.event("lgen", "LGEN", pay: "2027-01-08", ex: "2026-12-03", gbp: 112.6, certainty: ("published", "published")),
            F.event("hsba", "HSBA", pay: "2026-11-24", ex: "2026-10-09", gbp: 38.2, certainty: ("published", "published")),
            F.event("ulvr", "ULVR", pay: "2026-12-11", ex: "2026-11-21", gbp: 58.4, certainty: ("published", "published")),
            F.event("msft", "MSFT", pay: "2026-12-11", gbp: 6.12),
            F.event("bats", "BATS", pay: "2026-12-11", ex: "2026-12-11", gbp: 1), // ex on the pay day: one row
            F.event("past", "SHEL", pay: "2026-09-18", status: "received", gbp: 41.02)
        ]
        let rows = IncomeFigures.upcoming(events: events, currency: "GBP", today: F.today)
        XCTAssertEqual(rows.map(\.id), ["ulvr#ex", "hsba#pay", "lgen#ex", "bats#pay", "msft#pay", "ulvr#pay", "lgen#pay"])
        XCTAssertEqual(rows.first?.kind, .exDividend(payDay: FolyncLedgerDay(year: 2026, month: 12, day: 11)))
        XCTAssertEqual(IncomeText.dayLabel(rows[0].date, today: F.today, locale: F.britishEnglish), "Tomorrow")
        XCTAssertEqual(IncomeText.dayLabel(rows[1].date, today: F.today, locale: F.britishEnglish), "Tue 24 Nov")
        XCTAssertEqual(IncomeText.dayLabel(F.today, today: F.today, locale: F.britishEnglish), "Today")
        XCTAssertEqual(IncomeText.upcomingDayLabel(FolyncLedgerDay(year: 2027, month: 5, day: 20), today: F.today,
                                                   locale: F.britishEnglish), "Thu 20 May", "within six months")
        XCTAssertEqual(IncomeText.upcomingDayLabel(FolyncLedgerDay(year: 2027, month: 6, day: 8), today: F.today,
                                                   locale: F.britishEnglish), "Tue 8 Jun 2027", "past the chart")
    }

    func testThePillComesOnlyFromFolyncsDiscoveryDetail() {
        func pill(_ amount: String, _ date: String) -> String? {
            IncomeFigures.pill(for: F.discovery("e", amount: amount, date: date))
        }
        XCTAssertNil(IncomeFigures.pill(for: nil), "no detail, no pill")
        XCTAssertEqual(pill("published", "published"), "Declared")
        XCTAssertEqual(pill("estimated", "estimated"), "Estimated")
        XCTAssertEqual(pill("published", "estimated"), "Amount declared, date estimated")
        XCTAssertEqual(pill("estimated", "published"), "Amount estimated, date declared")
        XCTAssertEqual(pill("unknown", "published"), "Amount unknown, date declared")
        XCTAssertEqual(pill("published", "unknown"), "Amount declared, date unknown")
        XCTAssertEqual(pill("unknown", "estimated"), "Amount unknown, date estimated")
        XCTAssertNil(pill("unknown", "unknown"), "nothing known either way says nothing")
        XCTAssertEqual(pill("rumoured", "published"), "Amount unknown, date declared", "a value this build does not know")
    }

    func testHistoryIsReceivedPaymentsNewestFirstWithTheirOwnCurrency() {
        let events = [
            F.event("old", "SHEL", pay: "2026-03-20", status: "received", gbp: 30),
            F.event("usd", "AAPL", pay: "2026-11-13", status: "received", gbp: 3.04, quality: .partial,
                    own: 4, ownCurrency: "USD"),
            F.event("soon", "ULVR", pay: "2026-12-11", gbp: 58.4)
        ]
        let rows = IncomeFigures.history(events: events, currency: "GBP")
        XCTAssertEqual(rows.map(\.eventID), ["usd", "old"])
        XCTAssertEqual(rows[0].ownAmount?.currency, "USD")
        XCTAssertEqual(rows[0].ownAmount?.value, 4)
        XCTAssertTrue(rows[0].amountIsPartial)
        XCTAssertNil(rows[1].ownAmount, "same currency as the portfolio")
    }

    func testByHoldingSumsThePaymentsListedInTheChartsMonths() throws {
        let events = [
            F.event("u1", "ULVR", pay: "2026-09-11", status: "received", gbp: 50),
            F.event("u2", "ULVR", pay: "2026-12-11", gbp: 58.4, certainty: ("published", "published")),
            F.event("u3", "ULVR", pay: "2027-03-11", gbp: nil, quality: .unavailable),
            F.event("u0", "ULVR", pay: "2026-01-11", status: "received", gbp: 999), // before the chart's months
            F.event("h1", "HSBA", pay: "2026-11-24", gbp: 38.2),
            F.event("h2", "HSBA", pay: "2026-07-01", status: "received", gbp: 40)
        ]
        let rows = IncomeFigures.byHolding(events: events, currency: "GBP", today: F.today)
        XCTAssertEqual(rows.map(\.holding), ["ULVR", "HSBA"])
        let ulvr = try XCTUnwrap(rows.first)
        XCTAssertEqual(try XCTUnwrap(ulvr.received), 50, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(ulvr.toCome), 58.4, accuracy: 1e-9)
        XCTAssertEqual(ulvr.missingAmounts, 1)
        XCTAssertEqual(ulvr.nextPayment?.date, FolyncLedgerDay(year: 2026, month: 12, day: 11))
        let hsba = try XCTUnwrap(rows.last)
        XCTAssertEqual(try XCTUnwrap(hsba.received), 40, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(hsba.toCome), 38.2, accuracy: 1e-9)
        XCTAssertEqual(hsba.nextPayment?.amount, 38.2)
    }

    func testAHoldingWhosePaymentsHaveNoAmountShowsADashNotZero() throws {
        let events = [
            F.event("a1", "AZN", pay: "2026-09-23", status: "received", gbp: 47.21),
            F.event("a2", "AZN", pay: "2027-03-23", gbp: nil, quality: .unavailable)
        ]
        let row = try XCTUnwrap(IncomeFigures.byHolding(events: events, currency: "GBP", today: F.today).first)
        XCTAssertEqual(row.received, 47.21)
        XCTAssertNil(row.toCome, "a payment to come with no amount is unknown, not zero")
        XCTAssertEqual(IncomeText.amount(row.toCome, currency: "GBP"), "–")
        XCTAssertEqual(IncomeText.accessibilitySentence(row, currency: "GBP", locale: F.britishEnglish),
                       "AZN: £47.21 received and – to come, 1 payment with no amount yet; next payment Tue 23 Mar, –.")
        let nothingToCome = try XCTUnwrap(IncomeFigures.byHolding(events: [events[0]], currency: "GBP", today: F.today).first)
        XCTAssertEqual(nothingToCome.toCome, 0, "nothing listed to come sums to zero")
    }

    func testFolyncsFiguresAreShownAsGivenAndUnknownIsADash() {
        let response = F.response([])
        XCTAssertEqual(IncomeText.projected(response), "£456.78")
        XCTAssertEqual(IncomeText.figureLines(response), [
            IncomeFigureLine(title: "Declared", value: "£100.25"),
            IncomeFigureLine(title: "Yield, last 12 months, on today's value", value: "2.50%"),
            IncomeFigureLine(title: "Received in the last 12 months", value: "£321.50")
        ], "estimated income and yield on cost are left out when Folync gives none")
        XCTAssertEqual(IncomeText.holdingsLine(response), "8 of 9 holdings pay dividends")
        XCTAssertEqual(IncomeText.amount(nil, currency: "GBP"), "–")
        XCTAssertEqual(IncomeText.wholeAmount(148.4, currency: "GBP"), "£148")
    }

    // MARK: What VoiceOver reads

    func testEachMonthAndRowReadsAsOneSentence() throws {
        let events = [
            F.event("r", "ULVR", pay: "2026-11-05", status: "received", gbp: 96.8),
            F.event("d", "HSBA", pay: "2026-11-24", ex: "2026-10-09", gbp: 38.2, certainty: ("published", "published")),
            F.event("m", "AZN", pay: "2026-11-27", gbp: nil, quality: .unavailable),
            F.event("x", "ULVR", pay: "2026-12-11", ex: "2026-11-21", gbp: 58.4, certainty: ("published", "published")),
            F.event("h", "AAPL", pay: "2026-09-10", status: "received", gbp: 3.04, own: 4, ownCurrency: "USD")
        ]
        let chart = IncomeFigures.chart(events: events, currency: "GBP", today: F.today, isIncomplete: false)
        let november = try XCTUnwrap(chart.months.first { $0.month == IncomeMonth(year: 2026, month: 11) })
        XCTAssertEqual(IncomeText.accessibilitySentence(november, currency: "GBP", locale: F.britishEnglish),
                       "November 2026: £96.80 received and £38.20 declared, still to come; 1 payment with no amount yet.")
        let july = try XCTUnwrap(chart.months.first { $0.month == IncomeMonth(year: 2026, month: 7) })
        XCTAssertEqual(IncomeText.accessibilitySentence(july, currency: "GBP", locale: F.britishEnglish),
                       "July 2026: no payments listed.")

        let upcoming = IncomeFigures.upcoming(events: events, currency: "GBP", today: F.today)
        XCTAssertEqual(IncomeText.accessibilitySentence(upcoming[0], currency: "GBP", today: F.today, locale: F.britishEnglish),
                       "Tomorrow, ULVR, ex-dividend, pays 11 Dec, £58.40, declared.")
        let azn = try XCTUnwrap(upcoming.first { $0.holding == "AZN" })
        XCTAssertEqual(IncomeText.accessibilitySentence(azn, currency: "GBP", today: F.today, locale: F.britishEnglish),
                       "Fri 27 Nov, AZN, dividend, amount not known yet.")

        let history = IncomeFigures.history(events: events, currency: "GBP")
        XCTAssertEqual(IncomeText.accessibilitySentence(history[1], currency: "GBP", locale: F.britishEnglish),
                       "Thu 10 Sep 2026, AAPL, received £3.04, $4.00.")

        let holdings = IncomeFigures.byHolding(events: events, currency: "GBP", today: F.today)
        let ulvr = try XCTUnwrap(holdings.first { $0.holding == "ULVR" })
        XCTAssertEqual(IncomeText.accessibilitySentence(ulvr, currency: "GBP", locale: F.britishEnglish),
                       "ULVR: £96.80 received and £58.40 to come; next payment Fri 11 Dec, £58.40.")
    }

    // MARK: Sidebar

    func testIncomeSitsAfterChartsMarkedNewAndDimmedWithoutAFolyncPortfolio() throws {
        XCTAssertEqual(StockbarMainSection.income.title, "Income")
        XCTAssertEqual(StockbarMainSection.income.rawValue, "income")
        let analysis = try XCTUnwrap(StockbarMainSection.sidebarGroups.first { $0.title == "Analysis" })
        XCTAssertEqual(analysis.sections.prefix(2), [.charts, .income])
        let entries = StockbarSidebarModel.groups(dimmed: [.income: StockbarIncomeModel.needsFolyncReason],
                                                  new: [.income]).flatMap(\.entries)
        let income = try XCTUnwrap(entries.first { $0.section == .income })
        XCTAssertTrue(income.isNew)
        XCTAssertEqual(income.dimmedReason, "Needs a Folync portfolio")
        XCTAssertEqual(income.accessibilityValue, "New, Dimmed. Needs a Folync portfolio, 5 of 11")
    }
}
