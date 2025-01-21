import Cocoa

class SymbolMenu: NSMenu {
    private let symbol: String

    // Menu items
    private let symbolItem = NSMenuItem()
    private let priceItem = NSMenuItem()
    private let dailyGainItem = NSMenuItem()
    private let timestampItem = NSMenuItem()
    private let dailyPnLItem = NSMenuItem()
    private let totalPnLItem = NSMenuItem()
    private let unitsItem = NSMenuItem()
    private let avgPositionCostItem = NSMenuItem()
    private let positionCostItem = NSMenuItem()
    private let marketValueItem = NSMenuItem()

    init(symbol: String) {
        self.symbol = symbol
        super.init(title: "Stock Menu")

        setupMenu()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupMenu() {
        // Add all menu items
        addItem(symbolItem)
        addItem(priceItem)
        addItem(dailyGainItem)
        addItem(NSMenuItem.separator())
        addItem(timestampItem)
        addItem(NSMenuItem.separator())
        addItem(dailyPnLItem)
        addItem(totalPnLItem)
        addItem(NSMenuItem.separator())
        addItem(unitsItem)
        addItem(avgPositionCostItem)
        addItem(positionCostItem)
        addItem(marketValueItem)

        // Add close button
        addItem(NSMenuItem.separator())
        let closeItem = NSMenuItem(title: "Close", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addItem(closeItem)
    }

    func updateDisplay(with data: StockData) {
        // Update basic info
        symbolItem.title = data.symbol
        priceItem.title = String(format: "GBP %.2f", data.price)

        // Update daily gain with color
        let dailyGainText = String(format: "%.4f%%", data.dayGainPercentage)
        let gainColor = data.dayGainPercentage >= 0 ? NSColor.green : NSColor.red

        dailyGainItem.attributedTitle = NSAttributedString(
            string: dailyGainText,
            attributes: [.foregroundColor: gainColor]
        )

        // Update PnL information
        dailyPnLItem.title = String(format: "Daily PnL: GBP %.2f", data.dayPnL)
        totalPnLItem.title = String(format: "Total PnL: GBP %.2f", data.totalPnL)

        // Update position information
        unitsItem.title = String(format: "Units: %.1f", data.units)
        avgPositionCostItem.title = String(format: "Avg Position Cost: GBP %.1f", data.averagePositionCost)
        positionCostItem.title = String(format: "Position Cost: GBP %.2f", data.positionCost)
        marketValueItem.title = String(format: "Market Value: GBP %.2f", data.marketValue)

        // Update timestamp
        timestampItem.title = data.timestamp

        // Color coding for PnL values
        dailyPnLItem.attributedTitle = NSAttributedString(
            string: dailyPnLItem.title,
            attributes: [.foregroundColor: data.dayPnL >= 0 ? NSColor.green : NSColor.red]
        )

        totalPnLItem.attributedTitle = NSAttributedString(
            string: totalPnLItem.title,
            attributes: [.foregroundColor: data.totalPnL >= 0 ? NSColor.green : NSColor.red]
        )
    }
}
