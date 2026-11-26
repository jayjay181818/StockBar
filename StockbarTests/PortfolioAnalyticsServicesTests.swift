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

    func testWithNoCurrencyNamedNoSymbolIsGuessed() {
        let base = F.base
        let unnamed = FolyncDividendsResponse(
            schemaVersion: base.schemaVersion, sourceRevision: base.sourceRevision, generatedAt: base.generatedAt,
            scope: FolyncPortfolio(id: base.scope.id, name: base.scope.name, kind: base.scope.kind, currency: nil),
            currency: nil, quality: base.quality, reasonCodes: [], freshness: base.freshness,
            valuation: FolyncFinancialMetric(value: 5000, currency: nil, quality: .complete, reasonCodes: [], asOfDate: nil),
            holdingCoverage: base.holdingCoverage, summary: base.summary, discovery: nil, events: [], page: base.page
        )
        XCTAssertEqual(IncomeFigures.portfolioCurrency(base), "GBP")
        XCTAssertEqual(IncomeFigures.portfolioCurrency(unnamed), "", "no currency is made up")
        XCTAssertEqual(IncomeText.projected(unnamed), "456.78", "a plain figure, not one under a guessed symbol")

        // An amount that names a currency is not summed into an unnamed one,
        // and a received payment still shows its own.
        let paid = F.event("p", "SHEL", pay: "2026-10-20", status: "received", gbp: 30, own: 38, ownCurrency: "USD")
        XCTAssertNil(IncomeFigures.portfolioAmount(of: paid, currency: ""))
        let row = IncomeFigures.history(events: [paid], currency: "")[0]
        XCTAssertNil(row.amount)
        XCTAssertEqual(row.ownAmount?.currency, "USD")

        let chart = IncomeFigures.chart(events: [], currency: "", today: F.today, isIncomplete: false)
        XCTAssertEqual(IncomeText.chartCaption(chart), "Monthly sums from the payments listed, by pay date.")
        XCTAssertEqual(IncomeText.byHoldingCaption(span: "May to April", currency: ""),
                       "Sums of the payments listed for May to April. Holdings with no payment listed are not shown.")
        XCTAssertEqual(IncomeText.byHoldingCaption(span: "May to April", currency: "GBP"),
                       "Sums of the payments listed for May to April, in GBP. Holdings with no payment listed are not shown.")
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
        let order = StockbarMainSection.sidebarOrder
        let place = try XCTUnwrap(order.firstIndex(of: .income)) + 1
        XCTAssertEqual(income.accessibilityValue, "New, Dimmed. Needs a Folync portfolio, \(place) of \(order.count)")
        // The main window marks and dims its entries from these two sets.
        XCTAssertTrue(StockbarMainSection.newSections.contains(.income))
        // Income is no longer Folync-only: a local or Trading 212 portfolio gets an estimate.
        XCTAssertFalse(StockbarMainSection.folyncOnlySections.contains(.income))
        XCTAssertEqual(StockbarMainSection.needsFolyncReason, StockbarIncomeModel.needsFolyncReason)
    }
}

// MARK: - Income estimate for a local or Trading 212 portfolio (invented figures)

/// Stands in for `InstrumentEventsService`: records every call and answers
/// with the results given, or "no data". With `holds` on, each call waits
/// until `release()`.
private actor EventsProviderStandIn: InstrumentEventsProviding {
    struct Call: Equatable {
        let symbols: [String]
        let forceRefresh: Bool
    }

    private(set) var calls: [Call] = []
    private var answers: [[InstrumentEventsResult]] = []
    private var holds = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func answer(_ results: [InstrumentEventsResult]...) { answers += results }
    func hold(_ on: Bool) { holds = on }
    func release() {
        waiting.forEach { $0.resume() }
        waiting = []
    }
    var waitingCount: Int { waiting.count }

    func events(for symbols: [String], forceRefresh: Bool) async -> [InstrumentEventsResult] {
        calls.append(Call(symbols: symbols, forceRefresh: forceRefresh))
        let answer = answers.isEmpty
            ? symbols.map { InstrumentEventsResult(symbol: $0, source: .yahoo, outcome: .failed(.noData)) }
            : answers.removeFirst()
        if holds { await withCheckedContinuation { waiting.append($0) } }
        return answer
    }
}

@MainActor
final class StockbarLocalIncomeTests: XCTestCase {
    private typealias F = IncomeFixture
    private let fetchedAt = Date(timeIntervalSince1970: 1_795_100_000)

    /// Invented Yahoo answers, read the way the service reads the helper's.
    private func events(_ symbol: String, currency: String? = "GBP", dividends: [(String, Double)]? = [],
                        ex: String? = nil, pay: String? = nil) throws -> InstrumentEvents {
        let object: [String: Any] = [
            "symbol": symbol, "instrumentType": "EQUITY",
            "exDividendDate": ex ?? NSNull(), "dividendPayDate": pay ?? NSNull(),
            "earningsDate": NSNull(), "earningsDateEnd": NSNull(),
            "dividends": dividends.map { $0.map { ["date": $0.0, "amount": $0.1] as [String: Any] } } ?? NSNull(),
            "dividendCurrency": currency ?? NSNull(), "fetchedAt": fetchedAt.timeIntervalSince1970
        ]
        return try InstrumentEventsService.decoder.decode(InstrumentEvents.self,
                                                          from: JSONSerialization.data(withJSONObject: object))
    }

    private func day(_ text: String) throws -> FolyncLedgerDay {
        try XCTUnwrap(FolyncLedgerDay(string: text))
    }

    /// Pounds pass as they are, US dollars at an invented 0.8; nothing else has a rate.
    private func convert(_ amount: Double, _ currency: String) -> Double? {
        switch currency {
        case "GBP": amount
        case "USD": amount * 0.8
        default: nil
        }
    }

    private func estimate(_ holdings: [LocalIncomeHolding], _ answers: [InstrumentEvents]) -> LocalIncomeEstimate {
        LocalIncomeFigures.estimate(holdings: holdings,
                                    answers: Dictionary(uniqueKeysWithValues: answers.map { ($0.symbol, $0) }),
                                    currency: "GBP", today: F.today, convert: convert)
    }

    private func assertAmounts(_ actual: [Double?], _ expected: [Double], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (value, want) in zip(actual, expected) {
            XCTAssertEqual(value ?? .nan, want, accuracy: 1e-9, file: file, line: line)
        }
    }

    private let quarterly: [(String, Double)] = [
        ("2025-11-06", 0.24), // a year and two weeks ago: outside the last twelve months
        ("2025-11-25", 0.24), ("2026-02-05", 0.25), ("2026-05-07", 0.26), ("2026-08-06", 0.26)
    ]

    // MARK: The figures

    func testAPaymentYahooListsAsComingIsNotCountedTwice() throws {
        // Yahoo already lists the payment that last year's 25 November one stands for.
        let result = estimate([LocalIncomeHolding(symbol: "ALPHA", units: 10)],
                              [try events("ALPHA", dividends: quarterly + [("2026-11-21", 0.24)])])

        XCTAssertEqual(result.nextYear.map(\.date), [try day("2026-11-21"), try day("2027-02-05"),
                                                     try day("2027-05-07"), try day("2027-08-06")])
        XCTAssertEqual(result.nextYear.first?.dateSource, .yahooUpcoming)
        XCTAssertEqual(try XCTUnwrap(result.nextYearTotal), 10.1, accuracy: 1e-9, "four payments, not five")
    }

    func testYahoosExDateOnAnEstimatedDayGivesItYahoosPayDate() throws {
        let result = estimate([LocalIncomeHolding(symbol: "ALPHA", units: 10)],
                              [try events("ALPHA", dividends: quarterly, ex: "2026-11-25", pay: "2026-12-10")])

        let first = try XCTUnwrap(result.nextYear.first)
        XCTAssertEqual(first.date, try day("2026-11-25"))
        XCTAssertEqual(first.dateSource, .yahooUpcoming)
        XCTAssertEqual(first.payDay, try day("2026-12-10"))
        XCTAssertEqual(result.nextYear.count, 4, "the estimate is matched, not joined by a second row")
    }

    func testEachPaymentTimesTodaysUnitsAndTheSameAYearOn() throws {
        let result = estimate([LocalIncomeHolding(symbol: "ALPHA", units: 10)],
                              [try events("ALPHA", dividends: quarterly)])

        XCTAssertEqual(result.lastYear.map(\.date), [try day("2026-08-06"), try day("2026-05-07"),
                                                     try day("2026-02-05"), try day("2025-11-25")], "newest first")
        assertAmounts(result.lastYear.map(\.amount), [2.6, 2.6, 2.5, 2.4])
        XCTAssertTrue(result.lastYear.allSatisfy { $0.dateSource == .yahooRecord && $0.units == 10 })
        XCTAssertEqual(result.nextYear.map(\.date), [try day("2026-11-25"), try day("2027-02-05"),
                                                     try day("2027-05-07"), try day("2027-08-06")], "soonest first")
        assertAmounts(result.nextYear.map(\.amount), [2.4, 2.5, 2.6, 2.6])
        XCTAssertTrue(result.nextYear.allSatisfy { $0.dateSource == .estimated })
        XCTAssertEqual(try XCTUnwrap(result.lastYearTotal), 10.1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(result.nextYearTotal), 10.1, accuracy: 1e-9)

        // Twenty-five months, from November 2025 to November 2027.
        XCTAssertEqual(result.chart.months.count, 25)
        XCTAssertEqual(result.chart.months.first?.month, IncomeMonth(year: 2025, month: 11))
        XCTAssertEqual(result.chart.months.last?.month, IncomeMonth(year: 2027, month: 11))
        let november = try XCTUnwrap(result.chart.months.first { $0.month == IncomeMonth(year: 2026, month: 11) })
        XCTAssertEqual(november.lastYear, 0, accuracy: 1e-9)
        XCTAssertEqual(november.nextYear, 2.4, accuracy: 1e-9, "the repeat of last November's payment")
        XCTAssertEqual(result.chart.months.first?.lastYear ?? 0, 2.4, accuracy: 1e-9)

        let row = try XCTUnwrap(result.holdings.first)
        XCTAssertEqual(row.state, .paying)
        XCTAssertEqual(try XCTUnwrap(row.lastYear), 10.1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(row.nextYear), 10.1, accuracy: 1e-9)
        XCTAssertNil(row.nextDate, "no date from Yahoo")
    }

    func testYahoosUpcomingDateReplacesTheNearestEstimatedDate() throws {
        let result = estimate([LocalIncomeHolding(symbol: "ALPHA", units: 10)],
                              [try events("ALPHA", dividends: quarterly, ex: "2027-02-10", pay: "2027-02-26")])

        let replaced = try XCTUnwrap(result.nextYear.first { $0.date == (try? day("2027-02-10")) })
        XCTAssertEqual(replaced.dateSource, .yahooUpcoming)
        XCTAssertEqual(replaced.payDay, try day("2027-02-26"))
        XCTAssertEqual(try XCTUnwrap(replaced.amount), 2.5, accuracy: 1e-9, "the amount is still last year's, an estimate")
        XCTAssertFalse(result.nextYear.contains { $0.date == (try? day("2027-02-05")) }, "the estimated date gives way")
        XCTAssertEqual(result.nextYear.count, 4)
        XCTAssertEqual(result.holdings.first?.nextDate?.day, try day("2027-02-10"))
        XCTAssertEqual(result.holdings.first?.nextDate?.kind, .exDividend)
    }

    func testAnUpcomingDateFarFromAnyEstimateGetsARowOfItsOwnAndAPastOneIsIgnored() throws {
        let august: [(String, Double)] = [("2026-08-06", 0.5)]
        let far = estimate([LocalIncomeHolding(symbol: "BETA", units: 4)],
                           [try events("BETA", dividends: august, ex: "2027-01-15")])
        XCTAssertEqual(far.nextYear.map(\.date), [try day("2027-01-15"), try day("2027-08-06")])
        XCTAssertNil(far.nextYear.first?.amount, "no payment of last year is that one: its amount is not known")
        XCTAssertNil(far.nextYear.first?.ownAmount)
        XCTAssertEqual(far.nextYear.first?.dateSource, .yahooUpcoming)
        XCTAssertEqual(try XCTUnwrap(far.nextYearTotal), 2, accuracy: 1e-9)

        // An ex-dividend date already past changes nothing; a pay date still to come is the next date.
        let past = estimate([LocalIncomeHolding(symbol: "BETA", units: 4)],
                            [try events("BETA", dividends: august, ex: "2026-11-12", pay: "2026-11-26")])
        XCTAssertEqual(past.nextYear.map(\.dateSource), [.estimated])
        XCTAssertEqual(past.holdings.first?.nextDate?.day, try day("2026-11-26"))
        XCTAssertEqual(past.holdings.first?.nextDate?.kind, .payment)
    }

    func testAHoldingWithNoneUnknownOrNoRate() throws {
        let holdings = ["GAMMA", "NONE", "GONE", "BLANK", "DOLLAR", "EURO", "NOCUR"]
            .map { LocalIncomeHolding(symbol: $0, units: 10) }
        let result = estimate(holdings, [
            try events("GAMMA", dividends: [("2026-06-01", 1)]),
            try events("NONE", currency: nil, dividends: []),
            try events("BLANK", dividends: nil), // Yahoo gave no dividend answer
            try events("DOLLAR", currency: "USD", dividends: [("2026-06-01", 1)]),
            try events("EURO", currency: "EUR", dividends: [("2026-06-01", 1)]),
            try events("NOCUR", currency: nil, dividends: [("2026-06-01", 1)])
        ])
        let rows = Dictionary(uniqueKeysWithValues: result.holdings.map { ($0.symbol, $0) })

        XCTAssertEqual(rows["NONE"]?.state, LocalIncomeHoldingRow.State.none)
        XCTAssertEqual(LocalIncomeText.holdingFigure(try XCTUnwrap(rows["NONE"]), nextYear: false, currency: "GBP"), "None")
        for symbol in ["GONE", "BLANK"] {
            XCTAssertEqual(rows[symbol]?.state, .unknown, symbol)
            XCTAssertEqual(LocalIncomeText.holdingFigure(try XCTUnwrap(rows[symbol]), nextYear: true, currency: "GBP"), "–")
        }
        XCTAssertEqual(result.unknown, ["GONE", "BLANK"])
        XCTAssertEqual(try XCTUnwrap(rows["DOLLAR"]?.nextYear), 8, accuracy: 1e-9, "converted with the loaded rate")
        XCTAssertFalse(rows["DOLLAR"]?.isLeftOut ?? true)

        // No rate for euros, and no currency at all: own figures, not in the totals.
        let euro = try XCTUnwrap(rows["EURO"])
        XCTAssertTrue(euro.isLeftOut)
        XCTAssertNil(euro.nextYear)
        XCTAssertEqual(LocalIncomeText.holdingFigure(euro, nextYear: true, currency: "GBP"),
                       HoldingsCurrencyFormatter.amount(10, currency: "EUR"))
        XCTAssertTrue(try XCTUnwrap(rows["NOCUR"]).isLeftOut)
        XCTAssertEqual(LocalIncomeText.leftOutCaption(try XCTUnwrap(rows["NOCUR"])), "Not in the totals: Yahoo names no currency")
        XCTAssertEqual(LocalIncomeText.leftOutCaption(euro), "Not in the totals: no rate loaded")
        XCTAssertNil(LocalIncomeText.leftOutCaption(try XCTUnwrap(rows["GAMMA"])))
        XCTAssertNil(result.lastYear.first { $0.holding == "NOCUR" }?.amount, "no currency is ever guessed")
        XCTAssertEqual(result.leftOut, [LocalIncomeLeftOut(symbol: "EURO", currency: "EUR"),
                                        LocalIncomeLeftOut(symbol: "NOCUR", currency: "")])
        XCTAssertEqual(try XCTUnwrap(result.nextYearTotal), 18, accuracy: 1e-9, "GAMMA's 10 and DOLLAR's 8 only")
        XCTAssertEqual(result.holdings.map(\.symbol), ["GAMMA", "DOLLAR", "EURO", "NOCUR", "NONE", "BLANK", "GONE"],
                       "converted payers first, then those left out, then none, then unknown")
    }

    func testTheTotalsLeaveOutAnUnconvertedHoldingAndSaySo() throws {
        let result = estimate([LocalIncomeHolding(symbol: "GAMMA", units: 2), LocalIncomeHolding(symbol: "EURO", units: 2),
                               LocalIncomeHolding(symbol: "NOCUR", units: 1), LocalIncomeHolding(symbol: "GONE", units: 1)], [
            try events("GAMMA", dividends: [("2026-06-01", 1)]),
            try events("EURO", currency: "EUR", dividends: [("2026-06-01", 3)]),
            try events("NOCUR", currency: nil, dividends: [("2026-06-01", 1)])
        ])
        XCTAssertEqual(try XCTUnwrap(result.lastYearTotal), 2, accuracy: 1e-9)
        XCTAssertEqual(LocalIncomeText.leftOutNotice(result),
                       "The totals leave out EURO (EUR): no exchange rate to GBP is loaded; NOCUR: Yahoo names no currency. "
                       + "Their own figures are shown on their rows.")
        XCTAssertEqual(LocalIncomeText.unknownNotice(result),
                       "Yahoo had no answer for GONE, so it shows as – and is not in the totals.")
        XCTAssertEqual(result.chart.months.first { $0.month == IncomeMonth(year: 2026, month: 6) }?.lastYear ?? 0, 2,
                       accuracy: 1e-9, "the chart leaves it out too")

        // When nothing is known, the totals are unknown, not zero.
        let nothing = estimate([LocalIncomeHolding(symbol: "EURO", units: 1), LocalIncomeHolding(symbol: "GONE", units: 1)],
                               [try events("EURO", currency: "EUR", dividends: [("2026-06-01", 3)])])
        XCTAssertNil(nothing.lastYearTotal)
        XCTAssertNil(nothing.nextYearTotal)
        XCTAssertEqual(IncomeText.amount(nothing.nextYearTotal, currency: "GBP"), "–")
        XCTAssertNil(LocalIncomeText.leftOutNotice(estimate([], [])))
        XCTAssertNil(LocalIncomeText.unknownNotice(estimate([], [])))
        XCTAssertEqual(try XCTUnwrap(estimate([], []).nextYearTotal), 0, accuracy: 1e-9)
    }

