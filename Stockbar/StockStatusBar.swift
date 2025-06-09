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
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization
    init(dataModel: DataModel) {
        self.dataModel = dataModel
        mainStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        mainStatusItem?.button?.title = "StockBar"

        dataModel.$realTimeTrades
            .receive(on: DispatchQueue.main)
            .sink { [weak self] trades in
                self?.updateMainStatusItem(with: trades)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Public Methods
    func constructMainItemMenu(items: [NSMenuItem]) {
        let menu = NSMenu()
        items.forEach { menu.addItem($0) }
        mainStatusItem?.menu = menu
    }
    
    func removeAllSymbolItems() {
        // Properly remove status items from the status bar
        for controller in symbolStatusItems {
            NSStatusBar.system.removeStatusItem(controller.item)
        }
        symbolStatusItems.removeAll()
    }
    
    func constructSymbolItem(from realTimeTrade: RealTimeTrade, dataModel: DataModel) {
        let controller = StockStatusItemController(realTimeTrade: realTimeTrade, dataModel: dataModel)
        symbolStatusItems.append(controller)
    }
    
    func mainItem() -> NSStatusItem? {
        mainStatusItem
    }
    
    private func updateMainStatusItem(with trades: [RealTimeTrade]) {
        // Keep the main status item title as "StockBar" - don't show individual stock data
        mainStatusItem?.button?.title = "StockBar"
    }
}

class StockStatusItemController {
    // MARK: - Properties
    private let dataModel: DataModel
    let item: NSStatusItem
    private var cancellables = Set<AnyCancellable>()
    
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
        realTimeTrade.$realTimeInfo
            .receive(on: DispatchQueue.main)
            .sink { [weak self] trading in
                self?.updateDisplay(trade: realTimeTrade.trade, trading: trading)
            }
            .store(in: &cancellables)
    }
    
    private func updateDisplay(trade: Trade, trading: TradingInfo) {
        // Use normalized average cost (handles GBX to GBP conversion automatically)
        let avgCost = trade.position.getNormalizedAvgCost(for: trade.name)
        let currency = trading.currency ?? "USD"
        
        let data = TradingData(
            currentPrice: trading.currentPrice,
            previousPrice: trading.prevClosePrice,
            currency: currency,
            avgCost: avgCost,
            units: trade.position.unitSize,
            timeInfo: trading.getTimeInfo()
        )
        
        updateTitle(trade: trade, data: data)
        updateMenu(trade: trade, data: data)
    }
    
    private func updateTitle(trade: Trade, data: TradingData) {
        // No multiplier needed - prices and avgCost are already converted to the same currency
        let safeCurrent = data.currentPrice.isFinite ? data.currentPrice : 0
        let safePrev = data.previousPrice.isFinite ? data.previousPrice : 0
        let safeUnits = data.units.isFinite ? data.units : 0
        var pnl: Double? = nil
        
        // Only calculate PnL if we have valid price data
        if !data.currentPrice.isNaN && !data.previousPrice.isNaN && safePrev != 0 && safeUnits != 0 {
            pnl = (safeCurrent - safePrev) * safeUnits
        }
        
        let title: String
        if let pnl = pnl, pnl.isFinite {
            title = "\(trade.name) \(String(format: "%+.2f", pnl))"
        } else {
            title = "\(trade.name) –"
        }
        item.button?.title = title
        item.button?.alternateTitle = trade.name
        let color = dataModel.showColorCoding ?
            ((pnl ?? 0) >= 0 ? NSColor.systemGreen : NSColor.systemRed) :
            NSColor.labelColor
        item.button?.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: color]
        )
    }
    
    private func updateMenu(trade: Trade, data: TradingData) {
        let menu = NSMenu()
        // No multiplier needed - all values are already in the same currency
        let safeCurrent = data.currentPrice.isFinite ? data.currentPrice : 0
        let safePrev = data.previousPrice.isFinite ? data.previousPrice : 0
        let safeUnits = data.units.isFinite ? data.units : 0
        let safeAvgCost = data.avgCost.isFinite ? data.avgCost : 0
        // Calculate values safely
        let dayGain = safeCurrent - safePrev
        let dayGainPct = (safePrev != 0) ? (dayGain / safePrev) * 100 : Double.nan
        let marketValue = safeCurrent * safeUnits
        let positionCost = safeAvgCost * safeUnits
        let totalPL = marketValue - positionCost
        let dayPL = dayGain * safeUnits
        // Fallbacks for display
        func fmt(_ v: Double, decimals: Int = 2) -> String {
            v.isFinite ? String(format: String("%." + String(decimals) + "f"), v) : "N/A"
        }

        // For failed fetches, show currency but N/A for prices
        let priceDisplay = data.currentPrice.isNaN ? "N/A" : fmt(safeCurrent)
        let marketValueDisplay = data.currentPrice.isNaN ? "N/A" : fmt(marketValue)
        
        let menuItems = [
            ("Price", priceDisplay + " \(data.currency)"),
            ("Day Gain", (dayGain.isFinite ? String(format: "%+.2f", dayGain) : "N/A") +
                " (" + (dayGainPct.isFinite ? String(format: "%+.2f%%", dayGainPct) : "N/A") + ")"),
            ("Market Value", marketValueDisplay + " \(data.currency)"),
            ("Position Cost", fmt(positionCost) + " \(data.currency)"),
            ("Total P&L", (totalPL.isFinite ? String(format: "%+.2f", totalPL) : "N/A") + " \(data.currency)"),
            ("Day P&L", (dayPL.isFinite ? String(format: "%+.2f", dayPL) : "N/A") + " \(data.currency)"),
            ("Units", fmt(safeUnits, decimals: 0)),
            ("Avg Cost", fmt(safeAvgCost) + " \(data.currency)"),
            ("Last Update", (data.timeInfo.isEmpty || data.timeInfo.contains("1970") || data.timeInfo.contains("00:00")) ? "–" : data.timeInfo)
        ]
        menuItems.forEach { title, value in
            menu.addItem(withTitle: "\(title): \(value)", action: nil, keyEquivalent: "")
        }
        item.menu = menu
    }
}