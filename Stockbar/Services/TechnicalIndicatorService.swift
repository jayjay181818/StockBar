import Foundation

/// Service for calculating technical indicators from OHLC data
@MainActor
class TechnicalIndicatorService {
    static let shared = TechnicalIndicatorService()

    private init() {}

    // MARK: - Moving Averages

    /// Calculate Simple Moving Average (SMA)
    /// - Parameters:
    ///   - data: OHLC data points
    ///   - period: Number of periods for MA calculation
    /// - Returns: Array of (date, value) tuples for the moving average
    func calculateSMA(data: [OHLCDataPoint], period: Int) -> [(Date, Double)] {
        guard data.count >= period else { return [] }

        var result: [(Date, Double)] = []

        for i in (period - 1)..<data.count {
            let slice = data[(i - period + 1)...i]
            let average = slice.map { $0.close }.reduce(0, +) / Double(period)
            result.append((data[i].timestamp, average))
        }

        return result
    }

    /// Calculate Exponential Moving Average (EMA)
    /// - Parameters:
    ///   - data: OHLC data points
    ///   - period: Number of periods for EMA calculation
    /// - Returns: Array of (date, value) tuples for the exponential moving average
    func calculateEMA(data: [OHLCDataPoint], period: Int) -> [(Date, Double)] {
        guard data.count >= period else { return [] }

        var result: [(Date, Double)] = []
        let multiplier = 2.0 / Double(period + 1)

        // Start with SMA for first value
        let initialSlice = data[0..<period]
        var ema = initialSlice.map { $0.close }.reduce(0, +) / Double(period)
        result.append((data[period - 1].timestamp, ema))

        // Calculate EMA for remaining values
        for i in period..<data.count {
            ema = (data[i].close - ema) * multiplier + ema
            result.append((data[i].timestamp, ema))
        }

        return result
    }

    // MARK: - RSI (Relative Strength Index)

    /// Calculate Relative Strength Index (RSI)
    /// - Parameters:
    ///   - data: OHLC data points
    ///   - period: Number of periods for RSI calculation (default: 14)
    /// - Returns: Array of (date, RSI value) tuples
    func calculateRSI(data: [OHLCDataPoint], period: Int = 14) -> [(Date, Double)] {
        guard data.count > period else { return [] }

        var result: [(Date, Double)] = []
        var gains: [Double] = []
        var losses: [Double] = []

        // Calculate price changes
        for i in 1..<data.count {
            let change = data[i].close - data[i - 1].close
            gains.append(max(change, 0))
            losses.append(max(-change, 0))
        }

        // Calculate initial average gain and loss
        var avgGain = gains[0..<period].reduce(0, +) / Double(period)
        var avgLoss = losses[0..<period].reduce(0, +) / Double(period)

        // Calculate RSI for initial period
        let rs = avgGain / (avgLoss == 0 ? 1 : avgLoss)
        let rsi = 100 - (100 / (1 + rs))
        result.append((data[period].timestamp, rsi))

        // Calculate RSI for remaining periods using smoothed averages
        for i in period..<gains.count {
            avgGain = (avgGain * Double(period - 1) + gains[i]) / Double(period)
            avgLoss = (avgLoss * Double(period - 1) + losses[i]) / Double(period)

            let rs = avgGain / (avgLoss == 0 ? 1 : avgLoss)
            let rsi = 100 - (100 / (1 + rs))
            result.append((data[i + 1].timestamp, rsi))
        }

        return result
    }

    // MARK: - MACD (Moving Average Convergence Divergence)

    struct MACDResult {
        let timestamp: Date
        let macdLine: Double
        let signalLine: Double
        let histogram: Double
    }

    /// Calculate MACD (Moving Average Convergence Divergence)
    /// - Parameters:
    ///   - data: OHLC data points
    ///   - fastPeriod: Fast EMA period (default: 12)
    ///   - slowPeriod: Slow EMA period (default: 26)
    ///   - signalPeriod: Signal line EMA period (default: 9)
    /// - Returns: Array of MACD results (MACD line, signal line, histogram)
    func calculateMACD(data: [OHLCDataPoint], fastPeriod: Int = 12, slowPeriod: Int = 26, signalPeriod: Int = 9) -> [MACDResult] {
        guard data.count >= slowPeriod + signalPeriod else { return [] }

        // Calculate fast and slow EMAs
        let fastEMA = calculateEMA(data: data, period: fastPeriod)
        let slowEMA = calculateEMA(data: data, period: slowPeriod)

        // Calculate MACD line (fast EMA - slow EMA)
        var macdLine: [(Date, Double)] = []
        let _ = slowPeriod - 1 // Fix unused warning

        for i in 0..<slowEMA.count {
            let fastIndex = i + (fastPeriod - 1)
            if fastIndex < fastEMA.count {
                let macd = fastEMA[fastIndex].1 - slowEMA[i].1
                macdLine.append((slowEMA[i].0, macd))
            }
        }

        // Calculate signal line (9-period EMA of MACD line)
        guard macdLine.count >= signalPeriod else { return [] }

        let multiplier = 2.0 / Double(signalPeriod + 1)
        var signalLine: [(Date, Double)] = []

        // Start with SMA for first signal value
        let initialSlice = macdLine[0..<signalPeriod]
        var signal = initialSlice.map { $0.1 }.reduce(0, +) / Double(signalPeriod)
        signalLine.append((macdLine[signalPeriod - 1].0, signal))

        // Calculate EMA for remaining signal values
        for i in signalPeriod..<macdLine.count {
            signal = (macdLine[i].1 - signal) * multiplier + signal
            signalLine.append((macdLine[i].0, signal))
        }

        // Create MACD results with histogram
        var results: [MACDResult] = []
        let _ = signalPeriod - 1  // Signal start index (unused in simplified loop)

        for i in 0..<signalLine.count {
            let macdIndex = i + (signalPeriod - 1)
            if macdIndex < macdLine.count {
                let histogram = macdLine[macdIndex].1 - signalLine[i].1
                results.append(MACDResult(
                    timestamp: signalLine[i].0,
                    macdLine: macdLine[macdIndex].1,
                    signalLine: signalLine[i].1,
                    histogram: histogram
                ))
            }
        }

        return results
    }