    func testTheHoldingsAreTodaysUnitsWithoutWatchlistOrBenchmarkRows() {
        func row(_ symbol: String, _ units: String, watchlist: Bool = false) -> RealTimeTrade {
            RealTimeTrade(trade: Trade(name: symbol, position: Position(unitSize: units, positionAvgCost: "1"),
                                       isWatchlistOnly: watchlist), realTimeInfo: TradingInfo())
        }
        let holdings = LocalIncomeFigures.holdings(from: [
            row("alpha", "10"), row("BETA", "5", watchlist: true), row("^GSPC", "1"), row("ALPHA", "2.5"),
            row("ZERO", "0"), row("GAMMA.L", "7")
        ])
        XCTAssertEqual(holdings, [LocalIncomeHolding(symbol: "ALPHA", units: 12.5), LocalIncomeHolding(symbol: "GAMMA.L", units: 7)])
    }

    // MARK: The labels

    func testEveryLabelSaysEstimateAndNothingSaysReceived() throws {
        for label in [LocalIncomeText.headlineTitle, LocalIncomeText.lastYearTitle, LocalIncomeText.nextYearTitle,
                      LocalIncomeText.chartLastYear, LocalIncomeText.byHoldingLastYearColumn,
                      LocalIncomeText.byHoldingNextYearColumn,
                      LocalIncomeText.estimatePill, LocalIncomeText.yahooDatePill, LocalIncomeText.chartNextYear,
                      LocalIncomeText.estimateNotice] {
            XCTAssertTrue(label.lowercased().contains("estimate"), label)
        }
        XCTAssertEqual(LocalIncomeText.estimateNotice,
                       "These figures are an estimate from Yahoo's record of each holding's payments over the last year, "
                       + "at the units you hold today. They are not a record of what was paid to you.")
        XCTAssertEqual(LocalIncomeText.lastYearTitle, "Last 12 months, at today's units (estimate)")
        XCTAssertEqual(LocalIncomeText.nextYearTitle, "Next 12 months (estimate)")
        XCTAssertEqual(LocalIncomeText.byHoldingLastYearColumn, "Last 12 months (estimate)")
        XCTAssertEqual(LocalIncomeText.byHoldingNextYearColumn, "Next 12 months (estimate)")

        let result = estimate([LocalIncomeHolding(symbol: "ALPHA", units: 10)],
                              [try events("ALPHA", dividends: quarterly, ex: "2027-02-10", pay: "2027-02-26")])
        let lines = LocalIncomeText.figureLines(result)
        XCTAssertEqual(lines.map(\.title), ["Last 12 months, at today's units (estimate)"])
        XCTAssertEqual(lines.first?.value, HoldingsCurrencyFormatter.amount(10.1, currency: "GBP"))
        XCTAssertEqual(result.nextYear.map(LocalIncomeText.pill),
                       ["Estimate", "Yahoo's date, amount estimated", "Estimate", "Estimate"])

        let next = try XCTUnwrap(result.nextYear.first { $0.dateSource == .yahooUpcoming })
        XCTAssertEqual(LocalIncomeText.accessibilitySentence(nextYear: next, currency: "GBP", today: F.today,
                                                             locale: F.britishEnglish),
                       "Wed 10 Feb, ALPHA, ex-dividend, pays 26 Feb, £2.50, Yahoo's date, amount estimated.")
        let last = try XCTUnwrap(result.lastYear.first)
        XCTAssertEqual(LocalIncomeText.accessibilitySentence(lastYear: last, currency: "GBP", locale: F.britishEnglish),
                       "Thu 6 Aug 2026, ALPHA, ex-dividend, £2.60, estimate at today's units.")
        let month = try XCTUnwrap(result.chart.months.first { $0.month == IncomeMonth(year: 2026, month: 11) })
        XCTAssertEqual(LocalIncomeText.accessibilitySentence(month, currency: "GBP", locale: F.britishEnglish),
                       "November 2026: £2.40 estimated for the next 12 months.")
        let june = try XCTUnwrap(result.chart.months.first { $0.month == IncomeMonth(year: 2026, month: 5) })
        XCTAssertEqual(LocalIncomeText.accessibilitySentence(june, currency: "GBP", locale: F.britishEnglish),
                       "May 2026: £2.60 estimated in the last 12 months at today's units.")
        let row = try XCTUnwrap(result.holdings.first)
        XCTAssertEqual(LocalIncomeText.accessibilitySentence(row, currency: "GBP", today: F.today, locale: F.britishEnglish),
                       "ALPHA: £10.10 estimated in the last 12 months at today's units and £10.10 for the next 12 months; "
                       + "next date Ex-dividend Wed 10 Feb.")
        for text in [LocalIncomeText.lastYearCaption, LocalIncomeText.nextYearCaption, LocalIncomeText.chartCaption(result.chart)]
            + lines.map(\.title) {
            XCTAssertFalse(text.contains("Received"), text)
        }
    }

    func testTheStateNoticesSayWhatTheyAre() {
        XCTAssertEqual(LocalIncomeText.rateLimitNotice(until: F.now, locale: F.britishEnglish, timeZone: F.utc),
                       "Yahoo is limiting requests, so Stockbar won't ask it again until 12:00.")
        XCTAssertEqual(LocalIncomeText.staleNotice(count: 2, oldest: Date(timeIntervalSince1970: 1_795_169_400), now: F.now,
                                                   locale: F.britishEnglish, timeZone: F.utc),
                       "Couldn't get new figures from Yahoo for 2 holdings. Showing the copy saved at 10:10.")
        XCTAssertNil(LocalIncomeText.staleNotice(count: 0, oldest: nil))
        XCTAssertEqual(LocalIncomeText.failedNotice(count: 1),
                       "Couldn't reach Yahoo for 1 holding, and nothing is saved for it yet.")
        XCTAssertNil(LocalIncomeText.failedNotice(count: 0))
    }

    // MARK: When it asks

    private func makeModel(_ provider: EventsProviderStandIn, allowed: Bool = true) -> StockbarLocalIncomeModel {
        StockbarLocalIncomeModel(provider: provider, isAllowed: { allowed }, now: { F.now }, timeZone: F.utc)
    }

    private let held = [LocalIncomeHolding(symbol: "ALPHA", units: 10), LocalIncomeHolding(symbol: "BETA", units: 2)]

    private func settle(_ condition: @MainActor () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("condition never held", file: file, line: line)
    }

    private func drain() async {
        for _ in 0..<200 { await Task.yield() }
    }

    func testNothingIsAskedUntilThePageIsSelectedThenOnceAndNeverOnATimer() async throws {
        let provider = EventsProviderStandIn()
        let model = makeModel(provider)
        await drain()
        var calls = await provider.calls
        XCTAssertTrue(calls.isEmpty, "making the model, as the popover or Overview never do, asks nothing")
        XCTAssertEqual(model.phase, .idle)

        model.activate(holdings: held)
        model.activate(holdings: held)
        await settle { model.phase == .loaded }
        for view in [StockbarIncomeModel.View.history, .byHolding, .outlook] { model.view = view }
        _ = model.estimate(holdings: held, currency: "GBP") { amount, _ in amount }
        await drain()
        calls = await provider.calls
        XCTAssertEqual(calls, [EventsProviderStandIn.Call(symbols: ["ALPHA", "BETA"], forceRefresh: false)],
                       "one helper run for every symbol, letting the day-long copies answer")

        model.refresh(holdings: held)
        await settle { await provider.calls.count == 2 }
        calls = await provider.calls
        XCTAssertEqual(calls.last?.forceRefresh, true, "the refresh control asks afresh")

        model.deactivate()
        model.refresh(holdings: held)
        await drain()
        let count = await provider.calls.count
        XCTAssertEqual(count, 2, "a page no longer selected asks nothing")
    }

    func testNothingIsAskedWhenYahooIsNotAllowedOrThereAreNoHoldings() async {
        let provider = EventsProviderStandIn()
        let off = makeModel(provider, allowed: false)
        off.activate(holdings: held)
        off.refresh(holdings: held)
        XCTAssertEqual(off.phase, .notAllowed)
        let empty = makeModel(provider)
        empty.activate(holdings: [])
        XCTAssertEqual(empty.phase, .noHoldings)
        await drain()
        var calls = await provider.calls
        XCTAssertTrue(calls.isEmpty)
        // Holdings added while the page shows "no holdings": asked for once,
        // and editing them afterwards asks nothing more.
        empty.holdingsAppeared(held)
        await settle { empty.phase == .loaded }
        empty.holdingsAppeared(held + [LocalIncomeHolding(symbol: "GAMMA", units: 1)])
        await drain()
        calls = await provider.calls
        XCTAssertEqual(calls, [EventsProviderStandIn.Call(symbols: ["ALPHA", "BETA"], forceRefresh: false)])
        off.holdingsAppeared(held)
        await drain()
        calls = await provider.calls
        XCTAssertEqual(calls.count, 1, "never while Yahoo is not allowed")
        XCTAssertEqual(StockbarLocalIncomeModel.notAllowedReason, "Needs live market data, which is off")
    }

    func testLoadingRateLimitAndSavedCopiesAreShownForWhatTheyAre() async throws {
        let provider = EventsProviderStandIn()
        let until = F.now.addingTimeInterval(3_600)
        let alpha = try events("ALPHA", dividends: quarterly)
        await provider.answer([
            InstrumentEventsResult(symbol: "ALPHA", source: .yahoo, outcome: .events(alpha, .stale(.rateLimited(retryAfter: until)))),
            InstrumentEventsResult(symbol: "BETA", source: .yahoo, outcome: .failed(.timedOut))
        ])
        await provider.hold(true)
        let model = makeModel(provider)
        model.activate(holdings: held)
        XCTAssertEqual(model.phase, .loading)
        XCTAssertTrue(model.isLoading)
        await settle { await provider.waitingCount == 1 }
        await provider.release()
        await settle { model.phase == .loaded }

        XCTAssertEqual(model.rateLimitedUntil, until)
        XCTAssertEqual(model.staleCopies.count, 1)
        XCTAssertEqual(model.staleCopies.oldest, fetchedAt)
        XCTAssertEqual(model.failedWithoutCopy, 1)
        let result = model.estimate(holdings: held, currency: "GBP") { amount, _ in amount }
        XCTAssertEqual(try XCTUnwrap(result.nextYearTotal), 10.1, accuracy: 1e-9, "the saved copy still counts")
        XCTAssertEqual(result.unknown, ["BETA"])

        // Live providers refused for every symbol: the page says Yahoo can't be asked.
        let refused = EventsProviderStandIn()
        await refused.answer(held.map { InstrumentEventsResult(symbol: $0.symbol, source: .yahoo, outcome: .failed(.providerDisabled)) })
        let off = makeModel(refused)
        off.activate(holdings: held)
        await settle { off.phase != .loading }
        XCTAssertEqual(off.phase, .notAllowed)
    }

    func testAResultForAPageNoLongerSelectedIsNeverApplied() async {
        let provider = EventsProviderStandIn()
        await provider.hold(true)
        let model = makeModel(provider)
        model.activate(holdings: held)
        await settle { await provider.waitingCount == 1 }
        model.deactivate()
        await provider.release()
        await drain()
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNotEqual(model.phase, .loaded)
    }

    // MARK: The sidebar

    func testTheSidebarDimsIncomeOnlyWhenYahooCannotBeAskedOrFolyncIsStillLoading() {
        typealias S = StockbarMainSection
        // A local portfolio and a Trading 212 account: Folync is neither active nor enabled.
        let local = S.dimmedSections(isFolyncPortfolioActive: false, isFolyncEnabled: false, localIncomeAvailable: true)
        XCTAssertNil(local[.income], "Income is no longer dimmed")
        XCTAssertEqual(local[.activity], S.needsFolyncReason)
        XCTAssertEqual(local[.trades], S.needsFolyncReason)

        let off = S.dimmedSections(isFolyncPortfolioActive: false, isFolyncEnabled: false, localIncomeAvailable: false)
        XCTAssertEqual(off[.income], "Needs live market data, which is off")
        XCTAssertEqual(off[.activity], S.needsFolyncReason)

        XCTAssertEqual(S.dimmedSections(isFolyncPortfolioActive: true, isFolyncEnabled: true, localIncomeAvailable: false), [:],
                       "a Folync portfolio dims nothing, as before")
        let connecting = S.dimmedSections(isFolyncPortfolioActive: false, isFolyncEnabled: true, localIncomeAvailable: true)
        XCTAssertEqual(connecting[.income], S.needsFolyncReason, "Folync's page, waiting for its portfolio")

        let entries = StockbarSidebarModel.groups(dimmed: off, new: S.newSections).flatMap(\.entries)
        XCTAssertEqual(entries.first { $0.section == .income }?.dimmedReason, "Needs live market data, which is off")
        XCTAssertNil(StockbarSidebarModel.groups(dimmed: local, new: S.newSections).flatMap(\.entries)
            .first { $0.section == .income }?.dimmedReason)
    }

    func testTheEventsServiceAnswersOnlyWhenLiveDataIsOnOrAFixtureAnswers() {
        // The test process has live providers off and no fixture.
        XCTAssertFalse(StockbarProviderAccessPolicy.current.liveRequestsAllowed)
        XCTAssertNil(StockbarAcceptanceEventsFixture.current)
        XCTAssertFalse(InstrumentEventsService.canAnswer)
    }
}

// MARK: - Calendar and Next up (invented figures)

/// Stands in for the saved-data readers behind "Next up". It records every
/// read; it has no way to make a request.
private actor SavedCalendarStandIn: StockbarSavedDividendsReading, InstrumentEventsSavedReading {
    private var dividends: [String: FolyncDividendsResponse] = [:]
    private var events: [String: InstrumentEvents] = [:]
    private(set) var dividendReads: [FolyncDividendsQuery] = []
    private(set) var eventReads: [[String]] = []

    func save(_ response: FolyncDividendsResponse, for query: FolyncDividendsQuery) { dividends[query.cacheKey] = response }
    func save(_ answers: [InstrumentEvents]) { for answer in answers { events[answer.symbol] = answer } }

    func savedDividends(_ query: FolyncDividendsQuery) async -> FolyncDividendsResponse? {
        dividendReads.append(query)
        return dividends[query.cacheKey]
    }

    func savedEvents(for symbols: [String]) async -> [String: InstrumentEvents] {
        eventReads.append(symbols)
        return events.filter { symbols.contains($0.key) }
    }
}

/// Stands in for the coordinator with a real `FolyncLedgerFetchPolicy` in
/// front: counts the requests that would reach Folync.
private actor PolicyRouterStandIn: StockbarIncomeRouting {
    struct Request: Equatable {
        let query: String
        let forceRefresh: Bool
    }

    private let policy = FolyncLedgerFetchPolicy(now: { IncomeFixture.now })
    private let response: FolyncDividendsResponse
    private(set) var requests: [Request] = []

    init(response: FolyncDividendsResponse) { self.response = response }

    private func note(_ request: Request) { requests.append(request) }

    func routeDividends(_ query: FolyncDividendsQuery, forceRefresh: Bool) async -> FolyncRoutedDividendsResult {
        let key = FolyncLedgerFetchPolicy.Key(route: .dividends, endpoint: "https://folync.test", scopeID: "all",
                                              query: query.cacheKey, cursor: nil)
        let response = response
        let result: FolyncRoutedDividendsResult? = await policy.perform(key, forceRefresh: forceRefresh) {
            await self.note(Request(query: query.cacheKey, forceRefresh: forceRefresh))
            let answer = FolyncRoutedDividendsResult.folync(response, status: .current, paging: .firstPage)
            return FolyncLedgerFetchPolicy.Outcome(result: answer, firstPageToKeep: answer)
        }
        return result ?? .unavailable
    }

    func loadMoreDividends(_ query: FolyncDividendsQuery, after continuation: FolyncLedgerContinuation) async
        -> FolyncRoutedDividendsResult { .unavailable }
}

@MainActor
final class StockbarCalendarTests: XCTestCase {
    private typealias F = IncomeFixture
    private let fetchedAt = Date(timeIntervalSince1970: 1_795_100_000)

    private func day(_ text: String) throws -> FolyncLedgerDay {
        try XCTUnwrap(FolyncLedgerDay(string: text))
    }

    /// Invented Yahoo answers, read the way the service reads the helper's.
    private func events(_ symbol: String, currency: String? = "GBP", dividends: [(String, Double)]? = [],
                        ex: String? = nil, pay: String? = nil, earnings: String? = nil,
                        earningsEnd: String? = nil) throws -> InstrumentEvents {
        let object: [String: Any] = [
            "symbol": symbol, "instrumentType": "EQUITY",
            "exDividendDate": ex ?? NSNull(), "dividendPayDate": pay ?? NSNull(),
            "earningsDate": earnings ?? NSNull(), "earningsDateEnd": earningsEnd ?? NSNull(),
            "dividends": dividends.map { $0.map { ["date": $0.0, "amount": $0.1] as [String: Any] } } ?? NSNull(),
            "dividendCurrency": currency ?? NSNull(), "fetchedAt": fetchedAt.timeIntervalSince1970
        ]
        return try InstrumentEventsService.decoder.decode(InstrumentEvents.self,
                                                          from: JSONSerialization.data(withJSONObject: object))
    }

    private func result(_ events: InstrumentEvents) -> InstrumentEventsResult {
        InstrumentEventsResult(symbol: events.symbol, source: .yahoo, outcome: .events(events, .current))
    }

    /// Pounds pass as they are, US dollars at an invented 0.8; nothing else has a rate.
    private func convert(_ amount: Double, _ currency: String) -> Double? {
        switch currency {
        case "GBP": amount
        case "USD": amount * 0.8
        default: nil
        }
    }

    private func settle(_ condition: @MainActor () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("condition never held", file: file, line: line)
    }

    private func drain() async {
        for _ in 0..<200 { await Task.yield() }
    }

    /// Folync's invented events around Friday 20 November 2026.
    private var folyncEvents: [FolyncDividendEvent] {
        [
            F.event("e1", "ULVR", pay: "2026-12-11", ex: "2026-11-21", gbp: 58.40, certainty: ("published", "published")),
            F.event("e2", "VUSA", pay: "2027-01-08", ex: "2026-12-17", gbp: 96.20, certainty: ("estimated", "estimated")),
            F.event("e3", "HSBA", pay: "2026-11-24", gbp: 38.20),
            F.event("e4", "SHEL", pay: "2026-11-04", status: "received", gbp: 41.02),
            F.event("e5", "LGEN", pay: "2026-11-18", gbp: 12.00, certainty: ("published", "published")),
            F.event("e6", "MSFT", pay: "2025-10-01", status: "received", gbp: 6.12),
            F.event("e7", "BP", pay: "2026-12-01", ex: "2026-11-10", gbp: nil, certainty: ("published", "maybe"))
        ]
    }

