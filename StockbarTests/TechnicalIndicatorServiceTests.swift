import XCTest
@testable import Stockbar

@MainActor
final class TechnicalIndicatorServiceTests: XCTestCase {

    var service: TechnicalIndicatorService!

    override func setUp() {
        super.setUp()
        service = TechnicalIndicatorService.shared
    }

    override func tearDown() {
        service = nil
        super.tearDown()
    }

    // MARK: - Simple Moving Average (SMA) Tests

    func testSMA_WithSufficientData() {
        // Given: 10 data points, 5-period SMA
        let data = createMockOHLCData(count: 10, startPrice: 100.0)
        let period = 5

        // When: Calculate SMA
        let sma = service.calculateSMA(data: data, period: period)

        // Then: Should return 6 values (10 - 5 + 1)
        XCTAssertEqual(sma.count, 6, "SMA should return correct number of values")

        // First SMA should be average of first 5 closes
        if !sma.isEmpty {
            let expectedFirstAvg = data[0..<5].map { $0.close }.reduce(0, +) / 5.0
            XCTAssertEqual(sma[0].1, expectedFirstAvg, accuracy: 0.01, "First SMA value should match manual calculation")
        }
    }

    func testSMA_WithInsufficientData() {
        // Given: 3 data points, 5-period SMA
        let data = createMockOHLCData(count: 3, startPrice: 100.0)
        let period = 5

        // When: Calculate SMA
        let sma = service.calculateSMA(data: data, period: period)

        // Then: Should return empty array
        XCTAssertTrue(sma.isEmpty, "SMA should return empty for insufficient data")
    }

    func testSMA_WithConstantPrices() {
        // Given: All prices are the same
        let data = createMockOHLCData(count: 10, startPrice: 100.0, volatility: 0.0)
        let period = 5

        // When: Calculate SMA
        let sma = service.calculateSMA(data: data, period: period)

        // Then: All SMA values should equal the constant price
        for (_, value) in sma {
            XCTAssertEqual(value, 100.0, accuracy: 0.01, "SMA of constant prices should equal the price")
        }
    }

    // MARK: - Exponential Moving Average (EMA) Tests

    func testEMA_WithSufficientData() {
        // Given: 20 data points, 10-period EMA
        let data = createMockOHLCData(count: 20, startPrice: 100.0)
        let period = 10

        // When: Calculate EMA
        let ema = service.calculateEMA(data: data, period: period)

        // Then: Should return 11 values (20 - 10 + 1)
        XCTAssertEqual(ema.count, 11, "EMA should return correct number of values")

        // First EMA should equal SMA
        if !ema.isEmpty {
            let expectedFirstSMA = data[0..<period].map { $0.close }.reduce(0, +) / Double(period)
            XCTAssertEqual(ema[0].1, expectedFirstSMA, accuracy: 0.01, "First EMA should equal SMA")
        }
    }

    func testEMA_ShouldBeMoreResponsiveThanSMA() {
        // Given: Data with sudden price jump
        var data = createMockOHLCData(count: 15, startPrice: 100.0, volatility: 0.01)
        // Add sudden jump
        data.append(OHLCDataPoint(
            timestamp: Date(),
            open: 100.0,
            high: 120.0,
            low: 100.0,
            close: 120.0,
            volume: 1000
        ))
        let period = 10

        // When: Calculate both
        let sma = service.calculateSMA(data: data, period: period)
        let ema = service.calculateEMA(data: data, period: period)

        // Then: EMA should react faster to price change
        // (Last EMA value should be closer to 120 than last SMA value)
        if !sma.isEmpty && !ema.isEmpty {
            let lastSMA = sma.last!.1
            let lastEMA = ema.last!.1
            XCTAssertGreaterThan(lastEMA, lastSMA, "EMA should be more responsive to price changes")
        }
    }

    func testEMA_WithInsufficientData() {
        // Given: Insufficient data
        let data = createMockOHLCData(count: 5, startPrice: 100.0)
        let period = 10

        // When: Calculate EMA
        let ema = service.calculateEMA(data: data, period: period)

        // Then: Should return empty
        XCTAssertTrue(ema.isEmpty, "EMA should return empty for insufficient data")
    }

