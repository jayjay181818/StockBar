//
//  SymbolMenu.swift
//  StockBar
//
//  Created by Hongliang Fan on 2020-06-20.

import Cocoa

func dailyPNLNumber(_ tradingInfo: TradingInfo, _ position: Position) -> Double {
    // Calculate the raw PNL amount (difference * units)
    let rawPNL = (tradingInfo.currentPrice - tradingInfo.prevClosePrice) * position.unitSize

    // Assuming currency is already GBP if applicable, as per Python script
    return rawPNL
}

func dailyPNL(_ tradingInfo: TradingInfo, _ position: Position) -> String {
    let pnl = dailyPNLNumber(tradingInfo, position)
    let pnlString = String(format: "%+.2f", pnl)
    // Assuming currency is already GBP if applicable
    return "Daily PnL: \(tradingInfo.currency) \(pnlString)"
}

private func totalPNL(_ tradingInfo: TradingInfo, _ position: Position, _ symbol: String) -> String {
    // Use normalized average cost (handles GBX to GBP conversion automatically)
    let normalizedCost = position.getNormalizedAvgCost(for: symbol)
    let rawPNL = (tradingInfo.currentPrice * position.unitSize) - (normalizedCost * position.unitSize)
    // Assuming currency is already GBP if applicable
    let pnlString = String(format: "%+.2f", rawPNL)
    return "Total PnL: \(tradingInfo.currency) \(pnlString)"
}

private func totalPositionCost(_ tradingInfo: TradingInfo, _ position: Position, _ symbol: String) -> String {
    // Use normalized average cost (handles GBX to GBP conversion automatically)
    let normalizedCost = position.getNormalizedAvgCost(for: symbol)
    let rawCost = normalizedCost * position.unitSize
    // Assuming currency is already GBP if applicable
    return "Position Cost: \(tradingInfo.currency) \(String(format: "%.2f", rawCost))"
}

private func currentPositionValue(_ tradingInfo: TradingInfo, _ position: Position) -> String {
    // Calculate the total market value (current price * units)
    let rawValue = tradingInfo.currentPrice * position.unitSize
    // Assuming currency is already GBP if applicable
    return "Market Value: \(tradingInfo.currency) \(String(format: "%.2f", rawValue))"
}

final class SymbolMenu: NSMenu {
    init(tradingInfo: TradingInfo, position: Position, symbol: String) {
        super.init(title: String())
        self.addItem(withTitle: tradingInfo.shortName, action: nil, keyEquivalent: "")
        self.addItem(NSMenuItem.separator())
        self.addItem(withTitle: tradingInfo.getPrice(), action: nil, keyEquivalent: "")
        self.addItem(withTitle: tradingInfo.getChangePct(), action: nil, keyEquivalent: "")
        self.addItem(withTitle: tradingInfo.getLongChange(), action: nil, keyEquivalent: "")
        self.addItem(withTitle: tradingInfo.getTimeInfo(), action: nil, keyEquivalent: "")
        self.addItem(NSMenuItem.separator())
        self.addItem(withTitle: dailyPNL(tradingInfo, position), action: nil, keyEquivalent: "")
        self.addItem(withTitle: totalPNL(tradingInfo, position, symbol), action: nil, keyEquivalent: "")
        self.addItem(withTitle: "Units: \(position.unitSize)", action: nil, keyEquivalent: "")

        // Use normalized average cost display
        let normalizedCost = position.getNormalizedAvgCost(for: symbol)
        // Avg Position Cost should already be in GBP due to getNormalizedAvgCost
        self.addItem(withTitle: "Avg Position Cost: GBP \(String(format: "%.2f", normalizedCost))",
                    action: nil, keyEquivalent: "")

        self.addItem(withTitle: totalPositionCost(tradingInfo, position, symbol), action: nil, keyEquivalent: "")
        self.addItem(withTitle: currentPositionValue(tradingInfo, position), action: nil, keyEquivalent: "")
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