    private let folyncInputs = StockbarCalendarInputs(
        isFolyncEnabled: true, isFolyncPortfolio: true,
        holdings: [CalendarHolding(symbol: "ULVR", yahooSymbol: "ULVR.L"), CalendarHolding(symbol: "NOSYM", yahooSymbol: nil)],
        localHoldings: [LocalIncomeHolding(symbol: "ULVR", units: 10), LocalIncomeHolding(symbol: "NOSYM", units: 5)]
    )

    private let localInputs = StockbarCalendarInputs(
        isFolyncEnabled: false, isFolyncPortfolio: false,
        holdings: [CalendarHolding(symbol: "ALPHA", yahooSymbol: "ALPHA"), CalendarHolding(symbol: "BETA", yahooSymbol: "BETA")],
        localHoldings: [LocalIncomeHolding(symbol: "ALPHA", units: 10), LocalIncomeHolding(symbol: "BETA", units: 4)]
    )

    private func localAnswers() throws -> [InstrumentEvents] {
        [
            try events("ALPHA", dividends: [("2025-11-06", 0.24), ("2025-11-25", 0.24), ("2026-02-05", 0.25),
                                            ("2026-05-07", 0.26), ("2026-08-06", 0.26)],
                       ex: "2026-11-26", pay: "2026-12-10", earnings: "2027-01-28"),
            try events("BETA", currency: "USD", dividends: [("2026-03-02", 0.5)], ex: "2026-12-03")
        ]
    }

    private func localEstimate() throws -> LocalIncomeEstimate {
        LocalIncomeFigures.estimate(holdings: localInputs.localHoldings,
                                    answers: Dictionary(uniqueKeysWithValues: try localAnswers().map { ($0.symbol, $0) }),
                                    currency: "GBP", today: F.today, convert: convert)
    }

    private func summary(_ rows: [CalendarRow]) -> [String] {
        rows.map { "\($0.day.string) \($0.symbol) \($0.kind) \($0.pill?.title ?? "-")" }
    }

    // MARK: Rows

    func testFolyncRowsGiveAPaymentAndAnExDividendRowWithTheDatesPill() throws {
        let rows = CalendarFigures.folyncRows(events: folyncEvents, currency: "GBP", today: F.today)
        XCTAssertEqual(summary(rows.upcoming), [
            "2026-11-21 ULVR exDividend Declared",
            "2026-11-24 HSBA payment Upcoming", // no discovery detail
            "2026-12-01 BP payment Upcoming", // a date certainty this build does not know
            "2026-12-11 ULVR payment Declared",
            "2026-12-17 VUSA exDividend Estimated",
            "2027-01-08 VUSA payment Estimated"
        ], "BP's ex-dividend date has passed, so it has no row")
        XCTAssertEqual(summary(rows.past), [
            "2026-11-18 LGEN payment Declared", // not marked received, but its day has passed
            "2026-11-04 SHEL payment -" // received: no pill
        ], "MSFT's payment is more than twelve months back")

        let ulvrEx = rows.upcoming[0]
        XCTAssertEqual(ulvrEx.payDay, try day("2026-12-11"))
        XCTAssertEqual(CalendarText.title(ulvrEx), "Ex-dividend")
        XCTAssertEqual(CalendarText.detail(ulvrEx, locale: F.britishEnglish), ", pays 11 Dec, £58.40")
        XCTAssertNil(CalendarText.amountColumn(ulvrEx))
        XCTAssertEqual(CalendarText.dayLabel(ulvrEx.day, today: F.today, locale: F.britishEnglish), "Tomorrow")
        XCTAssertEqual(CalendarText.accessibilitySentence(ulvrEx, today: F.today, locale: F.britishEnglish),
                       "Tomorrow, ULVR, ex-dividend, pays 11 Dec, £58.40, declared.")

        let vusaEx = rows.upcoming[4]
        XCTAssertEqual(CalendarText.detail(vusaEx, locale: F.britishEnglish), ", pays 8 Jan, about £96.20",
                       "Folync's estimated amount is written about")
        XCTAssertEqual(CalendarText.title(rows.upcoming[5]) + CalendarText.detail(rows.upcoming[5]), "Dividend, about £96.20")
        XCTAssertNil(CalendarText.amountColumn(rows.upcoming[5]))
        XCTAssertEqual(CalendarText.amountColumn(rows.upcoming[3]), "£58.40", "a declared amount has its own column")

        let hsba = rows.upcoming[1]
        XCTAssertEqual(CalendarText.title(hsba), "Dividend")
        XCTAssertEqual(CalendarText.detail(hsba), "")
        XCTAssertEqual(CalendarText.amountColumn(hsba), "£38.20")
        XCTAssertEqual(CalendarText.accessibilitySentence(hsba, today: F.today, locale: F.britishEnglish),
                       "Tue 24 Nov, HSBA, dividend, £38.20, upcoming.")

        let bp = rows.upcoming[2]
        XCTAssertNil(bp.amount)
        XCTAssertEqual(CalendarText.amountColumn(bp), "–", "unknown is a dash, never zero")
        XCTAssertEqual(CalendarText.accessibilitySentence(bp, today: F.today, locale: F.britishEnglish),
                       "Tue 1 Dec, BP, dividend, amount not known, upcoming.")
    }

    func testLocalRowsComeFromTheIncomeEstimateWithEveryAmountAbout() throws {
        let rows = CalendarFigures.localRows(estimate: try localEstimate())
        XCTAssertEqual(summary(rows.upcoming), [
            "2026-11-26 ALPHA exDividend -", // Yahoo's own date: no pill
            "2026-12-03 BETA exDividend -", // Yahoo's date with no payment behind it
            "2026-12-10 ALPHA payment -", // Yahoo's pay date
            "2027-02-05 ALPHA exDividend Estimated",
            "2027-03-02 BETA exDividend Estimated",
            "2027-05-07 ALPHA exDividend Estimated",
            "2027-08-06 ALPHA exDividend Estimated"
        ])
        XCTAssertEqual(summary(rows.past), [
            "2026-08-06 ALPHA exDividend -", "2026-05-07 ALPHA exDividend -", "2026-03-02 BETA exDividend -",
            "2026-02-05 ALPHA exDividend -", "2025-11-25 ALPHA exDividend -"
        ], "Yahoo's record of the last twelve months, as ex-dividend dates")
        XCTAssertTrue((rows.upcoming + rows.past).allSatisfy(\.amountIsEstimate))

        let alphaEx = rows.upcoming[0]
        XCTAssertEqual(CalendarText.detail(alphaEx, locale: F.britishEnglish), ", pays 10 Dec, about £2.40")
        let beta = rows.upcoming[1]
        XCTAssertNil(beta.amount)
        XCTAssertEqual(CalendarText.title(beta) + CalendarText.detail(beta), "Ex-dividend", "no made-up amount")
        let pay = rows.upcoming[2]
        XCTAssertEqual(CalendarText.title(pay) + CalendarText.detail(pay), "Dividend, about £2.40")
        XCTAssertNil(CalendarText.amountColumn(pay), "an estimate's amount stays in its sentence")
        let estimated = rows.upcoming[4]
        XCTAssertEqual(CalendarText.detail(estimated), ", about £1.60", "converted at the loaded rate")
        XCTAssertEqual(CalendarText.accessibilitySentence(estimated, today: F.today, locale: F.britishEnglish),
                       "Tue 2 Mar, BETA, ex-dividend, about £1.60, estimated.")
        XCTAssertEqual(CalendarText.title(rows.past[0]) + CalendarText.detail(rows.past[0]), "Ex-dividend, about £2.60")
    }

    func testEarningsRowsSingleRangeAndPast() throws {
        let holdings = [
            CalendarHolding(symbol: "NVDA", yahooSymbol: "NVDA"), CalendarHolding(symbol: "ULVR", yahooSymbol: "ULVR.L"),
            CalendarHolding(symbol: "OLD", yahooSymbol: "OLD"), CalendarHolding(symbol: "WIDE", yahooSymbol: "WIDE"),
            CalendarHolding(symbol: "SOON", yahooSymbol: "SOON"), CalendarHolding(symbol: "NOSYM", yahooSymbol: nil),
            CalendarHolding(symbol: "NODATE", yahooSymbol: "NODATE")
        ]
        let answers = Dictionary(uniqueKeysWithValues: try [
            events("NVDA", earnings: "2026-11-25"),
            events("ULVR.L", earnings: "2027-01-27", earningsEnd: "2027-02-03"),
            events("OLD", earnings: "2026-11-10"),
            events("WIDE", earnings: "2026-11-18", earningsEnd: "2026-11-24"),
            events("SOON", earnings: "2026-11-20"),
            events("NODATE")
        ].map { ($0.symbol, $0) })
        let rows = CalendarFigures.earningsRows(holdings: holdings, answers: answers, today: F.today)
        XCTAssertEqual(summary(rows), [
            "2026-11-20 SOON earnings -", "2026-11-25 NVDA earnings -", "2027-01-27 ULVR earnings Estimated"
        ], "a date before today, or a range already begun, is not shown; no Confirmed pill")
        let range = rows[2]
        XCTAssertEqual(range.endDay, try day("2027-02-03"))
        XCTAssertEqual(CalendarText.title(range) + CalendarText.detail(range, locale: F.britishEnglish),
                       "Earnings, expected between 27 Jan and 3 Feb")
        XCTAssertEqual(CalendarText.accessibilitySentence(rows[1], today: F.today, locale: F.britishEnglish),
                       "Wed 25 Nov, NVDA, earnings.")
        let coverage = CalendarFigures.earningsCoverage(holdings: holdings, answers: answers, today: F.today)
        XCTAssertEqual(coverage, CalendarEarningsCoverage(withoutSymbol: 1, withoutDate: 3))
        XCTAssertEqual(CalendarText.earningsCoverageLine(coverage), "4 holdings have no earnings dates.")
        XCTAssertNil(CalendarText.earningsCoverageLine(CalendarEarningsCoverage(withoutSymbol: 0, withoutDate: 0)))
    }

    func testCalendarHoldingsUseTheSymbolYahooIsAskedFor() throws {
        let local = [LocalIncomeHolding(symbol: "ALPHA.L", units: 3), LocalIncomeHolding(symbol: "BAD SYM", units: 1)]
        XCTAssertEqual(CalendarFigures.holdings(local: local, folyncHoldings: nil), [
            CalendarHolding(symbol: "ALPHA.L", yahooSymbol: "ALPHA.L"), CalendarHolding(symbol: "BAD SYM", yahooSymbol: nil)
        ])
        let json = """
        [{"portfolioId":"pf","assetId":"a1","ticker":"ULVR","displayTicker":"ULVR","quoteSymbol":"ULVR.L","name":"U",
          "currency":"GBP","shares":10,"averageCost":40,"costValue":400,
          "valuation":{"value":420,"currency":"GBP","quality":"complete","reasonCodes":[],"asOfDate":null}},
         {"portfolioId":"pf","assetId":"a2","ticker":"NOQ","name":"N","currency":"GBP","shares":1,"averageCost":1,
          "costValue":1,"valuation":{"value":1,"currency":"GBP","quality":"complete","reasonCodes":[],"asOfDate":null}}]
        """
        let folync = try JSONDecoder().decode([FolyncHolding].self, from: Data(json.utf8))
        let held = [LocalIncomeHolding(symbol: "ULVR", units: 10), LocalIncomeHolding(symbol: "NOQ", units: 1)]
        XCTAssertEqual(CalendarFigures.holdings(local: held, folyncHoldings: folync), [
            CalendarHolding(symbol: "ULVR", yahooSymbol: "ULVR.L"), CalendarHolding(symbol: "NOQ", yahooSymbol: nil)
        ], "a Folync holding uses Folync's quote symbol, and one without gets no earnings")
    }

    // MARK: Grouping

    func testThisWeekNextWeekAndMonthsWithTodayOnEachDayOfTheWeek() throws {
        func row(_ text: String) throws -> CalendarRow {
            CalendarRow(id: text, kind: .payment, day: try day(text), symbol: "X\(text.suffix(2))", payDay: nil,
                        endDay: nil, amount: 1, currency: "GBP", amountIsEstimate: false, amountIsPartial: false, pill: nil)
        }
        // Monday 16 to Sunday 22 November 2026.
        for date in 16...22 {
            let today = FolyncLedgerDay(year: 2026, month: 11, day: date)
            let rows = try [today.string, "2026-11-22", "2026-11-23", "2026-11-29", "2026-11-30", "2026-12-01"].map(row)
            let groups = CalendarFigures.upcomingGroups(rows, today: today)
            XCTAssertEqual(groups.map(\.key), [.thisWeek, .nextWeek, .month(IncomeMonth(year: 2026, month: 11)),
                                               .month(IncomeMonth(year: 2026, month: 12))], "today is the \(date)th")
            XCTAssertEqual(groups[0].rows.map(\.day.string), date == 22 ? ["2026-11-22", "2026-11-22"]
                                                                       : [today.string, "2026-11-22"])
            XCTAssertEqual(groups[1].rows.map(\.day.string), ["2026-11-23", "2026-11-29"], "Monday to Sunday")
            XCTAssertEqual(groups[2].rows.map(\.day.string), ["2026-11-30"])
            XCTAssertEqual(CalendarText.groupTitle(groups[3].key, today: today, locale: F.britishEnglish), "December")
        }
        XCTAssertEqual(CalendarText.groupTitle(.month(IncomeMonth(year: 2027, month: 1)), today: F.today,
                                               locale: F.britishEnglish), "January 2027")
        let past = CalendarFigures.pastGroups(try ["2026-09-03", "2026-11-04", "2026-11-18"].map(row))
        XCTAssertEqual(past.map(\.key), [.month(IncomeMonth(year: 2026, month: 11)), .month(IncomeMonth(year: 2026, month: 9))])
        XCTAssertEqual(past[0].rows.map(\.day.string), ["2026-11-18", "2026-11-04"], "newest first")
    }

    // MARK: Month range and filters

    func testTheMonthBarStopsTwelveMonthsOutInEachView() async throws {
        let upcoming = CalendarMonthRange(mode: .upcoming, today: F.today)
        XCTAssertEqual(upcoming.first, IncomeMonth(year: 2026, month: 11))
        XCTAssertEqual(upcoming.last, IncomeMonth(year: 2027, month: 11))
        let past = CalendarMonthRange(mode: .past, today: F.today)
        XCTAssertEqual(past.first, IncomeMonth(year: 2025, month: 11))
        XCTAssertEqual(past.last, IncomeMonth(year: 2026, month: 11))

        let provider = EventsProviderStandIn()
        let model = StockbarCalendarModel(router: IncomeRouterStandIn(), provider: provider, isAllowed: { true },
                                          now: { F.now }, timeZone: F.utc)
        model.activate(localInputs)
        XCTAssertEqual(model.month, upcoming.first)
        XCTAssertFalse(model.monthRange.canGoBack(from: model.month), "the previous button is disabled")
        model.showPreviousMonth()
        XCTAssertEqual(model.month, upcoming.first)
        for _ in 0..<15 { model.showNextMonth() }
        XCTAssertEqual(model.month, upcoming.last, "stops at twelve months ahead")
        XCTAssertFalse(model.monthRange.canGoForward(from: model.month), "the next button is disabled")

        model.mode = .past
        XCTAssertEqual(model.month, past.last, "Past opens on this month")
        XCTAssertFalse(model.monthRange.canGoForward(from: model.month))
        for _ in 0..<15 { model.showPreviousMonth() }
        XCTAssertEqual(model.month, past.first, "stops at twelve months back")
        XCTAssertFalse(model.monthRange.canGoBack(from: model.month))
        await drain()
        let calls = await provider.calls
        XCTAssertEqual(calls.count, 1, "moving months and views asks nothing")
    }

    func testEachFilterAndTheEarningsFilterUnderPast() async throws {
        let dividend = CalendarRow(id: "d", kind: .payment, day: F.today, symbol: "D", payDay: nil, endDay: nil, amount: 1,
                                   currency: "GBP", amountIsEstimate: false, amountIsPartial: false, pill: nil)
        let earnings = CalendarRow(id: "e", kind: .earnings, day: F.today, symbol: "E", payDay: nil, endDay: nil, amount: nil,
                                   currency: "", amountIsEstimate: false, amountIsPartial: false, pill: nil)
        let old = CalendarRow(id: "o", kind: .exDividend, day: F.today.adding(months: -1), symbol: "O", payDay: nil,
                              endDay: nil, amount: 1, currency: "GBP", amountIsEstimate: true, amountIsPartial: false, pill: nil)
        let rows = CalendarRows(upcoming: [dividend, earnings], past: [old])
        XCTAssertEqual(CalendarFigures.rows(rows, mode: .upcoming, filter: .all).map(\.id), ["d", "e"])
        XCTAssertEqual(CalendarFigures.rows(rows, mode: .upcoming, filter: .dividends).map(\.id), ["d"])
        XCTAssertEqual(CalendarFigures.rows(rows, mode: .upcoming, filter: .earnings).map(\.id), ["e"])
        XCTAssertEqual(CalendarFigures.rows(rows, mode: .past, filter: .all).map(\.id), ["o"])
        XCTAssertEqual(CalendarFigures.rows(rows, mode: .past, filter: .dividends).map(\.id), ["o"])
        XCTAssertEqual(CalendarFigures.rows(rows, mode: .past, filter: .earnings).map(\.id), [])
        XCTAssertEqual(CalendarFigures.filters(for: .upcoming), [.all, .dividends, .earnings])
        XCTAssertEqual(CalendarFigures.filters(for: .past), [.all, .dividends], "Past has no Earnings filter")
        XCTAssertEqual(CalendarText.emptyLine(mode: .upcoming, filter: .earnings), "No earnings dates in the next 12 months.")
        XCTAssertEqual(CalendarText.emptyLine(mode: .past, filter: .all), "No dividends in the last 12 months.")

        let model = StockbarCalendarModel(router: IncomeRouterStandIn(), provider: EventsProviderStandIn(),
                                          isAllowed: { true }, now: { F.now }, timeZone: F.utc)
        model.filter = .earnings
        model.mode = .past
        XCTAssertEqual(model.filter, .all, "switching to Past leaves the Earnings filter")
        model.filter = .dividends
        model.mode = .upcoming
        XCTAssertEqual(model.filter, .dividends)
        XCTAssertEqual(model.gridRows(rows).map(\.id), ["d", "o"], "Upcoming's grid also shows this month's past rows")
        model.mode = .past
        XCTAssertEqual(model.gridRows(rows).map(\.id), ["o"])
    }

