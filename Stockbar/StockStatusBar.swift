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
        if let first = trades.first {
            let price = first.realTimeInfo.currentPrice.isNaN ? "-" : String(format: "%.2f", first.realTimeInfo.currentPrice)
            let symbol = first.trade.name
            mainStatusItem?.button?.title = "\(symbol): \(price)"
        } else {
            mainStatusItem?.button?.title = "StockBar"
        }
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
        // Handle GBX/GBp conversion
        let multiplier = (data.currency == "GBX" || data.currency == "GBp") ? 0.01 : 1.0
        let safeCurrent = data.currentPrice.isFinite ? data.currentPrice : 0
        let safePrev = data.previousPrice.isFinite ? data.previousPrice : 0
        let safeUnits = data.units.isFinite ? data.units : 0
        var pnl: Double? = nil
        if safePrev != 0 && safeUnits != 0 {
            pnl = (safeCurrent - safePrev) * safeUnits * multiplier
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
        let multiplier = (data.currency == "GBX" || data.currency == "GBp") ? 0.01 : 1.0
        let safeCurrent = data.currentPrice.isFinite ? data.currentPrice : 0
        let safePrev = data.previousPrice.isFinite ? data.previousPrice : 0
        let safeUnits = data.units.isFinite ? data.units : 0
        let safeAvgCost = data.avgCost.isFinite ? data.avgCost : 0
        // Calculate values safely
        let dayGain = (safeCurrent - safePrev) * multiplier
        let dayGainPct = (safePrev != 0) ? (dayGain / (safePrev * multiplier)) * 100 : Double.nan
        let marketValue = safeCurrent * safeUnits * multiplier
        let positionCost = safeAvgCost * safeUnits * multiplier
        let totalPL = marketValue - positionCost
        let dayPL = dayGain * safeUnits
        // Fallbacks for display
        func fmt(_ v: Double, decimals: Int = 2) -> String {
            v.isFinite ? String(format: String("%." + String(decimals) + "f"), v) : "N/A"
        }

        let menuItems = [
            ("Price", fmt(safeCurrent * multiplier) + " \(data.currency)"),
            ("Day Gain", (dayGain.isFinite ? String(format: "%+.2f", dayGain) : "N/A") +
                " (" + (dayGainPct.isFinite ? String(format: "%+.2f%%", dayGainPct) : "N/A") + ")"),
            ("Market Value", fmt(marketValue) + " \(data.currency)"),
            ("Position Cost", fmt(positionCost) + " \(data.currency)"),
            ("Total P&L", (totalPL.isFinite ? String(format: "%+.2f", totalPL) : "N/A") + " \(data.currency)"),
            ("Day P&L", (dayPL.isFinite ? String(format: "%+.2f", dayPL) : "N/A") + " \(data.currency)"),
            ("Units", fmt(safeUnits, decimals: 0)),
            ("Avg Cost", fmt(safeAvgCost * multiplier)),
            ("Last Update", (data.timeInfo == "1970-01-01 01:00 GMT+1" || data.timeInfo.contains("1970")) ? "–" : data.timeInfo)
        ]
        menuItems.forEach { title, value in
            menu.addItem(withTitle: "\(title): \(value)", action: nil, keyEquivalent: "")
        }
        item.menu = menu
    }
}