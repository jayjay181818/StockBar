//
//  CandlestickData.swift
//  Stockbar
//
//  Created for Phase 2: Chart Enhancements
//  Candlestick chart data models and helpers
//

import Foundation
import SwiftUI

// MARK: - OHLC Data Point

/// Represents a single OHLC (Open, High, Low, Close) data point for candlestick charts
struct OHLCDataPoint: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Int64

    /// Creates an OHLC data point
    init(
        id: UUID = UUID(),
        timestamp: Date,
        open: Double,
        high: Double,
        low: Double,
        close: Double,
        volume: Int64
    ) {
        self.id = id
        self.timestamp = timestamp
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
    }

    /// Whether this candle is bullish (close > open)
    var isBullish: Bool {
        close >= open
    }

    /// Body height (absolute difference between open and close)
    var bodyHeight: Double {
        abs(close - open)
    }

    /// Upper wick length (high - max(open, close))
    var upperWickLength: Double {
        high - max(open, close)
    }

    /// Lower wick length (min(open, close) - low)
    var lowerWickLength: Double {
        min(open, close) - low
    }

    /// True range (for ATR calculation)
    var trueRange: Double {
        high - low
    }

    /// Body top (higher of open/close)
    var bodyTop: Double {
        max(open, close)
    }

    /// Body bottom (lower of open/close)
    var bodyBottom: Double {
        min(open, close)
    }
}

// MARK: - Candlestick Style

/// Visual style options for candlestick charts
enum CandlestickStyle: String, CaseIterable, Codable {
    case filled = "Filled"           // Traditional filled/hollow candles
    case ohlcBars = "OHLC Bars"      // OHLC bar chart
    case heikinAshi = "Heikin-Ashi"  // Smoothed candlesticks

    var description: String {
        rawValue
    }
}

// MARK: - Volume Display Style

/// How to display volume bars
enum VolumeDisplayStyle: String, CaseIterable, Codable {
    case none = "None"
    case overlay = "Overlay"         // Volume bars overlaid on price chart
    case separate = "Separate Panel" // Volume in separate panel below

    var description: String {
        rawValue
    }
}

// MARK: - Chart Time Period

/// Time period options for charts
enum ChartTimePeriod: String, CaseIterable, Codable {
    case oneDay = "1D"
    case fiveDay = "5D"
    case oneMonth = "1M"
    case threeMonth = "3M"
    case sixMonth = "6M"
    case oneYear = "1Y"
    case fiveYear = "5Y"
    case max = "Max"

    var description: String {
        rawValue
    }

    /// yfinance period parameter
    var yfinancePeriod: String {
        switch self {
        case .oneDay: return "1d"
        case .fiveDay: return "5d"
        case .oneMonth: return "1mo"
        case .threeMonth: return "3mo"
        case .sixMonth: return "6mo"
        case .oneYear: return "1y"
        case .fiveYear: return "5y"
        case .max: return "max"
        }
    }

    /// Suggested interval for this period
    var suggestedInterval: ChartInterval {
        switch self {
        case .oneDay: return .fiveMin
        case .fiveDay: return .fifteenMin
        case .oneMonth: return .oneHour
        case .threeMonth: return .oneDay
        case .sixMonth: return .oneDay
        case .oneYear: return .oneWeek
        case .fiveYear: return .oneWeek
        case .max: return .oneMonth
        }
    }
}

// MARK: - Chart Interval

/// Data interval options for charts
enum ChartInterval: String, CaseIterable, Codable {
    case oneMin = "1m"
    case fiveMin = "5m"
    case fifteenMin = "15m"
    case thirtyMin = "30m"
    case oneHour = "1h"
    case oneDay = "1d"
    case oneWeek = "1wk"
    case oneMonth = "1mo"

    var description: String {
        switch self {
        case .oneMin: return "1 Minute"
        case .fiveMin: return "5 Minutes"
        case .fifteenMin: return "15 Minutes"
        case .thirtyMin: return "30 Minutes"
        case .oneHour: return "1 Hour"
        case .oneDay: return "1 Day"
        case .oneWeek: return "1 Week"
        case .oneMonth: return "1 Month"
        }
    }

    /// yfinance interval parameter
    var yfinanceInterval: String {
        rawValue
    }
}

// MARK: - Chart Settings

/// User preferences for candlestick charts
struct CandlestickChartSettings: Codable {
    var style: CandlestickStyle = .filled
    var volumeDisplay: VolumeDisplayStyle = .separate
    var showGrid: Bool = true
    var showCrosshair: Bool = true
    var bullishColor: String = "00AA00" // Green
    var bearishColor: String = "CC0000" // Red

    /// Get SwiftUI Color for bullish candles
    var bullishSwiftUIColor: Color {
        Color(hex: bullishColor) ?? .green
    }

    /// Get SwiftUI Color for bearish candles
    var bearishSwiftUIColor: Color {
        Color(hex: bearishColor) ?? .red
    }

    /// Save settings to UserDefaults
    func save() {
        if let encoded = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(encoded, forKey: "candlestickChartSettings")
        }
    }

    /// Load settings from UserDefaults
    static func load() -> CandlestickChartSettings {
        if let data = UserDefaults.standard.data(forKey: "candlestickChartSettings"),
           let decoded = try? JSONDecoder().decode(CandlestickChartSettings.self, from: data) {
            return decoded
        }
        return CandlestickChartSettings()
    }
}

// MARK: - Color Extension
// Moved to ChartAnnotationService.swift or shared utility to avoid redeclaration
// extension Color { ... }
