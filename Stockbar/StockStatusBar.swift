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
    @MainActor static func isStatusButtonEvent(eventWindow: NSWindow?, buttonWindow: NSWindow?, mouseLocation: NSPoint) -> Bool {
        guard let buttonWindow else { return false }
        if let eventWindow { return eventWindow === buttonWindow }
        return buttonWindow.frame.contains(mouseLocation)
    }
}

/// The ways a status-item popover closes besides a click elsewhere.
@MainActor
enum PopoverDismissal {
    static func isEscape(_ event: NSEvent) -> Bool {
        event.keyCode == 53 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
    }

    /// A popover left open on another Space would be stranded there.
    static func observeSpaceChange(_ handler: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    static func stopObserving(_ observer: inout NSObjectProtocol?) {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }
}

/// Decides when a menu-bar price is old enough to be marked as such.
enum MenuBarStaleness {
    /// Quotes are refetched at least every `refreshInterval`, or every half
    /// hour while the market is closed, so a healthy price is never much older
    /// than that. Beyond two and a half times it, refreshes are failing.
    static func isStale(lastUpdate: Date?, now: Date, refreshInterval: TimeInterval) -> Bool {
        guard let lastUpdate else { return false }
        let expected = max(refreshInterval, RefreshService.closedMarketFreshness)
        return now.timeIntervalSince(lastUpdate) > expected * 2.5
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
    private var popoverSpaceObserver: NSObjectProtocol?
    private var stalenessTimer: Timer?
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

        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.symbolStatusItems.forEach { $0.refreshStaleness() }
            }
        }
        timer.tolerance = 20
        stalenessTimer = timer

