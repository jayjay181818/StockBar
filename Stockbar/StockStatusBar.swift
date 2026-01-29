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

@MainActor
class StockStatusBar: NSObject, NSPopoverDelegate {
    // MARK: - Properties
    private let dataModel: DataModel
    private var mainStatusItem: NSStatusItem?
    private var symbolStatusItems: [StockStatusItemController] = []
    private var symbolItemById: [UUID: StockStatusItemController] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var mainPopover: NSPopover?
    private var mainMenuItems: [NSMenuItem] = []
    private var popoverGlobalMonitor: Any?
    private var popoverLocalMonitor: Any?

    // MARK: - Initialization
    init(dataModel: DataModel) {
        self.dataModel = dataModel
        super.init()
        
        mainStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // CRITICAL: Ensure the status item is visible
        mainStatusItem?.isVisible = true
        mainStatusItem?.button?.title = "StockBar"
        mainStatusItem?.button?.setButtonType(.momentaryPushIn)
        
        // Set up button action for popover (NOT menu - menus override colors)
        mainStatusItem?.button?.target = self
        mainStatusItem?.button?.action = #selector(toggleMainPopover(_:))

        print("🔧 MENU BAR: Main status item created, visible: \(mainStatusItem?.isVisible ?? false), button: \(mainStatusItem?.button != nil)")

        dataModel.$realTimeTrades
            .receive(on: DispatchQueue.main)
            .sink { [weak self] trades in
                print("🔧 MENU BAR: realTimeTrades changed, count: \(trades.count)")
                self?.updateMainStatusItem(with: trades)
            }
            .store(in: &cancellables)

        dataModel.tradeContentPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self = self else { return }
                self.updateMainStatusItem(with: self.dataModel.realTimeTrades)
            }
            .store(in: &cancellables)

