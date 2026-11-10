import Foundation

struct PerformanceMetrics {
    let totalReturn: Double
    let totalReturnPercent: Double
    let volatility: Double
    let maxValue: Double
    let minValue: Double
    let currency: String
    let startDate: Date
    let endDate: Date
    
    // MARK: - Advanced Analytics
    let sharpeRatio: Double?
    let maxDrawdown: Double?
    let maxDrawdownPercent: Double?
    let beta: Double?
    let annualizedReturn: Double?
    let annualizedVolatility: Double?
    let valueAtRisk: Double? // 95% VaR
    let winRate: Double? // Percentage of positive return periods
    
    var formattedTotalReturn: String {
        return String(format: "%+.2f %@", totalReturn, currency)
    }
    
    var formattedTotalReturnPercent: String {
        return String(format: "%+.2f%%", totalReturnPercent)
    }
    
    var formattedVolatility: String {
        return String(format: "%.2f%%", volatility)
    }
    
    var formattedSharpeRatio: String {
        guard let sharpe = sharpeRatio else { return "N/A" }
        return String(format: "%.2f", sharpe)
    }
    
    var formattedMaxDrawdown: String {
        guard let drawdown = maxDrawdownPercent else { return "N/A" }
        return String(format: "%.2f%%", drawdown)
    }
    
    var formattedAnnualizedReturn: String {
        guard let annualized = annualizedReturn else { return "N/A" }
        return String(format: "%.2f%%", annualized)
    }
    
    var formattedBeta: String {
        guard let betaValue = beta else { return "N/A" }
        return String(format: "%.2f", betaValue)
    }
    
    var formattedVaR: String {
        guard let var95 = valueAtRisk else { return "N/A" }
        return String(format: "%.2f%%", var95)
    }
    
    var formattedWinRate: String {
        guard let winRateValue = winRate else { return "N/A" }
        return String(format: "%.1f%%", winRateValue)
    }
}

extension HistoricalDataManager {
    /// Pure metrics over a sorted value series. Per-period statistics use one
    /// close per day, and annualised figures need at least 30 days of data.
    nonisolated static func performanceMetrics(
        points: [ChartDataPoint],
        previousPoint: ChartDataPoint?,
        currency: String,
        calendar: Calendar = .current
    ) -> PerformanceMetrics? {
        guard let firstPoint = points.first, let lastPoint = points.last else { return nil }

        // A single point is compared with the last value before the range.
        let basePoint = points.count == 1 ? previousPoint : firstPoint
        let totalReturn: Double
        let totalReturnPercent: Double
        if let basePoint, basePoint.value > 0 {
            totalReturn = lastPoint.value - basePoint.value
            totalReturnPercent = (totalReturn / basePoint.value) * 100
        } else {
            totalReturn = 0
            totalReturnPercent = 0
        }

        var dailyCloses: [Double] = []
        var lastDay: Date?
        for point in points where !calendar.isDateInWeekend(point.date) {
            let day = calendar.startOfDay(for: point.date)
            if day == lastDay {
                dailyCloses[dailyCloses.count - 1] = point.value
            } else {
                dailyCloses.append(point.value)
                lastDay = day
            }
        }
        let dailyReturns = zip(dailyCloses.dropFirst(), dailyCloses).map { current, previous in
            (current - previous) / previous
        }

        let meanReturn = dailyReturns.isEmpty ? 0 : dailyReturns.reduce(0, +) / Double(dailyReturns.count)
        let variance = dailyReturns.isEmpty ? 0 : dailyReturns.map { pow($0 - meanReturn, 2) }.reduce(0, +) / Double(dailyReturns.count)
        let volatility = sqrt(variance) * 100

        let values = points.map(\.value)
        let maxValue = values.max() ?? lastPoint.value
        let minValue = values.min() ?? lastPoint.value

        // Sharpe ratio, assuming a 2% annual risk-free rate.
        let riskFreeRate = 0.02 / 252
        let meanExcessReturn = meanReturn - riskFreeRate
        // Annualised, as on the Risk page and as the colour thresholds for this figure assume.
        let sharpeRatio = variance > 0 ? meanExcessReturn / sqrt(variance) * sqrt(252) : nil

        let (maxDrawdown, maxDrawdownPercent) = calculateMaxDrawdown(values: values)

        let span = lastPoint.date.timeIntervalSince(basePoint?.date ?? firstPoint.date)
        let periodInYears = span / (365.25 * 24 * 3600)
        let annualizedReturn: Double? = span >= 30 * 86_400 && basePoint != nil
            ? (pow(1 + totalReturnPercent / 100, 1 / periodInYears) - 1) * 100
            : nil
        let annualizedVolatility: Double? = dailyReturns.count >= 2 ? volatility * sqrt(252) : nil

        let sortedReturns = dailyReturns.sorted()
        let var95Index = Int(Double(sortedReturns.count) * 0.05)
        let valueAtRisk = var95Index < sortedReturns.count ? abs(sortedReturns[var95Index] * 100) : nil

        let positiveReturns = dailyReturns.filter { $0 > 0 }.count
        let winRate = dailyReturns.isEmpty ? nil : Double(positiveReturns) / Double(dailyReturns.count) * 100

        return PerformanceMetrics(
            totalReturn: totalReturn,
            totalReturnPercent: totalReturnPercent,
            volatility: volatility,
            maxValue: maxValue,
            minValue: minValue,
            currency: currency,
            startDate: basePoint?.date ?? firstPoint.date,
            endDate: lastPoint.date,
            sharpeRatio: sharpeRatio,
            maxDrawdown: maxDrawdown,
            maxDrawdownPercent: maxDrawdownPercent,
            beta: nil,
            annualizedReturn: annualizedReturn.flatMap { $0.isFinite ? $0 : nil },
            annualizedVolatility: annualizedVolatility,
            valueAtRisk: valueAtRisk,
            winRate: winRate
        )
    }

    /// Calculates maximum drawdown from a series of portfolio values
    private nonisolated static func calculateMaxDrawdown(values: [Double]) -> (maxDrawdown: Double?, maxDrawdownPercent: Double?) {
        guard values.count > 1, var peak = values.first else { return (nil, nil) }

        var maxDrawdown: Double = 0
        var maxDrawdownPercent: Double = 0
        for currentValue in values {
            peak = max(peak, currentValue)
            let drawdown = peak - currentValue
            if drawdown > maxDrawdown {
                maxDrawdown = drawdown
                maxDrawdownPercent = peak > 0 ? (drawdown / peak) * 100 : 0
            }
        }
        return (maxDrawdown, maxDrawdownPercent)
    }
}
