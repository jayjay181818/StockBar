import Cocoa
import Combine
import Foundation

// MARK: - Models
struct TradingData {
    let currentPrice: Double
    let previousPrice: Double
    let currency: String
    let avgCost: Double
    let units: Double
    let timeInfo: String
}

class StockStatusBar {
    // MARK: - Properties
    private let dataModel: DataModel
    private var mainStatusItem: NSStatusItem?
    private var symbolStatusItems: [StockStatusItemController] = []

    // MARK: - Initialization
    init(dataModel: DataModel) {
        self.dataModel = dataModel
        mainStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        mainStatusItem?.button?.title = "StockBar"
    }
    
    // MARK: - Public Methods
    func constructMainItemMenu(items: [NSMenuItem]) {
        let menu = NSMenu()
        items.forEach { menu.addItem($0) }
        mainStatusItem?.menu = menu
    }
    
    func removeAllSymbolItems() {
        symbolStatusItems.removeAll()
    }
    
    func constructSymbolItem(from realTimeTrade: RealTimeTrade, dataModel: DataModel) {
        let controller = StockStatusItemController(realTimeTrade: realTimeTrade, dataModel: dataModel)
        symbolStatusItems.append(controller)
    }
    
    func mainItem() -> NSStatusItem? {
        mainStatusItem
    }
}

class StockStatusItemController {
    // MARK: - Properties
    private let dataModel: DataModel
    let item: NSStatusItem
    var cancellable: AnyCancellable?
    
    // MARK: - Initialization
    init(realTimeTrade: RealTimeTrade, dataModel: DataModel) {
        self.dataModel = dataModel
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setupInitialState(with: realTimeTrade)
        setupDataBinding(for: realTimeTrade)
    }
    
    // MARK: - Private Methods
    private func setupInitialState(with trade: RealTimeTrade) {
        item.button?.title = trade.trade.name
        item.button?.alternateTitle = trade.trade.name
        item.button?.setButtonType(.toggle)
    }
    
    private func setupDataBinding(for realTimeTrade: RealTimeTrade) {
        let tradePublisher = realTimeTrade.sharedPassThroughTrade.merge(
            with: realTimeTrade.$trade.share()
        )
        
        cancellable = Publishers.CombineLatest(tradePublisher, realTimeTrade.$realTimeInfo.share())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] trade, trading in
                self?.updateDisplay(trade: trade, trading: trading)
            }
    }
    
    private func updateDisplay(trade: Trade, trading: TradingInfo) {
        let data = TradingData(
            currentPrice: trading.currentPrice,
            previousPrice: trading.prevClosePrice,
            currency: trading.currency ?? "USD",
            avgCost: Double(trade.position.positionAvgCostString) ?? 0,
            units: trade.position.unitSize,
            timeInfo: trading.getTimeInfo()
        )
        
        updateTitle(trade: trade, data: data)
        updateMenu(trade: trade, data: data)
    }
    
    private func updateTitle(trade: Trade, data: TradingData) {
        let pnl = (data.currentPrice - data.previousPrice) * data.units
        let title = "\(trade.name) \(String(format: "%+.2f", pnl))"
        item.button?.title = title
        item.button?.alternateTitle = trade.name
        
        let color = dataModel.showColorCoding ?
            (pnl >= 0 ? NSColor.systemGreen : NSColor.systemRed) :
            NSColor.labelColor
        
        item.button?.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: color]
        )
    }
    
    private func updateMenu(trade: Trade, data: TradingData) {
        let menu = NSMenu()
        
        // Calculate values
        let dayGain = data.currentPrice - data.previousPrice
        let dayGainPct = dayGain / data.previousPrice * 100
        let marketValue = data.currentPrice * data.units
        let positionCost = data.avgCost * data.units
        
        // Add menu items
        let menuItems = [
            ("Price", String(format: "%.2f \(data.currency)", data.currentPrice)),
            ("Day Gain", String(format: "%+.2f (%+.2f%%)", dayGain, dayGainPct)),
            ("Market Value", String(format: "%.2f \(data.currency)", marketValue)),
            ("Position Cost", String(format: "%.2f \(data.currency)", positionCost)),
            ("Total P&L", String(format: "%+.2f \(data.currency)", marketValue - positionCost)),
            ("Day P&L", String(format: "%+.2f \(data.currency)", dayGain * data.units)),
            ("Units", String(format: "%.0f", data.units)),
            ("Avg Cost", String(format: "%.2f \(data.currency)", data.avgCost)),
            ("Last Update", data.timeInfo)
        ]
        
        menuItems.forEach { title, value in
            menu.addItem(withTitle: "\(title): \(value)", action: nil, keyEquivalent: "")
        }
        
        item.menu = menu
    }
}