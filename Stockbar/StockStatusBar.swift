import Cocoa
import Combine
import Foundation
import SwiftUI

// MARK: - Models
struct TradingData {
    let currentPrice: Double
    let previousPrice: Double
    let currency: String
    let avgCost: Double
    let units: Double
    let timeInfo: String
    let lastUpdateTime: Int?

    // Pre/post market data
    let preMarketPrice: Double?
    let preMarketChange: Double?
    let preMarketChangePercent: Double?
    let postMarketPrice: Double?
    let postMarketChange: Double?
    let postMarketChangePercent: Double?
    let marketState: String?
    
    var displayPrice: Double {
        switch marketState {
        case "PRE":
            return preMarketPrice ?? currentPrice
        case "POST":
            return postMarketPrice ?? currentPrice
        default:
            return currentPrice
        }
    }
    
    func marketStateIndicator(useEmoji: Bool) -> String {
        if useEmoji {
            switch marketState {
            case "PRE": return "🔆"      // Bright sun for pre-market
            case "POST": return "🌙"     // Moon for after-hours
            case "CLOSED": return "🔒"   // Lock for closed
            default: return ""
            }
        } else {
            switch marketState {
            case "PRE": return "PRE"
            case "POST": return "AH"
            case "CLOSED": return "CLOSED"
            default: return ""
            }
        }
    }
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

        // CRITICAL: Ensure the status item is visible
        mainStatusItem?.isVisible = true
        mainStatusItem?.button?.title = "StockBar"

        print("🔧 MENU BAR: Main status item created, visible: \(mainStatusItem?.isVisible ?? false), button: \(mainStatusItem?.button != nil)")

        dataModel.$realTimeTrades
            .receive(on: DispatchQueue.main)
            .sink { [weak self] trades in
                print("🔧 MENU BAR: realTimeTrades changed, count: \(trades.count)")
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
        print("🔧 MENU BAR: Creating symbol item for \(realTimeTrade.trade.name)")
        let controller = StockStatusItemController(realTimeTrade: realTimeTrade, dataModel: dataModel)
        symbolStatusItems.append(controller)
        print("🔧 MENU BAR: Symbol item created for \(realTimeTrade.trade.name), total items: \(symbolStatusItems.count), item visible: \(controller.item.isVisible)")
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
    private let formattingService = MenuBarFormattingService()
    
    // MARK: - Initialization
    init(realTimeTrade: RealTimeTrade, dataModel: DataModel) {
        self.dataModel = dataModel
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // CRITICAL: Ensure the status item is visible
        self.item.isVisible = true

        print("🔧 ITEM: Initializing status item for \(realTimeTrade.trade.name), button: \(self.item.button != nil)")

        setupInitialState(with: realTimeTrade)
        setupDataBinding(for: realTimeTrade)

        print("🔧 ITEM: Status item configured for \(realTimeTrade.trade.name), visible: \(self.item.isVisible), title: \(self.item.button?.title ?? "nil")")
    }

    deinit {
        // Cleanup cancellables to prevent memory leaks
        cancellables.removeAll()
        // Note: Status item removal is handled by StockStatusBar.removeAllSymbolItems()
    }
    
    // MARK: - Private Methods
    private func setupInitialState(with trade: RealTimeTrade) {
        item.button?.title = trade.trade.name
        item.button?.alternateTitle = trade.trade.name
        item.button?.setButtonType(.toggle)
    }
    
    private func setupDataBinding(for realTimeTrade: RealTimeTrade) {
        // Listen to changes in trading info
        realTimeTrade.$realTimeInfo
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak realTimeTrade] trading in
                guard let self = self, let realTimeTrade = realTimeTrade else { return }
                self.updateDisplay(trade: realTimeTrade.trade, trading: trading)
            }
            .store(in: &cancellables)

