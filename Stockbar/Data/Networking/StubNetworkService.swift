//
//  StubNetworkService.swift
//  Stockbar
//
//  A network service implementation for testing that returns static data
//  avoiding actual network calls or Python dependency.
//

import Foundation

class StubNetworkService: NetworkService {
    
    private let logger = Logger.shared
    
    // Configurable behavior
    var shouldFail = false
    var failureError: NetworkError = .networkError("Stub failure")
    var responseDelay: TimeInterval = 0.0
    
    // Mock data storage
    var mockQuotes: [String: StockFetchResult] = [:]
    var mockHistoricalData: [String: [PriceSnapshot]] = [:]
    var mockOHLCData: [String: [OHLCSnapshot]] = [:]
    
    init() {
        // Populate some default mock data
        let now = Int(Date().timeIntervalSince1970)
        
        // AAPL
        mockQuotes["AAPL"] = StockFetchResult(
            currency: "USD",
            symbol: "AAPL",
            shortName: "Apple Inc.",
            regularMarketTime: now,
            exchangeTimezoneName: "America/New_York",
            regularMarketPrice: 150.0,
            regularMarketPreviousClose: 148.0,
            displayPrice: 150.0
        )
        
        // GOOGL
        mockQuotes["GOOGL"] = StockFetchResult(
            currency: "USD",
            symbol: "GOOGL",
            shortName: "Alphabet Inc.",
            regularMarketTime: now,
            exchangeTimezoneName: "America/New_York",
            regularMarketPrice: 2800.0,
            regularMarketPreviousClose: 2750.0,
            displayPrice: 2800.0
        )
        
        // TSLA
        mockQuotes["TSLA"] = StockFetchResult(
            currency: "USD",
            symbol: "TSLA",
            shortName: "Tesla Inc.",
            regularMarketTime: now,
            exchangeTimezoneName: "America/New_York",
            regularMarketPrice: 900.0,
            regularMarketPreviousClose: 910.0,
            displayPrice: 900.0
        )
        
        // UK Stock
        mockQuotes["LLOY.L"] = StockFetchResult(
            currency: "GBP",
            symbol: "LLOY.L",
            shortName: "Lloyds Banking Group",
            regularMarketTime: now,
            exchangeTimezoneName: "Europe/London",
            regularMarketPrice: 0.45,
            regularMarketPreviousClose: 0.44,
            displayPrice: 0.45
        )
    }
    
    func fetchQuote(for symbol: String) async throws -> StockFetchResult {
        await logger.debug("🧪 STUB: Fetching quote for \(symbol)")
        
        if responseDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(responseDelay * 1_000_000_000))
        }
        
        if shouldFail {
            throw failureError
        }
        
        if let quote = mockQuotes[symbol] ?? mockQuotes[symbol.uppercased()] {
            return quote
        }
        
        // Generate a dynamic mock if not predefined
        await logger.debug("🧪 STUB: Generating dynamic mock for \(symbol)")
        return StockFetchResult(
            currency: "USD",
            symbol: symbol,
            shortName: symbol,
            regularMarketTime: Int(Date().timeIntervalSince1970),
            exchangeTimezoneName: "America/New_York",
            regularMarketPrice: 100.0,
            regularMarketPreviousClose: 99.0,
            displayPrice: 100.0
        )
    }
    
    func fetchBatchQuotes(for symbols: [String]) async throws -> [StockFetchResult] {
        await logger.debug("🧪 STUB: Batch fetching for \(symbols.count) symbols")
        
        if responseDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(responseDelay * 1_000_000_000))
        }
        
        if shouldFail {
            throw failureError
        }
        
        var results: [StockFetchResult] = []
        for symbol in symbols {
            // In batch fetch, we typically just return what we can find/generate
            // without throwing unless the whole batch fails
            if let quote = try? await fetchQuote(for: symbol) {
                results.append(quote)
            }
        }
        
        return results
    }
    
    func fetchHistoricalData(for symbol: String, from startDate: Date, to endDate: Date) async throws -> [PriceSnapshot] {
        await logger.debug("🧪 STUB: Fetching historical data for \(symbol)")
        
        if responseDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(responseDelay * 1_000_000_000))
        }
        
        if shouldFail {
            throw failureError
        }
        
        if let history = mockHistoricalData[symbol] {
            // Filter by date range
            return history.filter { $0.timestamp >= startDate && $0.timestamp <= endDate }
        }
        
        // Generate some dummy history
        var generated: [PriceSnapshot] = []
        let calendar = Calendar.current
        var currentDate = startDate
        
        var price = 100.0
        
        while currentDate <= endDate {
            if !calendar.isDateInWeekend(currentDate) {
                let change = Double.random(in: -2.0...2.0)
                price += change
                
                generated.append(PriceSnapshot(
                    timestamp: currentDate,
                    price: price,
                    previousClose: price - change,
                    volume: Double(Int64.random(in: 100000...1000000)),
                    symbol: symbol
                ))
            }
            
            guard let nextDate = calendar.date(byAdding: .day, value: 1, to: currentDate) else { break }
            currentDate = nextDate
        }
        
        return generated
    }
    
    func fetchOHLCData(for symbol: String, period: String, interval: String) async throws -> [OHLCSnapshot] {
        await logger.debug("🧪 STUB: Fetching OHLC data for \(symbol)")
        
        if responseDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(responseDelay * 1_000_000_000))
        }
        
        if shouldFail {
            throw failureError
        }
        
        if let ohlc = mockOHLCData[symbol] {
            return ohlc
        }
        
        // Generate dummy OHLC
        var generated: [OHLCSnapshot] = []
        let count = 30 // default 30 points
        let now = Date()
        
        var price = 100.0
        
        for i in 0..<count {
            let date = now.addingTimeInterval(Double(-1 * (count - i) * 86400))
            let open = price
            let close = price + Double.random(in: -2...2)
            let high = max(open, close) + Double.random(in: 0...1)
            let low = min(open, close) - Double.random(in: 0...1)
            let volume = Int64.random(in: 50000...200000)
            
            generated.append(OHLCSnapshot(
                symbol: symbol,
                timestamp: date,
                open: open,
                high: high,
                low: low,
                close: close,
                volume: volume
            ))
            
            price = close
        }
        
        return generated
    }
    
    func fetchBatchOHLCData(for symbols: [String], period: String, interval: String) async throws -> [String: [OHLCSnapshot]] {
        await logger.debug("🧪 STUB: Batch fetching OHLC for \(symbols.count) symbols")
        
        if responseDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(responseDelay * 1_000_000_000))
        }
        
        if shouldFail {
            throw failureError
        }
        
        var results: [String: [OHLCSnapshot]] = [:]
        for symbol in symbols {
            if let ohlc = try? await fetchOHLCData(for: symbol, period: period, interval: interval) {
                results[symbol] = ohlc
            }
        }
        
        return results
    }
    
    func verifyAPIKey(service: String) async throws -> Bool {
        await logger.debug("🧪 STUB: Verifying API key for \(service)")
        
        if responseDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(responseDelay * 1_000_000_000))
        }
        
        // In stub mode, we can simulate success unless failure is configured
        if shouldFail {
            return false
        }
        
        return true
    }
    
    // MARK: - Helper methods for tests
    
    func setMockQuote(_ quote: StockFetchResult, for symbol: String) {
        mockQuotes[symbol] = quote
        mockQuotes[symbol.uppercased()] = quote
    }
    
    func clearMocks() {
        mockQuotes.removeAll()
        mockHistoricalData.removeAll()
        mockOHLCData.removeAll()
    }
}

