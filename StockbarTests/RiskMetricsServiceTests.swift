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
        let returns = Array(repeating: -0.20, count: 5)
            + [-0.10]
            + Array(repeating: 0.01, count: 94)
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
        let returns = (0..<252).map { index in index.isMultiple(of: 2) ? 0.008 : 0.012 }
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
            XCTAssertLessThan(sharpe, 10, "Sharpe ratio should be reasonable")
        }
    }

    func testSharpeRatio_WithNegativeReturns() async throws {
        // Given: Consistently negative returns
        let returns = (0..<252).map { $0 % 2 == 0 ? -0.008 : -0.012 } // ~-1% daily loss with some variance (a constant series has undefined Sharpe)
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
            XCTAssertLessThan(sortino, 30, "Sortino ratio should be reasonable (full-sample downside deviation)")
        }
    }

    func testSortinoRatio_WithOnlyPositiveReturns() async throws {
        // Given: All positive returns (no downside)
        let returns = [0.01, 0.02, 0.03, 0.04, 0.05]

        // When: Calculate Sortino Ratio
        let sortino = await service.calculateSortinoRatio(returns: returns, targetReturn: 0.0)

        // Then: With no downside returns, the current implementation returns nil.
        XCTAssertNil(sortino)
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
        let drawdown = await service.calculateMaxDrawdown(portfolioValues: values)

        // Then: Should detect 25% drawdown
        let maxDD = try XCTUnwrap(drawdown?.maxDrawdown)
        XCTAssertEqual(maxDD, 0.25, accuracy: 0.01, "Max drawdown should be 25%")
    }

    func testMaxDrawdown_WithIncreasingValues() async throws {
        // Given: Only increasing values (no drawdown)
        let values = [100.0, 110.0, 120.0, 130.0, 140.0]

        // When: Calculate max drawdown
        let drawdown = await service.calculateMaxDrawdown(portfolioValues: values)

        // Then: Drawdown should be 0
        let maxDD = try XCTUnwrap(drawdown?.maxDrawdown)
        XCTAssertEqual(maxDD, 0.0, accuracy: 0.001, "No drawdown for increasing values")
    }

    func testMaxDrawdown_WithEmptyValues() async throws {
        // Given: Empty values
        let values: [Double] = []

        // When: Calculate max drawdown
        let drawdown = await service.calculateMaxDrawdown(portfolioValues: values)

        // Then: Should return nil
        XCTAssertNil(drawdown)
    }

    // MARK: - Statistical Helper Tests

    func testStandardDeviation_WithKnownValues() async throws {
        // Given: Simple dataset with known sample std dev
        // Values: [2, 4, 4, 4, 5, 5, 7, 9]
        // Mean: 5, Sample variance: 32/7, Sample Std Dev: 2.1381
        let values = [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0]

        // When: Calculate standard deviation
        if let stdDev = await service.calculateStandardDeviation(values) {
            // Then: Should use sample standard deviation.
            XCTAssertEqual(stdDev, 2.1381, accuracy: 0.0001, "Std dev should use sample variance")
        } else {
            XCTFail("Should calculate standard deviation")
        }
    }

    func testStandardDeviation_WithConstantValues() async throws {
        // Given: All same values (zero variance)
        let values = [5.0, 5.0, 5.0, 5.0, 5.0]

        // When: Calculate standard deviation
        if let stdDev = await service.calculateStandardDeviation(values) {
            // Then: Should be 0
            XCTAssertEqual(stdDev, 0.0, accuracy: 0.001, "Std dev should be 0 for constant values")
        } else {
            XCTFail("Should calculate standard deviation")
        }
    }

    // MARK: - Comprehensive Risk Metrics Test

    func testCalculateComprehensiveRiskMetrics() async throws {
        // Given: Realistic portfolio data
        let portfolioValues = createMockPortfolioValues()

        // When: Calculate all risk metrics
        let metrics = await service.calculateComprehensiveRiskMetrics(
            portfolioValues: portfolioValues,
            marketReturns: nil
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

    private func createMockPortfolioValues() -> [Double] {
        var values: [Double] = []
        var value = 10000.0

        // Create 252 deterministic daily values (1 trading year)
        for i in 0..<252 {
            let randomReturn = sin(Double(i) / 6.0) * 0.01
            value *= (1.0 + randomReturn)
            values.append(value)
        }

        return values
    }

    // MARK: - Missing observations

    func testMaxDrawdown_IgnoresMissingZeroAndNonFiniteValues() async throws {
        let values = [100.0, 110.0, 0.0, .nan, 99.0, 105.0]

        let result = await service.calculateMaxDrawdown(portfolioValues: values)
        let metrics = try XCTUnwrap(result)

        XCTAssertEqual(metrics.maxDrawdown, 0.1, accuracy: 0.0001)
        XCTAssertEqual(metrics.peak, 110, accuracy: 0.0001)
        XCTAssertEqual(metrics.trough, 99, accuracy: 0.0001)
    }

    func testDrawdownPeriods_ReportDeepestTroughNotLastPointBeforeRecovery() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let dates = (0..<6).map { start.addingTimeInterval(Double($0) * 86_400) }
        let values = [100.0, 80.0, 70.0, 95.0, 101.0, 0.0]

        let periods = await service.findDrawdownPeriods(portfolioValues: values, dates: dates, threshold: 0.05)

        let period = try XCTUnwrap(periods.first)
        XCTAssertEqual(periods.count, 1)
        XCTAssertEqual(period.troughValue, 70, accuracy: 0.0001)
        XCTAssertEqual(period.drawdownPercent, 0.3, accuracy: 0.0001)
        XCTAssertEqual(period.endDate, dates[2])
        XCTAssertEqual(period.durationDays, 2)
    }

    func testComprehensiveMetrics_MissingValueDoesNotCreateFullLoss() async throws {
        let values = [100.0, 101.0, 0.0, 102.0, 103.0]

        let result = await service.calculateComprehensiveRiskMetrics(portfolioValues: values)
        let metrics = try XCTUnwrap(result)

        XCTAssertEqual(metrics.maxDrawdown, 0, accuracy: 0.0001)
    }

    // MARK: - Daily resampling, flows and optional ratios

    private func position(_ symbol: String, units: Double, price: Double, currency: String = "USD") -> PositionSnapshot {
        PositionSnapshot(symbol: symbol, units: units, priceAtDate: price, valueAtDate: units * price, currency: currency)
    }

    private func snapshot(_ date: Date, positions: [PositionSnapshot], convert: (Double, String) -> Double = { amount, _ in amount }) -> HistoricalPortfolioSnapshot {
        let total = positions.reduce(0) { $0 + convert($1.valueAtDate, $1.currency) }
        return HistoricalPortfolioSnapshot(
            date: date, totalValue: total, totalGains: 0, totalCost: total, currency: "USD",
            portfolioComposition: Dictionary(positions.map { ($0.symbol, $0) }, uniquingKeysWith: { first, _ in first })
        )
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testDailyCloses_KeepsLastValueOfEachDay() {
        let day1 = Date(timeIntervalSince1970: 1_699_920_000) // UTC midnight
        let dates = [day1 + 100, day1 + 300, day1 + 600, day1 + 86_400 + 300, day1 + 86_400 + 100]
        let values = [100.0, 101.0, 102.0, 110.0, 105.0]

        let daily = RiskMetricsService.dailyCloses(dates: dates, values: values, calendar: utcCalendar)

        XCTAssertEqual(daily.values, [102.0, 110.0])
        XCTAssertEqual(daily.dates.count, 2)
    }

    func testComprehensiveMetrics_IntradaySnapshotsAreResampledToDaily() async throws {
        // 5-minute data over 3 days: day closes 100, 110, 99 -> only 2 daily returns.
        let midnight = Date(timeIntervalSince1970: 1_699_920_000)
        var dates: [Date] = []
        var values: [Double] = []
        let closes = [100.0, 110.0, 99.0]
        for (dayIndex, close) in closes.enumerated() {
            for step in 0..<50 {
                dates.append(midnight.addingTimeInterval(Double(dayIndex) * 86_400 + Double(step) * 300))
                values.append(step == 49 ? close : close + Double(step % 7))
            }
        }

        let computed = await service.calculateComprehensiveRiskMetrics(portfolioValues: values, dates: dates)
        let metrics = try XCTUnwrap(computed)

        // Daily returns are +10% and -10%; sample stddev = 0.1414 -> annualized ~2.245.
        let stdResult = await service.calculateStandardDeviation([0.1, -0.1])
        let dailyStd = try XCTUnwrap(stdResult)
        let expected = dailyStd * sqrt(252.0)
        XCTAssertEqual(metrics.volatility, expected, accuracy: 0.001)
        // Peak 110 on day 2, trough 99 on day 3: exactly 1 calendar day, 10% drawdown.
        XCTAssertEqual(metrics.maxDrawdown, 0.10, accuracy: 0.0001)
        XCTAssertEqual(metrics.maxDrawdownDuration, 1)
    }

    func testMaxDrawdown_WithDatesReportsCalendarDays() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let dates = [0, 1, 11, 12].map { start.addingTimeInterval(Double($0) * 86_400) }

        let drawdown = await service.calculateMaxDrawdown(portfolioValues: [100, 120, 90, 100], dates: dates)
        let result = try XCTUnwrap(drawdown)

        XCTAssertEqual(result.maxDrawdown, 0.25, accuracy: 0.0001)
        XCTAssertEqual(result.duration, 10)
    }

    func testFlowAdjustedSeries_SellingHalfIsNotADrawdown() throws {
        let day1 = Date(timeIntervalSince1970: 1_699_920_000)
        let snapshots = [
            snapshot(day1, positions: [position("AAPL", units: 10, price: 100)]),
            snapshot(day1 + 86_400, positions: [position("AAPL", units: 5, price: 100)]),   // sold half, flat price
            snapshot(day1 + 2 * 86_400, positions: [position("AAPL", units: 5, price: 110)]) // +10% on remaining units
        ]

        let series = try XCTUnwrap(RiskMetricsService.flowAdjustedDailySeries(
            snapshots: snapshots, convert: { amount, _ in amount }, calendar: utcCalendar))

        XCTAssertEqual(series.returns.count, 2)
        XCTAssertEqual(series.returns[0], 0.0, accuracy: 0.0001)
        XCTAssertEqual(series.returns[1], 0.10, accuracy: 0.0001)
        XCTAssertEqual(series.values.min() ?? 0, 1000, accuracy: 0.001, "index must not fall when units are sold")
        XCTAssertEqual(series.currentValue, 550, accuracy: 0.001)
    }

    func testFlowAdjustedSeries_BuyingMoreIsNotAGain() throws {
        let day1 = Date(timeIntervalSince1970: 1_699_920_000)
        let snapshots = [
            snapshot(day1, positions: [position("AAPL", units: 10, price: 100)]),
            snapshot(day1 + 86_400, positions: [position("AAPL", units: 20, price: 100), position("MSFT", units: 5, price: 200)])
        ]

        let series = try XCTUnwrap(RiskMetricsService.flowAdjustedDailySeries(
            snapshots: snapshots, convert: { amount, _ in amount }, calendar: utcCalendar))

        XCTAssertEqual(series.returns, [0.0])
    }

    func testFlowAdjustedSeries_ConvertsMixedCurrenciesIncludingPence() throws {
        // 1 GBP = 1.25 USD; GBX is pence.
        let convert: (Double, String) -> Double = { amount, currency in
            switch currency {
            case "GBX": return amount / 100 * 1.25
            case "GBP": return amount * 1.25
            default: return amount
            }
        }
        let day1 = Date(timeIntervalSince1970: 1_699_920_000)
        let snapshots = [
            snapshot(day1, positions: [position("AAPL", units: 10, price: 100), position("VOD.L", units: 1000, price: 100, currency: "GBX")], convert: convert),
            snapshot(day1 + 86_400, positions: [position("AAPL", units: 10, price: 100), position("VOD.L", units: 1000, price: 110, currency: "GBX")], convert: convert)
        ]

        let series = try XCTUnwrap(RiskMetricsService.flowAdjustedDailySeries(snapshots: snapshots, convert: convert, calendar: utcCalendar))

        // AAPL = 1000 USD, VOD = 1000 GBX*... 1000 units * 100p = 1000 GBP-pence... = 10 GBP = 12.5 USD? no: 100000p = 1000 GBP = 1250 USD.
        // Gain on VOD = 10% of 1250 = 125 on a 2250 base.
        XCTAssertEqual(series.returns[0], 125.0 / 2250.0, accuracy: 0.0001)
    }

    func testComprehensiveMetrics_UndefinedRatiosAreNilNotZero() async throws {
        // Constant growth: zero variance (no Sharpe) and no negative period (no Sortino).
        var values = [100.0]
        for _ in 0..<10 { values.append(values.last! * 1.01) }

        let computed = await service.calculateComprehensiveRiskMetrics(portfolioValues: values)
        let metrics = try XCTUnwrap(computed)

        XCTAssertNil(metrics.sharpeRatio)
        XCTAssertNil(metrics.sortinoRatio)
        XCTAssertEqual(metrics.downsideDeviation, 0, accuracy: 1e-12)
    }

    func testDownsideDeviation_IsFullSampleAndAnnualized() async throws {
        let returns = [0.02, -0.04, 0.01, -0.02]   // squares of shortfalls: 0.0016 + 0.0004 over 4 periods

        let perPeriodResult = await service.calculateDownsideDeviation(returns)
        let annualResult = await service.calculateDownsideDeviation(returns, periodsPerYear: 252)
        let perPeriod = try XCTUnwrap(perPeriodResult)
        let annual = try XCTUnwrap(annualResult)

        XCTAssertEqual(perPeriod, sqrt(0.0020 / 4), accuracy: 1e-9)
        XCTAssertEqual(annual, perPeriod * sqrt(252.0), accuracy: 1e-9)
    }
}
