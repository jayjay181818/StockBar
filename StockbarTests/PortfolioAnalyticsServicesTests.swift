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