    // MARK: The grid

    func testTheGridStartsOnMondayDimsOtherMonthsAndFoldsExtraSymbols() throws {
        func row(_ id: String, _ text: String, _ kind: CalendarEventKind = .payment, pill: CalendarPill? = .declared,
                 amount: Double? = 38.20) throws -> CalendarRow {
            CalendarRow(id: id, kind: kind, day: try day(text), symbol: id, payDay: nil, endDay: nil, amount: amount,
                        currency: "GBP", amountIsEstimate: false, amountIsPartial: false, pill: pill)
        }
        let rows = try [
            row("HSBA", "2026-11-24"),
            row("A", "2026-11-25", .earnings, pill: nil, amount: nil), row("B", "2026-11-25"), row("C", "2026-11-25"),
            row("D", "2026-11-26"), row("E", "2026-11-26"), row("F", "2026-11-26"), row("G", "2026-11-26"),
            row("LGEN", "2026-12-03", .exDividend), row("LATE", "2026-12-10")
        ]
        let weeks = CalendarFigures.grid(month: IncomeMonth(year: 2026, month: 11), rows: rows, today: F.today)
        XCTAssertEqual(weeks.count, 6)
        XCTAssertTrue(weeks.allSatisfy { $0.count == 7 })
        XCTAssertEqual(weeks.first?.first?.day.string, "2026-10-26", "Monday first")
        XCTAssertEqual(weeks.last?.last?.day.string, "2026-12-06")
        let days = weeks.flatMap { $0 }
        XCTAssertEqual(days.filter(\.isInMonth).count, 30)
        XCTAssertFalse(days[0].isInMonth, "October's days are dimmed")
        XCTAssertEqual(days.filter(\.isToday).map(\.day.string), ["2026-11-20"])
        let wednesday = try XCTUnwrap(days.first { $0.day.string == "2026-11-25" })
        XCTAssertEqual(wednesday.shown.map(\.symbol), ["B", "C", "A"], "three fit: payments, then earnings")
        XCTAssertEqual(wednesday.overflow, 0)
        let thursday = try XCTUnwrap(days.first { $0.day.string == "2026-11-26" })
        XCTAssertEqual(thursday.shown.map(\.symbol), ["D", "E"])
        XCTAssertEqual(thursday.overflow, 2, "the rest become +2")
        let december = try XCTUnwrap(days.first { $0.day.string == "2026-12-03" })
        XCTAssertFalse(december.isInMonth)
        XCTAssertEqual(december.rows.map(\.symbol), ["LGEN"], "a dimmed day still shows its events")
        XCTAssertFalse(days.contains { $0.rows.contains { $0.symbol == "LATE" } })

        let tuesday = try XCTUnwrap(days.first { $0.day.string == "2026-11-24" })
        XCTAssertEqual(CalendarText.daySentence(tuesday, locale: F.britishEnglish),
                       "Tuesday 24 November: HSBA dividend, £38.20, declared")
        XCTAssertEqual(CalendarText.daySentence(wednesday, locale: F.britishEnglish),
                       "Wednesday 25 November: B dividend, £38.20, declared; C dividend, £38.20, declared; A earnings")
        XCTAssertEqual(CalendarText.monthSummary(weeks, month: IncomeMonth(year: 2026, month: 11), locale: F.britishEnglish),
                       "November 2026: events on 3 days.")

        let february = CalendarFigures.grid(month: IncomeMonth(year: 2027, month: 2), rows: [], today: F.today)
        XCTAssertEqual(february.count, 4, "1 February 2027 is a Monday and the 28th a Sunday")
        XCTAssertTrue(february.joined().allSatisfy(\.isInMonth))
    }

    // MARK: Next up

    func testNextUpTakesTheThreeSoonestInTheNextFourteenDays() throws {
        func row(_ id: String, _ offset: Int, _ kind: CalendarEventKind) -> CalendarRow {
            CalendarRow(id: id, kind: kind, day: CalendarFigures.adding(days: offset, to: F.today), symbol: id, payDay: nil,
                        endDay: nil, amount: kind == .earnings ? nil : 38.20, currency: "GBP", amountIsEstimate: false,
                        amountIsPartial: false, pill: kind == .earnings ? nil : .declared)
        }
        let rows = [row("LATE", 15, .payment), row("NVDA", 5, .earnings), row("HSBA", 4, .payment),
                    row("EDGE", 14, .payment), row("ULVR", 1, .exDividend)]
        let next = CalendarFigures.nextUp(rows, today: F.today)
        XCTAssertEqual(next.map(\.id), ["ULVR", "HSBA", "NVDA"])
        XCTAssertEqual(next.map(CalendarText.nextUpPhrase),
                       ["ULVR goes ex-dividend", "HSBA pays £38.20", "NVDA reports earnings"])
        XCTAssertEqual(CalendarText.nextUpSentence(next[0], today: F.today, locale: F.britishEnglish),
                       "Tomorrow, ULVR goes ex-dividend, declared.")
        XCTAssertEqual(CalendarFigures.nextUp([row("EDGE", 14, .payment), row("LATE", 15, .payment)], today: F.today)
            .map(\.id), ["EDGE"], "fourteen days ahead is the last day")
        XCTAssertTrue(CalendarFigures.nextUp([row("LATE", 15, .payment)], today: F.today).isEmpty)
    }

    func testNextUpReadsOnlySavedDataAndIsAbsentWithNothingSaved() async throws {
        let saved = SavedCalendarStandIn()
        let model = StockbarNextUpModel(dividends: saved, events: saved, now: { F.now }, timeZone: F.utc)
        model.reload(folyncInputs, currency: "GBP") { amount, _ in amount }
        await settle { await saved.dividendReads.count == 1 + StockbarNextUpModel.savedQueryDaysBack }
        await drain()
        XCTAssertTrue(model.rows.isEmpty, "nothing saved: no Next up")

        // A copy saved yesterday is under yesterday's query, and is still read.
        let yesterday = CalendarFigures.adding(days: -1, to: F.today)
        await saved.save(F.response(folyncEvents), for: IncomeFigures.query(today: yesterday))
        await saved.save([try events("ULVR.L", earnings: "2026-11-23")])
        model.reload(folyncInputs, currency: "GBP") { amount, _ in amount }
        await settle { model.rows.count == 3 }
        XCTAssertEqual(model.rows.map(\.id), ["e1#ex", "ULVR.L#earnings", "e3#pay"])
        XCTAssertEqual(model.rows.map(CalendarText.nextUpPhrase),
                       ["ULVR goes ex-dividend", "ULVR reports earnings", "HSBA pays £38.20"])
        let eventReads = await saved.eventReads
        XCTAssertEqual(eventReads.last, ["ULVR.L"], "only holdings with a Yahoo symbol are looked up")

        // A local portfolio: the estimate's inputs from the saved copies.
        await saved.save(try localAnswers())
        let local = StockbarNextUpModel(dividends: saved, events: saved, now: { F.now }, timeZone: F.utc)
        local.reload(localInputs, currency: "GBP") { [weak self] amount, currency in self?.convert(amount, currency) }
        await settle { !local.rows.isEmpty }
        XCTAssertEqual(local.rows.map(CalendarText.nextUpPhrase), ["ALPHA goes ex-dividend", "BETA goes ex-dividend"],
                       "ALPHA's payment on 10 December is past the fourteen days")

        // Folync enabled with its portfolio not loaded: nothing.
        let waiting = StockbarNextUpModel(dividends: saved, events: saved, now: { F.now }, timeZone: F.utc)
        let notLoaded = StockbarCalendarInputs(isFolyncEnabled: true, isFolyncPortfolio: false, holdings: [], localHoldings: [])
        waiting.reload(notLoaded, currency: "GBP") { amount, _ in amount }
        await drain()
        XCTAssertTrue(waiting.rows.isEmpty)
    }

    // MARK: Requests

    func testCalendarAndIncomeShareOneDividendsRequest() async throws {
        let router = PolicyRouterStandIn(response: F.response(folyncEvents))
        let calendar = StockbarCalendarModel(router: router, provider: EventsProviderStandIn(), isAllowed: { true },
                                             now: { F.now }, timeZone: F.utc)
        calendar.activate(folyncInputs)
        await settle { calendar.folync.phase == .loaded }
        let income = StockbarIncomeModel(router: router, now: { F.now }, timeZone: F.utc)
        income.activate(isFolyncPortfolio: true)
        await settle { income.phase == .loaded }
        var requests = await router.requests
        XCTAssertEqual(requests, [.init(query: IncomeFigures.query(today: F.today).cacheKey, forceRefresh: false)],
                       "one request answers both pages")

        calendar.refresh(folyncInputs)
        await settle { await router.requests.count == 2 }
        requests = await router.requests
        XCTAssertEqual(requests.last?.forceRefresh, true, "the refresh control skips the reuse window")
    }

    func testAFolyncPortfolioAsksOnceOnActivateAndTheRefreshForcesBoth() async throws {
        let router = IncomeRouterStandIn()
        let provider = EventsProviderStandIn()
        await router.answer(.folync(F.response(folyncEvents), status: .current, paging: .firstPage),
                            .folync(F.response(folyncEvents), status: .current, paging: .firstPage))
        await provider.answer([result(try events("ULVR.L", earnings: "2026-11-25"))],
                              [result(try events("ULVR.L", earnings: "2026-11-25"))])
        let model = StockbarCalendarModel(router: router, provider: provider, isAllowed: { true },
                                          now: { F.now }, timeZone: F.utc)
        await drain()
        var routed = await router.calls
        var asked = await provider.calls
        XCTAssertTrue(routed.isEmpty && asked.isEmpty, "nothing before the page is selected")

        model.activate(folyncInputs)
        model.activate(folyncInputs)
        await settle { model.folync.phase == .loaded && !model.isLoadingEarnings }
        routed = await router.calls
        asked = await provider.calls
        XCTAssertEqual(routed.map(\.query), [IncomeFigures.query(today: F.today)], "Income's own query")
        XCTAssertEqual(routed.map(\.forceRefresh), [false])
        XCTAssertEqual(asked, [.init(symbols: ["ULVR.L"], forceRefresh: false)], "one call, Yahoo symbols only")
        let rows = model.rows(folyncInputs, currency: "GBP") { amount, _ in amount }
        XCTAssertTrue(rows.upcoming.contains { $0.kind == .earnings && $0.symbol == "ULVR" })
        XCTAssertEqual(rows.upcoming.filter(\.isDividend).count, 6)

        // Views, filters and months, and time passing, ask nothing more.
        model.mode = .past
        model.filter = .dividends
        model.showPreviousMonth()
        await drain()
        routed = await router.calls
        asked = await provider.calls
        XCTAssertEqual(routed.count, 1)
        XCTAssertEqual(asked.count, 1)

        model.refresh(folyncInputs)
        await settle {
            let routed = await router.calls.count
            let asked = await provider.calls.count
            return routed == 2 && asked == 2
        }
        routed = await router.calls
        asked = await provider.calls
        XCTAssertEqual(routed.last?.forceRefresh, true)
        XCTAssertEqual(asked.last, .init(symbols: ["ULVR.L"], forceRefresh: true))

        model.deactivate()
        model.refresh(folyncInputs)
        await drain()
        routed = await router.calls
        asked = await provider.calls
        XCTAssertEqual(routed.count, 2, "a page no longer selected asks nothing")
        XCTAssertEqual(asked.count, 2)
    }

    func testALocalPortfolioAsksYahooOnceForBothDividendsAndEarnings() async throws {
        let router = IncomeRouterStandIn()
        let provider = EventsProviderStandIn()
        await provider.answer(try localAnswers().map(result), try localAnswers().map(result))
        let model = StockbarCalendarModel(router: router, provider: provider, isAllowed: { true },
                                          now: { F.now }, timeZone: F.utc)
        model.activate(localInputs)
        await settle { model.local.phase == .loaded }
        var asked = await provider.calls
        XCTAssertEqual(asked, [.init(symbols: ["ALPHA", "BETA"], forceRefresh: false)])
        let rows = model.rows(localInputs, currency: "GBP", convert: convert)
        XCTAssertEqual(rows.upcoming.filter { $0.kind == .earnings }.map(\.day.string), ["2027-01-28"],
                       "earnings from the same answers")
        XCTAssertEqual(rows.past.count, 5)

        model.refresh(localInputs)
        await settle { await provider.calls.count == 2 }
        asked = await provider.calls
        XCTAssertEqual(asked.last, .init(symbols: ["ALPHA", "BETA"], forceRefresh: true))
        let routed = await router.calls
        XCTAssertTrue(routed.isEmpty, "Folync is never asked for a local portfolio")
    }

    func testWithYahooOffAFolyncPortfolioShowsDividendsWithoutEarnings() async throws {
        let router = IncomeRouterStandIn()
        let provider = EventsProviderStandIn()
        await router.answer(.folync(F.response(folyncEvents), status: .current, paging: .firstPage))
        let model = StockbarCalendarModel(router: router, provider: provider, isAllowed: { false },
                                          now: { F.now }, timeZone: F.utc)
        model.activate(folyncInputs)
        await settle { model.folync.phase == .loaded }
        let asked = await provider.calls
        XCTAssertTrue(asked.isEmpty)
        XCTAssertTrue(model.earningsNotAllowed)
        let rows = model.rows(folyncInputs, currency: "GBP") { amount, _ in amount }
        XCTAssertEqual(rows.upcoming.count, 6)
        XCTAssertFalse(rows.upcoming.contains { $0.kind == .earnings })
        XCTAssertEqual(CalendarText.sourceLine(.folync), "Dividends from Folync · Earnings from Yahoo")
        XCTAssertEqual(CalendarText.sourceLine(.yahooEstimate), "Estimated from Yahoo's record · Earnings from Yahoo")
    }

    func testYahooPausedStillShowsTheDividends() async throws {
        let router = IncomeRouterStandIn()
        let provider = EventsProviderStandIn()
        let until = F.now.addingTimeInterval(3_600)
        await router.answer(.folync(F.response(folyncEvents), status: .current, paging: .firstPage))
        await provider.answer([InstrumentEventsResult(symbol: "ULVR.L", source: .yahoo,
                                                      outcome: .failed(.rateLimited(retryAfter: until)))])
        let model = StockbarCalendarModel(router: router, provider: provider, isAllowed: { true },
                                          now: { F.now }, timeZone: F.utc)
        model.activate(folyncInputs)
        await settle { model.folync.phase == .loaded && !model.isLoadingEarnings }
        XCTAssertEqual(InstrumentEventsAnswers.rateLimitedUntil(model.yahooResults), until)
        XCTAssertFalse(model.earningsNotAllowed)
        XCTAssertEqual(model.rows(folyncInputs, currency: "GBP") { amount, _ in amount }.upcoming.count, 6)
    }

    // MARK: The sidebar

    func testCalendarSitsAfterIncomeMarkedNewAndDimmedExactlyAsIncome() throws {
        typealias S = StockbarMainSection
        XCTAssertEqual(S.calendar.title, "Calendar")
        XCTAssertEqual(S.calendar.systemImage, "calendar")
        XCTAssertEqual(S(rawValue: "calendar"), .calendar, "STOCKBAR_ACCEPTANCE_SECTION=calendar opens it")
        let analysis = try XCTUnwrap(S.sidebarGroups.first { $0.title == "Analysis" })
        let income = try XCTUnwrap(analysis.sections.firstIndex(of: .income))
        XCTAssertEqual(analysis.sections[income + 1], .calendar, "straight after Income")
        XCTAssertTrue(S.newSections.contains(.calendar))
        let place = try XCTUnwrap(S.sidebarOrder.firstIndex(of: .calendar))
        XCTAssertEqual(S.calendar.shortcutNumber, place < 9 ? place + 1 : nil, "the ⌘-number follows the sidebar")

        for active in [false, true] {
            for enabled in [false, true] {
                for yahoo in [false, true] {
                    let dimmed = S.dimmedSections(isFolyncPortfolioActive: active, isFolyncEnabled: enabled,
                                                  localIncomeAvailable: yahoo)
                    XCTAssertEqual(dimmed[.calendar], dimmed[.income], "active \(active), enabled \(enabled), yahoo \(yahoo)")
                }
            }
        }
        // Folync; local and Trading 212 (Folync neither active nor enabled); providers off; Folync loading.
        XCTAssertNil(S.dimmedSections(isFolyncPortfolioActive: true, isFolyncEnabled: true, localIncomeAvailable: false)[.calendar])
        XCTAssertNil(S.dimmedSections(isFolyncPortfolioActive: false, isFolyncEnabled: false, localIncomeAvailable: true)[.calendar])
        XCTAssertEqual(S.dimmedSections(isFolyncPortfolioActive: false, isFolyncEnabled: false,
                                        localIncomeAvailable: false)[.calendar], "Needs live market data, which is off")
        XCTAssertEqual(S.dimmedSections(isFolyncPortfolioActive: false, isFolyncEnabled: true,
                                        localIncomeAvailable: true)[.calendar], S.needsFolyncReason)
        let entries = StockbarSidebarModel.groups(dimmed: [:], new: S.newSections).flatMap(\.entries)
        XCTAssertEqual(entries.first { $0.section == .calendar }?.isNew, true)
    }

    // MARK: Calendar days

    func testDaysNeverMoveInAnotherTimeZone() async throws {
        let payDay = try day("2026-11-20")
        let event = F.event("tz", "TZ", pay: "2026-11-20", gbp: 5, certainty: ("published", "published"))
        // 20:00 UTC on Friday 20 November is already Saturday the 21st in Tokyo.
        let evening = Date(timeIntervalSince1970: 1_795_204_800)
        // 02:00 UTC on the 20th is still Thursday the 19th in Los Angeles.
        let early = Date(timeIntervalSince1970: 1_795_140_000)
        for (zone, instant, today) in [("Asia/Tokyo", evening, "2026-11-21"), ("America/Los_Angeles", early, "2026-11-19")] {
            let timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            let model = StockbarCalendarModel(router: IncomeRouterStandIn(), provider: EventsProviderStandIn(),
                                              isAllowed: { true }, now: { instant }, timeZone: timeZone)
            model.activate(localInputs)
            XCTAssertEqual(model.today.string, today, zone)
            let rows = CalendarFigures.folyncRows(events: [event], currency: "GBP", today: model.today)
            let row = try XCTUnwrap((rows.upcoming + rows.past).first)
            XCTAssertEqual(row.day, payDay, "the pay day stays the 20th in \(zone)")
            XCTAssertEqual(rows.upcoming.isEmpty, zone == "Asia/Tokyo", "past in Tokyo, tomorrow in Los Angeles")
            let earnings = CalendarFigures.earningsRows(
                holdings: [CalendarHolding(symbol: "TZ", yahooSymbol: "TZ")],
                answers: ["TZ": try events("TZ", earnings: "2026-11-20")], today: model.today)
            XCTAssertEqual(earnings.map(\.day), zone == "Asia/Tokyo" ? [] : [payDay])
            XCTAssertEqual(CalendarFigures.weekdayIndex(payDay), 4, "a Friday in every zone")
        }
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        XCTAssertEqual(CalendarText.dayLabel(payDay, today: FolyncLedgerDay(early, in: losAngeles)), "Tomorrow")
    }
}

