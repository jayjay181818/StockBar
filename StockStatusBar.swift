//
//  StockStatusBar.swift
//  StockBar
//
//  Created by Hongliang Fan on 2020-06-20.

import Foundation
import Combine
import Cocoa

class StockStatusBar: NSStatusBar {
    private let dataModel: DataModel
    
    init(dataModel: DataModel) {
        self.dataModel = dataModel
        mainStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        mainStatusItem?.button?.title = "StockBar"
    }
    func constructMainItemMenu(items : [NSMenuItem]) {
        let menu = NSMenu()
        for item in items {
            menu.addItem(item)
        }
        mainStatusItem?.menu = menu
    }
    func removeAllSymbolItems() {
        symbolStatusItems.removeAll()
    }
    func constructSymbolItem(from realTimeTrade: RealTimeTrade, dataModel: DataModel) {
        symbolStatusItems.append(StockStatusItemController(realTimeTrade: realTimeTrade, dataModel: dataModel))
    }
    func mainItem() -> NSStatusItem? {
        return mainStatusItem
    }
    private var mainStatusItem : NSStatusItem?
    private var symbolStatusItems : [StockStatusItemController] = []
}

class StockStatusItemController {
    private let dataModel: DataModel
    
    init(realTimeTrade: RealTimeTrade, dataModel: DataModel) {
        self.dataModel = dataModel
        item.button?.title = realTimeTrade.trade.name
        item.button?.alternateTitle = realTimeTrade.trade.name
        // Set the toggle ButtonType to enable alternateTitle display
        item.button?.setButtonType(NSButton.ButtonType.toggle)
        // For a single trade, when any of the symbol, unit size, avg cost position, real time info changes,
        // update the detail menu and the button title.
        cancellable = Publishers.CombineLatest(realTimeTrade.sharedPassThroughTrade.merge(with: realTimeTrade.$trade.share()),
                                          realTimeTrade.$realTimeInfo.share())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (trade, trading) in
                guard let self = self else { return }
                
                // Use the centralized convertPrice function for all currency conversions
                let currentPriceConverted = convertPrice(price: trading.currentPrice, currency: trading.currency)
                let prevClosePriceConverted = convertPrice(price: trading.prevClosePrice, currency: trading.currency)
                let avgPositionCostConverted = convertPrice(price: Double(trade.position.positionAvgCostString) ?? 0, currency: trading.currency)
                
                // Calculate PnL using converted values
                let pnl = (currentPriceConverted.price - prevClosePriceConverted.price) * trade.position.unitSize
                let title = trade.name + String(format: "%+.2f", pnl)
                let fullTitle = (trading.currency == "GBX" || trading.currency == "GBp") ? "\(title) (→\(currentPriceConverted.currency))" : title
                self.item.button?.title = fullTitle
                self.item.button?.alternateTitle = trade.name
                
                // Apply color coding if enabled
                if self.dataModel.showColorCoding {
                    let color = pnl >= 0 ? NSColor.systemGreen : NSColor.systemRed
                    self.item.button?.attributedTitle = NSAttributedString(
                        string: fullTitle,
                        attributes: [.foregroundColor: color]
                    )
                } else {
                    self.item.button?.attributedTitle = NSAttributedString(
                        string: fullTitle,
                        attributes: [.foregroundColor: NSColor.labelColor]
                    )
                }
                
                // Calculate all values using converted prices
                let dayGain = currentPriceConverted.price - prevClosePriceConverted.price
                let dayGainPct = 100 * (dayGain / prevClosePriceConverted.price)
                let marketValue = currentPriceConverted.price * trade.position.unitSize
                let positionCost = avgPositionCostConverted.price * trade.position.unitSize
                let totalPnL = marketValue - positionCost
                let dayPnL = dayGain * trade.position.unitSize
                
                // Create StockData with converted values
                let stockData = StockData(
                    symbol: trade.name,
                    price: currentPriceConverted.price,
                    dayGain: dayGain,
                    dayGainPercentage: dayGainPct,
                    marketValue: marketValue,
                    positionCost: positionCost,
                    totalPnL: totalPnL,
                    dayPnL: dayPnL,
                    units: trade.position.unitSize,
                    averagePositionCost: avgPositionCostConverted.price,
                    timestamp: trading.getTimeInfo()
                )
                
                // Create menu with the converted values
                let menu = SymbolMenu(symbol: trade.name)
                menu.updateDisplay(with: stockData)
                self.item.menu = menu
        }
    }
    var item: NSStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var cancellable: AnyCancellable?
}