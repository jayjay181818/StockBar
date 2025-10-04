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
        let sharpeRatio: Double        // Risk-adjusted return
        let beta: Double?              // Market correlation (requires benchmark)
        let maxDrawdown: Double        // Maximum peak-to-trough decline
        let maxDrawdownDuration: Int   // Days in drawdown
        let volatility: Double         // Annualized standard deviation
        let downsideDeviation: Double  // Volatility of negative returns only
        let sortinoRatio: Double       // Downside risk-adjusted return
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

    // MARK: - Value at Risk (VaR) Calculation

    /// Calculate Value at Risk using historical method
    /// - Parameters:
    ///   - returns: Array of historical returns (as decimals, e.g., 0.05 for 5%)
    ///   - confidenceLevel: Confidence level (e.g., 0.95 for 95%, 0.99 for 99%)
    ///   - portfolioValue: Current portfolio value for absolute VaR
    /// - Returns: VaR as a positive number (potential loss)
    func calculateVaR(returns: [Double], confidenceLevel: Double, portfolioValue: Double) async -> Double? {
        guard !returns.isEmpty, confidenceLevel > 0, confidenceLevel < 1 else {
            return nil
        }

        // Sort returns from worst to best
        let sortedReturns = returns.sorted()

        // Find the percentile index
        let index = Int(Double(sortedReturns.count) * (1.0 - confidenceLevel))
        let clampedIndex = min(max(index, 0), sortedReturns.count - 1)

        // VaR is the return at the percentile (as a positive loss value)
        let varReturn = sortedReturns[clampedIndex]

        // Convert to absolute value loss
        let varAbsolute = abs(varReturn * portfolioValue)

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
        guard stdDev > 0 else { return nil }

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
        let downsideReturns = returns.filter { $0 < targetReturn }
        guard !downsideReturns.isEmpty else { return nil }

        let downsideSquaredDiffs = downsideReturns.map { pow($0 - targetReturn, 2) }
        let downsideVariance = downsideSquaredDiffs.reduce(0, +) / Double(downsideReturns.count)
        let downsideDeviation = sqrt(downsideVariance)

        guard downsideDeviation > 0 else { return nil }

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
    /// - Returns: Tuple of (max drawdown %, max drawdown duration in periods, peak value, trough value)
    func calculateMaxDrawdown(portfolioValues: [Double]) async -> (maxDrawdown: Double, duration: Int, peak: Double, trough: Double)? {
        guard portfolioValues.count > 1 else { return nil }

        var maxDrawdown = 0.0
        var maxDuration = 0
        var currentPeak = portfolioValues[0]
        var currentPeakIndex = 0
        var maxDrawdownPeak = portfolioValues[0]
        var maxDrawdownTrough = portfolioValues[0]

        for i in 1..<portfolioValues.count {
            let value = portfolioValues[i]

            // Update peak if we've reached a new high
            if value > currentPeak {
                currentPeak = value
                currentPeakIndex = i
            }

            // Calculate current drawdown from peak
            let drawdown = (currentPeak - value) / currentPeak

            // Update max drawdown if current is worse
            if drawdown > maxDrawdown {
                maxDrawdown = drawdown
                maxDuration = i - currentPeakIndex
                maxDrawdownPeak = currentPeak
                maxDrawdownTrough = value
            }
        }

        await logger.debug("📊 Max Drawdown: \(String(format: "%.2f%%", maxDrawdown * 100)) over \(maxDuration) periods (peak: \(String(format: "%.2f", maxDrawdownPeak)), trough: \(String(format: "%.2f", maxDrawdownTrough)))")

        return (maxDrawdown, maxDuration, maxDrawdownPeak, maxDrawdownTrough)
    }

    /// Find all drawdown periods exceeding a threshold
    /// - Parameters:
    ///   - portfolioValues: Array of portfolio values with corresponding dates
    ///   - dates: Array of dates corresponding to portfolio values
    ///   - threshold: Minimum drawdown percentage to report (e.g., 0.05 for 5%)
    /// - Returns: Array of DrawdownPeriod objects
    func findDrawdownPeriods(portfolioValues: [Double], dates: [Date], threshold: Double = 0.05) -> [DrawdownPeriod] {
        guard portfolioValues.count == dates.count, portfolioValues.count > 1 else {
            return []
        }

        var drawdownPeriods: [DrawdownPeriod] = []
        var currentPeak = portfolioValues[0]
        var currentPeakDate = dates[0]
        var inDrawdown = false

        for i in 1..<portfolioValues.count {
            let value = portfolioValues[i]

            // Check if we've reached a new high
            if value >= currentPeak {
                // If we were in a drawdown, record it
                if inDrawdown {
                    let drawdown = (currentPeak - portfolioValues[i - 1]) / currentPeak
                    if drawdown >= threshold {
                        let durationDays = Calendar.current.dateComponents([.day], from: currentPeakDate, to: dates[i - 1]).day ?? 0
                        let period = DrawdownPeriod(
                            startDate: currentPeakDate,
                            endDate: dates[i - 1],
                            peakValue: currentPeak,
                            troughValue: portfolioValues[i - 1],
                            drawdownPercent: drawdown,
                            durationDays: durationDays
                        )
                        drawdownPeriods.append(period)
                    }
                    inDrawdown = false
                }

                currentPeak = value
                currentPeakDate = dates[i]
            } else {
                // We're below the peak
                let drawdown = (currentPeak - value) / currentPeak

                if drawdown >= threshold && !inDrawdown {
                    inDrawdown = true
                }
            }
        }

        // Handle ongoing drawdown at end of data
        if inDrawdown {
            let lastIndex = portfolioValues.count - 1
            let drawdown = (currentPeak - portfolioValues[lastIndex]) / currentPeak
            if drawdown >= threshold {
                let durationDays = Calendar.current.dateComponents([.day], from: currentPeakDate, to: dates[lastIndex]).day ?? 0
                let period = DrawdownPeriod(
                    startDate: currentPeakDate,
                    endDate: dates[lastIndex],
                    peakValue: currentPeak,
                    troughValue: portfolioValues[lastIndex],
                    drawdownPercent: drawdown,
                    durationDays: durationDays
                )
                drawdownPeriods.append(period)
            }
        }

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

    /// Calculate downside deviation (volatility of negative returns only)
    func calculateDownsideDeviation(_ returns: [Double], targetReturn: Double = 0.0) -> Double? {
        let downsideReturns = returns.filter { $0 < targetReturn }
        guard !downsideReturns.isEmpty else { return nil }

        let squaredDiffs = downsideReturns.map { pow($0 - targetReturn, 2) }
        let variance = squaredDiffs.reduce(0, +) / Double(downsideReturns.count)

        return sqrt(variance)
    }

    /// Convert portfolio values to returns
    /// - Parameter values: Array of portfolio values
    /// - Returns: Array of returns (as decimals)
    func calculateReturns(from values: [Double]) -> [Double] {
        guard values.count > 1 else { return [] }

        var returns: [Double] = []
        for i in 1..<values.count {
            let previousValue = values[i - 1]
            guard previousValue > 0 else { continue }

            let currentValue = values[i]
            let returnValue = (currentValue - previousValue) / previousValue
            returns.append(returnValue)
        }

        return returns
    }

    // MARK: - Comprehensive Risk Analysis

    /// Calculate comprehensive risk metrics for a portfolio
    /// - Parameters:
    ///   - portfolioValues: Historical portfolio values
    ///   - riskFreeRate: Annual risk-free rate (default 4%)
    ///   - marketReturns: Optional benchmark returns for beta calculation
    /// - Returns: Complete RiskMetrics object
    func calculateComprehensiveRiskMetrics(
        portfolioValues: [Double],
        riskFreeRate: Double = 0.04,
        marketReturns: [Double]? = nil
    ) async -> RiskMetrics? {
        guard portfolioValues.count > 1 else {
            await logger.warning("⚠️ Insufficient portfolio data for risk metrics calculation")
            return nil
        }

        let currentValue = portfolioValues.last ?? 0

        // Calculate returns
        let returns = calculateReturns(from: portfolioValues)
        guard !returns.isEmpty else {
            await logger.warning("⚠️ No valid returns calculated")
            return nil
        }

        // Calculate VaR
        let var95 = await calculateVaR(returns: returns, confidenceLevel: 0.95, portfolioValue: currentValue) ?? 0
        let var99 = await calculateVaR(returns: returns, confidenceLevel: 0.99, portfolioValue: currentValue) ?? 0

        // Calculate Sharpe Ratio
        let sharpe = await calculateSharpeRatio(returns: returns, riskFreeRate: riskFreeRate) ?? 0

        // Calculate Sortino Ratio
        let sortino = await calculateSortinoRatio(returns: returns) ?? 0

        // Calculate Beta if market returns provided
        var beta: Double? = nil
        if let marketReturns = marketReturns, marketReturns.count == returns.count {
            beta = await calculateBeta(portfolioReturns: returns, marketReturns: marketReturns)
        }

        // Calculate Maximum Drawdown
        let drawdownResult = await calculateMaxDrawdown(portfolioValues: portfolioValues)
        let maxDrawdown = drawdownResult?.maxDrawdown ?? 0
        let maxDrawdownDuration = drawdownResult?.duration ?? 0

        // Calculate Volatility (annualized)
        let stdDev = calculateStandardDeviation(returns) ?? 0
        let volatility = stdDev * sqrt(252.0) // Annualized assuming daily data

        // Calculate Downside Deviation
        let downsideDeviation = calculateDownsideDeviation(returns) ?? 0

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

        await logger.info("✅ Calculated comprehensive risk metrics: Sharpe=\(String(format: "%.3f", sharpe)), MaxDD=\(String(format: "%.2f%%", maxDrawdown * 100)), Vol=\(String(format: "%.2f%%", volatility * 100))")

        return metrics
    }
}