    // MARK: - RSI (Relative Strength Index) Tests

    func testRSI_WithTrendingUpData() {
        // Given: Strongly uptrending data
        var data: [OHLCDataPoint] = []
        for i in 0..<30 {
            let price = 100.0 + Double(i) * 2.0 // Steadily increasing
            data.append(OHLCDataPoint(
                timestamp: Date().addingTimeInterval(Double(i) * 86400),
                open: price,
                high: price + 1,
                low: price - 0.5,
                close: price + 0.5,
                volume: 1000
            ))
        }

        // When: Calculate RSI
        let rsi = service.calculateRSI(data: data, period: 14)

        // Then: RSI should be high (overbought territory)
        if let lastRSI = rsi.last {
            XCTAssertGreaterThan(lastRSI.1, 60, "RSI should be high for uptrending data")
            XCTAssertLessThanOrEqual(lastRSI.1, 100, "RSI should not exceed 100")
        }
    }

    func testRSI_WithTrendingDownData() {
        // Given: Strongly downtrending data
        var data: [OHLCDataPoint] = []
        for i in 0..<30 {
            let price = 100.0 - Double(i) * 2.0 // Steadily decreasing
            data.append(OHLCDataPoint(
                timestamp: Date().addingTimeInterval(Double(i) * 86400),
                open: price,
                high: price + 0.5,
                low: price - 1,
                close: price - 0.5,
                volume: 1000
            ))
        }

        // When: Calculate RSI
        let rsi = service.calculateRSI(data: data, period: 14)

        // Then: RSI should be low (oversold territory)
        if let lastRSI = rsi.last {
            XCTAssertLessThan(lastRSI.1, 40, "RSI should be low for downtrending data")
            XCTAssertGreaterThanOrEqual(lastRSI.1, 0, "RSI should not be below 0")
        }
    }

    func testRSI_BoundaryConditions() {
        // Given: Any valid data
        let data = createMockOHLCData(count: 30, startPrice: 100.0)

        // When: Calculate RSI
        let rsi = service.calculateRSI(data: data, period: 14)

        // Then: All RSI values should be between 0 and 100
        for (_, value) in rsi {
            XCTAssertGreaterThanOrEqual(value, 0, "RSI should be >= 0")
            XCTAssertLessThanOrEqual(value, 100, "RSI should be <= 100")
        }
    }

    func testRSI_WithInsufficientData() {
        // Given: Insufficient data
        let data = createMockOHLCData(count: 10, startPrice: 100.0)

        // When: Calculate RSI with period 14
        let rsi = service.calculateRSI(data: data, period: 14)

        // Then: Should return empty
        XCTAssertTrue(rsi.isEmpty, "RSI should return empty for insufficient data")
    }

    // MARK: - MACD Tests

    func testMACD_WithSufficientData() {
        // Given: 50 data points
        let data = createMockOHLCData(count: 50, startPrice: 100.0)

        // When: Calculate MACD with default periods (12, 26, 9)
        let macd = service.calculateMACD(data: data)

        // Then: Should return results
        XCTAssertFalse(macd.isEmpty, "MACD should return values with sufficient data")

        // Verify histogram equals MACD - Signal
        for result in macd {
            let expectedHistogram = result.macdLine - result.signalLine
            XCTAssertEqual(result.histogram, expectedHistogram, accuracy: 0.001,
                          "Histogram should equal MACD line - Signal line")
        }
    }

    func testMACD_BullishCrossover() {
        // Given: Data that creates bullish crossover
        var data = createMockOHLCData(count: 40, startPrice: 100.0)
        // Add uptrend
        for i in 0..<15 {
            let price = 100.0 + Double(i) * 3.0
            data.append(OHLCDataPoint(
                timestamp: Date().addingTimeInterval(Double(40 + i) * 86400),
                open: price,
                high: price + 1,
                low: price - 0.5,
                close: price + 0.5,
                volume: 1000
            ))
        }

        // When: Calculate MACD
        let macd = service.calculateMACD(data: data)

        // Then: Later histograms should be positive (bullish)
        if macd.count > 5 {
            let lastFew = Array(macd.suffix(3))
            let positiveCount = lastFew.filter { $0.histogram > 0 }.count
            XCTAssertGreaterThan(positiveCount, 0, "Should have positive histogram values in uptrend")
        }
    }

