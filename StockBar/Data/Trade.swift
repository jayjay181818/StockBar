//
//  Trade.swift
//  StockBar
//
//  Created by Hongliang Fan on 2020-08-01.

import Foundation

public func convertPrice(price: Double, currency: String?) -> (price: Double, currency: String) {
    // Log initial input
    FileHandle.standardError.write("""
    ===== PRICE CONVERSION START =====
    Input Price: \(price)
    Input Currency: \(currency ?? "nil")
    """.data(using: .utf8)!)
    
    guard let currency = currency else {
        FileHandle.standardError.write("""
        No currency provided, returning original price
        ========================
        
        """.data(using: .utf8)!)
        return (price, "Price")
    }
    
    // Handle both GBX and GBp for London Stock Exchange stocks
    if currency == "GBX" || currency == "GBp" {
        let convertedPrice = price / 100.0
        
        // Log conversion details
        FileHandle.standardError.write("""
        
        Converting pence to pounds:
        Original Currency: \(currency)
        Original Price: \(price)
        Converted Currency: GBP
        Converted Price: \(convertedPrice)
        ========================
        
        """.data(using: .utf8)!)
        
        return (convertedPrice, "GBP")
    }
    
    // Log when no conversion is needed
    FileHandle.standardError.write("""
    
    No conversion needed:
    Currency: \(currency)
    Price: \(price)
    ========================
    
    """.data(using: .utf8)!)
    
    return (price, currency)
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
            let rawCost = Double(positionAvgCostString) ?? .nan
            
            // Log position cost conversion
            FileHandle.standardError.write("""
            ===== POSITION COST CONVERSION =====
            Raw Cost: \(rawCost)
            Currency: \(currency ?? "nil")
            """.data(using: .utf8)!)
            
            let converted = convertPrice(price: rawCost, currency: currency)
            
            FileHandle.standardError.write("""
            Converted Cost: \(converted.price)
            Converted Currency: \(converted.currency)
            ========================
            
            """.data(using: .utf8)!)
            
            return converted.price
        }
    }
    private var _unitSize : String
    var currency: String?
    
    init(unitSize : String, positionAvgCost : String, currency: String? = nil)
    {
        self._unitSize = "1"
        self.positionAvgCostString = positionAvgCost
        self.unitSizeString = unitSize
        
        // Log currency initialization
        FileHandle.standardError.write("""
        ===== POSITION INIT =====
        Input Currency: \(currency ?? "nil")
        Position Cost: \(positionAvgCost)
        ========================
        
        """.data(using: .utf8)!)
        
        // Keep the original currency (GBp or GBX) - conversion will happen in convertPrice
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
    
    func getPrice()->String {
        let converted = convertPrice(price: currentPrice, currency: currency)
        
        // Log the conversion details
        FileHandle.standardError.write("""
        ===== TRADING INFO PRICE =====
        Original Currency: \(currency ?? "nil")
        Original Price: \(currentPrice)
        Converted Currency: \(converted.currency)
        Converted Price: \(converted.price)
        ========================
        
        """.data(using: .utf8)!)
        
        return "\(converted.currency) \(String(format: "%.2f", converted.price))"
    }
    
    func getChange()->String {
        let change = currentPrice - prevClosePrice
        let converted = convertPrice(price: change, currency: currency)
        
        // Log the change calculation
        FileHandle.standardError.write("""
        ===== TRADING INFO CHANGE =====
        Original Currency: \(currency ?? "nil")
        Current Price: \(currentPrice)
        Previous Close: \(prevClosePrice)
        Raw Change: \(change)
        Converted Change: \(converted.price) \(converted.currency)
        ========================
        
        """.data(using: .utf8)!)
        
        return String(format: "%+.2f", converted.price)
    }
    
    func getLongChange()->String {
        let change = currentPrice - prevClosePrice
        let converted = convertPrice(price: change, currency: currency)
        return String(format: "%+.4f", converted.price)
    }
    
    func getChangePct()->String {
        let pctChange = 100 * (currentPrice - prevClosePrice) / prevClosePrice
        
        // Log the percentage calculation
        FileHandle.standardError.write("""
        ===== TRADING INFO PERCENT =====
        Current Price: \(currentPrice)
        Previous Close: \(prevClosePrice)
        Percent Change: \(pctChange)%
        ========================
        
        """.data(using: .utf8)!)
        
        return String(format: "%+.4f", pctChange) + "%"
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
