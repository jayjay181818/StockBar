import Foundation

/// Struct to represent the fetched stock data in a common format
struct StockFetchResult {
    let currency: String?
    let symbol: String
    let shortName: String?
    let regularMarketTime: Int?
    let exchangeTimezoneName: String?
    let regularMarketPrice: Double
    let regularMarketPreviousClose: Double
}