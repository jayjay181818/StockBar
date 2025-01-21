import Foundation

struct YahooFinanceQuote: Codable {
    let quoteResponse: QuoteResponse?
}

struct QuoteResponse: Codable {
    let result: [Result]?
    let error: Error?
}

struct Result: Codable {
    let currency: String?
    let symbol: String
    let shortName: String
    let regularMarketTime: Int
    let exchangeTimezoneName: String
    let regularMarketPrice: Double
    let regularMarketPreviousClose: Double
    
    func getPrice() -> String {
        guard let data = "\(regularMarketPrice)".data(using: .utf8),
              let priceString = String(data: data, encoding: .utf8) else {
            return String(format: "%.2f", regularMarketPrice)
        }
        return formatPrice(price: regularMarketPrice, currency: currency)
    }
    
    func getChange() -> String {
        let change = regularMarketPrice - regularMarketPreviousClose
        return String(format: "%+.2f", change)
    }
    
    func getLongChange() -> String {
        let change = regularMarketPrice - regularMarketPreviousClose
        return String(format: "%+.4f", change)
    }
    
    func getChangePct() -> String {
        let pctChange = 100 * (regularMarketPrice - regularMarketPreviousClose) / regularMarketPreviousClose
        return String(format: "%+.2f%%", pctChange)
    }
    
    func getTimeInfo() -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(regularMarketTime))
        if let tz = TimeZone(identifier: exchangeTimezoneName) {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
            dateFormatter.timeZone = tz
            return dateFormatter.string(from: date)
        } else {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
            return dateFormatter.string(from: date)
        }
    }
}

struct Error: Codable {
    let errorDescription: String
    
    enum CodingKeys: String, CodingKey {
        case errorDescription = "description"
    }
}