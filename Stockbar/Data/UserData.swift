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
    
    init() {}
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

class RealTimeTrade: ObservableObject, Identifiable {
    let id = UUID()
    @Published var trade: Trade
    @Published var realTimeInfo: TradingInfo

    init(trade: Trade, realTimeInfo: TradingInfo) {
        self.trade = trade
        self.realTimeInfo = realTimeInfo
    }
}

func logToFile(_ message: String) {
    Task {
        await Logger.shared.debug(message)
    }
}

func emptyTrades(size: Int) -> [Trade] {
    return [Trade].init(repeating: Trade(name: "", position: Position(unitSize: "1", positionAvgCost: "", currency: nil, costCurrency: nil)), count: size)
}

func emptyRealTimeTrade() -> RealTimeTrade {
    return RealTimeTrade(trade: Trade(name: "",
                                    position: Position(unitSize: "1",
                                                     positionAvgCost: "",
                                                     currency: nil,
                                                     costCurrency: nil)),
                        realTimeInfo: TradingInfo())
}