/// The Allocation page's groups, text and grid, worked out from invented figures.
final class AllocationPresentationTests: XCTestCase {
    private typealias P = AllocationPresentation

    private func group(_ key: String, _ value: Double, share: Double) -> AllocationGroup {
        AllocationGroup(key: key, label: key, value: value, share: share, dayChangePercent: nil, foldedCount: 0)
    }

    private func groups(_ count: Int) -> [AllocationGroup] {
        (0..<count).map { group("H\($0)", Double(100 - $0), share: Double(100 - $0) / 10) }
    }

    // MARK: Currency

    func testCurrencyGroupsSumValuesByPricingCurrencyWithPenceAsPounds() throws {
        let result = P.currencyGroups([
            AllocationHolding(symbol: "ALFA.L", value: 300, currency: "GBp"),
            AllocationHolding(symbol: "BRVO.L", value: 200, currency: "GBX"),
            AllocationHolding(symbol: "CHRL.L", value: 100, currency: "GBP"),
            AllocationHolding(symbol: "DLTA", value: 250, currency: "USD"),
            AllocationHolding(symbol: "ECHO", value: 150, currency: "eur"),
            AllocationHolding(symbol: "FXTR", value: 0, currency: "USD"),
            AllocationHolding(symbol: "GOLF", value: .nan, currency: "USD"),
            AllocationHolding(symbol: "HOTL", value: 40, currency: " ")
        ])
        XCTAssertEqual(result.map(\.key), ["GBP", "USD", "EUR"])
        XCTAssertEqual(result.map(\.value), [600, 250, 150])
        XCTAssertEqual(result[0].share, 60, accuracy: 1e-9)
        XCTAssertEqual(result[1].share, 25, accuracy: 1e-9)
        XCTAssertEqual(result[2].share, 15, accuracy: 1e-9)
        XCTAssertTrue(result.allSatisfy { $0.dayChangePercent == nil })
    }

    func testCurrencyGroupsOfNothingValuedAreEmpty() {
        XCTAssertEqual(P.currencyGroups([]), [])
        XCTAssertEqual(P.currencyGroups([AllocationHolding(symbol: "ALFA", value: -5, currency: "USD")]), [])
    }

    func testOneSymbolInTwoCurrenciesCountsInBoth() {
        let result = P.currencyGroups([
            AllocationHolding(symbol: "ALFA", value: 30, currency: "USD"),
            AllocationHolding(symbol: "ALFA", value: 70, currency: "GBP")
        ])
        XCTAssertEqual(result.map(\.key), ["GBP", "USD"])
        XCTAssertEqual(result.map(\.share), [70, 30])
    }

    // MARK: Holding and sector

    func testHoldingGroupsUseTheServicesValuesAndSharesLargestFirst() async {
        let sectors = await SectorAnalysisService().calculateSectorAllocations(
            positions: ["AAPL": 100, "ZZQX": 300, "MSFT": 100], dayChanges: [:])
        let result = P.holdingGroups(sectors)
        XCTAssertEqual(result.map(\.key), ["ZZQX", "AAPL", "MSFT"])
        XCTAssertEqual(result.map(\.value), [300, 100, 100])
        XCTAssertEqual(result[0].share, 60, accuracy: 1e-9)
        XCTAssertEqual(result[1].share, 20, accuracy: 1e-9)
    }

    func testSectorGroupsKeepTheServicesFiguresAndHideDayChangeWhenIncomplete() async {
        let sectors = await SectorAnalysisService().calculateSectorAllocations(
            positions: ["AAPL": 300, "ZZQX": 100], dayChanges: ["AAPL": 30])
        let shown = P.sectorGroups(sectors, showsDayChange: true)
        XCTAssertEqual(shown.map(\.label), ["Technology", "Unclassified"])
        XCTAssertEqual(shown.map(\.value), sectors.map(\.totalValue))
        XCTAssertEqual(shown.map(\.share), sectors.map(\.percentageOfPortfolio))
        XCTAssertEqual(shown[0].dayChangePercent, sectors[0].dayChangePercent)
        XCTAssertEqual(P.dayChangeText(shown[0]), AttributionFormat.signedPercent(sectors[0].dayChangePercent))
        let hidden = P.sectorGroups(sectors, showsDayChange: false)
        XCTAssertTrue(hidden.allSatisfy { $0.dayChangePercent == nil })
        XCTAssertEqual(P.dayChangeText(hidden[0]), "—")
    }

    // MARK: Folding

    func testEightGroupsAreLeftAlone() {
        XCTAssertEqual(P.folded(groups(8)), groups(8))
    }

    func testNineGroupsFoldTheTwoSmallestIntoOther() throws {
        let result = P.folded(groups(9))
        XCTAssertEqual(result.count, 8)
        XCTAssertEqual(Array(result.prefix(7)), Array(groups(9).prefix(7)))
        let other = try XCTUnwrap(result.last)
        XCTAssertTrue(other.isOther)
        XCTAssertEqual(other.foldedCount, 2)
        XCTAssertEqual(other.value, 93 + 92)
        XCTAssertEqual(other.share, 9.3 + 9.2, accuracy: 1e-9)
        XCTAssertNil(other.dayChangePercent)
        XCTAssertEqual(P.rowLabel(other, grouping: .holding), "Other (2 holdings)")
        XCTAssertEqual(P.rowLabel(other, grouping: .sector), "Other (2 sectors)")
        XCTAssertEqual(P.rowLabel(other, grouping: .currency), "Other (2 currencies)")
        XCTAssertEqual(P.dayChangeText(other), "—")
    }

    // MARK: Colours

    func testAGroupKeepsItsColourWhenAnotherIsAddedOrRemoved() {
        var book = AllocationColourBook(paletteCount: 10)
        book.assign(["ALFA", "BRVO", "CHRL"])
        let before = ["ALFA", "BRVO", "CHRL"].map { book.index(for: $0) }
        XCTAssertEqual(before, [0, 1, 2])
        book.assign(["DLTA", "ALFA", "CHRL"])          // BRVO sold, DLTA bought, order changed
        XCTAssertEqual(["ALFA", "BRVO", "CHRL"].map { book.index(for: $0) }, before)
        XCTAssertEqual(book.index(for: "DLTA"), 3)
        book.assign(["BRVO"])                           // BRVO back: same colour as before
        XCTAssertEqual(book.index(for: "BRVO"), 1)
    }

    func testNoSliceIsRedOrGreen() {
        for colour in StockbarPalette.allocationSlices + [StockbarPalette.allocationOther] {
            XCTAssertNotEqual(colour, .red)
            XCTAssertNotEqual(colour, .green)
            XCTAssertNotEqual(colour, .pink)
            XCTAssertNotEqual(colour, .mint)
        }
        for sector in SectorAnalysisService.Sector.allCases {
            XCTAssertNotEqual(PortfolioAnalyticsView.colorForSector(sector), .red, sector.rawValue)
            XCTAssertNotEqual(PortfolioAnalyticsView.colorForSector(sector), .green, sector.rawValue)
            XCTAssertNotEqual(PortfolioAnalyticsView.colorForSector(sector), .pink, sector.rawValue)
            XCTAssertNotEqual(PortfolioAnalyticsView.colorForSector(sector), .mint, sector.rawValue)
        }
        XCTAssertEqual(PortfolioAnalyticsView.colorForSector(.technology), .blue)
        XCTAssertEqual(PortfolioAnalyticsView.colorForSector(.unknown), StockbarPalette.allocationOther)
    }

    // MARK: Text

    func testRowAndCentreText() {
        let sector = AllocationGroup(key: "Technology", label: "Technology", value: 30_925.89, share: 36.71,
                                     dayChangePercent: 1.44, foldedCount: 0)
        XCTAssertEqual(P.shareText(sector.share), "36.7%")
        XCTAssertEqual(P.spokenRow(sector, grouping: .sector, currency: "GBP"),
                       "Technology, £30,925.89, 36.7 percent, day change up 1.44 percent")
        let unknownDay = AllocationGroup(key: "Energy", label: "Energy", value: 10, share: 5,
                                         dayChangePercent: nil, foldedCount: 0)
        XCTAssertEqual(P.spokenRow(unknownDay, grouping: .sector, currency: "GBP"),
                       "Energy, £10.00, 5.0 percent, day change unavailable")
        XCTAssertEqual(P.spokenRow(group("USD", 250, share: 25), grouping: .currency, currency: "GBP"),
                       "USD, £250.00, 25.0 percent")
        let centre = P.centreText(total: 84_301.47, holdingCount: 9, currency: "GBP")
        XCTAssertEqual(centre.total, "£84,301")
        XCTAssertEqual(centre.count, "9 holdings")
        XCTAssertEqual(P.centreText(total: 120, holdingCount: 1, currency: "GBP").count, "1 holding")
        XCTAssertEqual(P.scoreText(62.44), "62.4 of 100")
    }

    // MARK: Grid

    func testGridTakesTheTwelveLargestAndSaysSo() {
        let symbols = (0..<31).map { String(format: "S%02d", $0) }
        var values: [String: Double] = [:]
        for (index, symbol) in symbols.enumerated() where symbol != "S30" { values[symbol] = Double(index) }
        let grid = P.gridSymbols(symbols, values: values)
        XCTAssertEqual(grid, (18...29).reversed().map { String(format: "S%02d", $0) })
        XCTAssertEqual(P.gridNote(totalHoldings: 31), "The 12 largest of 31 holdings.")
        XCTAssertNil(P.gridNote(totalHoldings: 12))
        // Twelve or fewer: all of them, largest first, unvalued last.
        XCTAssertEqual(P.gridSymbols(["ALFA", "BRVO", "CHRL"], values: ["ALFA": 1, "BRVO": 5]), ["BRVO", "ALFA", "CHRL"])
    }

    func testCellTextAndLabel() {
        XCTAssertEqual(P.cellText(0.734), ".73")
        XCTAssertEqual(P.cellText(-0.124), "-.12")
        XCTAssertEqual(P.cellText(1), "1.00")
        XCTAssertEqual(P.cellText(-1), "-1.00")
        XCTAssertEqual(P.cellText(-0.001), ".00")
        XCTAssertEqual(P.cellText(nil), "–")
        XCTAssertEqual(P.cellLabel("VUSA", "NVDA", value: 0.734), "VUSA and NVDA, 0.73")
        XCTAssertEqual(P.cellLabel("VUSA", "NVDA", value: -0.124), "VUSA and NVDA, -0.12")
        XCTAssertEqual(P.cellLabel("VUSA", "NVDA", value: nil), "VUSA and NVDA, no figure")
    }

    func testShadeForPositiveZeroNegativeAndUnknown() {
        XCTAssertEqual(P.shade(0.73), .positive(0.73))
        XCTAssertEqual(P.shade(0), .none)
        XCTAssertEqual(P.shade(-0.4), .negative(0.4))
        XCTAssertEqual(P.shade(nil), .none)
        XCTAssertEqual(StockbarPalette.correlationFill(.none), .clear)
        XCTAssertNotEqual(StockbarPalette.correlationFill(.positive(0.5)), StockbarPalette.correlationFill(.negative(0.5)))
    }

    func testMostAndLeastAlikeLine() {
        typealias Pair = CorrelationMatrixService.CorrelationPair
        let top = [Pair(symbol1: "VUSA", symbol2: "MSFT", correlation: 0.781), Pair(symbol1: "A", symbol2: "B", correlation: 0.5)]
        let bottom = [Pair(symbol1: "AAPL", symbol2: "LGEN", correlation: 0.089), Pair(symbol1: "A", symbol2: "B", correlation: 0.5)]
        XCTAssertEqual(P.pairsLine(top: top, bottom: bottom),
                       "Most alike: VUSA and MSFT, 0.78. Least alike: AAPL and LGEN, 0.09.")
        let only = [Pair(symbol1: "ALFA", symbol2: "BRVO", correlation: -0.2)]
        XCTAssertEqual(P.pairsLine(top: only, bottom: only), "Most alike: ALFA and BRVO, -0.20.")
        XCTAssertNil(P.pairsLine(top: [], bottom: []))
    }
}

/// Allocation's Cash row: present, named and sized in every view when cash is held, absent
/// otherwise, and the page's shares agreeing with Holdings' weights. Invented figures only.
@MainActor
final class AllocationCashTests: XCTestCase {
    private typealias P = AllocationPresentation
    private let converter = CurrencyConverter(exchangeRates: ["USD": 1.0, "GBP": 0.8],
                                              refreshOnInit: false, loadHistoryOnInit: false)

    private func group(_ key: String, _ value: Double, share: Double) -> AllocationGroup {
        AllocationGroup(key: key, label: key, value: value, share: share, dayChangePercent: nil, foldedCount: 0)
    }

    /// £900 of holdings in two sectors and two currencies.
    private func sectors() async -> [SectorAnalysisService.SectorAllocation] {
        await SectorAnalysisService().calculateSectorAllocations(
            positions: ["AAPL": 540, "ZZQX": 360], dayChanges: ["AAPL": 5.4, "ZZQX": 3.6])
    }

    private let holdings = [AllocationHolding(symbol: "AAPL", value: 540, currency: "USD"),
                            AllocationHolding(symbol: "ZZQX", value: 360, currency: "GBP")]

    private func allViews(cash: AllocationCash) async -> [AllocationGrouping: [AllocationGroup]] {
        let sectors = await sectors()
        return [
            .sector: P.displayed(P.sectorGroups(sectors, showsDayChange: true), cash: cash),
            .holding: P.displayed(P.holdingGroups(sectors), cash: cash),
            .currency: P.displayed(P.currencyGroups(holdings), cash: cash)
        ]
    }

    // MARK: Present

    func testACashRowIsInEveryViewNamedSizedLastAndEveryShareIsOfHoldingsPlusCash() async throws {
        let views = await allViews(cash: AllocationCash(100))
        for (grouping, groups) in views {
            let cash = try XCTUnwrap(groups.last, grouping.rawValue)
            XCTAssertTrue(cash.isCash, grouping.rawValue)
            XCTAssertEqual(cash.label, "Cash")
            XCTAssertEqual(P.rowLabel(cash, grouping: grouping), "Cash")
            XCTAssertEqual(cash.value, 100)
            XCTAssertEqual(cash.share, 10, accuracy: 1e-9, "£100 of £1,000")
            XCTAssertEqual(P.shareText(cash.share), "10.0%")
            XCTAssertNil(cash.dayChangePercent)
            XCTAssertFalse(cash.isOther)
            XCTAssertEqual(groups.filter(\.isCash).count, 1, "one Cash row, not folded into a currency")
            XCTAssertEqual(groups.reduce(0) { $0 + $1.share }, 100, accuracy: 1e-9, grouping.rawValue)
            XCTAssertEqual(groups.reduce(0) { $0 + $1.value }, 1000, accuracy: 1e-9, grouping.rawValue)
        }
        let byHolding = try XCTUnwrap(views[.holding])
        XCTAssertEqual(byHolding.map(\.key), ["AAPL", "ZZQX", AllocationGroup.cashKey])
        XCTAssertEqual(byHolding.map { P.shareText($0.share) }, ["54.0%", "36.0%", "10.0%"])
        // A currency view's cash is its own row, never added to the pound's group.
        let byCurrency = try XCTUnwrap(views[.currency])
        XCTAssertEqual(byCurrency.map(\.key), ["USD", "GBP", AllocationGroup.cashKey])
        XCTAssertEqual(byCurrency[1].value, 360)
        // Sector rows keep their day's change; Cash has none and is not Unclassified.
        let bySector = try XCTUnwrap(views[.sector])
        XCTAssertEqual(bySector.map(\.label), ["Technology", "Unclassified", "Cash"])
        XCTAssertNotNil(bySector[0].dayChangePercent)
        // The same dash as the page's other unknown day changes, so two dashes never sit side by side.
        XCTAssertEqual(P.dayChangeText(bySector[2]), "—")
        XCTAssertEqual(P.dayChangeText(bySector[2]), P.dayChangeText(group("Energy", 10, share: 5)))
    }

    func testACashKeyCannotBeTakenByATickerCalledCash() {
        let groups = P.displayed([group("CASH", 50, share: 100)], cash: AllocationCash(50))
        XCTAssertEqual(groups.map(\.isCash), [false, true])
        XCTAssertEqual(groups.map(\.key), ["CASH", AllocationGroup.cashKey])
    }

    // MARK: Absent

    func testNoCashRowWithNoCashZeroCashOrCashBelowZero() async {
        let without = await allViews(cash: .none)
        for cash in [AllocationCash(nil), AllocationCash(0), AllocationCash(-0.0), AllocationCash(.nan),
                     AllocationCash(.infinity), AllocationCash(-250)] {
            let views = await allViews(cash: cash)
            for (grouping, groups) in views {
                XCTAssertFalse(groups.contains(where: \.isCash), "\(cash) \(grouping)")
                XCTAssertEqual(groups, without[grouping], "shares stay of the holdings' total")
                XCTAssertEqual(groups.reduce(0) { $0 + $1.share }, 100, accuracy: 1e-9)
            }
        }
        XCTAssertEqual(AllocationCash(nil), .none)
        XCTAssertEqual(AllocationCash(0), .none)
        XCTAssertEqual(AllocationCash(-250), .borrowing(-250))
        XCTAssertEqual(AllocationCash(2_940.18), .held(2_940.18))
        XCTAssertEqual(P.displayed([group("ALFA", 10, share: 100)], cash: .none), [group("ALFA", 10, share: 100)])
    }

