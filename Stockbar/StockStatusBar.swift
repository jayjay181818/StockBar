import Cocoa
@preconcurrency import Combine
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
        func validExtendedPrice(_ price: Double?) -> Double? {
            guard let price, price.isFinite, price > 0 else { return nil }
            return price
        }

        switch marketState {
        case "PRE":
            return validExtendedPrice(preMarketPrice) ?? currentPrice
        case "POST":
            return validExtendedPrice(postMarketPrice) ?? currentPrice
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

enum StatusItemAccessibility {
    /// Spoken direction for a change, so colour and arrows are never the only signal.
    static func direction(of change: Double) -> String {
        guard change.isFinite else { return "change unavailable" }
        if change > 0 { return "up" }
        if change < 0 { return "down" }
        return "unchanged"
    }
}

/// Decides whether a mouse-down belongs to a status item's own button.
enum StatusButtonClickPolicy {
    /// True when the event was delivered to the button's window, or (for global events,
    /// which carry no window) the pointer is inside it.
    static func isStatusButtonEvent(eventWindow: NSWindow?, buttonWindow: NSWindow?, mouseLocation: NSPoint) -> Bool {
        guard let buttonWindow else { return false }
        if let eventWindow { return eventWindow === buttonWindow }
        return buttonWindow.frame.contains(mouseLocation)
    }
}

enum MenuBarSymbolPresentation {
    static func title(for tradeName: String) -> String {
        tradeName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MenuPriceChangeSummary: Equatable {
    let change: Double
    let percent: Double
    let positionPnL: Double
}

enum MenuPriceChangeCalculator {
    static func rollingDaySummary(
        currentPrice: Double,
        previousClose: Double,
        units: Double,
        historicalPrices: [Double],
        symbol: String
    ) -> MenuPriceChangeSummary {
        let safeCurrent = currentPrice.isFinite && currentPrice > 0 ? currentPrice : 0
        let safePreviousClose = previousClose.isFinite && previousClose > 0 ? previousClose : 0
        let safeUnits = units.isFinite ? units : 0

        let historicalBaseline = historicalPrices
            .first(where: { $0.isFinite && $0 > 0 })
            .map { normalizedHistoricalPrice($0, currentPrice: safeCurrent, symbol: symbol) }
        let baseline = historicalBaseline ?? safePreviousClose

        guard safeCurrent > 0, baseline.isFinite, baseline > 0 else {
            return MenuPriceChangeSummary(change: .nan, percent: .nan, positionPnL: .nan)
        }

        let change = safeCurrent - baseline
        return MenuPriceChangeSummary(
            change: change,
            percent: (change / baseline) * 100,
            positionPnL: change * safeUnits
        )
    }

    private static func normalizedHistoricalPrice(
        _ price: Double,
        currentPrice: Double,
        symbol: String
    ) -> Double {
        // Safety net only: stored snapshots are repaired once by
        // UKPriceSnapshotScaleMigrationService.
        UKPriceScale.normalized(price, reference: currentPrice, symbol: symbol)
    }
}

@MainActor
class StockStatusBar: NSObject, NSPopoverDelegate {
    // MARK: - Properties
    private let dataModel: DataModel
    private var mainStatusItem: NSStatusItem?
    private var symbolStatusItems: [StockStatusItemController] = []
    private var symbolItemByKey: [String: StockStatusItemController] = [:]
    private var lastSymbolItemDebugSummary: String?
    private var cancellables = Set<AnyCancellable>()
    private var mainPopover: NSPopover?
    private var portfolioActions = PortfolioMenuActions.noop
    private var popoverGlobalMonitor: Any?
    private var popoverLocalMonitor: Any?
    private let mainPopoverSize = NSSize(width: 330, height: 410)

    // MARK: - Initialization
    init(dataModel: DataModel) {
        self.dataModel = dataModel
        super.init()
        
        mainStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        mainStatusItem?.autosaveName = StockbarAutosavePolicy.statusItemName("com.stockbar.portfolio")

        // CRITICAL: Ensure the status item is visible
        mainStatusItem?.isVisible = true
        mainStatusItem?.button?.title = "Stockbar"
        mainStatusItem?.button?.setButtonType(.momentaryPushIn)
        
        // Set up button action for popover (NOT menu - menus override colors)
        mainStatusItem?.button?.target = self
        mainStatusItem?.button?.action = #selector(toggleMainPopover(_:))
        // Open exactly once the click is complete; dismissal belongs to the
        // explicit outside-click monitors rather than the press lifecycle.
        mainStatusItem?.button?.sendAction(on: [.leftMouseUp])

        let statusItemVisible = mainStatusItem?.isVisible ?? false
        let hasButton = mainStatusItem?.button != nil
        Task { await Logger.shared.debug("🔧 MENU BAR: Main status item created, visible: \(statusItemVisible), button: \(hasButton)") }

        MenuBarContentUpdates.effectiveContentPublisher(dataModel.tradeContentPublisher)
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

        dataModel.historicalDataManager.$priceSnapshots
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateMainStatusItem(with: self.dataModel.realTimeTrades)
            }
            .store(in: &cancellables)

        dataModel.historicalDataManager.$historicalPortfolioSnapshots
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateMainStatusItem(with: self.dataModel.realTimeTrades)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Public Methods
    func configurePortfolioActions(
        refresh: @escaping () -> Void,
        preferences: @escaping () -> Void,
        quit: @escaping () -> Void,
        openApp: @escaping () -> Void = {}
    ) {
        portfolioActions = PortfolioMenuActions(refresh: refresh, preferences: preferences, quit: quit, openApp: openApp)
    }
    
    func removeAllSymbolItems() {
        for controller in symbolStatusItems {
            NSStatusBar.system.removeStatusItem(controller.item)
        }
        symbolStatusItems.removeAll()
        symbolItemByKey.removeAll()
    }
    
    func syncSymbolItems(with realTimeTrades: [RealTimeTrade], dataModel: DataModel, isVisible: Bool = true) {
        let desiredKeys = Set(realTimeTrades.map { symbolItemKey(for: $0) })

        for (key, controller) in symbolItemByKey where !desiredKeys.contains(key) {
            NSStatusBar.system.removeStatusItem(controller.item)
            symbolItemByKey[key] = nil
        }

        var orderedControllers: [StockStatusItemController] = []
        var seenKeys: Set<String> = []
        for trade in realTimeTrades {
            let key = symbolItemKey(for: trade)
            // One item per symbol, bound to the first row — the same row that
            // persistence keeps. Rebinding to later duplicates made the item
            // flip between rows and appear twice in `symbolStatusItems`.
            guard seenKeys.insert(key).inserted else { continue }
            if let existing = symbolItemByKey[key] {
                existing.update(realTimeTrade: trade)
                existing.item.isVisible = isVisible
                orderedControllers.append(existing)
            } else {
                let controller = StockStatusItemController(realTimeTrade: trade, dataModel: dataModel)
                controller.item.isVisible = isVisible
                symbolItemByKey[key] = controller
                orderedControllers.append(controller)
            }
        }

        symbolStatusItems = orderedControllers
        logSymbolItemState()
    }
    
    func constructSymbolItem(from realTimeTrade: RealTimeTrade, dataModel: DataModel) {
        let controller = StockStatusItemController(realTimeTrade: realTimeTrade, dataModel: dataModel)
        symbolStatusItems.append(controller)
        symbolItemByKey[symbolItemKey(for: realTimeTrade)] = controller
    }

    private func symbolItemKey(for realTimeTrade: RealTimeTrade) -> String {
        (realTimeTrade.sourceIdentity ?? realTimeTrade.trade.name)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }

    private func logSymbolItemState() {
        // This exists purely to emit a debug line, but building the summary
        // means reading `attributedTitle` off every status item — real work on a
        // path that runs on every menu bar sync. Bail before computing anything
        // when debug logging is off (the default).
        guard Logger.isDebugLoggingEnabled else { return }

        let visibleCount = symbolStatusItems.filter { $0.item.isVisible }.count
        let sample = symbolStatusItems.prefix(4).map { controller in
            let title = controller.item.button?.attributedTitle.string
                ?? controller.item.button?.title
                ?? "nil"
            return "\(title.isEmpty ? "empty" : title):\(controller.item.isVisible ? "visible" : "hidden")"
        }.joined(separator: ",")
        let summary = "retained=\(symbolStatusItems.count) visibleItems=\(visibleCount) sample=\(sample)"

        guard summary != lastSymbolItemDebugSummary else { return }
        lastSymbolItemDebugSummary = summary

        Task {
            await Logger.shared.debug("MenuBar: Symbol status item state \(summary)")
        }
    }
    
    func mainItem() -> NSStatusItem? {
        mainStatusItem
    }
    
    private func updateMainStatusItem(with trades: [RealTimeTrade]) {
        guard let button = mainStatusItem?.button else { return }
        let settings = dataModel.portfolioMenuBarDisplaySettings
        guard settings.isEnabled else {
            button.title = "Stockbar"
            button.attributedTitle = NSAttributedString(string: "Stockbar")
            return
        }

        let summary = dataModel.calculateDisplayPortfolioSummary(preferredCurrency: settings.currencyCode)
        let totalValue = summary.totalValue
        let chartChange = summary.valuationSource == .folyncProvided
            ? nil
            : rollingPortfolioDayChange(summary: summary)
        guard let dayChange = PortfolioMenuPerformanceResolver.resolve(
            summary: summary,
            range: .day,
            chartChange: chartChange
        ) else {
            button.title = "Stockbar"
            button.attributedTitle = NSAttributedString(string: "Stockbar")
            return
        }
        let dayGain = dayChange.value
        let dayGainPct = dayChange.percent
        let combined = PortfolioMenuBarTitleFormatter.title(
            totalValue: totalValue,
            dayGain: dayGain,
            dayGainPercent: dayGainPct,
            settings: settings
        )

        // Honour the colour-coding preference; an unchanged day is neutral.
        let dayColor: NSColor
        if !dataModel.showColorCoding || dayGain == 0 || !dayGain.isFinite {
            dayColor = .labelColor
        } else {
            dayColor = dayGain > 0 ? .systemGreen : .systemRed
        }

        Task { await Logger.shared.debug("🔧 PORTFOLIO: Updating main status item - dayGain: \(dayGain), combined: \(combined)") }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuBarFont(ofSize: 0),
            .foregroundColor: dayColor
        ]

        let attributed = NSAttributedString(string: combined, attributes: attributes)
        button.toolTip = "Portfolio value and today's change (\(summary.currency)). Click for details."
        // Colour must not be the only signal for direction.
        button.setAccessibilityLabel("Portfolio \(combined), today \(StatusItemAccessibility.direction(of: dayGain))")
        button.attributedTitle = attributed
        button.attributedAlternateTitle = attributed
    }

    private func rollingPortfolioDayChange(
        summary: DisplayPortfolioSummary,
        now: Date = Date()
    ) -> PortfolioMenuRangeChange? {
        let range = MenuChartTimeRange.day
        let storedPoints = dataModel.historicalDataManager.getPortfolioMenuValues(
            for: range.chartTimeRange,
            currentTrades: dataModel.realTimeTrades,
            preferredCurrency: summary.currency,
            now: now
        )
        let chartPoints = PortfolioMenuChartDataBuilder.prepareChartPoints(
            storedPoints: storedPoints,
            currentValue: summary.totalValue,
            range: range,
            now: now
        )
        return PortfolioMenuChartDataBuilder.rangeChange(for: chartPoints)
    }

    
    // MARK: - Popover Management
    @objc private func toggleMainPopover(_ sender: NSStatusBarButton) {
        if mainPopover == nil {
            mainPopover = NSPopover()
            // Dismissal is owned by the event monitors below. A transient
            // popover can interpret the mouse-up that completes a status-item
            // click as a new interaction and immediately close again.
            mainPopover?.behavior = .applicationDefined
            mainPopover?.delegate = self
        }
        
        if mainPopover?.isShown == true {
            mainPopover?.performClose(sender)
            stopMainPopoverEventMonitors()
        } else {
            mainPopover?.contentSize = mainPopoverSize
            mainPopover?.animates = false
            mainPopover?.appearance = StockbarAppearance.popoverAppearance()
            let hostingController = NSHostingController(
                rootView: PortfolioMenuPopoverView(
                    dataModel: dataModel,
                    actions: actionsForCurrentPortfolioPopover()
                )
            )
            // Size the popover to its SwiftUI content.
            hostingController.sizingOptions = .preferredContentSize
            mainPopover?.contentViewController = hostingController

            mainPopover?.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            startMainPopoverEventMonitors()
            clampMainPopoverToVisibleFrame()
        }
    }
    
    func popoverDidClose(_ notification: Notification) {
        updateMainStatusItem(with: dataModel.realTimeTrades)
    }
    
    private func startMainPopoverEventMonitors() {
        stopMainPopoverEventMonitors()
        
        // A click on the status button is handled by the button's own action, which
        // toggles the popover. Closing it here as well would make the toggle reopen it.
        popoverGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.mainPopover?.isShown == true,
                  !self.isMainStatusButtonEvent(event) else { return }
            self.mainPopover?.performClose(nil)
            self.stopMainPopoverEventMonitors()
        }
        
        popoverLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.mainPopover?.isShown == true,
                  let popoverWindow = self.mainPopover?.contentViewController?.view.window else {
                return event
            }
            if event.window != popoverWindow, !self.isMainStatusButtonEvent(event) {
                self.mainPopover?.performClose(nil)
                self.stopMainPopoverEventMonitors()
            }
            return event
        }
    }

    private func isMainStatusButtonEvent(_ event: NSEvent) -> Bool {
        StatusButtonClickPolicy.isStatusButtonEvent(
            eventWindow: event.window,
            buttonWindow: mainStatusItem?.button?.window,
            mouseLocation: NSEvent.mouseLocation
        )
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

    private func actionsForCurrentPortfolioPopover() -> PortfolioMenuActions {
        PortfolioMenuActions(
            refresh: { [weak self] in
                Task { @MainActor in self?.portfolioActions.refresh() }
            },
            preferences: { [weak self] in
                Task { @MainActor in
                    self?.closeMainPopover()
                    self?.portfolioActions.preferences()
                }
            },
            quit: { [weak self] in
                Task { @MainActor in
                    self?.closeMainPopover()
                    self?.portfolioActions.quit()
                }
            },
            openApp: { [weak self] in
                Task { @MainActor in
                    self?.closeMainPopover()
                    self?.portfolioActions.openApp()
                }
            }
        )
    }

    private func closeMainPopover() {
        mainPopover?.performClose(nil)
        stopMainPopoverEventMonitors()
    }

    private func clampMainPopoverToVisibleFrame() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let popoverWindow = self.mainPopover?.contentViewController?.view.window,
                  let screen = popoverWindow.screen else {
                return
            }

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

@MainActor
class StockStatusItemController: NSObject, NSPopoverDelegate {

    // MARK: - Properties
    private let dataModel: DataModel
    private var realTimeTrade: RealTimeTrade
    let item: NSStatusItem
    private var cancellables = Set<AnyCancellable>()
    private var detailPopover: NSPopover?
    private var popoverGlobalMonitor: Any?
    private var popoverLocalMonitor: Any?
    private let popoverSize = NSSize(width: 330, height: 410)
    private let formattingService = MenuBarFormattingService()
    private var titleUpdateCounter = 0
    private var suspensionNotice: String?
    
    // MARK: - Initialization
    init(realTimeTrade: RealTimeTrade, dataModel: DataModel) {
        self.dataModel = dataModel
        self.realTimeTrade = realTimeTrade
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item.autosaveName = Self.autosaveName(for: realTimeTrade.sourceIdentity ?? realTimeTrade.trade.name)
        
        super.init()

        // CRITICAL: Ensure the status item is visible
        self.item.isVisible = true

        let symbolName = realTimeTrade.trade.name
        let hasButton = self.item.button != nil
        Task { await Logger.shared.debug("🔧 ITEM: Initializing status item for \(symbolName), button: \(hasButton)") }

        setupInitialState(with: realTimeTrade)
        setupPopover()
        setupDataBinding(for: realTimeTrade)
        updateDisplay(trade: realTimeTrade.trade, trading: realTimeTrade.realTimeInfo)

        let configuredSymbol = realTimeTrade.trade.name
        let isVisible = self.item.isVisible
        let title = self.item.button?.title ?? "nil"
        Task { await Logger.shared.debug("🔧 ITEM: Status item configured for \(configuredSymbol), visible: \(isVisible), title: \(title)") }
    }

    deinit {}

    private static func autosaveName(for symbol: String) -> String {
        let stableSymbol = symbol
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
        return StockbarAutosavePolicy.statusItemName("com.stockbar.ticker.\(stableSymbol)")
    }

    func update(realTimeTrade: RealTimeTrade) {
        guard self.realTimeTrade !== realTimeTrade else {
            updateDisplay(trade: realTimeTrade.trade, trading: realTimeTrade.realTimeInfo)
            return
        }

        self.realTimeTrade = realTimeTrade
        cancellables.removeAll()
        // Preserve the current formatted title while rebinding. Resetting to the
        // ticker-only fallback makes variable-width status items visibly shift
        // until the asynchronous formatting task completes.
        setupDataBinding(for: realTimeTrade)
        updateDisplay(trade: realTimeTrade.trade, trading: realTimeTrade.realTimeInfo)
    }
    
    // MARK: - Private Methods
    private func setupInitialState(with trade: RealTimeTrade) {
        let fallbackTitle = MenuBarSymbolPresentation.title(for: trade.trade.name)
        item.button?.title = fallbackTitle
        item.button?.attributedTitle = NSAttributedString(
            string: fallbackTitle,
            attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.menuBarFont(ofSize: 0)
            ]
        )
        item.button?.setButtonType(.momentaryPushIn)
    }

    private func setupPopover() {
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        // Match the portfolio status item: one completed click should open
        // the popover and a later outside click should dismiss it.
        button.sendAction(on: [.leftMouseUp])
    }
    
    private func setupDataBinding(for realTimeTrade: RealTimeTrade) {
        dataModel.$showColorCoding
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak realTimeTrade] _ in
                guard let self, let realTimeTrade else { return }
                self.updateDisplay(trade: realTimeTrade.trade, trading: realTimeTrade.realTimeInfo)
            }
            .store(in: &cancellables)

        // Listen to changes in trading info
        realTimeTrade.$realTimeInfo
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak realTimeTrade] trading in
                guard let self = self, let realTimeTrade = realTimeTrade else { return }
                self.updateDisplay(trade: realTimeTrade.trade, trading: trading)
            }
            .store(in: &cancellables)

        // Listen to changes in market indicator setting
        dataModel.$showMarketIndicators
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak realTimeTrade] _ in
                guard let self = self, let realTimeTrade = realTimeTrade else { return }
                // Re-update display when setting changes
                self.updateDisplay(trade: realTimeTrade.trade, trading: realTimeTrade.realTimeInfo)
            }
            .store(in: &cancellables)

        // Listen to changes in menu bar display settings
        dataModel.$menuBarDisplaySettings
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak realTimeTrade] _ in
                guard let self = self, let realTimeTrade = realTimeTrade else { return }
                // Re-update display when formatting settings change
                self.updateDisplay(trade: realTimeTrade.trade, trading: realTimeTrade.realTimeInfo)
            }
            .store(in: &cancellables)

        // Recalculate rolling 24-hour values as soon as chart history arrives.
        dataModel.historicalDataManager.$priceSnapshots
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self, weak realTimeTrade] _ in
                guard let self, let realTimeTrade else { return }
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

        updateTitle(
            trade: trade,
            displaySymbol: MenuBarSymbolPresentation.title(for: trade.name),
            data: data
        )
        let updateID = titleUpdateCounter

        Task { @MainActor in
            guard updateID == titleUpdateCounter else { return }
            updatePopover(trade: trade, data: data)
            if detailPopover?.isShown == true {
                refreshSuspensionNotice()
            }
        }
    }
    
    private func updateTitle(trade: Trade, displaySymbol: String, data: TradingData) {
        let displayCandidate = data.displayPrice.isFinite && data.displayPrice > 0 ? data.displayPrice : nil
        let currentCandidate = data.currentPrice.isFinite && data.currentPrice > 0 ? data.currentPrice : nil
        // Unknown stays NaN so the title shows "—" rather than a price of 0.00.
        let safeDisplay = displayCandidate ?? currentCandidate ?? Double.nan
        let changeSummary = rollingDayChangeSummary(trade: trade, data: data)

        // Use formatting service for title generation
        let settings = dataModel.menuBarDisplaySettings

        titleUpdateCounter += 1
        let updateId = titleUpdateCounter

        Task { @MainActor in
            let formatted = await formattingService.formatStockTitle(
                symbol: displaySymbol,
                price: safeDisplay,
                change: changeSummary.change,
                changePct: changeSummary.percent,
                dayPL: changeSummary.positionPnL,
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

            item.button?.alternateTitle = displaySymbol
            let kind = trade.isWatchlistOnly ? "Watchlist" : "Holding"
            item.button?.toolTip = "\(displaySymbol) — \(kind). Click for details."
            item.button?.setAccessibilityLabel(
                "\(displaySymbol), \(kind.lowercased()): \(formatted.string), \(StatusItemAccessibility.direction(of: changeSummary.change))"
            )
        }
    }
    
    private func buildMenuMetrics(trade: Trade, data: TradingData) -> MenuPopoverMetrics {
        let displayCandidate = data.displayPrice.isFinite && data.displayPrice > 0 ? data.displayPrice : nil
        let currentCandidate = data.currentPrice.isFinite && data.currentPrice > 0 ? data.currentPrice : nil
        let safeDisplay = displayCandidate ?? currentCandidate ?? 0
        let safeUnits = data.units.isFinite ? data.units : 0
        let safeAvgCost = data.avgCost.isFinite ? data.avgCost : 0
        let changeSummary = rollingDayChangeSummary(trade: trade, data: data)

        let marketValue = safeDisplay * safeUnits
        let positionCost = safeAvgCost * safeUnits
        let totalPL = marketValue - positionCost
        let totalPLPct = positionCost > 0 ? (totalPL / positionCost) * 100 : Double.nan

        let updatedText = MenuPopoverFormatter.updatedText(from: [data.lastUpdateTime])

        let exchangeName = SymbolMetadata.exchangeDisplayName(for: trade.name)

        return MenuPopoverMetrics(
            exchangeName: exchangeName,
            marketValue: safeDisplay > 0 ? marketValue : nil,
            totalPnL: totalPL.isFinite ? totalPL : nil,
            totalPnLPercent: totalPLPct.isFinite ? totalPLPct : nil,
            dayPnL: changeSummary.positionPnL.isFinite ? changeSummary.positionPnL : nil,
            dayPnLPercent: changeSummary.percent.isFinite ? changeSummary.percent : nil,
            priceChange: changeSummary.change.isFinite ? changeSummary.change : nil,
            priceChangePercent: changeSummary.percent.isFinite ? changeSummary.percent : nil,
            units: safeUnits,
            avgCost: safeAvgCost,
            currency: data.currency,
            updatedText: updatedText,
            canEditUnits: canEditUnits(for: realTimeTrade),
            suspensionNotice: suspensionNotice
        )
    }

    private func rollingDayChangeSummary(trade: Trade, data: TradingData) -> MenuPriceChangeSummary {
        let endDate = Date()
        let startDate = MenuChartTimeRange.day.startDate(from: endDate)
        let historicalPrices = dataModel.historicalDataManager
            .getPriceSnapshots(for: trade.name, from: startDate, to: endDate)
            .map(\.price)

        return MenuPriceChangeCalculator.rollingDaySummary(
            currentPrice: data.displayPrice,
            previousClose: data.previousPrice,
            units: data.units,
            historicalPrices: historicalPrices,
            symbol: trade.name
        )
    }

    @MainActor
    private func updatePopover(trade: Trade, data: TradingData) {
        guard detailPopover?.isShown == true else { return }
        let metrics = buildMenuMetrics(trade: trade, data: data)
        let chartView = MenuPriceChartView(
            symbol: trade.name,
            currentPrice: data.displayPrice,
            currency: data.currency,
            metrics: metrics,
            onUnitsSave: { [weak self] newUnits in
                self?.updateUnits(newUnits, for: trade)
            },
            onRetry: { [weak self] in self?.retrySuspendedSymbol() }
        )

        // Keep the existing AppKit popover window and controller alive while
        // refreshing its SwiftUI content. Replacing the content controller of a
        // transient popover can cause AppKit to dismiss it during live updates.
        if let hostingController = detailPopover?.contentViewController
            as? NSHostingController<MenuPriceChartView> {
            hostingController.rootView = chartView
        } else {
            detailPopover?.contentViewController = NSHostingController(rootView: chartView)
        }
    }

    private func updateUnits(_ newUnits: Double, for trade: Trade) {
        guard newUnits.isFinite, newUnits > 0, canEditUnits(for: realTimeTrade) else { return }
        // Store full precision: fractional broker shares must not be rounded.
        realTimeTrade.trade.position.unitSizeString = Trading212BrokerValueNormalizer.format(newUnits)
        dataModel.triggerTradeUpdate()
    }

    /// Units are editable only for local portfolio positions. Broker- and
    /// Folync-provided quantities stay authoritative and read-only.
    private func canEditUnits(for realTimeTrade: RealTimeTrade) -> Bool {
        !realTimeTrade.trade.isWatchlistOnly && !dataModel.positionFinancialFieldsReadOnly(for: realTimeTrade)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if detailPopover == nil {
            detailPopover = NSPopover()
            // Keep the popover open after the status-item click completes.
            // Explicit local/global monitors handle later outside clicks.
            detailPopover?.behavior = .applicationDefined
            detailPopover?.delegate = self
        }

        detailPopover?.contentSize = popoverSize
        detailPopover?.animates = false
        detailPopover?.appearance = StockbarAppearance.popoverAppearance()

        if detailPopover?.isShown == true {
            detailPopover?.performClose(sender)
            stopPopoverEventMonitors()
        } else {
            let data = currentTradingData()
            let metrics = buildMenuMetrics(trade: realTimeTrade.trade, data: data)

            let chartView = MenuPriceChartView(
                symbol: realTimeTrade.trade.name,
                currentPrice: data.displayPrice,
                currency: metrics.currency,
                metrics: metrics,
                onUnitsSave: { [weak self] newUnits in
                    guard let self = self else { return }
                    self.updateUnits(newUnits, for: self.realTimeTrade.trade)
                },
                onRetry: { [weak self] in self?.retrySuspendedSymbol() }
            )
            let hostingController = NSHostingController(rootView: chartView)
            // Let the popover grow for optional rows such as the suspension notice.
            hostingController.sizingOptions = .preferredContentSize
            detailPopover?.contentViewController = hostingController
            refreshSuspensionNotice()

            detailPopover?.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            startPopoverEventMonitors()

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let popoverWindow = self.detailPopover?.contentViewController?.view.window,
                      let screen = popoverWindow.screen else { return }

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

        // Clicks on this item's own status button are handled by its toggle action.
        popoverGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, !self.isStatusButtonEvent(event) else { return }
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
            if self.isStatusButtonEvent(event) {
                return event
            }

            if self.detailPopover?.isShown == true {
                self.detailPopover?.performClose(nil)
                self.stopPopoverEventMonitors()
            }
            return event
        }
    }

    private func isStatusButtonEvent(_ event: NSEvent) -> Bool {
        StatusButtonClickPolicy.isStatusButtonEvent(
            eventWindow: event.window,
            buttonWindow: item.button?.window,
            mouseLocation: NSEvent.mouseLocation
        )
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

    /// Reads circuit-breaker state and, if it changed, re-renders the open popover.
    private func refreshSuspensionNotice() {
        let symbol = realTimeTrade.trade.name
        Task { @MainActor [weak self] in
            guard let self else { return }
            let status = await self.dataModel.cacheCoordinator.getCacheStatus(for: symbol, at: Date())
            let notice: String?
            if case .suspended(let failures, let resumeIn) = status {
                let minutes = max(1, Int((resumeIn / 60).rounded(.up)))
                notice = "Updates paused after \(failures) failed attempts. Automatic retry in \(minutes) min."
            } else {
                notice = nil
            }
            guard notice != self.suspensionNotice else { return }
            self.suspensionNotice = notice
            self.updatePopover(trade: self.realTimeTrade.trade, data: self.currentTradingData())
        }
    }

    private func retrySuspendedSymbol() {
        let symbol = realTimeTrade.trade.name
        Task { @MainActor [weak self] in
            guard let self else { return }
            await Logger.shared.info("🔄 [StockStatusBar] Manually retrying suspended symbol: \(symbol)")
            await self.dataModel.cacheCoordinator.clearSuspension(for: symbol)
            self.suspensionNotice = nil
            self.updatePopover(trade: self.realTimeTrade.trade, data: self.currentTradingData())
            await self.dataModel.refreshSymbolsImmediately([symbol], reason: "manual retry", force: true)
            self.refreshSuspensionNotice()
        }
    }

    private func currentTradingData() -> TradingData {
        let info = realTimeTrade.realTimeInfo
        return TradingData(
            currentPrice: info.currentPrice,
            previousPrice: info.prevClosePrice,
            currency: info.currency ?? "USD",
            avgCost: realTimeTrade.trade.position.getNormalizedAvgCost(for: realTimeTrade.trade.name),
            units: realTimeTrade.trade.position.unitSize,
            timeInfo: info.getTimeInfo(),
            lastUpdateTime: info.lastUpdateTime,
            preMarketPrice: info.preMarketPrice,
            preMarketChange: info.preMarketChange,
            preMarketChangePercent: info.preMarketChangePercent,
            postMarketPrice: info.postMarketPrice,
            postMarketChange: info.postMarketChange,
            postMarketChangePercent: info.postMarketChangePercent,
            marketState: info.marketState
        )
    }
}