        dataModel.$portfolioMenuBarDisplaySettings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateMainStatusItem(with: self.dataModel.realTimeTrades)
            }
            .store(in: &cancellables)

        dataModel.$showColorCoding
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateMainStatusItem(with: self.dataModel.realTimeTrades)
            }
            .store(in: &cancellables)

        dataModel.$preferredCurrency
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateMainStatusItem(with: self.dataModel.realTimeTrades)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Public Methods
    func constructMainItemMenu(items: [NSMenuItem]) {
        mainMenuItems = items
    }
    
    func removeAllSymbolItems() {
        for controller in symbolStatusItems {
            NSStatusBar.system.removeStatusItem(controller.item)
        }
        symbolStatusItems.removeAll()
        symbolItemById.removeAll()
    }
    
    func syncSymbolItems(with realTimeTrades: [RealTimeTrade], dataModel: DataModel) {
        let desiredIds = Set(realTimeTrades.map { $0.id })

        for (id, controller) in symbolItemById where !desiredIds.contains(id) {
            NSStatusBar.system.removeStatusItem(controller.item)
            symbolItemById[id] = nil
        }

        var orderedControllers: [StockStatusItemController] = []
        for trade in realTimeTrades {
            if let existing = symbolItemById[trade.id] {
                orderedControllers.append(existing)
            } else {
                let controller = StockStatusItemController(realTimeTrade: trade, dataModel: dataModel)
                symbolItemById[trade.id] = controller
                orderedControllers.append(controller)
            }
        }

        symbolStatusItems = orderedControllers
    }
    
    func constructSymbolItem(from realTimeTrade: RealTimeTrade, dataModel: DataModel) {
        let controller = StockStatusItemController(realTimeTrade: realTimeTrade, dataModel: dataModel)
        symbolStatusItems.append(controller)
        symbolItemById[realTimeTrade.id] = controller
    }
    
    func mainItem() -> NSStatusItem? {
        mainStatusItem
    }
    
    private func updateMainStatusItem(with trades: [RealTimeTrade]) {
        guard let button = mainStatusItem?.button else { return }
        let settings = dataModel.portfolioMenuBarDisplaySettings
        guard settings.isEnabled else {
            button.title = "StockBar"
            button.attributedTitle = NSAttributedString(string: "StockBar")
            return
        }

        let (totalValue, dayGain, dayGainPct) = calculatePortfolioSummary(for: trades, preferredCurrency: settings.currencyCode)

        let dayGainPctString = String(format: "%+.2f%%", dayGainPct)

        if dayGain.isFinite == false {
            button.title = "StockBar"
            button.attributedTitle = NSAttributedString(string: "StockBar")
            return
        }

        let symbol = currencySymbol(for: settings.currencyCode)
        let displayValue = "\(symbol)\(formatDecimal(totalValue, decimals: settings.decimalPlaces))"
        let displayDayGain = "\(formatSignedCurrency(dayGain, symbol: symbol, decimals: settings.decimalPlaces)) (\(dayGainPctString))"

        let combined = "\(displayValue) \(displayDayGain)"

        let dayColor: NSColor
        if dayGain > 0 {
            dayColor = NSColor.systemGreen
        } else if dayGain < 0 {
            dayColor = NSColor.systemRed
        } else {
            dayColor = NSColor.systemGreen
        }

        print("🔧 PORTFOLIO: Updating main status item - dayGain: \(dayGain), color: \(dayGain >= 0 ? "green" : "red"), combined: \(combined)")

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuBarFont(ofSize: 0),
            .foregroundColor: dayColor
        ]

        let attributed = NSAttributedString(string: combined, attributes: attributes)
        button.attributedTitle = attributed
        button.attributedAlternateTitle = attributed
    }

    private func calculatePortfolioSummary(
        for trades: [RealTimeTrade],
        preferredCurrency: String
    ) -> (totalValue: Double, dayGain: Double, dayGainPct: Double) {
        var totalValueUSD = 0.0
        var totalPrevUSD = 0.0
        var dayGainUSD = 0.0

        for trade in trades {
            guard !trade.trade.isWatchlistOnly else { continue }
            let info = trade.realTimeInfo
            guard info.currentPrice.isFinite, info.prevClosePrice.isFinite else { continue }

            let units = trade.trade.position.unitSize
            guard units > 0 else { continue }

            let currentValue = info.currentPrice * units
            let prevValue = info.prevClosePrice * units
            let currency = info.currency ?? "USD"

            let currentValueUSD = convertToUSD(amount: currentValue, currency: currency)
            let prevValueUSD = convertToUSD(amount: prevValue, currency: currency)

            totalValueUSD += currentValueUSD
            totalPrevUSD += prevValueUSD
            dayGainUSD += (currentValueUSD - prevValueUSD)
        }

        let dayGainPct = totalPrevUSD > 0 ? (dayGainUSD / totalPrevUSD) * 100 : 0

        let totalValue = convertFromUSD(amount: totalValueUSD, preferredCurrency: preferredCurrency)
        let dayGain = convertFromUSD(amount: dayGainUSD, preferredCurrency: preferredCurrency)

        return (totalValue, dayGain, dayGainPct)
    }

    private func convertToUSD(amount: Double, currency: String) -> Double {
        if currency == "GBX" || currency == "GBp" {
            let gbpAmount = amount / 100.0
            return dataModel.currencyConverter.convert(amount: gbpAmount, from: "GBP", to: "USD")
        }

        if currency == "GBP" {
            return dataModel.currencyConverter.convert(amount: amount, from: "GBP", to: "USD")
        }

        if currency == "USD" {
            return amount
        }

        return dataModel.currencyConverter.convert(amount: amount, from: currency, to: "USD")
    }

    private func convertFromUSD(amount: Double, preferredCurrency: String) -> Double {
        if preferredCurrency == "GBX" || preferredCurrency == "GBp" {
            let gbpAmount = dataModel.currencyConverter.convert(amount: amount, from: "USD", to: "GBP")
            return gbpAmount * 100.0
        }

        if preferredCurrency == "USD" {
            return amount
        }

        return dataModel.currencyConverter.convert(amount: amount, from: "USD", to: preferredCurrency)
    }

    static func convertToGBP(amount: Double, currency: String, currencyConverter: CurrencyConverter) -> Double? {
        guard amount.isFinite, amount > 0 else { return nil }

        if currency == "GBX" || currency == "GBp" {
            let gbpAmount = amount / 100.0
            return gbpAmount
        }

        if currency == "GBP" {
            return amount
        }

        if currency == "USD" {
            return currencyConverter.convert(amount: amount, from: "USD", to: "GBP")
        }

        return currencyConverter.convert(amount: amount, from: currency, to: "GBP")
    }

    private func currencySymbol(for currency: String) -> String {
        switch currency {
        case "GBP", "GBX", "GBp": return "£"
        case "USD": return "$"
        case "EUR": return "€"
        case "JPY": return "¥"
        case "CAD": return "C$"
        case "AUD": return "A$"
        default: return currency
        }
    }

    private func formatDecimal(_ value: Double, decimals: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.*f", decimals, value)
    }

    private func formatSignedCurrency(_ value: Double, symbol: String, decimals: Int) -> String {
        let formatted = formatDecimal(abs(value), decimals: decimals)
        let sign = value >= 0 ? "+" : "-"
        return "\(sign)\(symbol)\(formatted)"
    }
    
    // MARK: - Popover Management
    @objc private func toggleMainPopover(_ sender: NSStatusBarButton) {
        if mainPopover == nil {
            mainPopover = NSPopover()
            mainPopover?.behavior = .transient
            mainPopover?.delegate = self
        }
        
        if mainPopover?.isShown == true {
            mainPopover?.performClose(sender)
            stopMainPopoverEventMonitors()
        } else {
            let menu = NSMenu()
            mainMenuItems.forEach { menu.addItem($0.copy() as! NSMenuItem) }
            
            let menuView = NSHostingController(rootView: MainMenuPopoverView(menu: menu))
            mainPopover?.contentViewController = menuView
            mainPopover?.contentSize = NSSize(width: 200, height: CGFloat(mainMenuItems.count * 24 + 16))
            
            mainPopover?.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            startMainPopoverEventMonitors()
        }
    }
    
    func popoverDidClose(_ notification: Notification) {
        updateMainStatusItem(with: dataModel.realTimeTrades)
    }
    
    private func startMainPopoverEventMonitors() {
        stopMainPopoverEventMonitors()
        
        popoverGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.mainPopover?.isShown == true else { return }
            self.mainPopover?.performClose(nil)
            self.stopMainPopoverEventMonitors()
        }
        
        popoverLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.mainPopover?.isShown == true,
                  let popoverWindow = self.mainPopover?.contentViewController?.view.window else {
                return event
            }
            if event.window != popoverWindow {
                self.mainPopover?.performClose(nil)
                self.stopMainPopoverEventMonitors()
            }
            return event
        }
    }
    
    private func stopMainPopoverEventMonitors() {
        if let monitor = popoverGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            popoverGlobalMonitor = nil
        }
        if let monitor = popoverLocalMonitor {
            NSEvent.removeMonitor(monitor)
            popoverLocalMonitor = nil
        }
    }
}

