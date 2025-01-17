//
//  YahooFinanceDecoder.swift
//  StockBar
//
//  Created by Hongliang Fan on 2020-06-20.

import Foundation


struct YahooFinanceQuote: Codable {
    let quoteResponse: QuoteResponse?
}

struct QuoteResponse: Codable {
    let result: [Result]?
    let error: Error?
}

struct Result: Codable {
    let currency : String?
    let symbol: String
    let shortName: String
    let regularMarketTime: Int
    let exchangeTimezoneName: String
    let regularMarketPrice: Double
    let regularMarketPreviousClose: Double
    func getPrice()->String {
        let converted = convertPrice(price: regularMarketPrice, currency: currency)
        return "\(converted.currency) \(String(format: "%.2f", converted.price))"
    }
    func getChange()->String {
        let converted = convertPrice(price: regularMarketPrice - regularMarketPreviousClose, currency: currency)
        return String(format: "%+.2f", converted.price)
    }
    func getLongChange()->String {
        let converted = convertPrice(price: regularMarketPrice - regularMarketPreviousClose, currency: currency)
        return String(format: "%+.4f", converted.price)
    }
    func getChangePct()->String {
        return String(format: "%+.4f", 100*(regularMarketPrice - regularMarketPreviousClose)/regularMarketPreviousClose)+"%"
    }
    func getTimeInfo()->String {
        let date = Date(timeIntervalSince1970: TimeInterval(regularMarketTime))
        let tradeTimeZone = TimeZone(identifier: exchangeTimezoneName)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
        dateFormatter.timeZone = tradeTimeZone
        return dateFormatter.string(from: date)
    }
}

struct Error: Codable {
    let errorDescription: String

    enum CodingKeys: String, CodingKey {
        case errorDescription = "description"
    }
}

