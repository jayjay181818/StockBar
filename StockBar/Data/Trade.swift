//
//  Trade.swift
//  StockBar
//
//  Created by Hongliang Fan on 2020-08-01.

import Foundation

// Helper function to format price with currency
public func formatPrice(price: Double, currency: String?) -> String {
    guard let currency = currency else { return String(format: "%.2f", price) }
    return "\(currency) \(String(format: "%.2f", price))"
}

struct Trade : Codable, Equatable {
    var name : String
    var position : Position
}

struct Position : Codable, Equatable {
    var unitSizeString : String {
        get {
            return self._unitSize;
        }
        set(newUnitSize) {
            if (Double(newUnitSize) != nil) {
                _unitSize = newUnitSize;
            }
            else {
                _unitSize = "1";
            }
        }
    }
    var unitSize : Double {
        get {
            return Double(unitSizeString) ?? 1
        }
    }
    var positionAvgCostString : String
    var positionAvgCost : Double {
        get {
            return Double(positionAvgCostString) ?? .nan
        }
    }
    private var _unitSize : String
    var currency: String?
    
    init(unitSize : String, positionAvgCost : String, currency: String? = nil) {
        self._unitSize = "1"
        self.positionAvgCostString = positionAvgCost
        self.unitSizeString = unitSize
        self.currency = currency
    }
}

struct TradingInfo {
    var currentPrice : Double = .nan
    var prevClosePrice : Double = .nan
    var currency : String?
    var regularMarketTime: Int = 0
    var exchangeTimezoneName: String = ""
    var shortName: String = ""
    
    func getPrice() -> String {
        return formatPrice(price: currentPrice, currency: currency)
    }
    
    func getChange() -> String {
        let change = currentPrice - prevClosePrice
        return String(format: "%+.2f", change)
    }
    
    func getLongChange() -> String {
        let change = currentPrice - prevClosePrice
        return String(format: "%+.4f", change)
    }
    
    func getChangePct() -> String {
        let pctChange = 100 * (currentPrice - prevClosePrice) / prevClosePrice
        return String(format: "%+.4f", pctChange) + "%"
    }
    
    func getTimeInfo() -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(regularMarketTime))
        let tradeTimeZone = TimeZone(identifier: exchangeTimezoneName)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
        dateFormatter.timeZone = tradeTimeZone
        return dateFormatter.string(from: date)
    }
}
