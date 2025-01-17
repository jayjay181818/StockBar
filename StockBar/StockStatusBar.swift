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
                let pnl = dailyPNLNumber(trading, trade.position) // Already converted to GBP
                let title = trade.name + String(format: "%+.2f", pnl)
                let fullTitle = trading.currency == "GBX" ? "\(title) (GBX→GBP)" : title
                self?.item.button?.title = fullTitle
                self?.item.button?.alternateTitle = trade.name
                
                // Apply color coding if enabled
                if self?.dataModel.showColorCoding == true {
                    let color = pnl >= 0 ? NSColor.systemGreen : NSColor.systemRed
                    self?.item.button?.attributedTitle = NSAttributedString(
                        string: fullTitle,
                        attributes: [.foregroundColor: color]
                    )
                } else {
                    self?.item.button?.attributedTitle = NSAttributedString(
                        string: fullTitle,
                        attributes: [.foregroundColor: NSColor.labelColor]
                    )
                }
                
                self?.item.menu = SymbolMenu(tradingInfo: trading, position: trade.position)
        }
    }
    var item: NSStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var cancellable: AnyCancellable?
}