@MainActor
class StockStatusItemController: NSObject, NSPopoverDelegate {

    // MARK: - Properties
    private let dataModel: DataModel
    private let realTimeTrade: RealTimeTrade
    let item: NSStatusItem
    private var cancellables = Set<AnyCancellable>()
    private var detailPopover: NSPopover?
    private var popoverGlobalMonitor: Any?
    private var popoverLocalMonitor: Any?
    private let usePopover = true
    private let popoverSize = NSSize(width: 330, height: 410)
    private let formattingService = MenuBarFormattingService()
    private var titleUpdateCounter = 0
    
    // MARK: - Initialization
    init(realTimeTrade: RealTimeTrade, dataModel: DataModel) {
        self.dataModel = dataModel
        self.realTimeTrade = realTimeTrade
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        super.init()

        // CRITICAL: Ensure the status item is visible
        self.item.isVisible = true

        print("🔧 ITEM: Initializing status item for \(realTimeTrade.trade.name), button: \(self.item.button != nil)")

        setupInitialState(with: realTimeTrade)
        setupPopover()
        setupDataBinding(for: realTimeTrade)
        updateDisplay(trade: realTimeTrade.trade, trading: realTimeTrade.realTimeInfo)

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
        item.button?.setButtonType(.momentaryPushIn)
    }

    private func setupPopover() {
        guard let button = item.button else { return }
        if usePopover {
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
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
            if usePopover {
                updatePopover(trade: trade, data: data)
            }
        }
    }
    
