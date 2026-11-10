//
//  UserData.swift
//  StockBar
//
//  Created by Hongliang Fan on 2020-08-02.

import Combine
import Foundation
import SwiftUI

// MARK: - UserData and UserSettings

struct UserData: Codable {
    var positions: [Position]
    var settings: UserSettings
    var stocks: [StockInfo] = [] // For compatibility with existing code
    
    init(positions: [Position] = [], settings: UserSettings = UserSettings()) {
        self.positions = positions
        self.settings = settings
        self.stocks = []
    }
}

struct UserSettings: Codable {
    var preferredCurrency: String = "USD"
    var showColorCoding: Bool = true
    var refreshInterval: TimeInterval = 300.0
}

struct StockInfo: Codable {
    var symbol: String
    var currency: String?
    
    init(symbol: String, currency: String? = nil) {
        self.symbol = symbol
        self.currency = currency
    }
}

// MARK: - Existing Code

@Observable
class RealTimeTrade: Identifiable {
    let id = UUID()
    let sourceIdentity: String?
    let displayLabel: String?
    var trade: Trade
    var realTimeInfo: TradingInfo

    init(
        trade: Trade,
        realTimeInfo: TradingInfo,
        sourceIdentity: String? = nil,
        displayLabel: String? = nil
    ) {
        self.trade = trade
        self.realTimeInfo = realTimeInfo
        self.sourceIdentity = sourceIdentity
        self.displayLabel = displayLabel
    }
}

func emptyRealTimeTrade() -> RealTimeTrade {
    return RealTimeTrade(trade: Trade(name: "",
                                    position: Position(unitSize: "1",
                                                     positionAvgCost: "",
                                                     currency: nil,
                                                     costCurrency: nil)),
                        realTimeInfo: TradingInfo())
}
