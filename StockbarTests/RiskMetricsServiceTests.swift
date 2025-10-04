import XCTest
@testable import Stockbar

@MainActor
final class RiskMetricsServiceTests: XCTestCase {

    var service: RiskMetricsService!

    override func setUp() async throws {
        try await super.setUp()
        service = RiskMetricsService.shared
    }

    override func tearDown() async throws {
        service = nil
        try await super.tearDown()
    }

    // MARK: - Value at Risk (VaR) Tests

    func testVaR95_WithNormalReturns() async throws {
        // Given: Normal distribution-like returns
        let returns = [
            -0.05, -0.03, -0.02, -0.01, 0.00,
            0.01, 0.02, 0.03, 0.04, 0.05,
            0.01, 0.02, -0.01, 0.00, 0.01,
            0.02, 0.03, -0.02, 0.01, 0.00
        ]
        let portfolioValue = 10000.0

        // When: Calculate 95% VaR
        let var95 = await service.calculateVaR(
            returns: returns,
            confidenceLevel: 0.95,
            portfolioValue: portfolioValue
        )

        // Then: Should return reasonable VaR
        XCTAssertNotNil(var95)
        if let var95 = var95 {
            XCTAssertGreaterThan(var95, 0, "VaR should be positive")
            XCTAssertLessThan(var95, 1000, "VaR should be reasonable for 10k portfolio")
        }
    }

    func testVaR99_ShouldBeHigherThanVaR95() async throws {
        // Given: Same return series
        let returns = [
            -0.10, -0.05, -0.03, -0.02, -0.01,
            0.00, 0.01, 0.02, 0.03, 0.04,
            0.05, 0.06, 0.07, 0.08, 0.09
        ]
        let portfolioValue = 10000.0

        // When: Calculate both VaRs
        let var95 = await service.calculateVaR(returns: returns, confidenceLevel: 0.95, portfolioValue: portfolioValue)
        let var99 = await service.calculateVaR(returns: returns, confidenceLevel: 0.99, portfolioValue: portfolioValue)

        // Then: VaR99 should be higher than VaR95
        XCTAssertNotNil(var95)
        XCTAssertNotNil(var99)
        if let var95 = var95, let var99 = var99 {
            XCTAssertGreaterThan(var99, var95, "99% VaR should be higher than 95% VaR")
        }
    }

    func testVaR_WithEmptyReturns() async throws {
        // Given: Empty returns array
        let returns: [Double] = []
        let portfolioValue = 10000.0

        // When: Calculate VaR
        let var95 = await service.calculateVaR(returns: returns, confidenceLevel: 0.95, portfolioValue: portfolioValue)

        // Then: Should return nil
        XCTAssertNil(var95)
    }

    func testVaR_WithInvalidConfidenceLevel() async throws {
        // Given: Invalid confidence levels
        let returns = [-0.05, -0.03, 0.00, 0.02, 0.05]
        let portfolioValue = 10000.0

        // When: Calculate with invalid confidence
        let varZero = await service.calculateVaR(returns: returns, confidenceLevel: 0.0, portfolioValue: portfolioValue)
        let varOne = await service.calculateVaR(returns: returns, confidenceLevel: 1.0, portfolioValue: portfolioValue)
        let varNegative = await service.calculateVaR(returns: returns, confidenceLevel: -0.5, portfolioValue: portfolioValue)

        // Then: Should return nil
        XCTAssertNil(varZero)
        XCTAssertNil(varOne)
        XCTAssertNil(varNegative)
    }

    // MARK: - Sharpe Ratio Tests

    func testSharpeRatio_WithPositiveReturns() async throws {
        // Given: Positive return series with low volatility
        let returns = Array(repeating: 0.01, count: 252) // 1% daily return consistently
        let riskFreeRate = 0.02 // 2% annual

        // When: Calculate Sharpe Ratio
        let sharpe = await service.calculateSharpeRatio(
            returns: returns,
            riskFreeRate: riskFreeRate,
            periodsPerYear: 252
        )

        // Then: Should have very high Sharpe ratio (low volatility, high return)
        XCTAssertNotNil(sharpe)
        if let sharpe = sharpe {
            // With zero volatility and high returns, Sharpe should be extremely high
            // (In practice, this won't happen, but tests the calculation)
            XCTAssertGreaterThan(sharpe, 0, "Sharpe ratio should be positive for positive returns")
        }
    }

