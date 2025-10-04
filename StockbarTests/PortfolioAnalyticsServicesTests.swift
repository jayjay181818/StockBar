import XCTest
@testable import Stockbar

/// Combined tests for CorrelationMatrixService and SectorAnalysisService
final class PortfolioAnalyticsServicesTests: XCTestCase {

    // MARK: - Correlation Matrix Service Tests

    func testCorrelationMatrix_WithPerfectCorrelation() async throws {
        // Given: Two perfectly correlated return series
        let service = CorrelationMatrixService()
        let returns: [String: [Double]] = [
            "AAPL": [0.01, 0.02, -0.01, 0.03, 0.00],
            "MSFT": [0.01, 0.02, -0.01, 0.03, 0.00]  // Identical
        ]

        // When: Calculate correlation matrix
        let matrix = await service.calculateCorrelationMatrix(returns: returns)

        // Then: Correlation should be 1.0
        if let correlation = matrix.correlation(between: "AAPL", between: "MSFT") {
            XCTAssertEqual(correlation, 1.0, accuracy: 0.1, "Perfect correlation should be ~1.0")
        } else {
            XCTFail("Should calculate correlation")
        }
    }

    func testCorrelationMatrix_WithNegativeCorrelation() async throws {
        // Given: Negatively correlated series
        let service = CorrelationMatrixService()
        let returns: [String: [Double]] = [
            "AAPL": [0.02, 0.03, 0.01, 0.04, 0.02],
            "TSLA": [-0.02, -0.03, -0.01, -0.04, -0.02]  // Opposite
        ]

        // When: Calculate correlation matrix
        let matrix = await service.calculateCorrelationMatrix(returns: returns)

        // Then: Correlation should be negative
        if let correlation = matrix.correlation(between: "AAPL", between: "TSLA") {
            XCTAssertLessThan(correlation, 0, "Should have negative correlation")
            XCTAssertGreaterThan(correlation, -1.1, "Correlation should be >= -1")
        }
    }

    func testCorrelationMatrix_SelfCorrelation() async throws {
        // Given: Single symbol
        let service = CorrelationMatrixService()
        let returns: [String: [Double]] = [
            "AAPL": [0.01, 0.02, -0.01, 0.03, 0.00]
        ]

        // When: Calculate correlation matrix
        let matrix = await service.calculateCorrelationMatrix(returns: returns)

        // Then: Self-correlation should be 1.0
        if let correlation = matrix.correlation(between: "AAPL", between: "AAPL") {
            XCTAssertEqual(correlation, 1.0, accuracy: 0.001, "Self-correlation should be 1.0")
        }
    }

    func testCorrelationMatrix_WithMultipleSymbols() async throws {
        // Given: Multiple symbols with varied correlations
        let service = CorrelationMatrixService()
        let returns: [String: [Double]] = [
            "AAPL": [0.01, 0.02, -0.01, 0.03, 0.00, 0.02],
            "MSFT": [0.01, 0.015, -0.005, 0.025, 0.005, 0.015],  // High correlation
            "TSLA": [0.05, -0.03, 0.02, -0.01, 0.04, -0.02],     // Low correlation
            "GOOGL": [0.02, 0.01, 0.00, 0.02, 0.01, 0.01]       // Moderate correlation
        ]

        // When: Calculate correlation matrix
        let matrix = await service.calculateCorrelationMatrix(returns: returns)

        // Then: Matrix should be square and symmetric
        XCTAssertEqual(matrix.symbols.count, 4, "Should have 4 symbols")
        XCTAssertEqual(matrix.matrix.count, 4, "Matrix should be 4x4")

        // Verify symmetry
        for i in 0..<matrix.matrix.count {
            for j in 0..<matrix.matrix[i].count {
                XCTAssertEqual(matrix.matrix[i][j], matrix.matrix[j][i], accuracy: 0.001,
                             "Matrix should be symmetric")
            }
        }

        // Verify diagonal is 1.0
        for i in 0..<matrix.matrix.count {
            XCTAssertEqual(matrix.matrix[i][i], 1.0, accuracy: 0.001,
                          "Diagonal should be 1.0 (self-correlation)")
        }
    }

