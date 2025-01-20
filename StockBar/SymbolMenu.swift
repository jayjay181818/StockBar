//
//  SymbolMenu.swift
//  StockBar
//
//  Created by Hongliang Fan on 2020-06-20.

import Cocoa

func dailyPNLNumber(_ tradingInfo: TradingInfo, _ position: Position) -> Double {
    // Calculate the raw PNL amount (difference * units)
    let rawPNL = (tradingInfo.currentPrice - tradingInfo.prevClosePrice) * position.unitSize
    
    // Convert GBX to GBP for display
    if tradingInfo.currency == "GBX" || tradingInfo.currency == "GBp" {
        return rawPNL / 100.0
    }
    
    return rawPNL
}

func dailyPNL(_ tradingInfo: TradingInfo, _ position: Position) -> String {
    let pnl = dailyPNLNumber(tradingInfo, position)
    let pnlString = String(format: "%+.2f", pnl)
    let suffix = (tradingInfo.currency == "GBX" || tradingInfo.currency == "GBp") ? " (GBX→GBP)" : ""
    return "Daily PnL: GBP \(pnlString)\(suffix)"
}

fileprivate func totalPNL(_ tradingInfo: TradingInfo, _ position: Position) -> String {
    // Calculate the total value (current price * units - avg cost * units)
    let rawPNL = (tradingInfo.currentPrice * position.unitSize) - 
                 (Double(position.positionAvgCostString) ?? 0) * position.unitSize
    let pnl = (tradingInfo.currency == "GBX" || tradingInfo.currency == "GBp") ? rawPNL / 100.0 : rawPNL
    let suffix = (tradingInfo.currency == "GBX" || tradingInfo.currency == "GBp") ? " (GBX→GBP)" : ""
    let pnlString = String(format: "%+.2f", pnl)
    return "Total PnL: GBP \(pnlString)\(suffix)"
}

fileprivate func totalPositionCost(_ tradingInfo: TradingInfo, _ position: Position) -> String {
    // Calculate the total position cost (avg cost * units)
    let rawCost = (Double(position.positionAvgCostString) ?? 0) * position.unitSize
    let cost = (tradingInfo.currency == "GBX" || tradingInfo.currency == "GBp") ? rawCost / 100.0 : rawCost
    let suffix = (tradingInfo.currency == "GBX" || tradingInfo.currency == "GBp") ? " (GBX→GBP)" : ""
    return "Position Cost: GBP \(String(format: "%.2f", cost))\(suffix)"
}

fileprivate func currentPositionValue(_ tradingInfo: TradingInfo, _ position: Position) -> String {
    // Calculate the total market value (current price * units)
    let rawValue = tradingInfo.currentPrice * position.unitSize
    let value = (tradingInfo.currency == "GBX" || tradingInfo.currency == "GBp") ? rawValue / 100.0 : rawValue
    let suffix = (tradingInfo.currency == "GBX" || tradingInfo.currency == "GBp") ? " (GBX→GBP)" : ""
    return "Market Value: GBP \(String(format: "%.2f", value))\(suffix)"
}

final class SymbolMenu: NSMenu {
    init(tradingInfo: TradingInfo, position: Position) {
        super.init(title: String())
        self.addItem(withTitle: tradingInfo.shortName, action: nil, keyEquivalent: "")
        self.addItem(NSMenuItem.separator())
        self.addItem(withTitle: tradingInfo.getPrice(), action: nil, keyEquivalent: "")
        self.addItem(withTitle: tradingInfo.getChangePct(), action: nil, keyEquivalent: "")
        self.addItem(withTitle: tradingInfo.getLongChange(), action: nil, keyEquivalent: "")
        self.addItem(withTitle: tradingInfo.getTimeInfo(), action: nil, keyEquivalent: "")
        self.addItem(NSMenuItem.separator())
        self.addItem(withTitle: dailyPNL(tradingInfo, position), action: nil, keyEquivalent: "")
        self.addItem(withTitle: totalPNL(tradingInfo, position), action: nil, keyEquivalent: "")
        self.addItem(withTitle: "Units: \(position.unitSize)", action: nil, keyEquivalent: "")
        
        // Format average position cost with proper currency conversion
        let avgCost = position.positionAvgCost
        let displayCost = (tradingInfo.currency == "GBX" || tradingInfo.currency == "GBp") ? avgCost / 100.0 : avgCost
        let suffix = (tradingInfo.currency == "GBX" || tradingInfo.currency == "GBp") ? " (GBX→GBP)" : ""
        self.addItem(withTitle: "Avg Position Cost: GBP \(String(format: "%.2f", displayCost))\(suffix)", 
                    action: nil, keyEquivalent: "")
        
        self.addItem(withTitle: totalPositionCost(tradingInfo, position), action: nil, keyEquivalent: "")
        self.addItem(withTitle: currentPositionValue(tradingInfo, position), action: nil, keyEquivalent: "")
    }
    
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