    func testSharpeRatio_WithMixedReturns() async throws {
        // Given: Mixed return series (realistic scenario)
        let returns = [
            0.02, -0.01, 0.03, -0.02, 0.01,
            0.04, -0.01, 0.02, 0.00, 0.01,
            -0.03, 0.05, 0.01, -0.01, 0.02
        ]
        let riskFreeRate = 0.04 // 4% annual

        // When: Calculate Sharpe Ratio
        let sharpe = await service.calculateSharpeRatio(
            returns: returns,
            riskFreeRate: riskFreeRate,
            periodsPerYear: 252
        )

        // Then: Should return a reasonable value
        XCTAssertNotNil(sharpe)
        if let sharpe = sharpe {
            XCTAssertGreaterThan(sharpe, -5, "Sharpe ratio should be reasonable")
            XCTAssertLessThan(sharpe, 5, "Sharpe ratio should be reasonable")
        }
    }

    func testSharpeRatio_WithNegativeReturns() async throws {
        // Given: Consistently negative returns
        let returns = Array(repeating: -0.01, count: 252) // -1% daily loss
        let riskFreeRate = 0.04

        // When: Calculate Sharpe Ratio
        let sharpe = await service.calculateSharpeRatio(
            returns: returns,
            riskFreeRate: riskFreeRate,
            periodsPerYear: 252
        )

        // Then: Should be negative
        XCTAssertNotNil(sharpe)
        if let sharpe = sharpe {
            XCTAssertLessThan(sharpe, 0, "Sharpe ratio should be negative for negative returns")
        }
    }

    func testSharpeRatio_WithInsufficientData() async throws {
        // Given: Only one data point
        let returns = [0.05]

        // When: Calculate Sharpe Ratio
        let sharpe = await service.calculateSharpeRatio(returns: returns)

        // Then: Should return nil
        XCTAssertNil(sharpe)
    }

    // MARK: - Sortino Ratio Tests

    func testSortinoRatio_WithMixedReturns() async throws {
        // Given: Mixed returns with some downside
        let returns = [
            0.05, -0.02, 0.03, -0.01, 0.04,
            0.02, -0.03, 0.06, 0.01, 0.00
        ]
        let targetReturn = 0.0

        // When: Calculate Sortino Ratio
        let sortino = await service.calculateSortinoRatio(
            returns: returns,
            targetReturn: targetReturn,
            periodsPerYear: 252
        )

        // Then: Should return reasonable value
        XCTAssertNotNil(sortino)
        if let sortino = sortino {
            XCTAssertGreaterThan(sortino, -10, "Sortino ratio should be reasonable")
            XCTAssertLessThan(sortino, 10, "Sortino ratio should be reasonable")
        }
    }

    func testSortinoRatio_WithOnlyPositiveReturns() async throws {
        // Given: All positive returns (no downside)
        let returns = [0.01, 0.02, 0.03, 0.04, 0.05]

        // When: Calculate Sortino Ratio
        let sortino = await service.calculateSortinoRatio(returns: returns, targetReturn: 0.0)

        // Then: Should handle gracefully (infinite ratio technically, but should return reasonable value)
        // Implementation should handle this edge case
        XCTAssertNotNil(sortino)
    }

    // MARK: - Beta Calculation Tests

    func testBeta_WithPerfectCorrelation() async throws {
        // Given: Portfolio returns perfectly correlated with market
        let portfolioReturns = [0.01, 0.02, 0.03, -0.01, 0.04]
        let marketReturns = [0.01, 0.02, 0.03, -0.01, 0.04]

        // When: Calculate beta
        let beta = await service.calculateBeta(
            portfolioReturns: portfolioReturns,
            marketReturns: marketReturns
        )

        // Then: Beta should be close to 1.0
        XCTAssertNotNil(beta)
        if let beta = beta {
            XCTAssertEqual(beta, 1.0, accuracy: 0.1, "Beta should be ~1.0 for perfect correlation")
        }
    }

    func testBeta_WithHigherVolatility() async throws {
        // Given: Portfolio with 2x market volatility
        let marketReturns = [0.01, -0.01, 0.02, -0.02, 0.01]
        let portfolioReturns = marketReturns.map { $0 * 2.0 } // 2x market moves

        // When: Calculate beta
        let beta = await service.calculateBeta(
            portfolioReturns: portfolioReturns,
            marketReturns: marketReturns
        )

        // Then: Beta should be close to 2.0
        XCTAssertNotNil(beta)
        if let beta = beta {
            XCTAssertEqual(beta, 2.0, accuracy: 0.2, "Beta should be ~2.0 for 2x market volatility")
        }
    }

    func testBeta_WithInsufficientData() async throws {
        // Given: Insufficient data
        let portfolioReturns = [0.01]
        let marketReturns = [0.01]

        // When: Calculate beta
        let beta = await service.calculateBeta(
            portfolioReturns: portfolioReturns,
            marketReturns: marketReturns
        )

        // Then: Should return nil
        XCTAssertNil(beta)
    }