    // MARK: - Diversification Metrics Tests

    func testDiversificationMetrics_PerfectlyCorrelated() async throws {
        // Given: All symbols perfectly correlated
        let service = CorrelationMatrixService()
        let returns: [String: [Double]] = [
            "AAPL": [0.01, 0.02, -0.01, 0.03],
            "MSFT": [0.01, 0.02, -0.01, 0.03],
            "GOOGL": [0.01, 0.02, -0.01, 0.03]
        ]

        let weights = ["AAPL": 0.33, "MSFT": 0.33, "GOOGL": 0.34]

        // When: Calculate diversification metrics
        let metrics = await service.calculateDiversificationMetrics(
            returns: returns,
            weights: weights
        )

        // Then: Should show poor diversification
        XCTAssertGreaterThan(metrics.averageCorrelation, 0.9, "Average correlation should be very high")
        XCTAssertLessThan(metrics.diversificationScore, 50, "Diversification score should be low")
        XCTAssertEqual(metrics.riskLevel, .high, "Risk level should be high")
    }

    func testDiversificationMetrics_WellDiversified() async throws {
        // Given: Uncorrelated symbols
        let service = CorrelationMatrixService()
        let returns: [String: [Double]] = [
            "AAPL": [0.01, 0.02, -0.01, 0.03, 0.00],
            "TSLA": [0.02, -0.01, 0.03, -0.02, 0.01],
            "GOOGL": [-0.01, 0.01, 0.02, 0.00, -0.01],
            "NVDA": [0.03, 0.00, -0.02, 0.01, 0.02],
            "AMD": [-0.02, 0.02, 0.01, -0.01, 0.00]
        ]

        let weights = ["AAPL": 0.2, "TSLA": 0.2, "GOOGL": 0.2, "NVDA": 0.2, "AMD": 0.2]

        // When: Calculate diversification metrics
        let metrics = await service.calculateDiversificationMetrics(
            returns: returns,
            weights: weights
        )

        // Then: Should show good diversification
        XCTAssertGreaterThan(metrics.effectiveN, 1.5, "Should have multiple effective positions")
        XCTAssertGreaterThanOrEqual(metrics.diversificationScore, 0, "Score should be non-negative")
        XCTAssertLessThanOrEqual(metrics.diversificationScore, 100, "Score should not exceed 100")
    }

    func testDiversificationMetrics_EffectiveN() async throws {
        // Given: Varying correlations
        let service = CorrelationMatrixService()
        let returns: [String: [Double]] = [
            "AAPL": [0.01, 0.02, -0.01, 0.03],
            "MSFT": [0.01, 0.015, -0.005, 0.025],  // Slightly different
            "TSLA": [0.05, -0.03, 0.02, -0.01]     // Very different
        ]

        let weights = ["AAPL": 0.4, "MSFT": 0.4, "TSLA": 0.2]

        // When: Calculate metrics
        let metrics = await service.calculateDiversificationMetrics(
            returns: returns,
            weights: weights
        )

        // Then: Effective N should be reasonable
        XCTAssertGreaterThan(metrics.effectiveN, 1.0, "Should have > 1 effective position")
        XCTAssertLessThanOrEqual(metrics.effectiveN, 3.0, "Should not exceed number of stocks")
    }

    // MARK: - Top Correlated Pairs Tests

    func testTopCorrelatedPairs() async throws {
        // Given: Multiple symbols with known correlations
        let service = CorrelationMatrixService()
        let returns: [String: [Double]] = [
            "AAPL": [0.01, 0.02, -0.01, 0.03, 0.00],
            "MSFT": [0.01, 0.02, -0.01, 0.03, 0.00],  // Very similar to AAPL
            "TSLA": [0.05, -0.03, 0.02, -0.01, 0.04],
            "GOOGL": [0.02, 0.01, 0.00, 0.02, 0.01]
        ]

        // When: Get top correlated pairs
        let pairs = await service.getTopCorrelatedPairs(returns: returns, count: 3)

        // Then: Should return pairs
        XCTAssertGreaterThan(pairs.count, 0, "Should find correlated pairs")
        XCTAssertLessThanOrEqual(pairs.count, 3, "Should not exceed requested count")

        // First pair should have highest correlation
        if pairs.count >= 2 {
            XCTAssertGreaterThanOrEqual(pairs[0].correlation, pairs[1].correlation,
                                       "Pairs should be sorted by correlation")
        }
    }