        MenuBarContentUpdates.effectiveContentPublisher(dataModel.tradeContentPublisher)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self = self else { return }
                self.updateMainStatusItem(with: self.dataModel.realTimeTrades)
            }
            .store(in: &cancellables)

        ObservationPublisher.values(dataModel, \.portfolioMenuBarDisplaySettings)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateMainStatusItem(with: self.dataModel.realTimeTrades)
            }
            .store(in: &cancellables)

        ObservationPublisher.values(dataModel, \.showColorCoding)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateMainStatusItem(with: self.dataModel.realTimeTrades)
            }
            .store(in: &cancellables)

        ObservationPublisher.values(dataModel, \.preferredCurrency)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateMainStatusItem(with: self.dataModel.realTimeTrades)
            }
            .store(in: &cancellables)

        ObservationPublisher.values(dataModel.historicalDataManager, \.priceSnapshots)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateMainStatusItem(with: self.dataModel.realTimeTrades)
            }
            .store(in: &cancellables)

        ObservationPublisher.values(dataModel.historicalDataManager, \.historicalPortfolioSnapshots)
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
    
    
    func syncSymbolItems(with realTimeTrades: [RealTimeTrade], dataModel: DataModel, isVisible: Bool = true) {
        let desiredKeys = Set(realTimeTrades.map { symbolItemKey(for: $0) })

        for (key, controller) in symbolItemByKey where !desiredKeys.contains(key) {
            controller.tearDown()
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
                existing.setVisible(isVisible)
                orderedControllers.append(existing)
            } else {
                let controller = StockStatusItemController(realTimeTrade: trade, dataModel: dataModel)
                controller.setVisible(isVisible)
                symbolItemByKey[key] = controller
                orderedControllers.append(controller)
            }
        }

        symbolStatusItems = orderedControllers
        logSymbolItemState()
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
    
    
    private func updateMainStatusItem(with trades: [RealTimeTrade]) {
        guard let button = mainStatusItem?.button else { return }
        let settings = dataModel.portfolioMenuBarDisplaySettings
        guard settings.isEnabled else {
            showPlaceholderTitle(on: button)
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
            showPlaceholderTitle(on: button)
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
        let shownDayGain = MenuBarFormattingService.roundedForDisplay(
            dayGain, decimalPlaces: max(0, min(settings.decimalPlaces, 4))
        )
        if !dataModel.showColorCoding || shownDayGain == 0 {
            dayColor = .labelColor
        } else {
            dayColor = shownDayGain > 0 ? .systemGreen : .systemRed
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: MenuBarFormattingService.titleFont,
            .foregroundColor: dayColor
        ]

        let attributed = NSAttributedString(string: combined, attributes: attributes)
        button.toolTip = "Portfolio value and today's change (\(summary.currency)). Click for details."
        // Colour must not be the only signal for direction.
        button.setAccessibilityLabel("Portfolio \(combined), today \(StatusItemAccessibility.direction(of: shownDayGain))")
        button.attributedTitle = attributed
        button.attributedAlternateTitle = attributed
    }

    /// The plain "Stockbar" title. The tooltip, alternate title and accessibility
    /// label are reset too, or they would keep announcing the last portfolio
    /// value after the user turned the display off.
    private func showPlaceholderTitle(on button: NSStatusBarButton) {
        button.title = "Stockbar"
        button.attributedTitle = NSAttributedString(string: "Stockbar")
        button.attributedAlternateTitle = NSAttributedString(string: "Stockbar")
        button.toolTip = "Stockbar. Click for details."
        button.setAccessibilityLabel("Stockbar")
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
        // The popover applies the same test. With only an hour or two of
        // history the change would cover that hour, not the day, so the title
        // falls back to the previous-close figure as the popover does.
        guard PortfolioMenuChartDataBuilder.coversRange(chartPoints, range: range, now: now) else { return nil }
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
        
        popoverLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.mainPopover?.isShown == true,
                  let popoverWindow = self.mainPopover?.contentViewController?.view.window else {
                return event
            }
            if event.type == .keyDown {
                guard PopoverDismissal.isEscape(event) else { return event }
                self.mainPopover?.performClose(nil)
                self.stopMainPopoverEventMonitors()
                return nil
            }
            if event.window != popoverWindow, !self.isMainStatusButtonEvent(event) {
                self.mainPopover?.performClose(nil)
                self.stopMainPopoverEventMonitors()
            }
            return event
        }

        popoverSpaceObserver = PopoverDismissal.observeSpaceChange { [weak self] in
            guard let self, self.mainPopover?.isShown == true else { return }
            self.mainPopover?.performClose(nil)
            self.stopMainPopoverEventMonitors()
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
        PopoverDismissal.stopObserving(&popoverSpaceObserver)
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
    private var popoverSpaceObserver: NSObjectProtocol?
    private let popoverSize = NSSize(width: 330, height: 410)
    private let formattingService = MenuBarFormattingService()
    private var titleUpdateCounter = 0
    private var suspensionNotice: String?
    /// When the price on the title was fetched, and the tooltip and spoken
    /// label that go with it while it is current.
    private var titlePriceDate: Date?
    private var displayUpdatePending = false
    private var displayUpdateSkipped = false
    private var currentToolTip = ""
    private var currentAccessibilityLabel = ""
    
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

    /// Closes the popover and drops the event monitors and subscriptions of an
    /// item that is being removed; otherwise they outlive it.
    func tearDown() {
        detailPopover?.performClose(nil)
        stopPopoverEventMonitors()
        cancellables.removeAll()
    }

    private static func autosaveName(for symbol: String) -> String {
        let stableSymbol = symbol
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
        return StockbarAutosavePolicy.statusItemName("com.stockbar.ticker.\(stableSymbol)")
    }

    func update(realTimeTrade: RealTimeTrade) {
        guard self.realTimeTrade !== realTimeTrade else {
            scheduleDisplayUpdate()
            return
        }

        self.realTimeTrade = realTimeTrade
        cancellables.removeAll()
        // Preserve the current formatted title while rebinding. Resetting to the
        // ticker-only fallback makes variable-width status items visibly shift
        // until the asynchronous formatting task completes.
        setupDataBinding(for: realTimeTrade)
        scheduleDisplayUpdate()
    }

    func setVisible(_ visible: Bool) {
        guard item.isVisible != visible else { return }
        item.isVisible = visible
        // A hidden item skips its updates; catch up when it is shown again.
        if visible, displayUpdateSkipped { scheduleDisplayUpdate() }
    }

    /// One refresh changes the quote, the stored history and the trade list,
    /// each of which asked for its own redraw. They now share one, made after
    /// all three have landed.
    private func scheduleDisplayUpdate() {
        guard !displayUpdatePending else { return }
        displayUpdatePending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.displayUpdatePending = false
            guard self.item.isVisible || self.detailPopover?.isShown == true else {
                self.displayUpdateSkipped = true
                return
            }
            self.displayUpdateSkipped = false
            self.updateDisplay(trade: self.realTimeTrade.trade, trading: self.realTimeTrade.realTimeInfo)
        }
    }
    
    // MARK: - Private Methods
    private func setupInitialState(with trade: RealTimeTrade) {
        let fallbackTitle = MenuBarSymbolPresentation.title(for: trade.trade.name)
        item.button?.title = fallbackTitle
        item.button?.attributedTitle = NSAttributedString(
            string: fallbackTitle,
            attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: MenuBarFormattingService.titleFont
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
        ObservationPublisher.values(dataModel, \.showColorCoding)
            .dropFirst()
            .sink { [weak self, weak realTimeTrade] _ in
                guard let self, realTimeTrade != nil else { return }
                self.scheduleDisplayUpdate()
            }
            .store(in: &cancellables)

        // Listen to changes in trading info
        ObservationPublisher.values(realTimeTrade, \.realTimeInfo)
            .dropFirst()
            .sink { [weak self, weak realTimeTrade] _ in
                guard let self, realTimeTrade != nil else { return }
                self.scheduleDisplayUpdate()
            }
            .store(in: &cancellables)

        // Listen to changes in market indicator setting
        ObservationPublisher.values(dataModel, \.showMarketIndicators)
            .dropFirst()
            .sink { [weak self, weak realTimeTrade] _ in
                guard let self, realTimeTrade != nil else { return }
                self.scheduleDisplayUpdate()
            }
            .store(in: &cancellables)

        // Listen to changes in menu bar display settings
        ObservationPublisher.values(dataModel, \.menuBarDisplaySettings)
            .dropFirst()
            .sink { [weak self, weak realTimeTrade] _ in
                guard let self, realTimeTrade != nil else { return }
                self.scheduleDisplayUpdate()
            }
            .store(in: &cancellables)

        // Recalculate rolling 24-hour values as soon as chart history arrives.
        ObservationPublisher.values(dataModel.historicalDataManager, \.priceSnapshots)
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self, weak realTimeTrade] _ in
                guard let self, realTimeTrade != nil else { return }
                self.scheduleDisplayUpdate()
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
            let formatted = formattingService.formatStockTitle(
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

            // Compare the finished title, prefix included, so an unchanged
            // watchlist item is not redrawn on every refresh.
            let title: NSAttributedString
            if trade.isWatchlistOnly {
                let combined = NSMutableAttributedString(
                    string: "👁 ",
                    attributes: [
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .font: MenuBarFormattingService.titleFont
                    ]
                )
                combined.append(formatted)
                title = combined
            } else {
                title = formatted
            }
            if item.button?.attributedTitle != title {
                item.button?.attributedTitle = title
            }

            item.button?.alternateTitle = displaySymbol
            let kind = trade.isWatchlistOnly ? "Watchlist" : "Holding"
            currentToolTip = "\(displaySymbol) — \(kind). Click for details."
            currentAccessibilityLabel =
                "\(displaySymbol), \(kind.lowercased()): \(formatted.string), \(StatusItemAccessibility.direction(of: changeSummary.change))"
            titlePriceDate = data.lastUpdateTime.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
            refreshStaleness()
        }
    }

    /// Dims a title whose price has stopped updating and says how old it is,
    /// so yesterday's price is not read as the current one. Called on every
    /// title update and once a minute, since a failing refresh sends no update.
    func refreshStaleness(now: Date = Date()) {
        guard let button = item.button else { return }
        let stale = MenuBarStaleness.isStale(
            lastUpdate: titlePriceDate, now: now, refreshInterval: dataModel.refreshInterval
        )
        let alpha: CGFloat = stale ? 0.55 : 1
        if button.alphaValue != alpha { button.alphaValue = alpha }

        var toolTip = currentToolTip
        var label = currentAccessibilityLabel
        if stale, let titlePriceDate {
            let age = titlePriceDate.formatted(.relative(presentation: .named))
            toolTip += " Price last updated \(age)."
            label += ", price last updated \(age)"
        }
        if button.toolTip != toolTip { button.toolTip = toolTip }
        if button.accessibilityLabel() != label { button.setAccessibilityLabel(label) }
    }
    
    private func buildMenuMetrics(trade: Trade, data: TradingData) -> MenuPopoverMetrics {
        let safeUnits = data.units.isFinite ? data.units : 0
        let safeAvgCost = data.avgCost.isFinite ? data.avgCost : 0
        let changeSummary = rollingDayChangeSummary(trade: trade, data: data)

        // The same figures as the Holdings table: Folync's or the broker's own
        // when the position is linked, a local calculation otherwise.
        let positionValue = dataModel.calculatePositionValue(for: realTimeTrade)
        let profitLoss = dataModel.calculatePositionProfitLoss(for: realTimeTrade)
        let marketValue = positionValue.amount
        let totalPL = profitLoss.totalAmount
        let totalPLPct = profitLoss.totalPercent

        let updatedText = MenuPopoverFormatter.updatedText(from: [data.lastUpdateTime])

        let exchangeName = SymbolMetadata.exchangeDisplayName(for: trade.name)

        return MenuPopoverMetrics(
            exchangeName: exchangeName,
            marketValue: marketValue.isFinite ? marketValue : nil,
            totalPnL: totalPL.isFinite ? totalPL : nil,
            totalPnLPercent: totalPLPct.isFinite ? totalPLPct : nil,
            dayPnL: changeSummary.positionPnL.isFinite ? changeSummary.positionPnL : nil,
            dayPnLPercent: changeSummary.percent.isFinite ? changeSummary.percent : nil,
            priceChange: changeSummary.change.isFinite ? changeSummary.change : nil,
            priceChangePercent: changeSummary.percent.isFinite ? changeSummary.percent : nil,
            units: safeUnits,
            avgCost: safeAvgCost,
            currency: data.currency,
            valueCurrency: positionValue.currency.isEmpty ? nil : positionValue.currency,
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

        popoverLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                guard PopoverDismissal.isEscape(event), self.detailPopover?.isShown == true else { return event }
                self.detailPopover?.performClose(nil)
                self.stopPopoverEventMonitors()
                return nil
            }
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

        popoverSpaceObserver = PopoverDismissal.observeSpaceChange { [weak self] in
            guard let self, self.detailPopover?.isShown == true else { return }
            self.detailPopover?.performClose(nil)
            self.stopPopoverEventMonitors()
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
        PopoverDismissal.stopObserving(&popoverSpaceObserver)
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
