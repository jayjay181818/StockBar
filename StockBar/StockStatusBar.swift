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
    private var cancellables = Set<AnyCancellable>()
    private var mainStatusItem: NSStatusItem?
    private var symbolStatusItems: [StockStatusItemController] = []
    
    init(dataModel: DataModel) {
        self.dataModel = dataModel
        super.init()
        
        setupStatusItem()
        setupSubscriptions()
    }
    
    private func setupStatusItem() {
        mainStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        mainStatusItem?.button?.title = "StockBar"
    }
    
    private func setupSubscriptions() {
        // Subscribe to changes in realTimeTrades
        dataModel.$realTimeTrades
            .debounce(for: .seconds(0.1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMenu()
            }
            .store(in: &cancellables)
        
        // Subscribe to changes in showColorCoding
        dataModel.$showColorCoding
            .sink { [weak self] _ in
                self?.updateMenu()
            }
            .store(in: &cancellables)
        
        // Set up a timer to update the menu periodically
        Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateMenu()
            }
            .store(in: &cancellables)
    }
    
    private func updateMenu() {
        guard let menu = mainStatusItem?.menu else { return }
        if let firstItem = menu.items.first {
            let gains = dataModel.calculateNetGains()
            let formattedAmount = String(format: "%+.2f", gains.amount)
            firstItem.title = "Net Gains: \(formattedAmount) \(gains.currency)"
            
            if dataModel.showColorCoding {
                let color = gains.amount >= 0 ? NSColor.green : NSColor.systemRed
                firstItem.attributedTitle = NSAttributedString(
                    string: firstItem.title,
                    attributes: [.foregroundColor: color]
                )
            } else {
                firstItem.attributedTitle = nil
            }
        }
    }
    
    func constructMainItemMenu(items: [NSMenuItem]) {
        let menu = NSMenu()
        
        // Add net gains as first item
        let gains = dataModel.calculateNetGains()
        let gainsItem = NSMenuItem()
        let formattedAmount = String(format: "%+.2f", gains.amount)
        gainsItem.title = "Net Gains: \(formattedAmount) \(gains.currency)"
        if dataModel.showColorCoding {
            let color = gains.amount >= 0 ? NSColor.green : NSColor.systemRed
            gainsItem.attributedTitle = NSAttributedString(
                string: gainsItem.title,
                attributes: [.foregroundColor: color]
            )
        }
        menu.addItem(gainsItem)
        menu.addItem(NSMenuItem.separator())
        
        // Add other menu items
        for item in items {
            menu.addItem(item)
        }
        mainStatusItem?.menu = menu
        updateMenu() // Ensure the menu is updated immediately
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
}

class StockStatusItemController {
    private let dataModel: DataModel
    var item: NSStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var cancellable: AnyCancellable?
    
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
}