    // MARK: - Sector Analysis Service Tests

    func testSectorClassification_KnownSymbols() async throws {
        // Given: Well-known tech symbols
        let service = SectorAnalysisService()

        // When: Get sector for AAPL
        let aaplSector = await service.getSector(for: "AAPL")

        // Then: Should be Technology
        XCTAssertEqual(aaplSector, "Technology", "AAPL should be Technology sector")
    }

    func testSectorClassification_MultipleSymbols() async throws {
        // Given: Symbols from different sectors
        let service = SectorAnalysisService()
        let symbols = ["AAPL", "JPM", "JNJ", "XOM"]

        // When: Get sectors
        let sectors = await withTaskGroup(of: (String, String).self) { group in
            for symbol in symbols {
                group.addTask {
                    let sector = await service.getSector(for: symbol)
                    return (symbol, sector)
                }
            }

            var result: [String: String] = [:]
            for await (symbol, sector) in group {
                result[symbol] = sector
            }
            return result
        }

        // Then: Should have different sectors
        XCTAssertEqual(sectors.count, 4, "Should classify all symbols")
        let uniqueSectors = Set(sectors.values)
        XCTAssertGreaterThan(uniqueSectors.count, 1, "Should have multiple sectors")
    }

    func testSectorAllocation_Calculation() async throws {
        // Given: Portfolio with known sectors
        let service = SectorAnalysisService()
        let positions: [(String, Double)] = [
            ("AAPL", 10000),   // Technology
            ("MSFT", 10000),   // Technology
            ("JPM", 5000),     // Financials
            ("JNJ", 5000)      // Healthcare
        ]

        // When: Calculate sector allocation
        let allocation = await service.calculateSectorAllocation(positions: positions)

        // Then: Should allocate correctly
        XCTAssertGreaterThan(allocation.count, 0, "Should have sector allocations")

        // Technology should be largest (20k out of 30k = 66.67%)
        if let techAllocation = allocation.first(where: { $0.sector == "Technology" }) {
            XCTAssertGreaterThan(techAllocation.percentageOfPortfolio, 60,
                               "Technology should be dominant sector")
        }

        // Total percentage should be ~100%
        let totalPercentage = allocation.reduce(0.0) { $0 + $1.percentageOfPortfolio }
        XCTAssertEqual(totalPercentage, 100.0, accuracy: 0.1,
                      "Total allocation should be 100%")
    }

    func testSectorAllocation_WithEmptyPortfolio() async throws {
        // Given: Empty portfolio
        let service = SectorAnalysisService()
        let positions: [(String, Double)] = []

        // When: Calculate allocation
        let allocation = await service.calculateSectorAllocation(positions: positions)

        // Then: Should return empty
        XCTAssertTrue(allocation.isEmpty, "Empty portfolio should have no allocations")
    }

    func testDiversificationScore_Concentrated() async throws {
        // Given: Highly concentrated portfolio (all tech)
        let service = SectorAnalysisService()
        let positions: [(String, Double)] = [
            ("AAPL", 10000),
            ("MSFT", 10000),
            ("GOOGL", 10000)
        ]

        // When: Calculate diversification score
        let score = await service.calculateDiversificationScore(positions: positions)

        // Then: Should be low
        XCTAssertLessThan(score, 50, "Concentrated portfolio should have low diversification")
    }

    func testDiversificationScore_WellDiversified() async throws {
        // Given: Well-diversified portfolio across sectors
        let service = SectorAnalysisService()
        let positions: [(String, Double)] = [
            ("AAPL", 5000),   // Technology
            ("JPM", 5000),    // Financials
            ("JNJ", 5000),    // Healthcare
            ("XOM", 5000),    // Energy
            ("WMT", 5000),    // Consumer Defensive
            ("CAT", 5000)     // Industrials
        ]

        // When: Calculate diversification score
        let score = await service.calculateDiversificationScore(positions: positions)

        // Then: Should be high
        XCTAssertGreaterThan(score, 60, "Diversified portfolio should have high score")
        XCTAssertLessThanOrEqual(score, 100, "Score should not exceed 100")
    }