    // MARK: - Bollinger Bands

    struct BollingerBandsResult {
        let timestamp: Date
        let upper: Double
        let middle: Double  // SMA
        let lower: Double
    }

    /// Calculate Bollinger Bands
    /// - Parameters:
    ///   - data: OHLC data points
    ///   - period: Number of periods for SMA calculation (default: 20)
    ///   - standardDeviations: Number of standard deviations for bands (default: 2)
    /// - Returns: Array of Bollinger Bands results (upper, middle, lower)
    func calculateBollingerBands(data: [OHLCDataPoint], period: Int = 20, standardDeviations: Double = 2.0) -> [BollingerBandsResult] {
        guard data.count >= period else { return [] }

        var results: [BollingerBandsResult] = []

        for i in (period - 1)..<data.count {
            let slice = data[(i - period + 1)...i]
            let prices = slice.map { $0.close }

            // Calculate middle band (SMA)
            let middle = prices.reduce(0, +) / Double(period)

            // Calculate standard deviation
            let variance = prices.map { pow($0 - middle, 2) }.reduce(0, +) / Double(period)
            let stdDev = sqrt(variance)

            // Calculate upper and lower bands
            let upper = middle + (standardDeviations * stdDev)
            let lower = middle - (standardDeviations * stdDev)

            results.append(BollingerBandsResult(
                timestamp: data[i].timestamp,
                upper: upper,
                middle: middle,
                lower: lower
            ))
        }

        return results
    }

    // MARK: - Volume Indicators

    /// Calculate Volume Moving Average
    /// - Parameters:
    ///   - data: OHLC data points
    ///   - period: Number of periods for volume MA
    /// - Returns: Array of (date, volume MA) tuples
    func calculateVolumeMA(data: [OHLCDataPoint], period: Int) -> [(Date, Double)] {
        guard data.count >= period else { return [] }

        var result: [(Date, Double)] = []

        for i in (period - 1)..<data.count {
            let slice = data[(i - period + 1)...i]
            let average = slice.map { Double($0.volume) }.reduce(0, +) / Double(period)
            result.append((data[i].timestamp, average))
        }

        return result
    }

    /// Calculate On-Balance Volume (OBV)
    /// - Parameter data: OHLC data points
    /// - Returns: Array of (date, OBV) tuples
    func calculateOBV(data: [OHLCDataPoint]) -> [(Date, Int64)] {
        guard !data.isEmpty else { return [] }

        var result: [(Date, Int64)] = []
        var obv: Int64 = 0

        result.append((data[0].timestamp, obv))

        for i in 1..<data.count {
            if data[i].close > data[i - 1].close {
                obv += data[i].volume
            } else if data[i].close < data[i - 1].close {
                obv -= data[i].volume
            }
            // If close == previous close, OBV stays the same

            result.append((data[i].timestamp, obv))
        }

        return result
    }

    // MARK: - Volatility Indicators

    /// Calculate Average True Range (ATR)
    /// - Parameters:
    ///   - data: OHLC data points
    ///   - period: Number of periods for ATR calculation (default: 14)
    /// - Returns: Array of (date, ATR) tuples
    func calculateATR(data: [OHLCDataPoint], period: Int = 14) -> [(Date, Double)] {
        guard data.count > period else { return [] }

        var trueRanges: [Double] = []

        // Calculate true range for each period
        for i in 1..<data.count {
            let high = data[i].high
            let low = data[i].low
            let prevClose = data[i - 1].close

            let tr1 = high - low
            let tr2 = abs(high - prevClose)
            let tr3 = abs(low - prevClose)

            let trueRange = max(tr1, tr2, tr3)
            trueRanges.append(trueRange)
        }

        guard trueRanges.count >= period else { return [] }

        var result: [(Date, Double)] = []

        // Calculate initial ATR (simple average)
        var atr = trueRanges[0..<period].reduce(0, +) / Double(period)
        result.append((data[period].timestamp, atr))

        // Calculate smoothed ATR for remaining periods
        for i in period..<trueRanges.count {
            atr = (atr * Double(period - 1) + trueRanges[i]) / Double(period)
            result.append((data[i + 1].timestamp, atr))
        }

        return result
    }
}