    func testTheLineUnderTheChartWhenCashIsBelowZero() {
        XCTAssertEqual(P.borrowingLine(AllocationCash(-1_250.5), currency: "GBP"),
                       "Cash is below zero (-£1,250.50), so it has no slice and the percentages are of the holdings alone.")
        XCTAssertNil(P.borrowingLine(.none, currency: "GBP"))
        XCTAssertNil(P.borrowingLine(AllocationCash(0), currency: "GBP"))
        XCTAssertNil(P.borrowingLine(AllocationCash(100), currency: "GBP"))
    }

    // MARK: Folding

    func testCashIsNeverFoldedIntoOther() throws {
        // Nine holdings fold to seven and "Other" as before; Cash, smaller than all of them, comes after.
        let nine = (0..<9).map { group("H\($0)", Double(100 - $0), share: 0) }
        let result = P.displayed(nine, cash: AllocationCash(1))
        XCTAssertEqual(result.count, P.maximumSlices + 1)
        let other = try XCTUnwrap(result.first(where: \.isOther))
        XCTAssertEqual(other.foldedCount, 2)
        XCTAssertEqual(other.value, 93 + 92, "Other holds the two smallest holdings and no cash")
        XCTAssertTrue(try XCTUnwrap(result.last).isCash)
        XCTAssertEqual(try XCTUnwrap(result.last).value, 1)
        let total = nine.reduce(0) { $0 + $1.value } + 1
        XCTAssertEqual(other.share, 185 / total * 100, accuracy: 1e-9)
        XCTAssertEqual(result.reduce(0) { $0 + $1.share }, 100, accuracy: 1e-9)
    }

    // MARK: Text

    func testCentreTotalAndCaption() {
        let holdingsTotal = 81_370.29
        let held = AllocationCash(2_940.18)
        let total = P.shareTotal(holdingsTotal: holdingsTotal, cash: held)
        XCTAssertEqual(total, 84_310.47, accuracy: 1e-6)
        let centre = P.centreText(total: total, holdingCount: 9, currency: "GBP", includesCash: true)
        XCTAssertEqual(centre.total, "£84,310")
        XCTAssertEqual(centre.count, "9 holdings and cash")
        XCTAssertEqual(P.centreText(total: 120, holdingCount: 1, currency: "GBP", includesCash: true).count,
                       "1 holding and cash")
        XCTAssertEqual(P.shareTotal(holdingsTotal: holdingsTotal, cash: .none), holdingsTotal)
        XCTAssertEqual(P.shareTotal(holdingsTotal: holdingsTotal, cash: AllocationCash(-500)), holdingsTotal,
                       "cash below zero has no slice, so the total is the holdings'")
        XCTAssertEqual(P.centreText(total: holdingsTotal, holdingCount: 9, currency: "GBP").count, "9 holdings")
    }

    func testTheCashRowForVoiceOverAndItsTooltip() throws {
        let rows = P.displayed([group("VUSA", 81_370.29, share: 100)], cash: AllocationCash(2_940.18))
        let cash = try XCTUnwrap(rows.last)
        for grouping in AllocationGrouping.allCases {
            XCTAssertEqual(P.spokenRow(cash, grouping: grouping, currency: "GBP"), "Cash, £2,940.18, 3.5 percent",
                           "no day change spoken, in the Sector view too")
        }
        XCTAssertEqual(P.cashTooltip(cash, currency: "GBP"),
                       "Cash, £2,940.18, 3.5%. Cash has no sector and no day's change.")
        // An ordinary sector row still says when its day change is not known.
        XCTAssertEqual(P.spokenRow(group("Energy", 10, share: 5), grouping: .sector, currency: "GBP"),
                       "Energy, £10.00, 5.0 percent, day change unavailable")
        XCTAssertEqual(P.dayChangeText(group("Energy", 10, share: 5)), "—", "unchanged for other rows")
    }

    func testTheUnclassifiedNoteGivesTheRowsShareOfTheSameTotal() async throws {
        let sectors = await sectors()   // £360 of £900 unclassified
        XCTAssertEqual(try XCTUnwrap(P.unclassifiedShare(sectors, cash: .none)), 40, accuracy: 1e-9)
        let withCash = try XCTUnwrap(P.unclassifiedShare(sectors, cash: AllocationCash(100)))
        XCTAssertEqual(withCash, 36, accuracy: 1e-9)
        let row = try XCTUnwrap(P.displayed(P.sectorGroups(sectors, showsDayChange: true), cash: AllocationCash(100))
            .first { $0.key == SectorAnalysisService.Sector.unknown.rawValue })
        XCTAssertEqual(row.share, withCash, accuracy: 1e-9, "the note and the row agree")
        XCTAssertEqual(try XCTUnwrap(P.unclassifiedShare(sectors, cash: AllocationCash(-100))), 40, accuracy: 1e-9)
        let classified = await SectorAnalysisService().calculateSectorAllocations(positions: ["AAPL": 10], dayChanges: [:])
        XCTAssertNil(P.unclassifiedShare(classified, cash: AllocationCash(100)))

        XCTAssertEqual(P.unclassifiedNote(share: 40, basis: .portfolio),
                       "40.0% of the portfolio is in holdings with no known sector (shown as Unclassified).")
        XCTAssertEqual(P.unclassifiedNote(share: 36, basis: .portfolioWithCash),
                       "36.0% of the portfolio, cash included, is in holdings with no known sector (shown as Unclassified).")
        XCTAssertEqual(P.diversificationUnclassifiedNote(share: 40, basis: .portfolio),
                       "40.0% of the portfolio has no known sector and is excluded from this score.")
        XCTAssertEqual(P.diversificationUnclassifiedNote(share: 40, basis: .portfolioWithCash),
                       "40.0% of the holdings' value has no known sector and is excluded from this score.")
        XCTAssertEqual(P.diversificationUnavailableNote(share: 62, basis: .portfolio),
                       "Diversification unavailable: 62% of the portfolio has no known sector.")
        XCTAssertEqual(P.diversificationUnavailableNote(share: 62, basis: .portfolioWithCash),
                       "Diversification unavailable: 62% of the holdings' value has no known sector.")
        XCTAssertTrue(P.holdingsOnlyCaption.hasPrefix("Holdings only: cash is left out"))
    }

    func testTheCashColourIsNeutralAndItsOwn() {
        let cash = StockbarPalette.allocationCash
        for other in [StockbarPalette.allocationOther, .red, .green, .pink, .mint, .gray] {
            XCTAssertNotEqual(cash, other)
        }
        XCTAssertFalse(StockbarPalette.allocationSlices.contains(cash))
        for sector in SectorAnalysisService.Sector.allCases {
            XCTAssertNotEqual(PortfolioAnalyticsView.colorForSector(sector), cash, sector.rawValue)
        }
    }

    // MARK: Where the cash comes from, and agreement with Holdings

    private func trade(_ symbol: String, price: Double, units: String, currency: String,
                       identity: String? = nil) -> RealTimeTrade {
        var info = TradingInfo()
        info.currentPrice = price
        info.prevClosePrice = price
        info.currency = currency
        let position = Position(unitSize: units, positionAvgCost: "1", currency: currency)
        return RealTimeTrade(trade: Trade(name: symbol, position: position), realTimeInfo: info, sourceIdentity: identity)
    }

    private func model(preferredCurrency: String = "GBP", converter: CurrencyConverter? = nil,
                       trading212: Trading212SettingsStore? = nil) -> DataModel {
        let model = DataModel(currencyConverter: converter ?? self.converter, startRuntimeServices: false,
                              trading212SettingsStore: trading212 ?? disabledTrading212())
        let stored = StockbarRuntimeStorage.userDefaults.object(forKey: "preferredCurrency")
        addTeardownBlock { @MainActor in StockbarRuntimeStorage.userDefaults.set(stored, forKey: "preferredCurrency") }
        model.preferredCurrency = preferredCurrency
        return model
    }

    /// Trading 212 settings in a defaults suite of their own, removed after the test.
    private func trading212Settings(enabled: Bool) -> Trading212SettingsStore {
        let suite = "AllocationCashTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = Trading212SettingsStore(defaults: defaults)
        var settings = store.load()
        settings.isEnabled = enabled
        store.save(settings)
        return store
    }

    private func disabledTrading212() -> Trading212SettingsStore { trading212Settings(enabled: false) }

    /// A fresh Trading 212 valuation for the enabled account in `store`, in pounds.
    private func trading212Snapshot(_ store: Trading212SettingsStore, accountValue: Double, cash: Double?,
                                    positions: [String: Double]) -> Trading212BrokerValuationSnapshot {
        let settings = store.load()
        let now = Date()
        return Trading212BrokerValuationSnapshot(
            accountKey: "Trading212|\(settings.environment.rawValue)|\(settings.accountType.rawValue)|label|credential|account",
            currency: "GBP",
            accountValue: accountValue,
            investmentsValue: positions.values.reduce(0, +),
            cashValue: cash,
            totalUnrealizedProfitLoss: nil,
            totalCost: nil,
            positionsByManualSymbol: Dictionary(uniqueKeysWithValues: positions.map { symbol, value in
                (symbol, Trading212BrokerPositionValuation(
                    manualSymbol: symbol, instrumentId: "US:\(symbol)", brokerCurrentValue: value,
                    brokerTotalCost: nil, brokerUnrealizedProfitLoss: nil, fxImpact: nil, currency: "GBP", updatedAt: now))
            }),
            updatedAt: now
        )
    }

    /// An invented Folync portfolio, read through the production decoder as the app reads
    /// Folync's answer (schema 2, with every identity field it requires). By default two
    /// holdings worth £523.45 and £376.55 and £100 of cash, a total of £1,000; Folync's
    /// weights are each holding's share of that total. A holding's value may be "null" (not
    /// valued); `total` may be "null" (Folync gives none). A holding is valued in
    /// `valueCurrencies[asset]` (default pounds) and priced in `pricingCurrencies[asset]`
    /// (default its value's currency); `allocations[asset]` overrides Folync's weight.
    private func folyncSnapshot(total: String = "1000", totalCurrency: String = "GBP", cash: String = "100",
                                cashCurrency: String? = "GBP",
                                holdings: [(asset: String, value: String)] = [("a", "523.45"), ("b", "376.55")],
                                valueCurrencies: [String: String] = [:], pricingCurrencies: [String: String] = [:],
                                allocations: [String: String] = [:])
        throws -> FolyncPortfolioSnapshot {
        func metric(_ value: String, currency: String? = "GBP") -> String {
            let code = currency.map { "\"\($0)\"" } ?? "null"
            return "{ \"value\": \(value), \"currency\": \(code), \"quality\": \"complete\", \"reasonCodes\": [], \"asOfDate\": \"2026-07-11\" }"
        }
        func holding(_ asset: String, value: String) -> String {
            let allocation = allocations[asset] ?? Double(value).map { String($0 / 10) } ?? "null"
            let valueCurrency = valueCurrencies[asset] ?? "GBP"
            let pricingCurrency = pricingCurrencies[asset] ?? valueCurrency
            let ticker = asset.uppercased()
            return """
            { "portfolioId": "pf_demo", "portfolioName": "Demo", "assetId": "\(asset)", "ticker": "\(ticker)",
              "canonicalTicker": "\(ticker)", "displayTicker": "\(ticker)", "quoteSymbol": "\(ticker)",
              "aliases": ["\(ticker)"], "name": "Fund \(asset)",
              "currency": "\(pricingCurrency)", "valueCurrency": "\(valueCurrency)", "shares": 10, "averageCost": 1,
              "currentPrice": 1, "previousClose": 1,
              "marketValue": \(value), "costValue": 10, "dayGain": 1, "dayGainPct": 1, "totalGain": 1, "totalGainPct": 1,
              "allocationPct": \(allocation), "valuation": \(metric(value, currency: valueCurrency)) }
            """
        }
        let json = """
        {
          "schemaVersion": 2, "sourceRevision": "revision-1", "generatedAt": "2026-07-12T12:00:00.000Z",
          "scope": { "id": "all", "name": "All portfolios", "kind": "aggregate", "currency": "GBP" },
          "freshness": {
            "responseGeneratedAt": "2026-07-12T12:00:00.000Z", "asOf": "2026-07-11", "status": "current", "reasonCodes": [],
            "sources": {
              "snapshots": { "asOfDate": "2026-07-11", "status": "clean", "generation": 1, "dirtySince": null, "rebuildStartedAt": null, "failedAt": null, "completedAt": "2026-07-12T11:55:00.000Z" },
              "prices": { "asOfDate": "2026-07-11", "ageSeconds": 60, "missingCount": 0 },
              "fx": { "asOfDate": "2026-07-11", "ageSeconds": 60, "missingCount": 0 },
              "provider": { "lastSuccessfulSyncAt": "2026-07-12T11:55:00.000Z", "ageSeconds": 300 }
            }
          },
          "totalValue": \(metric(total, currency: totalCurrency)),
          "cash": \(metric(cash, currency: cashCurrency)),
          "profitLoss": { "unrealized": \(metric("12.5")), "realized": \(metric("0")), "day": \(metric("2")) },
          "holdings": [\(holdings.map { holding($0.asset, value: $0.value) }.joined(separator: ", "))]
        }
        """
        return try FolyncPortfolioDecoder().decodeSnapshot(Data(json.utf8))
    }

    /// A model showing `snapshot` the way the app does: Folync's holdings as its rows.
    private func folyncModel(_ snapshot: FolyncPortfolioSnapshot, preferredCurrency: String = "GBP",
                             converter: CurrencyConverter? = nil,
                             trading212: Trading212SettingsStore? = nil) -> DataModel {
        let folync = model(preferredCurrency: preferredCurrency, converter: converter, trading212: trading212)
        folync.folyncPortfolioSnapshot = snapshot
        folync.realTimeTrades = snapshot.makeDisplayTrades(overlays: [:])
        return folync
    }

    /// Allocation's Holding view against Holdings' Weight column, to the shown precision,
    /// for every holding Holdings gives a weight.
    private func assertAgreement(_ model: DataModel, file: StaticString = #filePath, line: UInt = #line) async throws {
        let valuation = AllocationValuation.make(from: model)
        let sectors = await SectorAnalysisService().calculateSectorAllocations(
            positions: valuation.positions, dayChanges: valuation.dayChanges)
        let rows = P.displayed(P.holdingGroups(sectors), cash: valuation.cash, sourceTotal: valuation.sourceTotal)
        let netValue = model.calculateNetValue()
        XCTAssertFalse(rows.isEmpty, file: file, line: line)
        for trade in model.realTimeTrades where !trade.trade.isWatchlistOnly {
            let weight = HoldingsWeight.text(model.calculatePositionWeight(for: trade, netValue: netValue))
            // A holding known to be worth nothing has no row; Holdings gives it nothing too.
            let share = rows.first { $0.key == trade.trade.name }?.share ?? 0
            XCTAssertEqual(P.shareText(share), weight, trade.trade.name, file: file, line: line)
        }
        XCTAssertEqual(rows.reduce(0) { $0 + $1.share }, 100, accuracy: 0.05, "the shares make up the whole",
                       file: file, line: line)
        if valuation.cash.heldAmount > 0 {
            let centre = P.shareTotal(holdingsTotal: valuation.positions.values.reduce(0, +), cash: valuation.cash,
                                      sourceTotal: valuation.sourceTotal)
            XCTAssertEqual(centre, netValue.amount, accuracy: 0.005, "the centre total is Holdings' net value",
                           file: file, line: line)
        }
    }

    // Folync with a total.

    func testFolyncWithATotalGivesFolyncsCashAndAgreesWithHoldings() async throws {
        let folync = folyncModel(try folyncSnapshot())
        let basis = folync.holdingsWeightBasis()
        XCTAssertEqual(basis.source, .folync)
        XCTAssertEqual(basis.cash, HoldingsWeightBasis.Amount(value: 100, currency: "GBP"))
        XCTAssertEqual(basis.total, HoldingsWeightBasis.Amount(value: 1000, currency: "GBP"))
        XCTAssertNil(basis.mismatch)
        let valuation = AllocationValuation.make(from: folync)
        XCTAssertEqual(valuation.cash, .held(100))
        XCTAssertEqual(valuation.sourceTotal, 1000)
        XCTAssertNil(valuation.cashOmission)
        XCTAssertEqual(valuation.positions, ["A": 523.45, "B": 376.55])
        XCTAssertEqual(valuation.dayChanges, ["A": 1, "B": 1], "Folync's own day gain, as before")
        try await assertAgreement(folync)

        let noCurrency = folyncModel(try folyncSnapshot(cashCurrency: nil))
        XCTAssertNil(noCurrency.holdingsWeightBasis().cash, "no currency named for the cash: not known, none guessed")
        XCTAssertEqual(AllocationValuation.make(from: noCurrency).cash, .none)
        XCTAssertNil(folyncModel(try folyncSnapshot(cash: "null")).holdingsWeightBasis().cash, "Folync gives no cash figure")
        let borrowing = folyncModel(try folyncSnapshot(total: "860", cash: "-40"))
        XCTAssertEqual(borrowing.holdingsWeightBasis().cash?.value, -40)
        XCTAssertEqual(AllocationValuation.make(from: borrowing).cash, .borrowing(-40))
        XCTAssertEqual(AllocationValuation.make(from: folyncModel(try folyncSnapshot(total: "900", cash: "0"))).cash, .none)
    }

    func testCashIsConvertedIntoTheDisplayCurrency() throws {
        let dollars = folyncModel(try folyncSnapshot(), preferredCurrency: "USD")
        let valuation = AllocationValuation.make(from: dollars)
        XCTAssertEqual(valuation.cash, .held(125), "£100 at 0.8 a dollar")
        XCTAssertEqual(valuation.sourceTotal ?? .nan, 1250, accuracy: 1e-9)
    }

