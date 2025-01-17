//
//  SymbolMenu.swift
//  StockBar
//
//  Created by Hongliang Fan on 2020-06-20.

import Cocoa
func dailyPNLNumber(_ tradingInfo: TradingInfo, _ position: Position)->Double {
    // Convert the total PNL amount (difference * units)
    let rawPNL = (tradingInfo.currentPrice - tradingInfo.prevClosePrice) * position.unitSize
    return convertPrice(price: rawPNL, currency: tradingInfo.currency).price
}
func dailyPNL(_ tradingInfo: TradingInfo, _ position: Position)->String {
    let pnlString = String(format: "%+.2f", dailyPNLNumber(tradingInfo, position))
    let suffix = tradingInfo.currency == "GBX" ? " (converted from GBX)" : ""
    return "Daily PnL: GBP " + pnlString + suffix
}
fileprivate func totalPNL(_ tradingInfo: TradingInfo, _ position: Position)->String {
    // Convert the total value (current price * units - avg cost * units)
    let rawPNL = (tradingInfo.currentPrice * position.unitSize) - (Double(position.positionAvgCostString) ?? 0) * position.unitSize
    let converted = convertPrice(price: rawPNL, currency: tradingInfo.currency)
    let suffix = tradingInfo.currency == "GBX" ? " (converted from GBX)" : ""
    let pnlString = String(format: "%+.2f", converted.price)
    return "Total PnL: GBP " + pnlString + suffix
}
fileprivate func totalPositionCost(_ tradingInfo: TradingInfo, _ position: Position)->String {
    // Convert the total position cost (avg cost * units)
    let rawCost = (Double(position.positionAvgCostString) ?? 0) * position.unitSize
    let converted = convertPrice(price: rawCost, currency: tradingInfo.currency)
    let suffix = tradingInfo.currency == "GBX" ? " (converted from GBX)" : ""
    return "Position Cost: GBP " + String(format: "%.2f", converted.price) + suffix
}
fileprivate func currentPositionValue(_ tradingInfo: TradingInfo, _ position: Position)->String {
    // Convert the total market value (current price * units)
    let rawValue = tradingInfo.currentPrice * position.unitSize
    let converted = convertPrice(price: rawValue, currency: tradingInfo.currency)
    let suffix = tradingInfo.currency == "GBX" ? " (converted from GBX)" : ""
    return "Market Value: GBP " + String(format: "%.2f", converted.price) + suffix
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
        let converted = convertPrice(price: 0, currency: tradingInfo.currency) // Just to get currency conversion
        let suffix = tradingInfo.currency == "GBX" ? " (converted from GBX)" : ""
        self.addItem(withTitle: "Avg Position Cost: \(converted.currency) \(position.positionAvgCost)\(suffix)", action: nil, keyEquivalent: "")
        self.addItem(withTitle: totalPositionCost(tradingInfo, position), action: nil, keyEquivalent: "")
        self.addItem(withTitle: currentPositionValue(tradingInfo, position), action: nil, keyEquivalent: "")
    }
    
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