    private func updateTitle(trade: Trade, data: TradingData) {
        let displayCandidate = data.displayPrice.isFinite && data.displayPrice > 0 ? data.displayPrice : nil
        let currentCandidate = data.currentPrice.isFinite && data.currentPrice > 0 ? data.currentPrice : nil
        let safeDisplay = displayCandidate ?? currentCandidate ?? 0
        let safePrev = data.previousPrice.isFinite && data.previousPrice > 0 ? data.previousPrice : 0
        let safeUnits = data.units.isFinite ? data.units : 0

        // Calculate change and change percentage
        let change: Double
        let changePct: Double
        if safeDisplay > 0 && safePrev > 0 {
            change = safeDisplay - safePrev
            changePct = (change / safePrev) * 100
        } else {
            change = Double.nan
            changePct = Double.nan
        }

        // Calculate day P&L for entire position
        let dayPL = change.isFinite ? change * safeUnits : Double.nan

        // Use formatting service for title generation
        let settings = dataModel.menuBarDisplaySettings

        titleUpdateCounter += 1
        let updateId = titleUpdateCounter

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

            guard updateId == titleUpdateCounter else { return }

            if item.button?.attributedTitle != formatted {
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

        let metrics = buildMenuMetrics(trade: trade, data: data)

        // Add price chart as the second item
        let chartHostingView = MenuPriceChartHostingView(
            symbol: trade.name,
            currentPrice: data.displayPrice,
            currency: data.currency,
            metrics: metrics,
            onUnitsSave: { [weak self] newUnits in
                self?.updateUnits(newUnits, for: trade)
            }
        )

        // Ensure the hosting view is properly sized before adding to menu
        chartHostingView.needsLayout = true
        chartHostingView.layoutSubtreeIfNeeded()

        let chartMenuItem = NSMenuItem()
        chartMenuItem.view = chartHostingView

        // Set menu item size explicitly to match the full width
        chartMenuItem.representedObject = NSValue(size: NSSize(width: 330, height: 410))

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

        if !usePopover {
            let menu = NSMenu()

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

            Task { @MainActor in
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
            }

            let sparklineView = SparklineHostingView(symbol: trade.name, timeRange: .week)
            let sparklineMenuItem = NSMenuItem()
            sparklineMenuItem.view = sparklineView
            menu.addItem(sparklineMenuItem)

            let metrics = buildMenuMetrics(trade: trade, data: data)

            let chartHostingView = MenuPriceChartHostingView(
                symbol: trade.name,
                currentPrice: data.displayPrice,
                currency: data.currency,
                metrics: metrics,
                onUnitsSave: { [weak self] newUnits in
                    self?.updateUnits(newUnits, for: trade)
                }
            )

            chartHostingView.needsLayout = true
            chartHostingView.layoutSubtreeIfNeeded()

            let chartMenuItem = NSMenuItem()
            chartMenuItem.view = chartHostingView

            chartMenuItem.representedObject = NSValue(size: NSSize(width: 330, height: 410))

            menu.addItem(chartMenuItem)

            menu.addItem(NSMenuItem.separator())

            if data.preMarketPrice != nil || data.postMarketPrice != nil {
                menu.addItem(NSMenuItem.separator())
            }

            for (title, value) in menuItems {
                let menuItem = NSMenuItem()

                var lineColor = NSColor.labelColor

                let cleanTitle = title.replacingOccurrences(of: " 🔔", with: "")
                    .replacingOccurrences(of: " 🌙", with: "")
                    .replacingOccurrences(of: " 📊", with: "")

                if cleanTitle.hasPrefix("Price") {
                    lineColor = totalPL > 0 ? NSColor.systemGreen : (totalPL < 0 ? NSColor.systemRed : NSColor.labelColor)
                } else if title == "Day Gain" {
                    lineColor = dayGain > 0 ? NSColor.systemGreen : (dayGain < 0 ? NSColor.systemRed : NSColor.labelColor)
                } else if title == "Market Value" {
                    lineColor = totalPL > 0 ? NSColor.systemGreen : (totalPL < 0 ? NSColor.systemRed : NSColor.labelColor)
                } else if title == "Total P&L" {
                    lineColor = totalPL > 0 ? NSColor.systemGreen : (totalPL < 0 ? NSColor.systemRed : NSColor.labelColor)
                } else if title == "Day P&L" {
                    lineColor = dayPL > 0 ? NSColor.systemGreen : (dayPL < 0 ? NSColor.systemRed : NSColor.labelColor)
                } else if title == "Avg Cost" {
                    lineColor = totalPL > 0 ? NSColor.systemGreen : (totalPL < 0 ? NSColor.systemRed : NSColor.labelColor)
                } else if title == "Last Update" {
                    if let lastUpdate = data.lastUpdateTime {
                        let lastUpdateDate = Date(timeIntervalSince1970: TimeInterval(lastUpdate))
                        let minutesSinceUpdate = Date().timeIntervalSince(lastUpdateDate) / 60
                        lineColor = minutesSinceUpdate <= 60 ? NSColor.systemGreen : NSColor.systemRed
                    } else {
                        lineColor = NSColor.systemRed
                    }
                }

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
    }

    private static let updatedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "HH:mm dd/MM/yy"
        return formatter
    }()

    private func buildMenuMetrics(trade: Trade, data: TradingData) -> MenuPopoverMetrics {
        let displayCandidate = data.displayPrice.isFinite && data.displayPrice > 0 ? data.displayPrice : nil
        let currentCandidate = data.currentPrice.isFinite && data.currentPrice > 0 ? data.currentPrice : nil
        let safeDisplay = displayCandidate ?? currentCandidate ?? 0
        let safePrev = data.previousPrice.isFinite ? data.previousPrice : 0
        let safeUnits = data.units.isFinite ? data.units : 0
        let safeAvgCost = data.avgCost.isFinite ? data.avgCost : 0

        let dayGain = (safeDisplay > 0 && safePrev > 0) ? safeDisplay - safePrev : Double.nan
        let dayGainPct = (safePrev > 0 && !dayGain.isNaN) ? (dayGain / safePrev) * 100 : Double.nan
        let dayPL = (!dayGain.isNaN && safeUnits > 0) ? dayGain * safeUnits : Double.nan

        let marketValue = safeDisplay * safeUnits
        let positionCost = safeAvgCost * safeUnits
        let totalPL = marketValue - positionCost
        let totalPLPct = positionCost > 0 ? (totalPL / positionCost) * 100 : Double.nan


        let updatedText: String
        if let lastUpdateTime = data.lastUpdateTime, lastUpdateTime > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(lastUpdateTime))
            updatedText = "Updated: \(Self.updatedDateFormatter.string(from: date))"
        } else {
            updatedText = "Updated: —"
        }

        let exchangeName = SymbolMetadata.isUKSymbol(trade.name) ? "London Stock Ex" : "Market"

        return MenuPopoverMetrics(
            exchangeName: exchangeName,
            marketValue: safeDisplay > 0 ? marketValue : nil,
            totalPnL: totalPL.isFinite ? totalPL : nil,
            totalPnLPercent: totalPLPct.isFinite ? totalPLPct : nil,
            dayPnL: dayPL.isFinite ? dayPL : nil,
            dayPnLPercent: dayGainPct.isFinite ? dayGainPct : nil,
            priceChange: dayGain.isFinite ? dayGain : nil,
            priceChangePercent: dayGainPct.isFinite ? dayGainPct : nil,
            units: safeUnits,
            avgCost: safeAvgCost,
            currency: data.currency,
            updatedText: updatedText,
            canEditUnits: !trade.isWatchlistOnly
        )
    }