    func testAcrossCurrenciesTheFiguresAreCheckedAgainstTheSourcesTotalInItsCurrency() async throws {
        // Folync values B at $475 and counts it as £376.55 in its £1,000 total; at Stockbar's
        // 0.8 it is £380, so holdings and cash come to £1,003.45. Shares of that would put
        // A's £523.45 at 52.2% against Holdings' 52.3%: no Cash row, and the line says why.
        let apart = folyncModel(try folyncSnapshot(holdings: [("a", "523.45"), ("b", "475")],
                                                   valueCurrencies: ["b": "USD"], allocations: ["b": "37.655"]))
        let valuation = AllocationValuation.make(from: apart)
        XCTAssertEqual(valuation.positions["B"] ?? .nan, 380, accuracy: 1e-9)
        XCTAssertEqual(valuation.cash, .none)
        XCTAssertNil(valuation.sourceTotal)
        XCTAssertEqual(valuation.cashOmission, .totalDiffers)

        // When Stockbar's rate gives Folync's figure, they reconcile, and every share is of
        // Folync's total: the same as Holdings' weights.
        let together = folyncModel(try folyncSnapshot(holdings: [("a", "523.45"), ("b", "470.6875")],
                                                      valueCurrencies: ["b": "USD"], allocations: ["b": "37.655"]))
        let reconciled = AllocationValuation.make(from: together)
        XCTAssertEqual(reconciled.cash, .held(100))
        XCTAssertEqual(reconciled.sourceTotal ?? .nan, 1000, accuracy: 1e-9)
        try await assertAgreement(together)

        // The same in dollars: checked in pounds, where Folync added them up, then shown in dollars.
        let dollars = folyncModel(try folyncSnapshot(holdings: [("a", "523.45"), ("b", "470.6875")],
                                                     valueCurrencies: ["b": "USD"], allocations: ["b": "37.655"]),
                                  preferredCurrency: "USD")
        XCTAssertEqual(AllocationValuation.make(from: dollars).sourceTotal ?? .nan, 1250, accuracy: 1e-9)
    }

    func testPenceAreCheckedAgainstAPoundTotalWithoutAnExchangeRate() async throws {
        // £376.55 given in pence converts at a fixed 100, so even with no rate table loaded
        // the figures are checked, and a gap in pence is a gap.
        let noRates = CurrencyConverter(exchangeRates: [:], refreshOnInit: false, loadHistoryOnInit: false)
        let pence = folyncModel(try folyncSnapshot(holdings: [("a", "523.45"), ("b", "37655")],
                                                   valueCurrencies: ["b": "GBp"], allocations: ["b": "37.655"]),
                                converter: noRates)
        let valuation = AllocationValuation.make(from: pence)
        XCTAssertEqual(valuation.positions["B"] ?? .nan, 376.55, accuracy: 1e-9)
        XCTAssertEqual(valuation.cash, .held(100))
        XCTAssertEqual(valuation.sourceTotal ?? .nan, 1000, accuracy: 1e-9)
        try await assertAgreement(pence)

        let short = folyncModel(try folyncSnapshot(holdings: [("a", "523.45"), ("b", "38000")],
                                                   valueCurrencies: ["b": "GBp"]), converter: noRates)
        XCTAssertEqual(AllocationValuation.make(from: short).cashOmission, .totalDiffers)
    }

    func testAFigureWithNoRateIntoTheTotalsCurrencyLeavesCashOut() throws {
        // Everything converts into pounds for the page, but the total is in euros, which the
        // loaded table lacks: the check cannot be made, so no Cash row and the rate line.
        let euros = folyncModel(try folyncSnapshot(total: "1150", totalCurrency: "EUR"))
        let valuation = AllocationValuation.make(from: euros)
        XCTAssertEqual(valuation.covered, 2)
        XCTAssertEqual(valuation.cash, .none)
        XCTAssertNil(valuation.sourceTotal)
        XCTAssertEqual(valuation.cashOmission, .noExchangeRate)
        XCTAssertEqual(P.omissionLine(valuation.cashOmission),
                       "There is no exchange rate for the cash yet, so these percentages are of the holdings alone, without cash.")
    }

    // The tolerance.

    func testTheCheckAllowsHonestRoundingAndNoMore() throws {
        // Half a penny for each figure summed: two £4.99 parts of a £9.99 total pass...
        XCTAssertTrue(AllocationValuation.reconciles([4.99, 4.99], with: 9.99, currency: "GBP"))
        XCTAssertFalse(AllocationValuation.reconciles([4.99, 4.98], with: 9.99, currency: "GBP"), "two pence is more")
        // ...or 0.05% of the total, whichever is larger.
        XCTAssertTrue(AllocationValuation.reconciles([900, 100], with: 1_000.5, currency: "GBP"))
        XCTAssertFalse(AllocationValuation.reconciles([900, 100], with: 1_000.6, currency: "GBP"))
        // The smallest unit is the currency's own.
        XCTAssertEqual(AllocationValuation.smallestUnit(of: "GBP"), 0.01, accuracy: 1e-12)
        XCTAssertEqual(AllocationValuation.smallestUnit(of: "JPY"), 1, accuracy: 1e-12)
        XCTAssertEqual(AllocationValuation.smallestUnit(of: "GBX"), 1, accuracy: 1e-12)
        XCTAssertEqual(AllocationValuation.smallestUnit(of: "GBp"), 1, accuracy: 1e-12)
        XCTAssertTrue(AllocationValuation.reconciles([499, 499], with: 999, currency: "JPY"))
        XCTAssertFalse(AllocationValuation.reconciles([499, 498], with: 999, currency: "JPY"))

        // Through the page's own path: a £4.99 holding and £4.99 of cash in a £9.99 total.
        let small = folyncModel(try folyncSnapshot(total: "9.99", cash: "4.99", holdings: [("a", "4.99")]))
        let valuation = AllocationValuation.make(from: small)
        XCTAssertEqual(valuation.cash, .held(4.99))
        XCTAssertEqual(valuation.sourceTotal ?? .nan, 9.99, accuracy: 1e-12)
        let short = folyncModel(try folyncSnapshot(total: "9.99", cash: "4.98", holdings: [("a", "4.99")]))
        XCTAssertEqual(AllocationValuation.make(from: short).cashOmission, .totalDiffers)
    }

    // A holding known to be worth nothing.

    func testAHoldingWorthZeroIsValuedAddsNothingAndLeavesTheCashRow() async throws {
        let folync = folyncModel(try folyncSnapshot(holdings: [("a", "523.45"), ("b", "376.55"), ("c", "0")]))
        let valuation = AllocationValuation.make(from: folync)
        XCTAssertEqual(valuation.eligible, 3)
        XCTAssertEqual(valuation.covered, 3, "a known zero is a value")
        XCTAssertEqual(valuation.dayCovered, 3)
        XCTAssertEqual(valuation.positions, ["A": 523.45, "B": 376.55], "and gets no slice")
        XCTAssertEqual(valuation.holdings.map(\.symbol), ["A", "B"])
        XCTAssertEqual(valuation.cash, .held(100))
        XCTAssertNil(valuation.cashOmission)
        XCTAssertEqual(valuation.sourceTotal, 1000)
        try await assertAgreement(folync)

        // No value at all is unvalued.
        let partial = AllocationValuation.make(from: folyncModel(try folyncSnapshot(
            holdings: [("a", "523.45"), ("b", "376.55"), ("c", "null")])))
        XCTAssertEqual(partial.covered, 2)
        XCTAssertEqual(partial.cashOmission, .partialCoverage)

        // A value below zero is known, so valued, but has no slice to draw. Folync's £995
        // total counts it; the slices do not, so they cannot be of that total: no Cash row.
        let negative = AllocationValuation.make(from: folyncModel(try folyncSnapshot(
            total: "995", holdings: [("a", "523.45"), ("b", "376.55"), ("c", "-5")])))
        XCTAssertEqual(negative.covered, 3)
        XCTAssertEqual(negative.positions, ["A": 523.45, "B": 376.55])
        XCTAssertEqual(negative.cash, .none)
        XCTAssertEqual(negative.cashOmission, .totalDiffers)

        // A local holding at a price of zero has no usable price, as Holdings has it.
        let local = model()
        local.realTimeTrades = [trade("ALFA", price: 40, units: "10", currency: "GBP"),
                                trade("ZERO", price: 0, units: "10", currency: "GBP")]
        XCTAssertEqual(AllocationValuation.make(from: local).covered, 1)
    }

    // The currency view.

    func testTheCurrencyViewGroupsAFolyncHoldingByTheCurrencyItIsPricedIn() async throws {
        // B is a dollar share that Folync values in pounds, as `FolyncPortfolioSourceTests` has it.
        let folync = folyncModel(try folyncSnapshot(pricingCurrencies: ["b": "USD"]))
        let valuation = AllocationValuation.make(from: folync)
        XCTAssertEqual(valuation.holdings, [AllocationHolding(symbol: "A", value: 523.45, currency: "GBP"),
                                            AllocationHolding(symbol: "B", value: 376.55, currency: "USD")])
        let rows = P.displayed(P.currencyGroups(valuation.holdings), cash: valuation.cash,
                               sourceTotal: valuation.sourceTotal)
        XCTAssertEqual(rows.map(\.label), ["GBP", "USD", "Cash"])
        XCTAssertEqual(rows.map { P.shareText($0.share) }, ["52.3%", "37.7%", "10.0%"])

        // Its slice is its value in the display currency, converted at the loaded rate.
        let dollars = AllocationValuation.make(from: folyncModel(try folyncSnapshot(pricingCurrencies: ["b": "USD"]),
                                                                 preferredCurrency: "USD"))
        let usd = try XCTUnwrap(P.currencyGroups(dollars.holdings).first { $0.key == "USD" })
        XCTAssertEqual(usd.value, 470.6875, accuracy: 1e-9)

        // With no pricing currency named, the value's currency stands in, as before.
        let unnamed = AllocationValuation.make(from: folyncModel(try folyncSnapshot(pricingCurrencies: ["b": " "])))
        XCTAssertEqual(unnamed.holdings.map(\.currency), ["GBP", "GBP"])
    }

    // One look at Folync's holdings per calculation.

    func testTheLookupFindsTheHoldingAScanWouldFind() throws {
        let snapshot = try folyncSnapshot()
        let folync = folyncModel(snapshot)
        // Two holdings under one key: the first, as `holdings.first(where:)` finds it.
        let doubled = try folyncSnapshot(holdings: [("a", "523.45"), ("a", "1"), ("b", "376.55")])
        folync.folyncPortfolioSnapshot = doubled
        let lookup = folync.holdingsValuationLookup()
        XCTAssertNil(lookup.broker)
        XCTAssertEqual(lookup.folyncHoldings?.count, 2)
        let rowA = try XCTUnwrap(folync.realTimeTrades.first { $0.trade.name == "A" })
        XCTAssertEqual(lookup.folyncHolding(for: rowA)?.marketValue, 523.45)
        XCTAssertEqual(folync.weighedPositionValue(for: rowA, in: lookup)?.amount, 523.45)
        XCTAssertEqual(folync.calculatePositionValue(for: rowA).amount, 523.45, "the same as Holdings' own lookup")
        let unmatched = trade("NONE", price: 1, units: "1", currency: "GBP", identity: "all|pf_demo|none")
        XCTAssertNil(folync.weighedPositionValue(for: unmatched, in: lookup))
        XCTAssertNil(model().holdingsValuationLookup().folyncHoldings, "no Folync snapshot, no Folync holdings")
    }

    // Folync without a total, beside a fresh Trading 212 account.

    func testFolyncWithoutATotalNeverTakesTrading212sCash() async throws {
        let store = trading212Settings(enabled: true)
        let folync = folyncModel(try folyncSnapshot(total: "null"), trading212: store)
        folync.setTrading212BrokerValuationSnapshotForTesting(
            trading212Snapshot(store, accountValue: 5_000, cash: 700, positions: ["A": 4_300]))
        // No Trading 212 valuation applies while Folync is active: Holdings' net value is the
        // sum of Folync's rows at their prices (two holdings of 10 units at £1), never the
        // Trading 212 account's £5,000.
        XCTAssertEqual(folync.calculateNetValue().amount, 20, accuracy: 1e-9)
        XCTAssertNil(folync.freshTrading212BrokerValuationSnapshot())
        XCTAssertEqual(folync.displayValuationSource, .localCalculationFallback)

        let basis = folync.holdingsWeightBasis()
        XCTAssertEqual(basis.source, .folync)
        XCTAssertNil(basis.cash, "never the Trading 212 account's £700")
        XCTAssertEqual(basis.mismatch, .folyncWithoutTotal)
        let valuation = AllocationValuation.make(from: folync)
        XCTAssertEqual(valuation.cash, .none)
        XCTAssertNil(valuation.sourceTotal)
        XCTAssertEqual(valuation.cashOmission, .folyncWithoutTotal)
        XCTAssertEqual(valuation.positions, ["A": 523.45, "B": 376.55], "Folync's values, not the broker's")
        XCTAssertEqual(P.omissionLine(valuation.cashOmission),
                       "Folync gives no total value for this portfolio, so these percentages are of the holdings alone, without cash.")
        XCTAssertEqual(AllocationShareBasis(cash: valuation.cash, omission: valuation.cashOmission), .holdings)
    }

    // Trading 212.

    func testTrading212GivesTheAccountsCashAndAgreesWithHoldings() async throws {
        let store = trading212Settings(enabled: true)
        let broker = model(trading212: store)
        // Priced in dollars locally; Holdings and Allocation both take the broker's value in pounds.
        broker.realTimeTrades = [trade("ALFA", price: 900, units: "1", currency: "USD"),
                                 trade("BRVO", price: 1, units: "1", currency: "USD"),
                                 trade("WTCH", price: 5, units: "1", currency: "GBP")]
        broker.realTimeTrades[2].trade.isWatchlistOnly = true
        broker.setTrading212BrokerValuationSnapshotForTesting(
            trading212Snapshot(store, accountValue: 1_000, cash: 100, positions: ["ALFA": 523.45, "BRVO": 376.55]))

        let basis = broker.holdingsWeightBasis()
        XCTAssertEqual(basis.source, .trading212)
        XCTAssertEqual(basis.cash, HoldingsWeightBasis.Amount(value: 100, currency: "GBP"))
        XCTAssertEqual(basis.total, HoldingsWeightBasis.Amount(value: 1_000, currency: "GBP"))
        XCTAssertNil(basis.mismatch, "a watchlist row is not a holding outside the account")
        let valuation = AllocationValuation.make(from: broker)
        XCTAssertEqual(valuation.positions, ["ALFA": 523.45, "BRVO": 376.55])
        XCTAssertEqual(valuation.cash, .held(100))
        XCTAssertEqual(valuation.holdings.map(\.currency), ["USD", "USD"], "the currency view keeps the priced-in currency")
        XCTAssertEqual(valuation.eligible, 2)
        try await assertAgreement(broker)
    }

    func testTrading212WithAManualHoldingBesideItHasNoCashRow() async throws {
        let store = trading212Settings(enabled: true)
        let broker = model(trading212: store)
        broker.realTimeTrades = [trade("ALFA", price: 900, units: "1", currency: "USD"),
                                 trade("MANL", price: 20, units: "10", currency: "GBP")]
        broker.setTrading212BrokerValuationSnapshotForTesting(
            trading212Snapshot(store, accountValue: 1_000, cash: 100, positions: ["ALFA": 900]))

        // Holdings' own inconsistency, reported and left alone: the manual holding is weighed
        // against an account value that leaves it out, so the weights come to more than 100%.
        let netValue = broker.calculateNetValue()
        let weights = broker.realTimeTrades.compactMap { broker.calculatePositionWeight(for: $0, netValue: netValue) }
        XCTAssertEqual(weights.reduce(0, +), 110, accuracy: 1e-9)

        XCTAssertEqual(broker.holdingsWeightBasis().mismatch, .holdingsOutsideBrokerAccount)
        let valuation = AllocationValuation.make(from: broker)
        XCTAssertEqual(valuation.cash, .none)
        XCTAssertEqual(valuation.cashOmission, .holdingsOutsideBrokerAccount)
        XCTAssertEqual(valuation.positions, ["ALFA": 900, "MANL": 200], "the same values as Holdings weighs")
        XCTAssertEqual(P.omissionLine(valuation.cashOmission),
                       "Holdings' weights are of the Trading 212 account's value, which leaves out the holdings kept "
                       + "outside it. So these percentages are of the holdings alone, without cash.")
    }

    func testTrading212WhoseHoldingsAndCashMissTheAccountValueHasNoCashRow() {
        // The account holds £400 the app has no row for, so £900 and £100 are not its £1,400.
        let store = trading212Settings(enabled: true)
        let broker = model(trading212: store)
        broker.realTimeTrades = [trade("ALFA", price: 900, units: "1", currency: "USD")]
        broker.setTrading212BrokerValuationSnapshotForTesting(
            trading212Snapshot(store, accountValue: 1_400, cash: 100, positions: ["ALFA": 900]))
        let valuation = AllocationValuation.make(from: broker)
        XCTAssertEqual(valuation.cash, .none)
        XCTAssertEqual(valuation.cashOmission, .totalDiffers)
        XCTAssertEqual(P.omissionLine(.totalDiffers),
                       "The holdings and cash do not add up to the portfolio's total value, so these percentages are of the holdings alone, without cash.")

        // Pennies of rounding between the account's figures are within the tolerance.
        broker.setTrading212BrokerValuationSnapshotForTesting(
            trading212Snapshot(store, accountValue: 1_000.03, cash: 100, positions: ["ALFA": 900]))
        XCTAssertEqual(AllocationValuation.make(from: broker).cash, .held(100))
    }

    // Local.

    func testALocalPortfolioHasNoCashAndAgreesWithHoldings() async throws {
        // £400 + $500 (£400 at 0.8) + £233.33: a local portfolio, whose weights Holdings works out itself.
        let local = model()
        local.realTimeTrades = [trade("ALFA", price: 40, units: "10", currency: "GBP"),
                                trade("BRVO", price: 50, units: "10", currency: "USD"),
                                trade("CHRL", price: 23.333, units: "10", currency: "GBP")]
        let basis = local.holdingsWeightBasis()
        XCTAssertEqual(basis, HoldingsWeightBasis(source: .local, total: nil, cash: nil, mismatch: nil))
        let valuation = AllocationValuation.make(from: local)
        XCTAssertEqual(valuation.cash, .none)
        XCTAssertNil(valuation.cashOmission)
        XCTAssertEqual(valuation.positions["BRVO"] ?? .nan, 400, accuracy: 1e-9)
        try await assertAgreement(local)
    }

    // Exchange rates.

