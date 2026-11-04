import Foundation

/// Service for calculating portfolio risk metrics and analytics
/// Provides VaR, Sharpe ratio, beta, maximum drawdown, and other risk measures
actor RiskMetricsService {
    static let shared = RiskMetricsService()

    private let logger = Logger.shared

    private init() {}

    // MARK: - Data Models

    struct RiskMetrics {
        let valueAtRisk95: Double      // 95% VaR (5% worst case)
        let valueAtRisk99: Double      // 99% VaR (1% worst case)
        let sharpeRatio: Double?       // Risk-adjusted return (nil when undefined)
        let beta: Double?              // Market correlation (requires benchmark)
        let maxDrawdown: Double        // Maximum peak-to-trough decline
        let maxDrawdownDuration: Int   // Observations from peak to trough
        let volatility: Double         // Annualized standard deviation
        let downsideDeviation: Double  // Annualized downside deviation (full-sample divisor)
        let sortinoRatio: Double?      // Downside risk-adjusted return (nil when no downside)
        let calculationDate: Date
    }

    struct DrawdownPeriod {
        let startDate: Date
        let endDate: Date
        let peakValue: Double
        let troughValue: Double
        let drawdownPercent: Double
        let durationDays: Int
    }

    struct MaxDrawdownMetrics {
        let maxDrawdown: Double
        let duration: Int
        let peak: Double
        let trough: Double
    }

    /// One close per calendar day with flow-adjusted returns between consecutive closes.
    struct DailyRiskSeries {
        let dates: [Date]
        /// Chain-linked index (starts at the first daily close) used for drawdowns.
        let values: [Double]
        /// Flow-adjusted daily returns (decimals). May be shorter than `values.count - 1`
        /// when an interval could not be measured.
        let returns: [Double]
        /// Latest actual portfolio value, used for absolute VaR.
        let currentValue: Double
    }

    // MARK: - Daily resampling and flow adjustment

    /// Keeps the last valid observation of each calendar day, in chronological order.
    nonisolated static func dailyCloses(
        dates: [Date],
        values: [Double],
        calendar: Calendar = .current
    ) -> (dates: [Date], values: [Double]) {
        var lastByDay: [Date: (date: Date, value: Double)] = [:]
        for (date, value) in zip(dates, values) where value.isFinite && value > 0 {
            let day = calendar.startOfDay(for: date)
            if let existing = lastByDay[day], existing.date > date { continue }
            lastByDay[day] = (date, value)
        }
        let sorted = lastByDay.values.sorted { $0.date < $1.date }
        return (sorted.map(\.date), sorted.map(\.value))
    }

    /// Brings every snapshot's portfolio-level amounts into `targetCurrency`. A snapshot recorded
    /// in another currency has `totalValue`, `totalGains` and `totalCost` converted with `convert`
    /// (which also handles pence); one that cannot be converted (no rate) is dropped and counted,
    /// so a USD total is never read as GBP. Position currencies are converted separately by the
    /// caller's per-position converter.
    nonisolated static func normalizingSnapshotCurrencies(
        _ snapshots: [HistoricalPortfolioSnapshot],
        to targetCurrency: String,
        convert: (_ amount: Double, _ from: String, _ to: String) -> Double
    ) -> (snapshots: [HistoricalPortfolioSnapshot], convertedCount: Int, droppedCount: Int) {
        let target = targetCurrency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        var result: [HistoricalPortfolioSnapshot] = []
        var converted = 0
        var dropped = 0
        for snapshot in snapshots {
            let source = snapshot.currency.trimmingCharacters(in: .whitespacesAndNewlines)
            if source.uppercased() == target {
                result.append(snapshot)
                continue
            }
            let value = convert(snapshot.totalValue, source, target)
            let gains = convert(snapshot.totalGains, source, target)
            let cost = convert(snapshot.totalCost, source, target)
            guard !source.isEmpty, value.isFinite, gains.isFinite, cost.isFinite else {
                dropped += 1
                continue
            }
            converted += 1
            result.append(HistoricalPortfolioSnapshot(
                date: snapshot.date, totalValue: value, totalGains: gains, totalCost: cost,
                currency: targetCurrency, portfolioComposition: snapshot.portfolioComposition
            ))
        }
        return (result, converted, dropped)
    }

    /// Builds a daily, trade-flow-adjusted series. Each day's return revalues the
    /// previous day's holdings at the new prices (`prevValue * priceNow / pricePrev`),
    /// so buying or selling units never registers as performance.
    /// - Parameter convert: converts an amount in a position currency into the
    ///   portfolio currency (handles GBX/GBp pence).
    /// Intervals where only one side has composition data cannot be separated from
    /// flows and are skipped (index held flat). If neither side has composition data
    /// the raw total-value change is used, which cannot exclude flows.
    nonisolated static func flowAdjustedDailySeries(
        snapshots: [HistoricalPortfolioSnapshot],
        convert: (Double, String) -> Double,
        calendar: Calendar = .current
    ) -> DailyRiskSeries? {
        var lastByDay: [Date: HistoricalPortfolioSnapshot] = [:]
        for snapshot in snapshots where snapshot.totalValue.isFinite && snapshot.totalValue > 0 {
            let day = calendar.startOfDay(for: snapshot.date)
            if let existing = lastByDay[day], existing.date > snapshot.date { continue }
            lastByDay[day] = snapshot
        }
        let days = lastByDay.values.sorted { $0.date < $1.date }
        guard days.count > 1, let first = days.first, let last = days.last else { return nil }

        func holdings(_ snapshot: HistoricalPortfolioSnapshot) -> [String: PositionSnapshot] {
            snapshot.portfolioComposition.filter { !SymbolMetadata.isBenchmarkSymbol($0.key) }
        }

        var indexValues = [first.totalValue]
        var returns: [Double] = []
        for i in 1..<days.count {
            let prev = days[i - 1]
            let now = days[i]
            let prevHoldings = holdings(prev)
            let nowHoldings = holdings(now)
            var periodReturn: Double?
            if prevHoldings.isEmpty && nowHoldings.isEmpty {
                periodReturn = (now.totalValue - prev.totalValue) / prev.totalValue
            } else if !prevHoldings.isEmpty && !nowHoldings.isEmpty {
                var before = 0.0
                var after = 0.0
                for (symbol, position) in prevHoldings {
                    let value = convert(position.valueAtDate, position.currency)
                    guard value.isFinite, value > 0 else { continue }
                    var ratio = 1.0
                    if let current = nowHoldings[symbol],
                       position.priceAtDate.isFinite, position.priceAtDate > 0,
                       current.priceAtDate.isFinite, current.priceAtDate > 0 {
                        ratio = current.priceAtDate / position.priceAtDate
                    }
                    before += value
                    after += value * ratio
                }
                if before > 0 { periodReturn = after / before - 1 }
            }
            if let periodReturn, periodReturn.isFinite {
                returns.append(periodReturn)
                indexValues.append(indexValues[indexValues.count - 1] * (1 + periodReturn))
            } else {
                indexValues.append(indexValues[indexValues.count - 1])
            }
        }
        return DailyRiskSeries(dates: days.map(\.date), values: indexValues, returns: returns, currentValue: last.totalValue)
    }

    // MARK: - Value at Risk (VaR) Calculation

    /// Calculate Value at Risk using historical method
    /// - Parameters:
    ///   - returns: Array of historical returns (as decimals, e.g., 0.05 for 5%)
    ///   - confidenceLevel: Confidence level (e.g., 0.95 for 95%, 0.99 for 99%)
    ///   - portfolioValue: Current portfolio value for absolute VaR
    /// - Returns: VaR as a positive number (potential loss)
    func calculateVaR(returns: [Double], confidenceLevel: Double, portfolioValue: Double) async -> Double? {
        let finiteReturns = returns.filter { $0.isFinite }
        guard !finiteReturns.isEmpty, confidenceLevel > 0, confidenceLevel < 1,
              portfolioValue.isFinite else {
            return nil
        }

        // Sort returns from worst to best
        let sortedReturns = finiteReturns.sorted()

        // Find the percentile index
        let index = Int(Double(sortedReturns.count) * (1.0 - confidenceLevel))
        let clampedIndex = min(max(index, 0), sortedReturns.count - 1)

        // VaR is a loss: a percentile return at or above zero means no loss at that
        // confidence level, not a loss of the same magnitude.
        let varReturn = sortedReturns[clampedIndex]

        // Convert to absolute value loss
        let varAbsolute = max(0, -varReturn) * portfolioValue

        await logger.debug("📊 VaR(\(Int(confidenceLevel * 100))%): \(String(format: "%.2f%%", varReturn * 100)) or $\(String(format: "%.2f", varAbsolute))")

        return varAbsolute
    }

    // MARK: - Sharpe Ratio Calculation

    /// Calculate Sharpe Ratio (risk-adjusted return)
    /// - Parameters:
    ///   - returns: Array of periodic returns (daily, weekly, etc.)
    ///   - riskFreeRate: Annual risk-free rate (e.g., 0.04 for 4%)
    ///   - periodsPerYear: Number of periods per year (252 for daily, 52 for weekly, 12 for monthly)
    /// - Returns: Annualized Sharpe Ratio
    func calculateSharpeRatio(returns: [Double], riskFreeRate: Double = 0.04, periodsPerYear: Int = 252) async -> Double? {
        guard returns.count > 1 else { return nil }

        // Calculate mean return
        let meanReturn = returns.reduce(0, +) / Double(returns.count)

        // Calculate standard deviation
        guard let stdDev = calculateStandardDeviation(returns) else { return nil }

        // Avoid division by zero
        // Floating-point noise on a constant series must not produce an astronomical ratio.
        guard stdDev > 1e-12 else { return nil }

        // Convert risk-free rate to periodic rate
        let periodicRiskFreeRate = riskFreeRate / Double(periodsPerYear)

        // Calculate Sharpe Ratio: (mean return - risk-free rate) / standard deviation
        let excessReturn = meanReturn - periodicRiskFreeRate
        let sharpeRatio = (excessReturn / stdDev) * sqrt(Double(periodsPerYear))

        await logger.debug("📊 Sharpe Ratio: \(String(format: "%.3f", sharpeRatio)) (mean: \(String(format: "%.4f%%", meanReturn * 100)), std: \(String(format: "%.4f%%", stdDev * 100)))")

        return sharpeRatio
    }

    // MARK: - Sortino Ratio Calculation

    /// Calculate Sortino Ratio (downside risk-adjusted return)
    /// Similar to Sharpe but only considers downside volatility
    /// - Parameters:
    ///   - returns: Array of periodic returns
    ///   - targetReturn: Minimum acceptable return (default 0)
    ///   - periodsPerYear: Number of periods per year
    /// - Returns: Annualized Sortino Ratio
    func calculateSortinoRatio(returns: [Double], targetReturn: Double = 0.0, periodsPerYear: Int = 252) async -> Double? {
        guard returns.count > 1 else { return nil }

        // Calculate mean return
        let meanReturn = returns.reduce(0, +) / Double(returns.count)

        // Calculate downside deviation (only negative returns)
        guard returns.contains(where: { $0 < targetReturn }),
              let downsideDeviation = calculateDownsideDeviation(returns, targetReturn: targetReturn),
              downsideDeviation > 0 else { return nil }

        // Calculate Sortino Ratio
        let excessReturn = meanReturn - targetReturn
        let sortinoRatio = (excessReturn / downsideDeviation) * sqrt(Double(periodsPerYear))

        await logger.debug("📊 Sortino Ratio: \(String(format: "%.3f", sortinoRatio)) (downside dev: \(String(format: "%.4f%%", downsideDeviation * 100)))")

        return sortinoRatio
    }

    // MARK: - Beta Calculation

    /// Calculate portfolio beta (market correlation)
    /// Beta = Covariance(portfolio returns, market returns) / Variance(market returns)
    /// - Parameters:
    ///   - portfolioReturns: Array of portfolio returns
    ///   - marketReturns: Array of benchmark market returns (e.g., S&P 500)
    /// - Returns: Portfolio beta (1.0 = market risk, <1.0 = less volatile, >1.0 = more volatile)
    func calculateBeta(portfolioReturns: [Double], marketReturns: [Double]) async -> Double? {
        guard portfolioReturns.count == marketReturns.count, portfolioReturns.count > 1 else {
            return nil
        }

        // Calculate means
        let portfolioMean = portfolioReturns.reduce(0, +) / Double(portfolioReturns.count)
        let marketMean = marketReturns.reduce(0, +) / Double(marketReturns.count)

        // Calculate covariance
        var covariance = 0.0
        for i in 0..<portfolioReturns.count {
            covariance += (portfolioReturns[i] - portfolioMean) * (marketReturns[i] - marketMean)
        }
        covariance /= Double(portfolioReturns.count - 1)

        // Calculate market variance
        var marketVariance = 0.0
        for returnValue in marketReturns {
            marketVariance += pow(returnValue - marketMean, 2)
        }
        marketVariance /= Double(marketReturns.count - 1)

        guard marketVariance > 0 else { return nil }

        let beta = covariance / marketVariance

        await logger.debug("📊 Beta: \(String(format: "%.3f", beta)) (covariance: \(String(format: "%.6f", covariance)), market var: \(String(format: "%.6f", marketVariance)))")

        return beta
    }

    // MARK: - Maximum Drawdown Analysis

    /// Calculate maximum drawdown and related metrics
    /// - Parameter portfolioValues: Array of portfolio values over time (chronological order)
    func calculateMaxDrawdown(portfolioValues rawValues: [Double]) async -> MaxDrawdownMetrics? {
        await calculateMaxDrawdown(portfolioValues: rawValues, dates: nil)
    }

    /// Calculate maximum drawdown; when `dates` is supplied, `duration` is the number of
    /// calendar days from the peak to the trough instead of the observation count.
    func calculateMaxDrawdown(portfolioValues rawValues: [Double], dates rawDates: [Date]?) async -> MaxDrawdownMetrics? {
        // Missing observations are stored as 0 or NaN. Treating them as real
        // values reports a spurious 100% one-period drawdown.
        var portfolioValues: [Double] = []
        var dates: [Date] = []
        for (index, value) in rawValues.enumerated() where value.isFinite && value > 0 {
            if let rawDates {
                guard index < rawDates.count else { continue }
                dates.append(rawDates[index])
            }
            portfolioValues.append(value)
        }
        guard portfolioValues.count > 1 else { return nil }

        var maxDrawdown = 0.0
        var maxDuration = 0
        var currentPeak = portfolioValues[0]
        var currentPeakIndex = 0
        var maxDrawdownPeak = portfolioValues[0]
        var maxDrawdownTrough = portfolioValues[0]

        for i in 1..<portfolioValues.count {
            let value = portfolioValues[i]

            if value > currentPeak {
                currentPeak = value
                currentPeakIndex = i
            }

            let drawdown = (currentPeak - value) / currentPeak
            if drawdown > maxDrawdown {
                maxDrawdown = drawdown
                if rawDates != nil {
                    maxDuration = Calendar.current.dateComponents(
                        [.day],
                        from: Calendar.current.startOfDay(for: dates[currentPeakIndex]),
                        to: Calendar.current.startOfDay(for: dates[i])
                    ).day ?? 0
                } else {
                    maxDuration = i - currentPeakIndex
                }
                maxDrawdownPeak = currentPeak
                maxDrawdownTrough = value
            }
        }

        await logger.debug("📊 Max Drawdown: \(String(format: "%.2f%%", maxDrawdown * 100)) over \(maxDuration) periods (peak: \(String(format: "%.2f", maxDrawdownPeak)), trough: \(String(format: "%.2f", maxDrawdownTrough)))")

        return MaxDrawdownMetrics(
            maxDrawdown: maxDrawdown,
            duration: maxDuration,
            peak: maxDrawdownPeak,
            trough: maxDrawdownTrough
        )
    }

    /// Find all drawdown periods exceeding a threshold
    /// - Parameters:
    ///   - portfolioValues: Array of portfolio values with corresponding dates
    ///   - dates: Array of dates corresponding to portfolio values
    ///   - threshold: Minimum drawdown percentage to report (e.g., 0.05 for 5%)
    /// - Returns: Array of DrawdownPeriod objects
    func findDrawdownPeriods(portfolioValues rawValues: [Double], dates rawDates: [Date], threshold: Double = 0.05) -> [DrawdownPeriod] {
        guard rawValues.count == rawDates.count else { return [] }
        let observations = zip(rawValues, rawDates).filter { $0.0.isFinite && $0.0 > 0 }
        guard observations.count > 1 else { return [] }

        var drawdownPeriods: [DrawdownPeriod] = []
        var currentPeak = observations[0].0
        var currentPeakDate = observations[0].1
        var trough = currentPeak
        var troughDate = currentPeakDate

        func recordIfSignificant() {
            let drawdown = (currentPeak - trough) / currentPeak
            guard drawdown >= threshold else { return }
            let durationDays = Calendar.current.dateComponents([.day], from: currentPeakDate, to: troughDate).day ?? 0
            drawdownPeriods.append(DrawdownPeriod(
                startDate: currentPeakDate,
                endDate: troughDate,
                peakValue: currentPeak,
                troughValue: trough,
                drawdownPercent: drawdown,
                durationDays: durationDays
            ))
        }

        for (value, date) in observations.dropFirst() {
            if value >= currentPeak {
                // Recovery: record the episode using its deepest point.
                recordIfSignificant()
                currentPeak = value
                currentPeakDate = date
                trough = value
                troughDate = date
            } else if value < trough {
                trough = value
                troughDate = date
            }
        }
        // Ongoing drawdown at the end of the data.
        recordIfSignificant()

        return drawdownPeriods.sorted { $0.drawdownPercent > $1.drawdownPercent }
    }

    // MARK: - Statistical Helper Functions

    /// Calculate standard deviation of a dataset
    func calculateStandardDeviation(_ values: [Double]) -> Double? {
        guard values.count > 1 else { return nil }

        let mean = values.reduce(0, +) / Double(values.count)
        let squaredDiffs = values.map { pow($0 - mean, 2) }
        let variance = squaredDiffs.reduce(0, +) / Double(values.count - 1)

        return sqrt(variance)
    }

    /// Calculate mean (average) of a dataset
    func calculateMean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Calculate downside deviation with the standard full-sample divisor
    /// (every period is in the denominator; non-negative periods contribute zero).
    /// - Parameter periodsPerYear: when given, the result is annualized by sqrt(periodsPerYear);
    ///   otherwise it is per period.
    func calculateDownsideDeviation(_ returns: [Double], targetReturn: Double = 0.0, periodsPerYear: Int? = nil) -> Double? {
        guard !returns.isEmpty else { return nil }

        let squaredShortfalls = returns.map { pow(min($0 - targetReturn, 0), 2) }
        let deviation = sqrt(squaredShortfalls.reduce(0, +) / Double(returns.count))

        return periodsPerYear.map { deviation * sqrt(Double($0)) } ?? deviation
    }

    /// Convert portfolio values to returns
    /// - Parameter values: Array of portfolio values
    /// - Returns: Array of returns (as decimals)
    func calculateReturns(from values: [Double]) -> [Double] {
        guard values.count > 1 else { return [] }

        var returns: [Double] = []
        for i in 1..<values.count {
            let previousValue = values[i - 1]
            let currentValue = values[i]
            guard previousValue.isFinite, previousValue > 0, currentValue.isFinite else { continue }

            let returnValue = (currentValue - previousValue) / previousValue
            returns.append(returnValue)
        }

        return returns
    }

    // MARK: - Comprehensive Risk Analysis

    /// Calculate comprehensive risk metrics from raw portfolio values.
    /// Values are treated as one observation per period (daily by default); when `dates`
    /// is supplied they are first resampled to one close per calendar day. Raw values
    /// cannot separate trades from performance - prefer `flowAdjustedDailySeries`.
    func calculateComprehensiveRiskMetrics(
        portfolioValues rawValues: [Double],
        dates: [Date]? = nil,
        riskFreeRate: Double = 0.04,
        marketReturns: [Double]? = nil
    ) async -> RiskMetrics? {
        // Drop missing observations (0/NaN) so they cannot create spurious
        // -100% returns and 100% drawdowns.
        var values: [Double]
        var seriesDates: [Date]?
        if let dates {
            let daily = Self.dailyCloses(dates: dates, values: rawValues)
            values = daily.values
            seriesDates = daily.dates
        } else {
            values = rawValues.filter { $0.isFinite && $0 > 0 }
            seriesDates = nil
        }
        guard values.count > 1 else {
            await logger.warning("⚠️ Insufficient portfolio data for risk metrics calculation")
            return nil
        }
        let returns = calculateReturns(from: values)
        return await computeMetrics(
            values: values, dates: seriesDates, returns: returns,
            currentValue: values.last ?? 0, riskFreeRate: riskFreeRate, marketReturns: marketReturns
        )
    }

    /// Calculate comprehensive risk metrics from a daily flow-adjusted series.
    func calculateComprehensiveRiskMetrics(
        series: DailyRiskSeries,
        riskFreeRate: Double = 0.04,
        marketReturns: [Double]? = nil
    ) async -> RiskMetrics? {
        guard series.values.count > 1 else {
            await logger.warning("⚠️ Insufficient portfolio data for risk metrics calculation")
            return nil
        }
        return await computeMetrics(
            values: series.values, dates: series.dates, returns: series.returns,
            currentValue: series.currentValue, riskFreeRate: riskFreeRate, marketReturns: marketReturns
        )
    }

    private func computeMetrics(
        values portfolioValues: [Double],
        dates: [Date]?,
        returns: [Double],
        currentValue: Double,
        riskFreeRate: Double,
        marketReturns: [Double]?
    ) async -> RiskMetrics? {
        guard !returns.isEmpty else {
            await logger.warning("⚠️ No valid returns calculated")
            return nil
        }

        let var95 = await calculateVaR(returns: returns, confidenceLevel: 0.95, portfolioValue: currentValue) ?? 0
        let var99 = await calculateVaR(returns: returns, confidenceLevel: 0.99, portfolioValue: currentValue) ?? 0

        // Ratios stay nil when undefined (zero variance, no downside); callers show "—".
        let sharpe = await calculateSharpeRatio(returns: returns, riskFreeRate: riskFreeRate)
        let sortino = await calculateSortinoRatio(returns: returns)

        var beta: Double?
        if let marketReturns = marketReturns, marketReturns.count == returns.count {
            beta = await calculateBeta(portfolioReturns: returns, marketReturns: marketReturns)
        }

        let drawdownResult = await calculateMaxDrawdown(portfolioValues: portfolioValues, dates: dates)
        let maxDrawdown = drawdownResult?.maxDrawdown ?? 0
        let maxDrawdownDuration = drawdownResult?.duration ?? 0

        // Annualized with the same factor as the downside deviation (daily periods).
        let stdDev = calculateStandardDeviation(returns) ?? 0
        let volatility = stdDev * sqrt(252.0)
        let downsideDeviation = calculateDownsideDeviation(returns, periodsPerYear: 252) ?? 0

        let metrics = RiskMetrics(
            valueAtRisk95: var95,
            valueAtRisk99: var99,
            sharpeRatio: sharpe,
            beta: beta,
            maxDrawdown: maxDrawdown,
            maxDrawdownDuration: maxDrawdownDuration,
            volatility: volatility,
            downsideDeviation: downsideDeviation,
            sortinoRatio: sortino,
            calculationDate: Date()
        )

        let sharpeText = sharpe.map { String(format: "%.3f", $0) } ?? "n/a"
        await logger.info("✅ Calculated comprehensive risk metrics: Sharpe=\(sharpeText), MaxDD=\(String(format: "%.2f%%", maxDrawdown * 100)), Vol=\(String(format: "%.2f%%", volatility * 100))")

        return metrics
    }
}