    @MainActor
    private func updatePopover(trade: Trade, data: TradingData) {
        guard detailPopover != nil else { return }
        let metrics = buildMenuMetrics(trade: trade, data: data)
        let chartView = MenuPriceChartView(
            symbol: trade.name,
            currentPrice: data.displayPrice,
            currency: data.currency,
            metrics: metrics,
            onUnitsSave: { [weak self] newUnits in
                self?.updateUnits(newUnits, for: trade)
            }
        )
        detailPopover?.contentViewController = NSHostingController(rootView: chartView)
    }

    private func updateUnits(_ newUnits: Double, for trade: Trade) {
        guard newUnits.isFinite, newUnits > 0 else { return }
        realTimeTrade.trade.position.unitSizeString = String(format: "%.0f", newUnits)
        dataModel.triggerTradeUpdate()
    }



    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if detailPopover == nil {
            detailPopover = NSPopover()
            detailPopover?.behavior = .transient
            detailPopover?.delegate = self
        }

        detailPopover?.contentSize = popoverSize
        detailPopover?.animates = false

        if detailPopover?.isShown == true {
            detailPopover?.performClose(sender)
            stopPopoverEventMonitors()
        } else {
            let metrics = buildMenuMetrics(trade: realTimeTrade.trade, data: TradingData(
                currentPrice: realTimeTrade.realTimeInfo.currentPrice,
                previousPrice: realTimeTrade.realTimeInfo.prevClosePrice,
                currency: realTimeTrade.realTimeInfo.currency ?? "USD",
                avgCost: realTimeTrade.trade.position.getNormalizedAvgCost(for: realTimeTrade.trade.name),
                units: realTimeTrade.trade.position.unitSize,
                timeInfo: realTimeTrade.realTimeInfo.getTimeInfo(),
                lastUpdateTime: realTimeTrade.realTimeInfo.lastUpdateTime,
                preMarketPrice: realTimeTrade.realTimeInfo.preMarketPrice,
                preMarketChange: realTimeTrade.realTimeInfo.preMarketChange,
                preMarketChangePercent: realTimeTrade.realTimeInfo.preMarketChangePercent,
                postMarketPrice: realTimeTrade.realTimeInfo.postMarketPrice,
                postMarketChange: realTimeTrade.realTimeInfo.postMarketChange,
                postMarketChangePercent: realTimeTrade.realTimeInfo.postMarketChangePercent,
                marketState: realTimeTrade.realTimeInfo.marketState
            ))

            let chartView = MenuPriceChartView(
                symbol: realTimeTrade.trade.name,
                currentPrice: metrics.marketValue != nil ? realTimeTrade.realTimeInfo.currentPrice : realTimeTrade.realTimeInfo.currentPrice,
                currency: metrics.currency,
                metrics: metrics,
                onUnitsSave: { [weak self] newUnits in
                    guard let self = self else { return }
                    self.updateUnits(newUnits, for: self.realTimeTrade.trade)
                }
            )
            detailPopover?.contentViewController = NSHostingController(rootView: chartView)

            detailPopover?.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            startPopoverEventMonitors()

            DispatchQueue.main.async { [weak self, weak sender] in
                guard let self, let sender,
                      let popoverWindow = self.detailPopover?.contentViewController?.view.window,
                      let screen = sender.window?.screen else { return }

                let visibleFrame = screen.visibleFrame
                var frame = popoverWindow.frame

                if frame.maxY > visibleFrame.maxY {
                    frame.origin.y = visibleFrame.maxY - frame.height
                }
                if frame.minY < visibleFrame.minY {
                    frame.origin.y = visibleFrame.minY
                }
                if frame.minX < visibleFrame.minX {
                    frame.origin.x = visibleFrame.minX
                }
                if frame.maxX > visibleFrame.maxX {
                    frame.origin.x = visibleFrame.maxX - frame.width
                }

                popoverWindow.setFrame(frame, display: true)
            }
        }
    }

    // MARK: - NSPopoverDelegate
    func popoverDidClose(_ notification: Notification) {
        // Force refresh the menu bar item title to ensure color/formatting is restored
        // after the system might have reset it during the highlight state.
        updateDisplay(trade: realTimeTrade.trade, trading: realTimeTrade.realTimeInfo)
    }

    private func startPopoverEventMonitors() {
        stopPopoverEventMonitors()

        popoverGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            guard let popoverWindow = self.detailPopover?.contentViewController?.view.window else {
                if self.detailPopover?.isShown == true {
                    self.detailPopover?.performClose(nil)
                    self.stopPopoverEventMonitors()
                }
                return
            }

            let mouseLocation = NSEvent.mouseLocation
            if popoverWindow.frame.contains(mouseLocation) {
                return
            }

            if self.detailPopover?.isShown == true {
                self.detailPopover?.performClose(nil)
                self.stopPopoverEventMonitors()
            }
        }

        popoverLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if let popoverWindow = self.detailPopover?.contentViewController?.view.window,
               event.window == popoverWindow {
                return event
            }

            if self.detailPopover?.isShown == true {
                self.detailPopover?.performClose(nil)
                self.stopPopoverEventMonitors()
            }
            return event
        }
    }

    private func stopPopoverEventMonitors() {
        if let monitor = popoverGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            popoverGlobalMonitor = nil
        }
        if let monitor = popoverLocalMonitor {
            NSEvent.removeMonitor(monitor)
            popoverLocalMonitor = nil
        }
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

struct MainMenuPopoverView: View {
    let menu: NSMenu
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(menu.items.enumerated()), id: \.offset) { _, item in
                if item.isSeparatorItem {
                    Divider()
                        .padding(.vertical, 2)
                } else {
                    Button(action: {
                        dismiss()
                        if let action = item.action, let target = item.target {
                            _ = target.perform(action, with: item)
                        }
                    }) {
                        HStack {
                            if let title = item.attributedTitle {
                                Text(AttributedString(title))
                            } else {
                                Text(item.title)
                            }
                            Spacer()
                            if !item.keyEquivalent.isEmpty {
                                Text(item.keyEquivalent)
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!item.isEnabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
            }
        }
        .padding(8)
        .frame(minWidth: 180)
    }
}
