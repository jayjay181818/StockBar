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

    func testFlowAdjustedSeries_AHundredfoldPriceJumpIsNotAReturn() throws {
        let day1 = Date(timeIntervalSince1970: 1_699_920_000)
        let snapshots = [
            snapshot(day1, positions: [position("VOD.L", units: 10, price: 1), position("AAPL", units: 10, price: 100)]),
            // VOD.L stored in pence on day two (a data slip); AAPL really rose 10%.
            snapshot(day1 + 86_400, positions: [position("VOD.L", units: 10, price: 100), position("AAPL", units: 10, price: 110)])
        ]

        let series = try XCTUnwrap(RiskMetricsService.flowAdjustedDailySeries(
            snapshots: snapshots, convert: { amount, _ in amount }, calendar: utcCalendar))

        // Base 10 + 1000; only AAPL's +100 counts.
        XCTAssertEqual(series.returns[0], 100.0 / 1010.0, accuracy: 0.0001)
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

    func testReturnStatistics_HandWorkedValues() {
        // Mean 1%; squared deviations 1, 4, 4, 1 (x 1e-4), so variance 2.5e-4.
        let statistics = ReturnStatistics(dailyReturns: [0.02, -0.01, 0.03, 0.00], annualRiskFreeRate: 0)
        let deviation = sqrt(2.5e-4)

        XCTAssertEqual(statistics.volatility, deviation * 100, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(statistics.sharpeRatio), 0.01 / deviation * sqrt(252), accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(statistics.annualizedVolatility), deviation * 100 * sqrt(252), accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(statistics.valueAtRisk), 1.0, accuracy: 1e-9, "the worst of four days")
        XCTAssertEqual(try XCTUnwrap(statistics.winRate), 50, accuracy: 1e-9)
    }

    func testReturnStatistics_UndefinedFiguresAreNil() {
        let none = ReturnStatistics(dailyReturns: [])
        XCTAssertEqual(none.volatility, 0)
        XCTAssertNil(none.sharpeRatio)
        XCTAssertNil(none.annualizedVolatility)
        XCTAssertNil(none.valueAtRisk)
        XCTAssertNil(none.winRate)

        // Returns that never vary have no Sharpe ratio.
        XCTAssertNil(ReturnStatistics(dailyReturns: [0.01, 0.01, 0.01]).sharpeRatio)
    }
}

// MARK: - Risk page