        // Listen to changes in market indicator setting
        dataModel.$showMarketIndicators
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak realTimeTrade] _ in
                guard let self = self, let realTimeTrade = realTimeTrade else { return }
                // Re-update display when setting changes
                self.updateDisplay(trade: realTimeTrade.trade, trading: realTimeTrade.realTimeInfo)
            }
            .store(in: &cancellables)

        // Listen to changes in menu bar display settings
        dataModel.$menuBarDisplaySettings
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak realTimeTrade] _ in
                guard let self = self, let realTimeTrade = realTimeTrade else { return }
                // Re-update display when formatting settings change
                self.updateDisplay(trade: realTimeTrade.trade, trading: realTimeTrade.realTimeInfo)
            }
            .store(in: &cancellables)
    }
    
    private func updateDisplay(trade: Trade, trading: TradingInfo) {
        // Defensive check in case called after deallocation
        guard item.button != nil else { return }

        // Use normalized average cost (handles GBX to GBP conversion automatically)
        let avgCost = trade.position.getNormalizedAvgCost(for: trade.name)
        let currency = trading.currency ?? "USD"

        let data = TradingData(
            currentPrice: trading.currentPrice,
            previousPrice: trading.prevClosePrice,
            currency: currency,
            avgCost: avgCost,
            units: trade.position.unitSize,
            timeInfo: trading.getTimeInfo(),
            lastUpdateTime: trading.lastUpdateTime,
            preMarketPrice: trading.preMarketPrice,
            preMarketChange: trading.preMarketChange,
            preMarketChangePercent: trading.preMarketChangePercent,
            postMarketPrice: trading.postMarketPrice,
            postMarketChange: trading.postMarketChange,
            postMarketChangePercent: trading.postMarketChangePercent,
            marketState: trading.marketState
        )

        updateTitle(trade: trade, data: data)

        // Update menu asynchronously since it accesses the actor
        Task { @MainActor in
            await updateMenu(trade: trade, data: data)
        }
    }
    
    private func updateTitle(trade: Trade, data: TradingData) {
        // Use display price (current, pre-market, or post-market) vs yesterday's close for day P&L
        let safeDisplay = data.displayPrice.isFinite ? data.displayPrice : 0
        let safePrev = data.previousPrice.isFinite ? data.previousPrice : 0
        let safeUnits = data.units.isFinite ? data.units : 0

        // Calculate change and change percentage
        let change = safeDisplay - safePrev
        let changePct = safePrev > 0 ? (change / safePrev) * 100 : 0

        // Calculate day P&L for entire position
        let dayPL = change * safeUnits

        // Use formatting service for title generation
        let settings = dataModel.menuBarDisplaySettings

        Task { @MainActor in
            let formatted = await formattingService.formatStockTitle(
                symbol: trade.name,
                price: safeDisplay,
                change: change,
                changePct: changePct,
                dayPL: dayPL,
                currency: data.currency,
                settings: settings,
                useColorCoding: dataModel.showColorCoding
            )

            // Add watchlist indicator prefix if needed
            if trade.isWatchlistOnly {
                let watchlistPrefix = NSAttributedString(
                    string: "👁 ",
                    attributes: [
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .font: NSFont.menuBarFont(ofSize: 0)
                    ]
                )
                let combined = NSMutableAttributedString()
                combined.append(watchlistPrefix)
                combined.append(formatted)
                item.button?.attributedTitle = combined
            } else {
                item.button?.attributedTitle = formatted
            }

            item.button?.alternateTitle = trade.name
        }
    }
    
    @MainActor
    private func updateMenu(trade: Trade, data: TradingData) async {
        let menu = NSMenu()

        // Add watchlist indicator at the top if this is a watchlist-only stock
        if trade.isWatchlistOnly {
            let watchlistItem = NSMenuItem()
            let watchlistText = NSMutableAttributedString()
            watchlistText.append(NSAttributedString(
                string: "👁 Watchlist Only\n",
                attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 13),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            ))
            watchlistText.append(NSAttributedString(
                string: "Not included in portfolio calculations",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.tertiaryLabelColor
                ]
            ))
            watchlistItem.attributedTitle = watchlistText
            watchlistItem.isEnabled = false
            menu.addItem(watchlistItem)
            menu.addItem(NSMenuItem.separator())
        }

        // If there's an error message, display it prominently
        if let errorMsg = dataModel.realTimeTrades.first(where: { $0.trade.name == trade.name })?.realTimeInfo.errorMessage {
            let errorItem = NSMenuItem()
            let errorText = NSMutableAttributedString()
            errorText.append(NSAttributedString(
                string: "⚠️ Error\n",
                attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 13),
                    .foregroundColor: NSColor.systemRed
                ]
            ))
            errorText.append(NSAttributedString(
                string: errorMsg,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            ))
            errorItem.attributedTitle = errorText
            errorItem.isEnabled = false
            menu.addItem(errorItem)
            menu.addItem(NSMenuItem.separator())
        }

        // Check if symbol is suspended (circuit breaker)
        let cacheStatus = await dataModel.cacheCoordinator.getCacheStatus(for: trade.name, at: Date())
        if case .suspended(let failures, let resumeIn) = cacheStatus {
            let suspendedItem = NSMenuItem()
            let suspendedText = NSMutableAttributedString()
            suspendedText.append(NSAttributedString(
                string: "🔴 Connection Suspended\n",
                attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 13),
                    .foregroundColor: NSColor.systemOrange
                ]
            ))
            let resumeMinutes = Int(resumeIn / 60)
            suspendedText.append(NSAttributedString(
                string: "Failed \(failures) times. Will retry in \(resumeMinutes)m",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            ))
            suspendedItem.attributedTitle = suspendedText
            suspendedItem.isEnabled = false
            menu.addItem(suspendedItem)

            // Add "Retry Now" button for suspended symbols
            let retryItem = NSMenuItem(
                title: "Retry Now",
                action: #selector(retrySymbol(_:)),
                keyEquivalent: ""
            )
            retryItem.representedObject = trade.name
            retryItem.target = self
            menu.addItem(retryItem)

            menu.addItem(NSMenuItem.separator())
        }

        // Add compact sparkline trend before the detailed chart
        let sparklineView = SparklineHostingView(symbol: trade.name, timeRange: .week)
        let sparklineMenuItem = NSMenuItem()
        sparklineMenuItem.view = sparklineView
        menu.addItem(sparklineMenuItem)

        // Add price chart as the second item
        let chartHostingView = MenuPriceChartHostingView(
            symbol: trade.name,
            currentPrice: data.displayPrice,
            currency: data.currency
        )

        // Ensure the hosting view is properly sized before adding to menu
        chartHostingView.needsLayout = true
        chartHostingView.layoutSubtreeIfNeeded()

        let chartMenuItem = NSMenuItem()
        chartMenuItem.view = chartHostingView

        // Set menu item size explicitly to match the full width
        chartMenuItem.representedObject = NSValue(size: NSSize(width: 312, height: 232))

        menu.addItem(chartMenuItem)

        // Add separator after chart
        menu.addItem(NSMenuItem.separator())
        
        // Use display price which includes pre/post market data when applicable
        let safeDisplay = data.displayPrice.isFinite ? data.displayPrice : 0
        let safePrev = data.previousPrice.isFinite ? data.previousPrice : 0
        let safeUnits = data.units.isFinite ? data.units : 0
        let safeAvgCost = data.avgCost.isFinite ? data.avgCost : 0
        
        // Calculate day gain using display price (current, pre-market, or post-market) vs yesterday's close
        // This shows the true gain/loss from yesterday's close to current displayed price
        let dayGain = (safeDisplay > 0 && safePrev > 0) ? safeDisplay - safePrev : Double.nan
        let dayGainPct = (safePrev > 0 && !dayGain.isNaN) ? (dayGain / safePrev) * 100 : Double.nan
        let dayPL = (!dayGain.isNaN && safeUnits > 0) ? dayGain * safeUnits : Double.nan
        
        // Use display price for market value and total P&L (includes pre/post market for current value)
        let marketValue = safeDisplay * safeUnits
        let positionCost = safeAvgCost * safeUnits
        let totalPL = marketValue - positionCost
        
        // Fallbacks for display
        func fmt(_ v: Double, decimals: Int = 2) -> String {
            v.isFinite ? String(format: String("%." + String(decimals) + "f"), v) : "N/A"
        }

        // For failed fetches, show currency but N/A for prices
        let priceDisplay = data.displayPrice.isNaN ? "N/A" : fmt(safeDisplay)
        let marketValueDisplay = data.displayPrice.isNaN ? "N/A" : fmt(marketValue)
        
        // Build menu items including pre/post market data
        var menuItems: [(String, String)] = []
        
        // Current price with market state indicator
        let marketIndicator = dataModel.showMarketIndicators ? data.marketStateIndicator(useEmoji: true) : ""
        let priceLabel = marketIndicator.isEmpty ? "Price" : "Price \(marketIndicator)"
        menuItems.append((priceLabel, priceDisplay + " \(data.currency)"))
        
        // Add pre-market data if available
        if let prePrice = data.preMarketPrice, !prePrice.isNaN {
            menuItems.append(("Pre-Market", fmt(prePrice) + " \(data.currency)"))
            if let preChange = data.preMarketChange, !preChange.isNaN,
               let preChangePct = data.preMarketChangePercent, !preChangePct.isNaN {
                menuItems.append(("Pre-Market Change", String(format: "%+.2f (%+.2f%%)", preChange, preChangePct)))
            }
        }
        
        // Add post-market data if available
        if let postPrice = data.postMarketPrice, !postPrice.isNaN {
            menuItems.append(("After Hours", fmt(postPrice) + " \(data.currency)"))
            if let postChange = data.postMarketChange, !postChange.isNaN,
               let postChangePct = data.postMarketChangePercent, !postChangePct.isNaN {
                menuItems.append(("After Hours Change", String(format: "%+.2f (%+.2f%%)", postChange, postChangePct)))
            }
        }
        
        // Add separator if we have pre/post market data
        if data.preMarketPrice != nil || data.postMarketPrice != nil {
            menu.addItem(NSMenuItem.separator())
        }
        
        // Regular market data - show position info only for portfolio stocks
        if trade.isWatchlistOnly {
            // For watchlist stocks, only show price and day change (no position data)
            menuItems.append(contentsOf: [
                ("Day Gain", (dayGain.isFinite ? String(format: "%+.2f", dayGain) : "N/A") +
                    " (" + (dayGainPct.isFinite ? String(format: "%+.2f%%", dayGainPct) : "N/A") + ")"),
                ("Last Update", (data.timeInfo.isEmpty || data.timeInfo.contains("1970") || data.timeInfo.contains("00:00")) ? "–" : data.timeInfo)
            ])
        } else {
            // For portfolio stocks, show full position details
            menuItems.append(contentsOf: [
                ("Day Gain", (dayGain.isFinite ? String(format: "%+.2f", dayGain) : "N/A") +
                    " (" + (dayGainPct.isFinite ? String(format: "%+.2f%%", dayGainPct) : "N/A") + ")"),
                ("Market Value", marketValueDisplay + " \(data.currency)"),
                ("Position Cost", fmt(positionCost) + " \(data.currency)"),
                ("Total P&L", (totalPL.isFinite ? String(format: "%+.2f", totalPL) : "N/A") + " \(data.currency)"),
                ("Day P&L", (dayPL.isFinite ? String(format: "%+.2f", dayPL) : "N/A") + " \(data.currency)"),
                ("Units", fmt(safeUnits, decimals: 0)),
                ("Avg Cost", fmt(safeAvgCost) + " \(data.currency)"),
                ("Last Update", (data.timeInfo.isEmpty || data.timeInfo.contains("1970") || data.timeInfo.contains("00:00")) ? "–" : data.timeInfo)
            ])
        }
        
        // Add menu items with color coding based on profit/loss and recency
        for (title, value) in menuItems {
            let menuItem = NSMenuItem()

            // Determine line color based on title and conditions
            var lineColor = NSColor.labelColor

            // Strip market state emoji from price label for comparison
            let cleanTitle = title.replacingOccurrences(of: " 🔔", with: "")
                .replacingOccurrences(of: " 🌙", with: "")
                .replacingOccurrences(of: " 📊", with: "")

            if cleanTitle.hasPrefix("Price") {
                // Green if in profit overall, red if at loss
                lineColor = totalPL > 0 ? NSColor.systemGreen : (totalPL < 0 ? NSColor.systemRed : NSColor.labelColor)
            } else if title == "Day Gain" {
                // Green if gain for the day, red if loss
                lineColor = dayGain > 0 ? NSColor.systemGreen : (dayGain < 0 ? NSColor.systemRed : NSColor.labelColor)
            } else if title == "Market Value" {
                // Green if in profit, red if at loss
                lineColor = totalPL > 0 ? NSColor.systemGreen : (totalPL < 0 ? NSColor.systemRed : NSColor.labelColor)
            } else if title == "Total P&L" {
                // Green if in profit, red if at loss
                lineColor = totalPL > 0 ? NSColor.systemGreen : (totalPL < 0 ? NSColor.systemRed : NSColor.labelColor)
            } else if title == "Day P&L" {
                // Green if profit for the day, red if loss
                lineColor = dayPL > 0 ? NSColor.systemGreen : (dayPL < 0 ? NSColor.systemRed : NSColor.labelColor)
            } else if title == "Avg Cost" {
                // Green if in profit overall, red if at loss
                lineColor = totalPL > 0 ? NSColor.systemGreen : (totalPL < 0 ? NSColor.systemRed : NSColor.labelColor)
            } else if title == "Last Update" {
                // Green if updated within last 60 minutes, red if older
                if let lastUpdate = data.lastUpdateTime {
                    let lastUpdateDate = Date(timeIntervalSince1970: TimeInterval(lastUpdate))
                    let minutesSinceUpdate = Date().timeIntervalSince(lastUpdateDate) / 60
                    lineColor = minutesSinceUpdate <= 60 ? NSColor.systemGreen : NSColor.systemRed
                } else {
                    lineColor = NSColor.systemRed // No timestamp = red
                }
            }

            // Create attributed string with full line colored
            let attributedString = NSMutableAttributedString(
                string: "\(title): \(value)",
                attributes: [
                    .font: NSFont.menuFont(ofSize: 14),
                    .foregroundColor: lineColor
                ]
            )

            menuItem.attributedTitle = attributedString
            menuItem.isEnabled = false
            menu.addItem(menuItem)
        }

        // Add exchange rate information if currency conversion is active
        if data.currency != dataModel.preferredCurrency && data.currency != "N/A" {
            let rateInfo = dataModel.currencyConverter.getExchangeRateInfo(from: data.currency, to: dataModel.preferredCurrency)
            let timeSinceRefresh = dataModel.currencyConverter.getTimeSinceRefresh()

            let rateString: String
            if rateInfo.rate != 1.0 {
                if rateInfo.isFallback {
                    rateString = String(format: "1 %@ ≈ %.4f %@ (fallback rate)", data.currency, rateInfo.rate, dataModel.preferredCurrency)
                } else {
                    rateString = String(format: "1 %@ = %.4f %@ (updated %@)", data.currency, rateInfo.rate, dataModel.preferredCurrency, timeSinceRefresh)
                }

                // Determine color based on last refresh time
                let lastRefresh = dataModel.currencyConverter.lastRefreshTime
                let minutesSinceRefresh = Date().timeIntervalSince(lastRefresh) / 60
                let rateColor = minutesSinceRefresh <= 60 ? NSColor.systemGreen : NSColor.systemRed

                let rateItem = NSMenuItem()
                let rateText = NSMutableAttributedString()
                rateText.append(NSAttributedString(
                    string: "💱 Exchange Rate\n",
                    attributes: [
                        .font: NSFont.boldSystemFont(ofSize: 11),
                        .foregroundColor: rateColor
                    ]
                ))
                rateText.append(NSAttributedString(
                    string: rateString,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 10),
                        .foregroundColor: rateColor
                    ]
                ))
                rateItem.attributedTitle = rateText
                rateItem.isEnabled = false
                menu.addItem(rateItem)
            }
        }

        menu.addItem(NSMenuItem.separator())

        let preferencesItem = NSMenuItem(title: "Preferences…", action: #selector(AppDelegate.showPreferences(_:)), keyEquivalent: ",")
        preferencesItem.target = NSApp.delegate
        menu.addItem(preferencesItem)

        let quitItem = NSMenuItem(title: "Quit StockBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        item.menu = menu
    }

    // MARK: - Actions

    @objc private func retrySymbol(_ sender: NSMenuItem) {
        guard let symbol = sender.representedObject as? String else { return }

        Task {
            await Logger.shared.info("🔄 [StockStatusBar] Manually retrying suspended symbol: \(symbol)")

            // Clear suspension state
            await dataModel.cacheCoordinator.clearSuspension(for: symbol)

            // Trigger immediate refresh
            await dataModel.refreshAllTrades()
        }
    }
}