    func testACurrencyMissingFromALoadedTableHasNoRateAndNoFallback() throws {
        // The table has dollars and pounds; the euro is a real currency with a hard-coded fallback.
        XCTAssertTrue(converter.getExchangeRateInfo(from: "EUR", to: "GBP").rate.isFinite,
                      "the lenient path still finds a rate for it")
        XCTAssertNil(converter.convertWithLoadedRates(amount: 100, from: "EUR", to: "GBP"))
        XCTAssertEqual(converter.convertWithLoadedRates(amount: 100, from: "USD", to: "GBP") ?? .nan, 80, accuracy: 1e-9)
        XCTAssertEqual(converter.convertWithLoadedRates(amount: 100, from: "GBp", to: "USD") ?? .nan, 1.25, accuracy: 1e-9)
        XCTAssertEqual(converter.convertWithLoadedRates(amount: 250, from: "GBX", to: "GBP") ?? .nan, 2.5, accuracy: 1e-12)
        XCTAssertEqual(converter.convertWithLoadedRates(amount: 2.5, from: "GBP", to: "GBp") ?? .nan, 250, accuracy: 1e-12)

        let euroCash = folyncModel(try folyncSnapshot(cashCurrency: "EUR"))
        let valuation = AllocationValuation.make(from: euroCash)
        XCTAssertEqual(valuation.cash, .none, "no cash, rather than cash at a hard-coded rate")
        XCTAssertEqual(valuation.cashOmission, .noExchangeRate)
        XCTAssertEqual(P.omissionLine(.noExchangeRate),
                       "There is no exchange rate for the cash yet, so these percentages are of the holdings alone, without cash.")

        let euroHolding = model()
        euroHolding.realTimeTrades = [trade("ALFA", price: 40, units: "10", currency: "GBP"),
                                      trade("EURO", price: 50, units: "10", currency: "EUR")]
        let partial = AllocationValuation.make(from: euroHolding)
        XCTAssertEqual(partial.covered, 1)
        XCTAssertEqual(partial.eligible, 2)
        XCTAssertNil(partial.positions["EURO"])
    }

    func testTheCalculationIsKeyedOnTheLoadedRatesAndNothingElseAboutThem() throws {
        let rates = CurrencyConverter(exchangeRates: [:], refreshOnInit: false, loadHistoryOnInit: false)
        let dollars = folyncModel(try folyncSnapshot(), preferredCurrency: "USD", converter: rates)
        // The value the page's calculation task is keyed on, read from the page itself.
        func trigger() -> PortfolioAnalyticsView.AnalyticsTrigger { PortfolioAnalyticsView(dataModel: dollars).analyticsTrigger }
        let waiting = trigger()
        XCTAssertNil(waiting.loadedRates)
        XCTAssertEqual(AllocationValuation.make(from: dollars).covered, 0, "no rates loaded: nothing valued at a guessed rate")

        // A table without a load time is not used for conversion, so it changes nothing here.
        rates.exchangeRates = ["USD": 1.0, "GBP": 0.8]
        XCTAssertEqual(trigger(), waiting)
        XCTAssertNil(rates.convertWithLoadedRates(amount: 1, from: "GBP", to: "USD"))

        // The rates arriving start the calculation again, and it then finds them.
        rates.lastRefreshTime = Date(timeIntervalSince1970: 1_000)
        let loaded = trigger()
        XCTAssertNotEqual(loaded, waiting)
        XCTAssertEqual(loaded.loadedRates, ["USD": 1.0, "GBP": 0.8])
        XCTAssertEqual(AllocationValuation.make(from: dollars).cash, .held(125))

        // A refresh with the same rates at a later time does not.
        rates.lastRefreshTime = Date(timeIntervalSince1970: 2_000)
        XCTAssertEqual(trigger(), loaded)

        // New rates do, under the same time or not.
        rates.exchangeRates = ["USD": 1.0, "GBP": 0.75]
        XCTAssertNotEqual(trigger(), loaded)
    }

    // A Trading 212 account with nothing linked, valued by the ordinary sync against a fake broker.

    private static let cashOnlyTrading212Summary = """
    { "cash": { "availableToTrade": 2400.5, "inPies": 0, "reservedForOrders": 100 }, "currency": "GBP", "id": 42,
      "investments": { "currentValue": 0, "realizedProfitLoss": 0, "totalCost": 0, "unrealizedProfitLoss": 0 },
      "totalValue": 2500.5 }
    """

    @MainActor
    func testACashOnlyTrading212AccountIsAllCashAfterTheOrdinarySync() async throws {
        let account = try FakeTrading212Account()
        defer { account.cleanUp() }
        account.answer(summary: Self.cashOnlyTrading212Summary)
        let broker = account.makeDataModel(converter: converter)
        // Before the sync there is nothing to show: no holding and no cash.
        let before = AllocationValuation.make(from: broker)
        XCTAssertFalse(P.hasContent(eligibleHoldings: before.eligible, cash: before.cash))

        _ = try await broker.syncLinkedTrading212Holdings(reason: "auto")

        let basis = broker.holdingsWeightBasis()
        XCTAssertEqual(basis, HoldingsWeightBasis(source: .trading212,
                                                  total: HoldingsWeightBasis.Amount(value: 2_500.5, currency: "GBP"),
                                                  cash: HoldingsWeightBasis.Amount(value: 2_500.5, currency: "GBP"),
                                                  mismatch: nil))
        let valuation = AllocationValuation.make(from: broker)
        XCTAssertEqual(valuation.eligible, 0)
        XCTAssertEqual(valuation.cash, .held(2_500.5))
        XCTAssertEqual(valuation.sourceTotal ?? .nan, 2_500.5, accuracy: 1e-9)
        XCTAssertNil(valuation.cashOmission)
        XCTAssertTrue(P.hasContent(eligibleHoldings: valuation.eligible, cash: valuation.cash))
        for grouping in AllocationGrouping.allCases {
            let rows = P.displayed([], cash: valuation.cash, sourceTotal: valuation.sourceTotal)
            XCTAssertEqual(rows.map { P.rowLabel($0, grouping: grouping) }, ["Cash"], grouping.rawValue)
            XCTAssertEqual(rows.map { P.shareText($0.share) }, ["100.0%"], grouping.rawValue)
        }
        let centre = P.centreText(total: P.shareTotal(holdingsTotal: 0, cash: valuation.cash, sourceTotal: valuation.sourceTotal),
                                  holdingCount: 0, currency: "GBP", includesCash: true)
        XCTAssertEqual(centre.count, "Cash only")
        XCTAssertEqual(P.shareTotal(holdingsTotal: 0, cash: valuation.cash, sourceTotal: valuation.sourceTotal),
                       broker.calculateNetValue().amount, accuracy: 1e-9, "the centre total is Holdings' net value")
        XCTAssertEqual(AllocationShareBasis(cash: valuation.cash, omission: valuation.cashOmission), .portfolioWithCash)
    }

    @MainActor
    func testATrading212AccountWithHoldingsNotLinkedHasNoCashRowAndSaysWhy() async throws {
        let account = try FakeTrading212Account()
        defer { account.cleanUp() }
        account.answer(summary: """
        { "cash": { "availableToTrade": 2500.5, "inPies": 0, "reservedForOrders": 0 }, "currency": "GBP", "id": 42,
          "investments": { "currentValue": 500, "realizedProfitLoss": 0, "totalCost": 450, "unrealizedProfitLoss": 50 },
          "totalValue": 3000.5 }
        """)
        let broker = account.makeDataModel(converter: converter)
        _ = try await broker.syncLinkedTrading212Holdings(reason: "auto")

        // Holdings' total is the whole account, the £500 it holds unlinked included.
        XCTAssertEqual(broker.calculateNetValue().amount, 3_000.5, accuracy: 1e-9)
        XCTAssertEqual(broker.calculateNetGains().amount, 50, accuracy: 1e-9)
        // Allocation has no row for the unlinked £500, so £2,500.50 of cash is not the total.
        let valuation = AllocationValuation.make(from: broker)
        XCTAssertEqual(valuation.cash, .none)
        XCTAssertEqual(valuation.cashOmission, .totalDiffers)
        XCTAssertFalse(P.hasContent(eligibleHoldings: valuation.eligible, cash: valuation.cash),
                       "nothing to draw, as before the sync")
        // What the page then shows: the empty page's line, which says why, not only the
        // request for a holding the page shows with nothing at all to allocate.
        XCTAssertEqual(P.emptyStateMessage(valuation.cashOmission),
                       "The cash does not add up to the portfolio's total value: part of it is in no holding shown here "
                       + "(with Trading 212, investments not linked to a holding), so there is no allocation to show.")
        XCTAssertEqual(P.emptyStateMessage(nil), "Add a holding to your portfolio to see how it is allocated")
        for omission in [AllocationCashOmission.partialCoverage, .holdingsOutsideBrokerAccount] {
            XCTAssertEqual(P.emptyStateMessage(omission), P.emptyStateMessage(nil), "\(omission): needs holdings, so only asks for one")
        }
        XCTAssertEqual(P.emptyStateMessage(.noExchangeRate),
                       "There is no exchange rate for the cash yet, so there is no allocation to show.")
        XCTAssertEqual(P.emptyStateMessage(.folyncWithoutTotal),
                       "Folync gives no total value for this portfolio, so its cash has no share to show.")
        // Holdings shows the account's £3,000.50 with no rows, and its empty table says whose figure it is.
        XCTAssertTrue(broker.isValuedFromTrading212AccountAlone)
        XCTAssertEqual(HoldingsText.emptyTableDescription(valuedFromTrading212Account: broker.isValuedFromTrading212AccountAlone),
                       "The total is your Trading 212 account's value: its cash and any holdings not linked here. "
                       + "Link or add holdings to list them.")
        XCTAssertEqual(HoldingsText.emptyTableDescription(valuedFromTrading212Account: false),
                       "Add a holding, or connect a portfolio in Settings → Connections.")
    }

    @MainActor
    func testTheCalculationIsKeyedOnTheFreshTrading212ValuationsFigures() async throws {
        let account = try FakeTrading212Account()
        defer { account.cleanUp() }
        account.answer(summary: Self.cashOnlyTrading212Summary)
        let broker = account.makeDataModel(converter: converter)
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        broker.trading212Clock = { now }
        // The trigger as the page builds it, from the model's state now.
        func trigger() -> PortfolioAnalyticsView.AnalyticsTrigger {
            PortfolioAnalyticsView.AnalyticsTrigger(range: .threeMonths, currency: broker.preferredCurrency, tick: 0,
                                                    converter: broker.currencyConverter, dataModel: broker)
        }
        let none = trigger()
        XCTAssertNil(none.brokerValuation)

        _ = try await broker.syncLinkedTrading212Holdings(reason: "auto")
        let first = trigger()
        XCTAssertNotEqual(first, none, "a valuation arriving starts the calculation")
        XCTAssertEqual(first.brokerValuation?.cashValue ?? .nan, 2_500.5, accuracy: 1e-9)
        XCTAssertEqual(first.brokerValuation?.accountValue ?? .nan, 2_500.5, accuracy: 1e-9)
        XCTAssertEqual(first.brokerValuation?.currency, "GBP")

        // A later sync that brings the same figures does not start it again.
        now += 60
        _ = try await broker.syncLinkedTrading212Holdings(reason: "auto")
        XCTAssertNotEqual(broker.trading212BrokerValuationSnapshot?.updatedAt, Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertEqual(trigger(), first, "an unchanged sync does not recalculate")

        // A sync that brings only new cash: no holding changes, yet the page recalculates
        // and then finds the new cash.
        account.answer(summary: Self.cashOnlyTrading212Summary.replacingOccurrences(of: "2400.5", with: "2900.5")
            .replacingOccurrences(of: "2500.5", with: "3000.5"))
        _ = try await broker.syncLinkedTrading212Holdings(reason: "auto")
        let second = trigger()
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(second.tick, first.tick, "no portfolio change: only the valuation moved")
        XCTAssertEqual(second.brokerValuation?.cashValue ?? .nan, 3_000.5, accuracy: 1e-9)
        XCTAssertEqual(AllocationValuation.make(from: broker).cash, .held(3_000.5))

        // The valuation goes stale (past four sync intervals): no valuation, so the page
        // recalculates without it; the next sync brings the same figures back, and it
        // recalculates again.
        now += TimeInterval(account.settings.load().syncIntervalSeconds * 4) + 1
        XCTAssertNil(trigger().brokerValuation)
        XCTAssertNotEqual(trigger(), second)
        _ = try await broker.syncLinkedTrading212Holdings(reason: "auto")
        XCTAssertEqual(trigger(), second)

        // A stored account-only valuation stops applying beside a holding of the app's own,
        // and starts to again once it is removed.
        broker.realTimeTrades = [FakeTrading212Account.row("ALFA", price: 40, units: "10")]
        XCTAssertNil(trigger().brokerValuation)
        broker.realTimeTrades = []
        XCTAssertEqual(trigger(), second)

        broker.setTrading212BrokerValuationSnapshotForTesting(nil)
        XCTAssertEqual(trigger(), none)
    }

    @MainActor
    func testTheTriggerIsToldOfEveryStoredValuationEvenWhenNoneApplies() async throws {
        let account = try FakeTrading212Account()
        defer { account.cleanUp() }
        account.answer(summary: Self.cashOnlyTrading212Summary)
        let broker = account.makeDataModel(converter: converter)
        _ = try await broker.syncLinkedTrading212Holdings(reason: "auto")
        // Trading 212 turned off: the fresh valuation is decided without reading the stored one.
        account.change { $0.isEnabled = false }
        let told = expectation(description: "the trigger's reads changed")
        withObservationTracking {
            _ = PortfolioAnalyticsView.AnalyticsTrigger(range: .threeMonths, currency: "GBP", tick: 0,
                                                        converter: broker.currencyConverter, dataModel: broker)
        } onChange: {
            told.fulfill()
        }
        broker.trading212AccountDidChange()
        // Observation calls `onChange` as the property is set, so this does not wait.
        await fulfillment(of: [told], timeout: 5)
    }

    // Coverage, cash only and a single holding.

    func testPartialCoverageLeavesCashOutAndSaysSo() throws {
        let folync = folyncModel(try folyncSnapshot(holdings: [("a", "523.45"), ("b", "376.55"), ("c", "null")]))
        let valuation = AllocationValuation.make(from: folync)
        XCTAssertEqual(valuation.covered, 2)
        XCTAssertEqual(valuation.eligible, 3)
        XCTAssertEqual(valuation.cash, .none, "the full cash beside part of the holdings would overstate its share")
        XCTAssertEqual(valuation.cashOmission, .partialCoverage)
        XCTAssertNil(P.omissionLine(.partialCoverage), "the coverage notice says it")
        XCTAssertEqual(P.coverageNotice(covered: 2, eligible: 3, leavesOutCash: true),
                       "Based on 2 of 3 holdings. The rest have no price or exchange rate yet, so the percentages are "
                       + "of the valued holdings only, without cash.")
        XCTAssertEqual(P.coverageNotice(covered: 2, eligible: 3, leavesOutCash: false),
                       "Based on 2 of 3 holdings. The rest have no price or exchange rate yet, so the percentages are "
                       + "of the valued part only.")

        // A local portfolio has no cash to leave out, so nothing is said about it.
        let local = model()
        local.realTimeTrades = [trade("ALFA", price: 40, units: "10", currency: "GBP"),
                                trade("NOPR", price: .nan, units: "10", currency: "GBP")]
        XCTAssertNil(AllocationValuation.make(from: local).cashOmission)
    }

    func testCashOnlyIsAllCashAndASingleHoldingIsShown() throws {
        let cashOnly = folyncModel(try folyncSnapshot(total: "100", holdings: []))
        let valuation = AllocationValuation.make(from: cashOnly)
        XCTAssertEqual(valuation.eligible, 0)
        XCTAssertEqual(valuation.cash, .held(100), "£100 of cash is the whole of a £100 total")
        XCTAssertTrue(P.hasContent(eligibleHoldings: valuation.eligible, cash: valuation.cash))
        let rows = P.displayed([], cash: valuation.cash, sourceTotal: valuation.sourceTotal)
        XCTAssertEqual(rows.map(\.label), ["Cash"])
        XCTAssertEqual(rows.map { P.shareText($0.share) }, ["100.0%"])
        XCTAssertEqual(P.centreText(total: 100, holdingCount: 0, currency: "GBP", includesCash: true).count, "Cash only")

        let single = model()
        single.realTimeTrades = [trade("ALFA", price: 40, units: "10", currency: "GBP")]
        let one = AllocationValuation.make(from: single)
        XCTAssertEqual(one.covered, 1)
        XCTAssertTrue(P.hasContent(eligibleHoldings: one.eligible, cash: one.cash))

        XCTAssertFalse(P.hasContent(eligibleHoldings: 0, cash: .none), "nothing to show")
        XCTAssertFalse(P.hasContent(eligibleHoldings: 0, cash: .borrowing(-5)))
    }

    // Tiny cash and borrowing.

    func testCashThatShowsAsZeroCountsAsZero() throws {
        for tiny in ["0.004", "-0.004"] {
            let folync = folyncModel(try folyncSnapshot(total: "900.004", cash: tiny))
            let valuation = AllocationValuation.make(from: folync)
            XCTAssertEqual(valuation.cash, .none, tiny)
            XCTAssertNil(valuation.cashOmission, tiny)
            XCTAssertNil(P.borrowingLine(valuation.cash, currency: "GBP"), "no \"below zero (£0.00)\" line")
            XCTAssertEqual(AllocationShareBasis(cash: valuation.cash, omission: valuation.cashOmission), .portfolio)
        }
        // Half a penny is shown as a penny, so it is cash.
        let penny = folyncModel(try folyncSnapshot(total: "900.006", cash: "0.006"))
        XCTAssertEqual(AllocationValuation.make(from: penny).cash, .held(0.006))
    }

    func testWithCashBelowZeroEveryNoteSaysItsShareIsOfTheHoldings() async throws {
        let basis = AllocationShareBasis(cash: .borrowing(-250), omission: nil)
        XCTAssertEqual(basis, .holdings)
        let sectors = await sectors()   // £360 of £900 unclassified
        let share = try XCTUnwrap(P.unclassifiedShare(sectors, cash: .borrowing(-250)))
        XCTAssertEqual(share, 40, accuracy: 1e-9)
        let notes = [P.unclassifiedNote(share: share, basis: basis),
                     P.diversificationUnclassifiedNote(share: share, basis: basis),
                     P.diversificationUnavailableNote(share: 62, basis: basis)]
        XCTAssertEqual(notes, [
            "40.0% of the holdings' value is in holdings with no known sector (shown as Unclassified).",
            "40.0% of the holdings' value has no known sector and is excluded from this score.",
            "Diversification unavailable: 62% of the holdings' value has no known sector."
        ])
        for note in notes { XCTAssertFalse(note.contains("portfolio"), note) }
        XCTAssertEqual(AllocationShareBasis(cash: .none, omission: .totalDiffers), .holdings)
        XCTAssertEqual(AllocationShareBasis(cash: .none, omission: nil), .portfolio)
        XCTAssertEqual(AllocationShareBasis(cash: .held(10), omission: nil), .portfolioWithCash)
    }
}