    func testTopHeavySectors_Detection() async throws {
        // Given: Portfolio with one dominant sector
        let service = SectorAnalysisService()
        let positions: [(String, Double)] = [
            ("AAPL", 15000),   // Technology
            ("MSFT", 10000),   // Technology
            ("GOOGL", 8000),   // Technology (total: 33k / 38k = 87%)
            ("JPM", 5000)      // Financials
        ]

        // When: Get recommendations
        let recommendations = await service.getRecommendations(positions: positions)

        // Then: Should warn about technology concentration
        let hasTechWarning = recommendations.contains { recommendation in
            recommendation.lowercased().contains("technology") ||
            recommendation.lowercased().contains("concentrated")
        }
        XCTAssertTrue(hasTechWarning, "Should warn about technology sector concentration")
    }

    func testMissingSectors_Recommendations() async throws {
        // Given: Portfolio missing major sectors
        let service = SectorAnalysisService()
        let positions: [(String, Double)] = [
            ("AAPL", 10000),   // Only technology
            ("MSFT", 10000)
        ]

        // When: Get recommendations
        let recommendations = await service.getRecommendations(positions: positions)

        // Then: Should suggest diversification
        XCTAssertGreaterThan(recommendations.count, 0,
                           "Should provide recommendations for missing sectors")

        let suggestsDiversification = recommendations.contains { recommendation in
            recommendation.lowercased().contains("diversif") ||
            recommendation.lowercased().contains("consider")
        }
        XCTAssertTrue(suggestsDiversification,
                     "Should recommend diversification")
    }

    // MARK: - Industry Breakdown Tests

    func testIndustryBreakdown_WithinSector() async throws {
        // Given: Multiple stocks in same sector but different industries
        let service = SectorAnalysisService()
        let positions: [(String, Double)] = [
            ("AAPL", 10000),   // Technology / Consumer Electronics
            ("MSFT", 10000)    // Technology / Software
        ]

        // When: Calculate allocation
        let allocation = await service.calculateSectorAllocation(positions: positions)

        // Then: Should have industry breakdown
        if let techSector = allocation.first(where: { $0.sector == "Technology" }) {
            XCTAssertGreaterThan(techSector.industryBreakdown.count, 0,
                               "Should have industry breakdown")
        }
    }

    // MARK: - Edge Cases

    func testCorrelationMatrix_WithInsufficientData() async throws {
        // Given: Very short return series
        let service = CorrelationMatrixService()
        let returns: [String: [Double]] = [
            "AAPL": [0.01],
            "MSFT": [0.02]
        ]

        // When: Calculate correlation
        let matrix = await service.calculateCorrelationMatrix(returns: returns)

        // Then: Should handle gracefully
        XCTAssertEqual(matrix.symbols.count, 2, "Should still create matrix structure")
    }

    func testSectorAnalysis_WithUnknownSymbol() async throws {
        // Given: Unknown/unlisted symbol
        let service = SectorAnalysisService()

        // When: Get sector
        let sector = await service.getSector(for: "UNKNOWN123")

        // Then: Should return default
        XCTAssertEqual(sector, "Unknown", "Should return Unknown for unmapped symbols")
    }

    func testDiversificationMetrics_WithSingleStock() async throws {
        // Given: Single stock portfolio
        let service = CorrelationMatrixService()
        let returns: [String: [Double]] = [
            "AAPL": [0.01, 0.02, -0.01, 0.03]
        ]
        let weights = ["AAPL": 1.0]

        // When: Calculate metrics
        let metrics = await service.calculateDiversificationMetrics(
            returns: returns,
            weights: weights
        )

        // Then: Should show poor diversification
        XCTAssertEqual(metrics.effectiveN, 1.0, accuracy: 0.1,
                      "Single stock should have effectiveN = 1")
        XCTAssertEqual(metrics.concentrationScore, 1.0, accuracy: 0.1,
                      "Single stock should have maximum concentration")
    }
}
