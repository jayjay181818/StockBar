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
        let matrix: [[Double]]  // NxN matrix of correlation coefficients
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
            let correlationFactor = (1.0 - averageCorrelation) * 40  // Max 40 points
            let concentrationFactor = (1.0 - concentrationScore) * 30  // Max 30 points
            let effectiveFactor = min(effectiveN / 10.0, 1.0) * 30  // Max 30 points

            return correlationFactor + concentrationFactor + effectiveFactor
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
        var matrix = Array(repeating: Array(repeating: 0.0, count: n), count: n)

        for i in 0..<n {
            for j in 0..<n {
                if i == j {
                    matrix[i][j] = 1.0  // Perfect correlation with self
                } else if let returns1 = returns[symbols[i]],
                          let returns2 = returns[symbols[j]] {
                    matrix[i][j] = pearsonCorrelation(returns1, returns2)
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
    /// - Returns: Correlation coefficient (-1 to +1)
    private func pearsonCorrelation(_ x: [Double], _ y: [Double]) -> Double {
        guard x.count == y.count, x.count > 1 else {
            return 0.0
        }

        let n = Double(x.count)
        let sumX = x.reduce(0, +)
        let sumY = y.reduce(0, +)
        let sumXY = zip(x, y).map(*).reduce(0, +)
        let sumX2 = x.map { $0 * $0 }.reduce(0, +)
        let sumY2 = y.map { $0 * $0 }.reduce(0, +)

        let numerator = n * sumXY - sumX * sumY
        let denominator = sqrt((n * sumX2 - sumX * sumX) * (n * sumY2 - sumY * sumY))

        guard denominator > 0 else {
            return 0.0
        }

        return numerator / denominator
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
        let matrix = correlationMatrix.matrix
        let n = symbols.count

        // Calculate average correlation (excluding diagonal)
        var sumCorrelations = 0.0
        var pairCount = 0
        for i in 0..<n {
            for j in (i+1)..<n {
                sumCorrelations += matrix[i][j]
                pairCount += 1
            }
        }
        let averageCorrelation = pairCount > 0 ? sumCorrelations / Double(pairCount) : 0.0

        // Find max and min correlations
        var maxCorr = -1.0
        var minCorr = 1.0
        for i in 0..<n {
            for j in (i+1)..<n {
                maxCorr = max(maxCorr, matrix[i][j])
                minCorr = min(minCorr, matrix[i][j])
            }
        }

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
            let symbol_i = symbols[i]
            let w_i = weights[symbol_i] ?? 0.0
            let vol_i = volatilities[symbol_i] ?? 0.0

            for j in 0..<n {
                let symbol_j = symbols[j]
                let w_j = weights[symbol_j] ?? 0.0
                let vol_j = volatilities[symbol_j] ?? 0.0
                let corr = matrix[i][j]

                variance += w_i * w_j * vol_i * vol_j * corr
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
        let matrix = correlationMatrix.matrix
        let n = symbols.count

        var pairs: [CorrelationPair] = []

        for i in 0..<n {
            for j in (i+1)..<n {
                pairs.append(CorrelationPair(
                    symbol1: symbols[i],
                    symbol2: symbols[j],
                    correlation: matrix[i][j]
                ))
            }
        }

        return Array(pairs.sorted { $0.correlation > $1.correlation }.prefix(count))
    }

    /// Find lowest correlated pairs (best diversification)
    func findBottomCorrelations(
        correlationMatrix: CorrelationMatrix,
        count: Int = 5
    ) async -> [CorrelationPair] {
        let symbols = correlationMatrix.symbols
        let matrix = correlationMatrix.matrix
        let n = symbols.count

        var pairs: [CorrelationPair] = []

        for i in 0..<n {
            for j in (i+1)..<n {
                pairs.append(CorrelationPair(
                    symbol1: symbols[i],
                    symbol2: symbols[j],
                    correlation: matrix[i][j]
                ))
            }
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

    /// Extract return series from historical data
    func extractReturnSeries(
        from snapshots: [String: [PriceSnapshot]]
    ) async -> [String: [Double]] {
        var returnSeries: [String: [Double]] = [:]

        for (symbol, prices) in snapshots {
            let priceValues = prices.sorted { $0.timestamp < $1.timestamp }.map { $0.price }
            let returns = calculateReturns(prices: priceValues)

            if !returns.isEmpty {
                returnSeries[symbol] = returns
            }
        }

        return returnSeries
    }
}