/// The Risk page's drawdown series and everything it writes. The figure literals
/// in `testFiguresMatchThePageBeforeTheRedesign` were printed by the page's own
/// formatting before the redesign, from the same invented series.
@MainActor
final class RiskPageTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let britishEnglish = Locale(identifier: "en_GB")
    private let start = Date(timeIntervalSince1970: 1_767_571_200) // Monday 5 January 2026, UTC

    private func days(_ count: Int) -> [Date] {
        (0..<count).map { start.addingTimeInterval(Double($0) * 86_400) }
    }

    private func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    /// A made-up daily series: weekdays from 5 January 2026, a slow rise with a
    /// slide between the first third and the half, and noise from a fixed seed.
    private static func invented(_ count: Int, seed: UInt64) -> RiskMetricsService.DailyRiskSeries {
        var state = seed
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var dates: [Date] = []
        var values = [50_000.0]
        var returns: [Double] = []
        var day = Date(timeIntervalSince1970: 1_767_571_200)
        while dates.count < count {
            if !calendar.isDateInWeekend(day) {
                dates.append(day)
                if dates.count > 1 {
                    let slide = dates.count > count / 3 && dates.count < count / 2
                    let dailyReturn = (next() - 0.5) * 0.03 + (slide ? -0.006 : 0.0008)
                    returns.append(dailyReturn)
                    values.append(values[values.count - 1] * (1 + dailyReturn))
                }
            }
            day += 86_400
        }
        return .init(dates: dates, values: values, returns: returns, currentValue: values[values.count - 1] * 1.13)
    }

    private static func lastPart(_ series: RiskMetricsService.DailyRiskSeries, days: Int) -> RiskMetricsService.DailyRiskSeries {
        .init(dates: Array(series.dates.suffix(days)), values: Array(series.values.suffix(days)),
              returns: Array(series.returns.suffix(days - 1)), currentValue: series.currentValue)
    }

    private static var rising: RiskMetricsService.DailyRiskSeries {
        let dates = (0..<25).map { Date(timeIntervalSince1970: 1_767_571_200 + Double($0) * 86_400) }
        return .init(dates: dates, values: (0..<25).map { 100 * pow(1.01, Double($0)) },
                     returns: Array(repeating: 0.01, count: 24), currentValue: 2500)
    }

    // MARK: Drawdown series

    func testDrawdownSeries_RisingOnlyStaysAtZero() async throws {
        let values = [100.0, 101, 103, 103, 110]
        let series = RiskMetricsService.drawdownSeries(values: values, dates: days(5))

        XCTAssertEqual(series.map(\.drawdown), [0, 0, 0, 0, 0])
        XCTAssertEqual(series.map(\.date), days(5))
        let maximum = await RiskMetricsService.shared.calculateMaxDrawdown(portfolioValues: values, dates: days(5))
        XCTAssertEqual(RiskMetricsService.lowestPoint(of: series)?.drawdown, -(try XCTUnwrap(maximum).maxDrawdown))
        XCTAssertEqual(RiskMetricsService.lowestPoint(of: series)?.date, days(5)[0], "the first day at the lowest")
    }

    func testDrawdownSeries_FallAndRecovery() async throws {
        let values = [100.0, 120, 90, 100, 130, 117]
        let series = RiskMetricsService.drawdownSeries(values: values, dates: days(6))

        XCTAssertEqual(series.map(\.drawdown)[0...2], [0, 0, -0.25])
        XCTAssertEqual(series[3].drawdown, -20.0 / 120, accuracy: 1e-15)
        XCTAssertEqual(series[4].drawdown, 0)
        XCTAssertEqual(series[5].drawdown, -0.1, accuracy: 1e-15)
        let lowest = try XCTUnwrap(RiskMetricsService.lowestPoint(of: series))
        let maximum = await RiskMetricsService.shared.calculateMaxDrawdown(portfolioValues: values, dates: days(6))
        XCTAssertEqual(lowest.drawdown, -(try XCTUnwrap(maximum).maxDrawdown))
        XCTAssertEqual(lowest.date, days(6)[2])
    }

    func testDrawdownSeries_FallStillUnderWayAtTheEnd() async throws {
        let values = [100.0, 110, 99, 88]
        let series = RiskMetricsService.drawdownSeries(values: values, dates: days(4))

        XCTAssertEqual(series.last?.drawdown ?? 0, -0.2, accuracy: 1e-15)
        let lowest = try XCTUnwrap(RiskMetricsService.lowestPoint(of: series))
        XCTAssertEqual(lowest.date, days(4)[3])
        let maximum = await RiskMetricsService.shared.calculateMaxDrawdown(portfolioValues: values, dates: days(4))
        XCTAssertEqual(lowest.drawdown, -(try XCTUnwrap(maximum).maxDrawdown))
    }

    func testDrawdownSeries_OneDayAndEmpty() async {
        let one = RiskMetricsService.drawdownSeries(values: [100], dates: days(1))
        XCTAssertEqual(one, [RiskMetricsService.DrawdownPoint(date: days(1)[0], drawdown: 0)])
        // The service has no maximum drawdown for one day, so the page shows none.
        let maximum = await RiskMetricsService.shared.calculateMaxDrawdown(portfolioValues: [100], dates: days(1))
        XCTAssertNil(maximum)

        XCTAssertEqual(RiskMetricsService.drawdownSeries(values: [], dates: []), [])
        XCTAssertNil(RiskMetricsService.lowestPoint(of: []))
    }

    func testDrawdownSeries_LeavesOutWhatTheMaximumDrawdownLeavesOut() async throws {
        let values = [100.0, 0, .nan, 80, -5, 90, 70]
        let dates = days(6) // the last value has no date
        let series = RiskMetricsService.drawdownSeries(values: values, dates: dates)

        XCTAssertEqual(series.map(\.date), [dates[0], dates[3], dates[5]])
        let maximum = await RiskMetricsService.shared.calculateMaxDrawdown(portfolioValues: values, dates: dates)
        XCTAssertEqual(RiskMetricsService.lowestPoint(of: series)?.drawdown, -(try XCTUnwrap(maximum).maxDrawdown))
    }

    func testDrawdownSeries_LowestPointIsTheStripsWorstFallOnInventedSeries() async throws {
        let base = Self.invented(60, seed: 7)
        for series in [base, Self.lastPart(base, days: 25), Self.invented(120, seed: 99), Self.invented(250, seed: 3), Self.rising] {
            let computed = await RiskMetricsService.shared.calculateComprehensiveRiskMetrics(series: series)
            let metrics = try XCTUnwrap(computed)
            let points = RiskMetricsService.drawdownSeries(values: series.values, dates: series.dates)
            XCTAssertEqual(points.count, series.values.count)
            XCTAssertEqual(RiskMetricsService.lowestPoint(of: points)?.drawdown, -metrics.maxDrawdown)
            XCTAssertEqual(RiskText.fall(-(RiskMetricsService.lowestPoint(of: points)?.drawdown ?? .nan)),
                           RiskText.fall(metrics.maxDrawdown))
        }
    }

    // MARK: The same figures as before

    private struct Shown: Equatable {
        var var95, var99, sharpe, sortino, worstFall, volatility, downside: String
        var sharpeDetail, volatilityDetail: String?
        var sortinoDetail: String
        var worstFallDetail: String?
        var tradingDays: Int
        var falls: [String]
        var worstFallIsLoss = true
    }

    private func shown(_ series: RiskMetricsService.DailyRiskSeries) async throws -> Shown {
        let computed = await RiskMetricsService.shared.calculateComprehensiveRiskMetrics(
            series: series, riskFreeRate: RiskMetricsService.annualRiskFreeRate)
        let metrics = try XCTUnwrap(computed)
        let periods = await RiskMetricsService.shared.findDrawdownPeriods(
            portfolioValues: series.values, dates: series.dates, threshold: RiskText.fallThreshold)
        // What the page shows: its tiles and bad-day figures, as the view lays them out.
        let tiles = RiskText.tiles(metrics)
        XCTAssertEqual(tiles.map(\.title), ["Volatility", "Sharpe ratio", "Sortino ratio", "Worst fall"])
        let badDay = RiskText.badDayFigures(metrics, currency: "GBP")
        XCTAssertEqual(badDay.map(\.lead), [RiskText.oneDayIn20, RiskText.oneDayIn100])
        XCTAssertEqual(badDay.map(\.caption), [RiskText.valueAtRisk95, RiskText.valueAtRisk99])
        return Shown(
            var95: badDay[0].amount, var99: badDay[1].amount,
            sharpe: tiles[1].value, sortino: tiles[2].value, worstFall: tiles[3].value, volatility: tiles[0].value,
            downside: RiskText.percent(metrics.downsideDeviation),
            sharpeDetail: tiles[1].detail, volatilityDetail: tiles[0].detail,
            sortinoDetail: tiles[2].detail ?? "", worstFallDetail: tiles[3].detail,
            tradingDays: series.returns.count,
            falls: periods.map { "\(RiskText.fall($0.drawdownPercent)) \(RiskText.fallLength($0.durationDays))" },
            worstFallIsLoss: tiles[3].isLoss
        )
    }

    /// Before the redesign the page showed, for these series: A60 £721.47, £990.51,
    /// -2.553 (Poor), -3.247, 11.31% over 55 days, 13.96% (Low), 10.81%, 59 days, one
    /// fall of 11.31% over 55 days. Its last 25 days: £652.94, £721.47, -2.944, -3.699,
    /// 5.09% over 9, 14.04%, 11.01%, 24 days, falls of 5.09% (9 days) and 5.01% (12).
    /// B120: £804.04, £1,058.39, 0.241 (Below average), 0.343, 16.05% over 42, 14.63%,
    /// 10.11%, 119 days, one fall of 16.05% over 42 days. Rising: £0.00, £0.00, "—", "—",
    /// 0.00% over 0, 0.00% (Very low), 0.00%, 24 days, no falls. The redesign writes a
    /// fall with a minus sign and an unknown figure as "–"; every digit is the same.
    func testFiguresMatchThePageBeforeTheRedesign() async throws {
        let base = Self.invented(60, seed: 7)

        let whole = try await shown(base)
        XCTAssertEqual(whole, Shown(
            var95: "£721.47", var99: "£990.51", sharpe: "-2.553", sortino: "-3.247", worstFall: "-11.31%",
            volatility: "13.96%", downside: "10.81%", sharpeDetail: "Poor, return for the risk taken", volatilityDetail: "Low, over a year",
            sortinoDetail: "Counts only the falls", worstFallDetail: "55 days, peak to low",
            tradingDays: 59, falls: ["-11.31% 55 days, peak to low"]))

        let lastPart = try await shown(Self.lastPart(base, days: 25))
        XCTAssertEqual(lastPart, Shown(
            var95: "£652.94", var99: "£721.47", sharpe: "-2.944", sortino: "-3.699", worstFall: "-5.09%",
            volatility: "14.04%", downside: "11.01%", sharpeDetail: "Poor, return for the risk taken", volatilityDetail: "Low, over a year",
            sortinoDetail: "Counts only the falls", worstFallDetail: "9 days, peak to low",
            tradingDays: 24, falls: ["-5.09% 9 days, peak to low", "-5.01% 12 days, peak to low"]))

        let longer = try await shown(Self.invented(120, seed: 99))
        XCTAssertEqual(longer, Shown(
            var95: "£804.04", var99: "£1,058.39", sharpe: "0.241", sortino: "0.343", worstFall: "-16.05%",
            volatility: "14.63%", downside: "10.11%", sharpeDetail: "Below average, return for the risk taken", volatilityDetail: "Low, over a year",
            sortinoDetail: "Counts only the falls", worstFallDetail: "42 days, peak to low",
            tradingDays: 119, falls: ["-16.05% 42 days, peak to low"]))

        let rising = try await shown(Self.rising)
        XCTAssertEqual(rising, Shown(
            var95: "£0.00", var99: "£0.00", sharpe: "–", sortino: "–", worstFall: "0.00%",
            volatility: "0.00%", downside: "0.00%", sharpeDetail: nil, volatilityDetail: "Very low, over a year",
            sortinoDetail: "No falling days", worstFallDetail: "Never below its peak",
            tradingDays: 24, falls: [], worstFallIsLoss: false))
    }

    // MARK: Text

    func testUnknownFiguresAreADash() {
        XCTAssertEqual(RiskText.percent(.nan), "–")
        XCTAssertEqual(RiskText.ratio(nil), "–")
        XCTAssertEqual(RiskText.ratio(.infinity), "–")
        XCTAssertEqual(RiskText.amount(.nan, currency: "GBP"), "–")
        XCTAssertEqual(RiskText.fall(.nan), "–")
        XCTAssertNil(RiskText.volatilityDetail(.nan))
        XCTAssertNil(RiskText.sharpeDetail(nil))
        XCTAssertNil(RiskText.worstFallDetail(fall: .nan, duration: 0))
    }

    func testFallSignAndRounding() {
        XCTAssertEqual(RiskText.fall(0.07), "-7.00%")
        XCTAssertEqual(RiskText.fall(0.000_01), "0.00%", "a fall that rounds to nothing has no sign")
        XCTAssertEqual(RiskText.fall(0), "0.00%")
        XCTAssertEqual(RiskText.worstFallDetail(fall: 0.07, duration: 1), "1 day, peak to low")
        XCTAssertEqual(RiskText.fallLength(1), "1 day, peak to low")
    }

    func testThresholdsAreTheOldOnes() {
        XCTAssertEqual([0.31, 0.30, 0.21, 0.16, 0.11, 0.10].map { RiskText.volatilityReading($0) },
                       ["Very high", "High", "High", "Moderate", "Low", "Very low"])
        XCTAssertEqual([3.01, 3.0, 2.0, 1.0, 0.5, 0.0, -1].map { RiskText.sharpeReading($0) },
                       ["Exceptional", "Very good", "Good", "Adequate", "Below average", "Poor", "Poor"])
        XCTAssertEqual(RiskText.volatilityDetail(0.12), "Low, over a year")
        XCTAssertEqual(RiskText.sharpeDetail(1.08), "Good, return for the risk taken")
    }

    func testBadDaySentences() {
        XCTAssertEqual(RiskText.badDaySentence(lead: RiskText.oneDayIn20, amount: "£719.96", caption: RiskText.valueAtRisk95),
                       "On 1 day in 20, expect to lose more than £719.96. 95% value at risk.")
        XCTAssertEqual(RiskText.badDaySentence(lead: RiskText.oneDayIn100, amount: "£1,028.38", caption: RiskText.valueAtRisk99),
                       "On 1 day in 100, more than £1,028.38. 99% value at risk.")
        XCTAssertEqual(RiskText.BadDayFigure(lead: RiskText.oneDayIn20, amount: "–", caption: RiskText.valueAtRisk95).accessibility,
                       "On 1 day in 20, expect to lose more than –. 95% value at risk.")
    }

    func testFallRowAndEmptyLine() {
        let now = utcDate(2026, 11, 20)
        let period = RiskMetricsService.DrawdownPeriod(
            startDate: utcDate(2026, 1, 26), endDate: utcDate(2026, 5, 15), peakValue: 100, troughValue: 93,
            drawdownPercent: 0.07, durationDays: 109)
        XCTAssertEqual(RiskText.dateRange(period.startDate, period.endDate, now: now, locale: britishEnglish, timeZone: utc),
                       "26 Jan to 15 May")
        XCTAssertEqual(RiskText.dateRange(utcDate(2025, 12, 30), utcDate(2026, 1, 15), now: now, locale: britishEnglish, timeZone: utc),
                       "30 Dec 2025 to 15 Jan 2026")
        XCTAssertEqual(RiskText.dateRange(utcDate(2025, 3, 3), utcDate(2025, 4, 1), now: now, locale: britishEnglish, timeZone: utc),
                       "3 Mar 2025 to 1 Apr 2025")
        XCTAssertEqual(RiskText.fallAccessibility(period, now: now, locale: britishEnglish, timeZone: utc),
                       "Fell 7.00%, 26 Jan to 15 May, 109 days, peak to low")
        XCTAssertEqual(RiskText.noFalls, "No falls of more than 5% in this range.")
        XCTAssertNil(RiskText.fallsShownNote(shown: 5, total: 5))
        XCTAssertEqual(RiskText.fallsShownNote(shown: 5, total: 7), "Showing the 5 largest of 7.")
    }

    func testLowestPointLabelAndChartText() {
        let series = [
            RiskMetricsService.DrawdownPoint(date: utcDate(2026, 5, 14), drawdown: 0),
            RiskMetricsService.DrawdownPoint(date: utcDate(2026, 5, 15), drawdown: -0.07),
            RiskMetricsService.DrawdownPoint(date: utcDate(2026, 5, 18), drawdown: -0.012)
        ]
        XCTAssertEqual(RiskText.lowestPointLabel(series[1], locale: britishEnglish, timeZone: utc), "-7.00%, 15 May")
        XCTAssertEqual(RiskText.chartAccessibility(series, locale: britishEnglish, timeZone: utc),
                       "Lowest point 7.00% below its peak, on 15 May 2026. Now 1.20% below its peak.")

        let recovered = series + [RiskMetricsService.DrawdownPoint(date: utcDate(2026, 5, 19), drawdown: 0)]
        XCTAssertEqual(RiskText.chartAccessibility(recovered, locale: britishEnglish, timeZone: utc),
                       "Lowest point 7.00% below its peak, on 15 May 2026. Now at its peak.")
        XCTAssertEqual(RiskText.chartAccessibility([series[0]], locale: britishEnglish, timeZone: utc),
                       "Never below its peak in this range.")
        XCTAssertEqual(RiskText.chartAccessibility([], locale: britishEnglish, timeZone: utc), "No values in this range.")
    }

    func testFootnoteForFolyncAndLocalPortfolios() {
        let first = utcDate(2026, 1, 2)
        let last = utcDate(2026, 11, 19)
        XCTAssertEqual(
            RiskText.footnote(tradingDays: 229, first: first, last: last, isFolyncPortfolio: true, riskFreeRate: 0.04,
                              locale: britishEnglish, timeZone: utc),
            "Based on 229 trading days, 2 Jan to 19 Nov 2026, from Stockbar's own stored history, not Folync's. "
                + "Historical VaR, annualized from daily returns that leave out buys and sells. "
                + "Risk-free rate 4.0% a year, used by the Sharpe and Sortino ratios.")
        XCTAssertEqual(
            RiskText.footnote(tradingDays: 1, first: utcDate(2025, 12, 31), last: utcDate(2026, 1, 2), isFolyncPortfolio: false,
                              riskFreeRate: 0.04, locale: britishEnglish, timeZone: utc),
            "Based on 1 trading day, 31 Dec 2025 to 2 Jan 2026, from Stockbar's own stored history. "
                + "Historical VaR, annualized from daily returns that leave out buys and sells. "
                + "Risk-free rate 4.0% a year, used by the Sharpe and Sortino ratios.")
    }
}
