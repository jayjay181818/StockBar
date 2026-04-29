import XCTest
@testable import Stockbar

final class PortfolioAnalyticsServicesTests: XCTestCase {
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
                XCTAssertEqual(matrix.matrix[row][column], matrix.matrix[column][row], accuracy: 0.001)
            }
            XCTAssertEqual(matrix.matrix[row][row], 1.0, accuracy: 0.001)
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
}
