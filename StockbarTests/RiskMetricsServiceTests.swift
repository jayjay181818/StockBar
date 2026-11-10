import XCTest
@testable import Stockbar

@MainActor
final class RiskMetricsServiceTests: XCTestCase {

    // A property, not async setUp and tearDown: on a main-actor test class
    // those two hops cost about 0.2 s for every test.
    private var service: RiskMetricsService { .shared }

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

        // Then: the 5th percentile of 20 returns is the second worst, -3%.
        XCTAssertEqual(try XCTUnwrap(var95), 300, accuracy: 0.0001)
    }

    func testVaR_IsZeroNotALossWhenThePercentileReturnIsAGain() async throws {
        // Every day is a gain: there is no loss at the 95% level.
        let gains = [0.01, 0.02, 0.03, 0.04, 0.05, 0.02, 0.01, 0.03, 0.02, 0.04]
        let var95 = await service.calculateVaR(returns: gains, confidenceLevel: 0.95, portfolioValue: 10_000)
        XCTAssertEqual(try XCTUnwrap(var95), 0, accuracy: 0.0001)
    }

    func testVaR_ReportsTheLossAndIgnoresNonFiniteReturns() async throws {
        var returns = [Double](repeating: 0.01, count: 18) + [-0.10, -0.10]
        returns.append(.nan)
        returns.append(.infinity)
        let var95 = await service.calculateVaR(returns: returns, confidenceLevel: 0.95, portfolioValue: 10_000)
        XCTAssertEqual(try XCTUnwrap(var95), 1_000, accuracy: 0.01)

        let none = await service.calculateVaR(returns: [.nan, .infinity], confidenceLevel: 0.95, portfolioValue: 10_000)
        XCTAssertNil(none)
    }

    func testSnapshotsInAnotherCurrencyAreConvertedOrDropped() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        func snapshot(_ offset: Int, value: Double, currency: String) -> HistoricalPortfolioSnapshot {
            HistoricalPortfolioSnapshot(date: day.addingTimeInterval(Double(offset) * 86_400), totalValue: value,
                                        totalGains: value / 10, totalCost: value * 0.9, currency: currency,
                                        portfolioComposition: [:])
        }
        // 1 GBP = 1.25 USD; CHF has no rate.
        let convert: (Double, String, String) -> Double = { amount, from, to in
            switch (from, to) {
            case ("USD", "GBP"): return amount / 1.25
            case ("CHF", _): return .nan
            default: return amount
            }
        }
        let input = [snapshot(0, value: 1_000, currency: "GBP"),
                     snapshot(1, value: 1_250, currency: "USD"),
                     snapshot(2, value: 900, currency: "CHF"),
                     snapshot(3, value: 1_100, currency: "gbp")]

        let result = RiskMetricsService.normalizingSnapshotCurrencies(input, to: "GBP", convert: convert)

        XCTAssertEqual(result.snapshots.count, 3)
        XCTAssertEqual(result.convertedCount, 1)
        XCTAssertEqual(result.droppedCount, 1)
        let usdSnapshot = result.snapshots[1]
        XCTAssertEqual(usdSnapshot.totalValue, 1_000, accuracy: 0.0001, "1,250 USD is 1,000 GBP, not 1,250 GBP")
        XCTAssertEqual(usdSnapshot.totalGains, 100, accuracy: 0.0001)
        XCTAssertEqual(usdSnapshot.currency, "GBP")
        XCTAssertEqual(result.snapshots[2].totalValue, 1_100, accuracy: 0.0001, "same currency in another case is untouched")
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

        // Then: of 100 returns the 95% level lands on the -10% day and the
        // 99% level on a -20% day.
        XCTAssertEqual(try XCTUnwrap(var95), 1_000, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(var99), 2_000, accuracy: 0.0001)
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

        // Then: mean 1%, sample deviation 0.2% x sqrt(252/251), worked out by hand.
        XCTAssertEqual(try XCTUnwrap(sharpe), 78.586208, accuracy: 0.00001)
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

        // Then: the figure worked out independently of the service.
        XCTAssertEqual(try XCTUnwrap(sharpe), 6.051574, accuracy: 0.00001)
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

        // Then: mean -1% less the daily risk-free rate, over the same deviation.
        XCTAssertEqual(try XCTUnwrap(sharpe), -80.472277, accuracy: 0.00001)
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

        // Then: mean 1.5% over a downside deviation of sqrt(0.0014 / 10),
        // every period in the divisor.
        XCTAssertEqual(try XCTUnwrap(sortino), 20.124612, accuracy: 0.00001)
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

        // Then: identical series give a beta of exactly one.
        XCTAssertEqual(try XCTUnwrap(beta), 1.0, accuracy: 1e-9)
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

        // Then: twice the market's moves is a beta of two.
        XCTAssertEqual(try XCTUnwrap(beta), 2.0, accuracy: 1e-9)
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
        // Daily returns of +10%, -10%, +10%, +10%: mean 5%, sample deviation 10%.
        let portfolioValues = [100.0, 110.0, 99.0, 108.9, 119.79]

        let result = await service.calculateComprehensiveRiskMetrics(
            portfolioValues: portfolioValues,
            riskFreeRate: 0.04,
            marketReturns: nil
        )
        let metrics = try XCTUnwrap(result)
        let annual = sqrt(252.0)

        // With four returns both levels land on the worst day: 10% of 119.79.
        XCTAssertEqual(metrics.valueAtRisk95, 11.979, accuracy: 1e-6)
        XCTAssertEqual(metrics.valueAtRisk99, 11.979, accuracy: 1e-6)
        XCTAssertEqual(metrics.volatility, 0.1 * annual, accuracy: 1e-9)
        XCTAssertEqual(metrics.maxDrawdown, 0.10, accuracy: 1e-9)
        // One 10% fall in four periods: sqrt(0.01 / 4) = 5% a period.
        XCTAssertEqual(metrics.downsideDeviation, 0.05 * annual, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(metrics.sharpeRatio), (0.05 - 0.04 / 252) / 0.1 * annual, accuracy: 1e-9)
        // Sortino clears the same hurdle as Sharpe: the risk-free rate per trading day.
        let hurdle = 0.04 / 252
        let shortfall = ((-0.10 - hurdle) * (-0.10 - hurdle) / 4).squareRoot()
        XCTAssertEqual(try XCTUnwrap(metrics.sortinoRatio), (0.05 - hurdle) / shortfall * annual, accuracy: 1e-9)
        XCTAssertNil(metrics.beta, "no market series was given")
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
