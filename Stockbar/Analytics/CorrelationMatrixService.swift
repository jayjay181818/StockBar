//
//  CorrelationMatrixService.swift
//  Stockbar
//
//  Created by Claude Code on 2025-10-03.
//  Portfolio correlation analysis and diversification metrics
//

import Foundation

/// Service for calculating correlation matrices and diversification metrics
actor CorrelationMatrixService {

    // MARK: - Data Models

    /// Correlation matrix with metadata
    struct CorrelationMatrix {
        let symbols: [String]
        /// NxN matrix of correlation coefficients; `nil` where the correlation is undefined
        /// (a zero-variance series, or too little data).
        let matrix: [[Double?]]
        let timestamp: Date

        /// Get correlation between two symbols
        func correlation(between symbol1: String, between symbol2: String) -> Double? {
            guard let index1 = symbols.firstIndex(of: symbol1),
                  let index2 = symbols.firstIndex(of: symbol2),
                  index1 < matrix.count,
                  index2 < matrix[index1].count else {
                return nil
            }
            return matrix[index1][index2]
        }

        /// Defined off-diagonal pairs (upper triangle) in matrix order.
        func definedPairs() -> [(i: Int, j: Int, value: Double)] {
            var pairs: [(i: Int, j: Int, value: Double)] = []
            for i in 0..<symbols.count {
                for j in (i + 1)..<symbols.count where i < matrix.count && j < matrix[i].count {
                    if let value = matrix[i][j] { pairs.append((i, j, value)) }
                }
            }
            return pairs
        }
    }

    /// Correlation pair for top/bottom correlations
    struct CorrelationPair: Identifiable {
        let id = UUID()
        let symbol1: String
        let symbol2: String
        let correlation: Double
    }

    /// Diversification metrics
    struct DiversificationMetrics {
        let averageCorrelation: Double      // Mean of all pairwise correlations
        let maxCorrelation: Double          // Highest pairwise correlation
        let minCorrelation: Double          // Lowest pairwise correlation
        let effectiveN: Double              // Effective number of independent positions
        let diversificationRatio: Double    // Portfolio vol / weighted avg vol
        let concentrationScore: Double      // Herfindahl index (0-1, lower = more diversified)

        /// Overall diversification score (0-100, higher is better)
        var diversificationScore: Double {
            // Combine multiple factors
            // Negative average correlation or a degenerate concentration must not push
            // any factor (or the total) outside its documented range.
            let correlationFactor = max(0, min(1, 1.0 - averageCorrelation)) * 40  // Max 40 points
            let concentrationFactor = max(0, min(1, 1.0 - concentrationScore)) * 30  // Max 30 points
            let effectiveFactor = max(0, min(effectiveN / 10.0, 1.0)) * 30  // Max 30 points

            let total = correlationFactor + concentrationFactor + effectiveFactor
            return total.isFinite ? max(0, min(100, total)) : 0
        }

        /// Risk level based on diversification
        var riskLevel: RiskLevel {
            if diversificationScore >= 70 {
                return .low
            } else if diversificationScore >= 50 {
                return .medium
            } else {
                return .high
            }
        }

        enum RiskLevel: String {
            case low = "Low"
            case medium = "Medium"
            case high = "High"

            var description: String {
                switch self {
                case .low:
                    return "Well diversified portfolio"
                case .medium:
                    return "Moderate diversification"
                case .high:
                    return "Concentrated portfolio - consider diversifying"
                }
            }
        }
    }

    // MARK: - Correlation Calculation

    /// Calculate correlation matrix for multiple symbols
    /// - Parameter returns: Dictionary mapping symbols to their return series
    /// - Returns: Correlation matrix
    func calculateCorrelationMatrix(returns: [String: [Double]]) async -> CorrelationMatrix {
        await Logger.shared.debug("📊 Calculating correlation matrix for \(returns.count) symbols")

        let symbols = Array(returns.keys).sorted()
        let n = symbols.count
        var matrix = Array(repeating: Array<Double?>(repeating: nil, count: n), count: n)

        for i in 0..<n {
            for j in 0..<n {
                if i == j {
                    matrix[i][j] = 1.0  // Perfect correlation with self
                } else if let returns1 = returns[symbols[i]],
                          let returns2 = returns[symbols[j]] {
                    matrix[i][j] = Self.pearsonCorrelation(returns1, returns2)
                }
            }
        }

        await Logger.shared.debug("📊 Correlation matrix calculated: \(n)x\(n)")
        return CorrelationMatrix(symbols: symbols, matrix: matrix, timestamp: Date())
    }

    /// Calculate Pearson correlation coefficient between two return series
    /// - Parameters:
    ///   - x: First return series
    ///   - y: Second return series
    /// - Returns: Correlation coefficient (-1 to +1), or `nil` when it is undefined
    ///   (series of different length, fewer than two points, non-finite values or a
    ///   zero-variance series).
    nonisolated static func pearsonCorrelation(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count > 1,
              x.allSatisfy(\.isFinite), y.allSatisfy(\.isFinite) else {
            return nil
        }

        let n = Double(x.count)
        let meanX = x.reduce(0, +) / n
        let meanY = y.reduce(0, +) / n

        var sumXY = 0.0
        var sumX2 = 0.0
        var sumY2 = 0.0
        for (a, b) in zip(x, y) {
            let dx = a - meanX
            let dy = b - meanY
            sumXY += dx * dy
            sumX2 += dx * dx
            sumY2 += dy * dy
        }

        // A constant series has no variance (allow for rounding in the mean).
        func isConstant(_ sumSquares: Double, mean: Double) -> Bool {
            let scale = max(abs(mean), 1e-12)
            return sumSquares <= n * pow(scale * 1e-9, 2)
        }
        guard !isConstant(sumX2, mean: meanX), !isConstant(sumY2, mean: meanY) else {
            return nil
        }

        let denominator = sqrt(sumX2 * sumY2)
        guard denominator.isFinite, denominator > 0 else { return nil }

        return max(-1, min(1, sumXY / denominator))
    }

    // MARK: - Diversification Metrics

    /// Calculate comprehensive diversification metrics
    /// - Parameters:
    ///   - correlationMatrix: Correlation matrix
    ///   - weights: Position weights (must sum to 1.0)
    ///   - volatilities: Individual asset volatilities
    /// - Returns: Diversification metrics
    func calculateDiversificationMetrics(
        correlationMatrix: CorrelationMatrix,
        weights: [String: Double],
        volatilities: [String: Double]
    ) async -> DiversificationMetrics {
        await Logger.shared.debug("📊 Calculating diversification metrics")

        let symbols = correlationMatrix.symbols
        // Calculate average correlation (excluding diagonal)
        // Undefined (nil) correlations are left out rather than counted as zero.
        let definedValues = correlationMatrix.definedPairs().map(\.value)
        let averageCorrelation = definedValues.isEmpty
            ? 0.0
            : definedValues.reduce(0, +) / Double(definedValues.count)

        // Find max and min correlations
        let maxCorr = definedValues.max() ?? 0.0
        let minCorr = definedValues.min() ?? 0.0

        // Calculate effective number of independent positions
        // effectiveN = 1 / sum(weight_i^2)
        let weightValues = symbols.map { weights[$0] ?? 0.0 }
        let sumWeightSquares = weightValues.map { $0 * $0 }.reduce(0, +)
        let effectiveN = sumWeightSquares > 0 ? 1.0 / sumWeightSquares : 1.0

        // Calculate diversification ratio
        // DR = (weighted avg volatility) / (portfolio volatility)
        let weightedAvgVol = symbols.reduce(0.0) { sum, symbol in
            let weight = weights[symbol] ?? 0.0
            let vol = volatilities[symbol] ?? 0.0
            return sum + weight * vol
        }

        let portfolioVariance = calculatePortfolioVariance(
            correlationMatrix: correlationMatrix,
            weights: weights,
            volatilities: volatilities
        )
        let portfolioVol = sqrt(portfolioVariance)
        let diversificationRatio = portfolioVol > 0 ? weightedAvgVol / portfolioVol : 1.0

        // Calculate concentration score (Herfindahl index)
        let concentrationScore = weightValues.map { $0 * $0 }.reduce(0, +)

        await Logger.shared.debug("📊 Diversification metrics: avgCorr=\(String(format: "%.3f", averageCorrelation)), effectiveN=\(String(format: "%.2f", effectiveN)), DR=\(String(format: "%.2f", diversificationRatio))")

        return DiversificationMetrics(
            averageCorrelation: averageCorrelation,
            maxCorrelation: maxCorr,
            minCorrelation: minCorr,
            effectiveN: effectiveN,
            diversificationRatio: diversificationRatio,
            concentrationScore: concentrationScore
        )
    }

    /// Calculate portfolio variance using correlation matrix
    private func calculatePortfolioVariance(
        correlationMatrix: CorrelationMatrix,
        weights: [String: Double],
        volatilities: [String: Double]
    ) -> Double {
        let symbols = correlationMatrix.symbols
        let matrix = correlationMatrix.matrix
        let n = symbols.count

        var variance = 0.0

        for i in 0..<n {
            let firstSymbol = symbols[i]
            let firstWeight = weights[firstSymbol] ?? 0.0
            let firstVolatility = volatilities[firstSymbol] ?? 0.0

            for j in 0..<n {
                let secondSymbol = symbols[j]
                let secondWeight = weights[secondSymbol] ?? 0.0
                let secondVolatility = volatilities[secondSymbol] ?? 0.0
                let corr = matrix[i][j] ?? 0.0

                variance += firstWeight * secondWeight * firstVolatility * secondVolatility * corr
            }
        }

        return variance
    }

    // MARK: - Top/Bottom Correlations

    /// Find highest correlated pairs
    func findTopCorrelations(
        correlationMatrix: CorrelationMatrix,
        count: Int = 5
    ) async -> [CorrelationPair] {
        let symbols = correlationMatrix.symbols

        // Pairs with an undefined correlation are skipped.
        let pairs = correlationMatrix.definedPairs().map {
            CorrelationPair(symbol1: symbols[$0.i], symbol2: symbols[$0.j], correlation: $0.value)
        }

        return Array(pairs.sorted { $0.correlation > $1.correlation }.prefix(count))
    }

    /// Find lowest correlated pairs (best diversification)
    func findBottomCorrelations(
        correlationMatrix: CorrelationMatrix,
        count: Int = 5
    ) async -> [CorrelationPair] {
        let symbols = correlationMatrix.symbols

        // Pairs with an undefined correlation are skipped.
        let pairs = correlationMatrix.definedPairs().map {
            CorrelationPair(symbol1: symbols[$0.i], symbol2: symbols[$0.j], correlation: $0.value)
        }

        return Array(pairs.sorted { $0.correlation < $1.correlation }.prefix(count))
    }

    // MARK: - Helper Functions

    /// Calculate returns from price series
    func calculateReturns(prices: [Double]) -> [Double] {
        guard prices.count > 1 else { return [] }

        var returns: [Double] = []
        for i in 1..<prices.count {
            let prevPrice = prices[i-1]
            guard prevPrice > 0 else { continue }
            let returnValue = (prices[i] - prevPrice) / prevPrice
            returns.append(returnValue)
        }

        return returns
    }

    /// Builds date-aligned daily return series. Each symbol contributes its
    /// last valid price per calendar day; only days present for every symbol
    /// are used, so return `i` covers the same interval for all series.
    /// Pearson correlation is meaningless for series paired by index alone.
    ///
    /// With `minimumCommonDays`, holdings are left out one at a time (the one
    /// whose absence adds the most shared days first) until the rest share at
    /// least that many days, and are named in `excluded`. One newly added
    /// holding then no longer blanks the correlation for all the others.
    nonisolated static func alignedDailyReturns(
        from snapshots: [String: [PriceSnapshot]],
        calendar: Calendar = .current,
        minimumCommonDays: Int? = nil
    ) -> (returns: [String: [Double]], commonDays: Int, excluded: [String]) {
        var dailyPrices: [String: [Date: Double]] = [:]
        for (symbol, prices) in snapshots {
            var byDay: [Date: (timestamp: Date, price: Double)] = [:]
            for snapshot in prices
            where snapshot.price.isFinite && snapshot.price > 0 && !calendar.isDateInWeekend(snapshot.timestamp) {
                let day = calendar.startOfDay(for: snapshot.timestamp)
                if let existing = byDay[day], existing.timestamp > snapshot.timestamp { continue }
                byDay[day] = (snapshot.timestamp, snapshot.price)
            }
            if !byDay.isEmpty {
                dailyPrices[symbol] = byDay.mapValues(\.price)
            }
        }

        func sharedDays(_ symbols: some Sequence<String>) -> Set<Date> {
            var shared: Set<Date>?
            for symbol in symbols {
                let days = Set(dailyPrices[symbol]?.keys.map { $0 } ?? [])
                shared = shared.map { $0.intersection(days) } ?? days
            }
            return shared ?? []
        }

        var excluded: [String] = []
        if let minimumCommonDays {
            var kept = Set(dailyPrices.keys)
            // A holding with too few days of its own can never qualify.
            for symbol in kept.sorted() where (dailyPrices[symbol]?.count ?? 0) < minimumCommonDays {
                kept.remove(symbol)
                excluded.append(symbol)
            }
            while kept.count > 2, sharedDays(kept).count < minimumCommonDays {
                // Sorted so the same holding is chosen on every run.
                guard let drop = kept.sorted().max(by: {
                    sharedDays(kept.subtracting([$0])).count < sharedDays(kept.subtracting([$1])).count
                }) else { break }
                kept.remove(drop)
                excluded.append(drop)
            }
            dailyPrices = dailyPrices.filter { kept.contains($0.key) }
            excluded.sort()
        }

        guard dailyPrices.count > 1 else { return ([:], 0, excluded) }
        let commonDays = sharedDays(dailyPrices.keys).sorted()
        guard commonDays.count > 2 else { return ([:], commonDays.count, excluded) }

        var returns: [String: [Double]] = [:]
        for (symbol, prices) in dailyPrices {
            let series = commonDays.compactMap { prices[$0] }
            returns[symbol] = zip(series, series.dropFirst()).map { ($1 - $0) / $0 }
        }
        return (returns, commonDays.count, excluded)
    }

    /// Annualised volatility (252 trading days) of a daily return series.
    nonisolated static func annualizedVolatility(of returns: [Double]) -> Double? {
        guard returns.count > 1 else { return nil }
        let mean = returns.reduce(0, +) / Double(returns.count)
        let variance = returns.reduce(0) { $0 + pow($1 - mean, 2) } / Double(returns.count - 1)
        let volatility = sqrt(variance) * sqrt(252)
        return volatility.isFinite ? volatility : nil
    }
}