    // MARK: - Maximum Drawdown Tests

    func testMaxDrawdown_WithDecreasingValues() async throws {
        // Given: Portfolio with clear drawdown
        let values = [
            100.0, 110.0, 120.0, // Peak at 120
            115.0, 110.0, 100.0, 90.0, // Drawdown to 90 (-25%)
            95.0, 100.0, 110.0 // Recovery
        ]

        // When: Calculate max drawdown
        let (maxDD, duration) = await service.calculateMaxDrawdown(values: values)

        // Then: Should detect 25% drawdown
        XCTAssertNotNil(maxDD)
        if let maxDD = maxDD {
            XCTAssertEqual(maxDD, 0.25, accuracy: 0.01, "Max drawdown should be 25%")
        }
    }

    func testMaxDrawdown_WithIncreasingValues() async throws {
        // Given: Only increasing values (no drawdown)
        let values = [100.0, 110.0, 120.0, 130.0, 140.0]

        // When: Calculate max drawdown
        let (maxDD, duration) = await service.calculateMaxDrawdown(values: values)

        // Then: Drawdown should be 0
        XCTAssertNotNil(maxDD)
        if let maxDD = maxDD {
            XCTAssertEqual(maxDD, 0.0, accuracy: 0.001, "No drawdown for increasing values")
        }
    }

    func testMaxDrawdown_WithEmptyValues() async throws {
        // Given: Empty values
        let values: [Double] = []

        // When: Calculate max drawdown
        let (maxDD, duration) = await service.calculateMaxDrawdown(values: values)

        // Then: Should return nil
        XCTAssertNil(maxDD)
    }

    // MARK: - Statistical Helper Tests

    func testStandardDeviation_WithKnownValues() async throws {
        // Given: Simple dataset with known std dev
        // Values: [2, 4, 4, 4, 5, 5, 7, 9]
        // Mean: 5, Variance: 4, Std Dev: 2
        let values = [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0]

        // When: Calculate standard deviation
        if let stdDev = service.calculateStandardDeviation(values) {
            // Then: Should be 2.0
            XCTAssertEqual(stdDev, 2.0, accuracy: 0.01, "Std dev should be 2.0")
        } else {
            XCTFail("Should calculate standard deviation")
        }
    }

    func testStandardDeviation_WithConstantValues() async throws {
        // Given: All same values (zero variance)
        let values = [5.0, 5.0, 5.0, 5.0, 5.0]

        // When: Calculate standard deviation
        if let stdDev = service.calculateStandardDeviation(values) {
            // Then: Should be 0
            XCTAssertEqual(stdDev, 0.0, accuracy: 0.001, "Std dev should be 0 for constant values")
        } else {
            XCTFail("Should calculate standard deviation")
        }
    }

    // MARK: - Comprehensive Risk Metrics Test

    func testCalculateComprehensiveRiskMetrics() async throws {
        // Given: Realistic portfolio data
        let portfolioSnapshots = createMockPortfolioSnapshots()

        // When: Calculate all risk metrics
        let metrics = await service.calculateRiskMetrics(
            portfolioSnapshots: portfolioSnapshots,
            benchmarkReturns: nil
        )

        // Then: All metrics should be calculated
        XCTAssertNotNil(metrics)
        if let metrics = metrics {
            XCTAssertGreaterThan(metrics.valueAtRisk95, 0, "VaR95 should be positive")
            XCTAssertGreaterThan(metrics.valueAtRisk99, metrics.valueAtRisk95, "VaR99 > VaR95")
            XCTAssertGreaterThan(metrics.volatility, 0, "Volatility should be positive")
            XCTAssertGreaterThanOrEqual(metrics.maxDrawdown, 0, "Max drawdown should be non-negative")
        }
    }

    // MARK: - Helper Methods

    private func createMockPortfolioSnapshots() -> [PortfolioSnapshot] {
        var snapshots: [PortfolioSnapshot] = []
        let calendar = Calendar.current
        let baseDate = Date()
        var value = 10000.0

        // Create 252 days of portfolio snapshots (1 trading year)
        for i in 0..<252 {
            let date = calendar.date(byAdding: .day, value: -i, to: baseDate)!

            // Simulate realistic portfolio movements
            let randomReturn = Double.random(in: -0.03...0.03) // -3% to +3% daily
            value *= (1.0 + randomReturn)

            let snapshot = PortfolioSnapshot(
                timestamp: date,
                totalValue: value,
                totalGain: value - 10000.0
            )
            snapshots.append(snapshot)
        }

        return snapshots.reversed() // Chronological order
    }
}
