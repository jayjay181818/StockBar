import Foundation

struct Error: Codable {
    let code: String
    let description: String
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
    
    func toStockData(position: Position) -> StockData {
        // Log initial data
        FileHandle.standardError.write("""
        ===== YAHOO FINANCE DECODER START =====
        Symbol: \(symbol)
        Raw Market Price: \(regularMarketPrice)
        Raw Previous Close: \(regularMarketPreviousClose)
        Original Currency: \(currency ?? "nil")
        Is LSE Stock: \(symbol.hasSuffix(".L"))
        ========================
        
        """.data(using: .utf8)!)
        
        // Pass through the original currency without modification
        let effectiveCurrency = currency
        
        // Log currency details
        FileHandle.standardError.write("""
        ===== YAHOO FINANCE CURRENCY =====
        Symbol: \(symbol)
        Original Currency: \(currency ?? "nil")
        Is LSE Stock: \(symbol.hasSuffix(".L"))
        Currency is GBp: \(currency == "GBp")
        Effective Currency: \(effectiveCurrency ?? "nil")
        ========================
        
        """.data(using: .utf8)!)
        
        // Pass the raw prices and original currency to TradingInfo
        var info = TradingInfo()
        info.currentPrice = regularMarketPrice
        info.prevClosePrice = regularMarketPreviousClose
        info.currency = effectiveCurrency
        info.regularMarketTime = regularMarketTime
        info.exchangeTimezoneName = exchangeTimezoneName
        info.shortName = shortName
        
        // Log final values
        FileHandle.standardError.write("""
        ===== YAHOO FINANCE DECODER RESULT =====
        Current Price: \(regularMarketPrice) \(effectiveCurrency ?? "nil")
        Previous Close: \(regularMarketPreviousClose) \(effectiveCurrency ?? "nil")
        ========================
        
        """.data(using: .utf8)!)
        
        return StockData(name: symbol, position: position, info: info)
    }
}

struct YahooFinanceDecoder {
    static func decode(data: Data, position: Position) -> StockData? {
        let decoder = JSONDecoder()
        do {
            let response = try decoder.decode(QuoteResponse.self, from: data)
            if let error = response.error {
                print("Yahoo Finance API error: \(error.code) - \(error.description)")
                return nil
            }
            guard let result = response.result?.first else {
                print("No result found in Yahoo Finance response")
                return nil
            }
            return result.toStockData(position: position)
        } catch {
            print("Failed to decode Yahoo Finance response: \(error)")
            return nil
        }
    }
}