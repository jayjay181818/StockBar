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
        // Listen to changes in trading info
        realTimeTrade.$realTimeInfo
            .receive(on: DispatchQueue.main)
            .sink { [weak self] trading in
                self?.updateDisplay(trade: realTimeTrade.trade, trading: trading)
            }
            .store(in: &cancellables)
        
        // Listen to changes in market indicator setting
        dataModel.$showMarketIndicators
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Re-update display when setting changes
                self?.updateDisplay(trade: realTimeTrade.trade, trading: realTimeTrade.realTimeInfo)
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
            timeInfo: trading.getTimeInfo(),
            preMarketPrice: trading.preMarketPrice,
            preMarketChange: trading.preMarketChange,
            preMarketChangePercent: trading.preMarketChangePercent,
            postMarketPrice: trading.postMarketPrice,
            postMarketChange: trading.postMarketChange,
            postMarketChangePercent: trading.postMarketChangePercent,
            marketState: trading.marketState
        )
        
        updateTitle(trade: trade, data: data)
        updateMenu(trade: trade, data: data)
    }
    
    private func updateTitle(trade: Trade, data: TradingData) {
        // Use display price (current, pre-market, or post-market) vs yesterday's close for day P&L
        let safeDisplay = data.displayPrice.isFinite ? data.displayPrice : 0
        let safePrev = data.previousPrice.isFinite ? data.previousPrice : 0
        let safeUnits = data.units.isFinite ? data.units : 0
        var pnl: Double? = nil

        // Calculate day P&L using the current display price (which includes pre/post market) vs yesterday's close
        // Skip P&L calculation for watchlist stocks
        if !trade.isWatchlistOnly && !data.displayPrice.isNaN && !data.previousPrice.isNaN && safePrev != 0 && safeUnits != 0 && safeDisplay > 0 {
            pnl = (safeDisplay - safePrev) * safeUnits
        }

        // Include market state indicator in title for pre/post market hours
        let marketIndicator = dataModel.showMarketIndicators ? data.marketStateIndicator(useEmoji: true) : ""
        let watchlistIndicator = trade.isWatchlistOnly ? "👁 " : ""
        let titleBase = marketIndicator.isEmpty ? "\(watchlistIndicator)\(trade.name)" : "\(watchlistIndicator)\(trade.name) \(marketIndicator)"

        let title: String
        if let pnl = pnl, pnl.isFinite {
            title = "\(titleBase) \(String(format: "%+.2f", pnl))"
        } else {
            title = titleBase
        }
        item.button?.title = title
        item.button?.alternateTitle = trade.name

        // For watchlist stocks, use secondary color; for portfolio stocks, use P&L-based coloring
        let color: NSColor
        if trade.isWatchlistOnly {
            color = NSColor.secondaryLabelColor
        } else {
            color = dataModel.showColorCoding ?
                ((pnl ?? 0) >= 0 ? NSColor.systemGreen : NSColor.systemRed) :
                NSColor.labelColor
        }

        item.button?.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: color]
        )
    }
    
    private func updateMenu(trade: Trade, data: TradingData) {
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
        let cacheStatus = dataModel.cacheCoordinator.getCacheStatus(for: trade.name, at: Date())
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

        // Set menu item size explicitly
        chartMenuItem.representedObject = NSValue(size: NSSize(width: 260, height: 180))

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
        
        menuItems.forEach { title, value in
            menu.addItem(withTitle: "\(title): \(value)", action: nil, keyEquivalent: "")
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

                let rateItem = NSMenuItem()
                let rateText = NSMutableAttributedString()
                rateText.append(NSAttributedString(
                    string: "💱 Exchange Rate\n",
                    attributes: [
                        .font: NSFont.boldSystemFont(ofSize: 11),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]
                ))
                rateText.append(NSAttributedString(
                    string: rateString,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 10),
                        .foregroundColor: NSColor.tertiaryLabelColor
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

        Task { await Logger.shared.info("🔄 [StockStatusBar] Manually retrying suspended symbol: \(symbol)") }

        // Clear suspension state
        dataModel.cacheCoordinator.clearSuspension(for: symbol)

        // Trigger immediate refresh
        Task {
            await dataModel.refreshAllTrades()
        }
    }
}