    func testMACD_WithInsufficientData() {
        // Given: Insufficient data
        let data = createMockOHLCData(count: 20, startPrice: 100.0)

        // When: Calculate MACD (needs 26 + 9 = 35)
        let macd = service.calculateMACD(data: data)

        // Then: Should return empty
        XCTAssertTrue(macd.isEmpty, "MACD should return empty for insufficient data")
    }

    // MARK: - Bollinger Bands Tests

    func testBollingerBands_WithSufficientData() {
        // Given: Sufficient data
        let data = createMockOHLCData(count: 30, startPrice: 100.0)

        // When: Calculate Bollinger Bands
        let bands = service.calculateBollingerBands(data: data, period: 20, standardDeviations: 2)

        // Then: Should return values
        XCTAssertFalse(bands.isEmpty, "Bollinger Bands should return values")

        // Verify relationships: lower < middle < upper
        for band in bands {
            XCTAssertLessThan(band.lowerBand, band.middleBand, "Lower band should be below middle")
            XCTAssertLessThan(band.middleBand, band.upperBand, "Middle band should be below upper")
        }
    }

    func testBollingerBands_WidthIncreasesWithVolatility() {
        // Given: Low volatility data
        let lowVolData = createMockOHLCData(count: 30, startPrice: 100.0, volatility: 0.001)
        let highVolData = createMockOHLCData(count: 30, startPrice: 100.0, volatility: 0.05)

        // When: Calculate bands
        let lowVolBands = service.calculateBollingerBands(data: lowVolData, period: 20, standardDeviations: 2)
        let highVolBands = service.calculateBollingerBands(data: highVolData, period: 20, standardDeviations: 2)

        // Then: High volatility bands should be wider
        if let lowLast = lowVolBands.last, let highLast = highVolBands.last {
            let lowWidth = lowLast.upperBand - lowLast.lowerBand
            let highWidth = highLast.upperBand - highLast.lowerBand
            XCTAssertGreaterThan(highWidth, lowWidth, "High volatility should produce wider bands")
        }
    }

    // MARK: - Integration Tests

    func testMultipleIndicators_OnSameData() {
        // Given: Same dataset
        let data = createMockOHLCData(count: 50, startPrice: 100.0)

        // When: Calculate multiple indicators
        let sma20 = service.calculateSMA(data: data, period: 20)
        let ema20 = service.calculateEMA(data: data, period: 20)
        let rsi = service.calculateRSI(data: data, period: 14)
        let macd = service.calculateMACD(data: data)
        let bb = service.calculateBollingerBands(data: data, period: 20, standardDeviations: 2)

        // Then: All should return results
        XCTAssertFalse(sma20.isEmpty, "SMA should have results")
        XCTAssertFalse(ema20.isEmpty, "EMA should have results")
        XCTAssertFalse(rsi.isEmpty, "RSI should have results")
        XCTAssertFalse(macd.isEmpty, "MACD should have results")
        XCTAssertFalse(bb.isEmpty, "Bollinger Bands should have results")
    }

    // MARK: - Helper Methods

    private func createMockOHLCData(count: Int, startPrice: Double, volatility: Double = 0.02) -> [OHLCDataPoint] {
        var data: [OHLCDataPoint] = []
        var price = startPrice

        for i in 0..<count {
            let change = Double.random(in: -volatility...volatility)
            let open = price
            let close = price * (1 + change)
            let high = max(open, close) * 1.01
            let low = min(open, close) * 0.99

            data.append(OHLCDataPoint(
                timestamp: Date().addingTimeInterval(Double(i) * 86400), // 1 day intervals
                open: open,
                high: high,
                low: low,
                close: close,
                volume: Int64.random(in: 100000...10000000)
            ))

            price = close
        }

        return data
    }
}

// MARK: - OHLCDataPoint Extension for Testing

extension OHLCDataPoint {
    init(timestamp: Date, open: Double, high: Double, low: Double, close: Double, volume: Int64) {
        self.timestamp = timestamp
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
    }
}
