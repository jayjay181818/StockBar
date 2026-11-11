import Foundation

/// Statistics of a series of daily returns (decimals: 0.01 is 1%).
/// The one place the chart's portfolio and per-holding figures are worked out,
/// so the two cannot drift apart.
struct ReturnStatistics: Equatable, Sendable {
    static let tradingDaysPerYear = 252.0

    /// Standard deviation of the daily returns, in percent (population form).
    let volatility: Double
    /// Annualised, over the same risk-free rate as the Risk page. Nil when the returns do not vary.
    let sharpeRatio: Double?
    /// In percent. Nil with fewer than two returns.
    let annualizedVolatility: Double?
    /// The loss, in percent, that 95% of days stayed within. Nil with no returns.
    let valueAtRisk: Double?
    /// Share of days with a gain, in percent. Nil with no returns.
    let winRate: Double?

    init(dailyReturns: [Double], annualRiskFreeRate: Double = RiskMetricsService.annualRiskFreeRate) {
        let count = Double(dailyReturns.count)
        let mean = dailyReturns.isEmpty ? 0 : dailyReturns.reduce(0, +) / count
        let variance = dailyReturns.isEmpty ? 0 : dailyReturns.map { pow($0 - mean, 2) }.reduce(0, +) / count
        volatility = sqrt(variance) * 100

        let dailyRiskFreeRate = annualRiskFreeRate / Self.tradingDaysPerYear
        sharpeRatio = variance > 0
            ? (mean - dailyRiskFreeRate) / sqrt(variance) * sqrt(Self.tradingDaysPerYear)
            : nil
        annualizedVolatility = dailyReturns.count >= 2 ? volatility * sqrt(Self.tradingDaysPerYear) : nil

        let sorted = dailyReturns.sorted()
        let index = Int(count * 0.05)
        valueAtRisk = index < sorted.count ? abs(sorted[index] * 100) : nil
        winRate = dailyReturns.isEmpty ? nil : Double(dailyReturns.filter { $0 > 0 }.count) / count * 100
    }
}
