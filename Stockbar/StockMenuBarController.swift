import Foundation
import Combine
import Cocoa
import SwiftUI

@MainActor
class StockMenuBarController: NSObject {
    // MARK: - Properties
    private var cancellables = Set<AnyCancellable>()
    private let statusBar: StockStatusBar
    private let data: DataModel
    private var mainWindowController: StockbarMainWindowController?
    private var lastSymbolMenuBarSyncSummary: String?
    
    private let logger = Logger.shared
    
    // MARK: - Initialization
    init(data: DataModel) {
        self.data = data
        self.statusBar = StockStatusBar(dataModel: data)
        super.init()
        refreshExternalDisplayState()
        configurePortfolioActions()
        // Timer management is now handled by DataModel/RefreshService
        setupDataBinding()
        setupNotifications()
        startExternalDisplayPolling()
    }
    
    // MARK: - Private Methods
    
    private func setupDataBinding() {
        self.data.$realTimeTrades
            .receive(on: DispatchQueue.main)
            .sink { [weak self] realTimeTrades in
                self?.syncSymbolItemsFromUserData(realTimeTrades: realTimeTrades)
            }
            .store(in: &cancellables)

        self.data.tradeContentPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                self.syncSymbolItemsFromUserData(realTimeTrades: self.data.realTimeTrades)
            }
            .store(in: &cancellables)

        self.data.$hideAllMenuBarItems
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.syncSymbolItemsFromUserData(realTimeTrades: self.data.realTimeTrades)
            }
            .store(in: &cancellables)

        self.data.$requireExternalDisplayForMenuBarStocks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.syncSymbolItemsFromUserData(realTimeTrades: self.data.realTimeTrades)
            }
            .store(in: &cancellables)

        self.data.$isExternalDisplayConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.syncSymbolItemsFromUserData(realTimeTrades: self.data.realTimeTrades)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .menuBarVisibilityChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.syncSymbolItemsFromUserData(realTimeTrades: self.data.realTimeTrades)
            }
            .store(in: &cancellables)
    }
    
    private func configurePortfolioActions() {
        statusBar.configurePortfolioActions(
            refresh: { [weak self] in
                Task { @MainActor in self?.refreshPortfolio() }
            },
            preferences: { [weak self] in
                Task { @MainActor in self?.showPreferences(nil) }
            },
            quit: { [weak self] in
                Task { @MainActor in self?.quitApp() }
            }
        )
    }
    
    private func syncSymbolItemsFromUserData(realTimeTrades: [RealTimeTrade]) {
        Task { await logger.debug("🔧 CONTROLLER: Syncing symbol items, count: \(realTimeTrades.count)") }
        let visibleTrades = realTimeTrades.filter { $0.trade.showInMenuBar }
        let isAllowed = data.shouldShowStockMenuBarItems

        statusBar.syncSymbolItems(
            with: visibleTrades,
            dataModel: data,
            isVisible: isAllowed
        )

        logSymbolMenuBarSyncSummary(
            visibleCount: isAllowed ? visibleTrades.count : 0,
            totalCount: realTimeTrades.count,
            isAllowed: isAllowed
        )

        guard isAllowed else {
            Task { await logger.debug("🔧 CONTROLLER: Stock menu bar items hidden by effective visibility policy") }
            return
        }

        Task { await logger.debug("🔧 CONTROLLER: Synced \(visibleTrades.count) of \(realTimeTrades.count) symbol items (filtered by visibility)") }
    }

    private func logSymbolMenuBarSyncSummary(visibleCount: Int, totalCount: Int, isAllowed: Bool) {
        let summary = [
            "allowed=\(isAllowed)",
            "visible=\(visibleCount)",
            "total=\(totalCount)",
            "externalRequired=\(data.requireExternalDisplayForMenuBarStocks)",
            "externalConnected=\(data.isExternalDisplayConnected)",
            "manualHidden=\(data.hideAllMenuBarItems)"
        ].joined(separator: " ")

        guard summary != lastSymbolMenuBarSyncSummary else { return }
        lastSymbolMenuBarSyncSummary = summary

        Task {
            await logger.info("MenuBar: Symbol ticker sync \(summary)")
        }
    }

    // MARK: - Actions
    
    private func quitApp() {
        NSApp.terminate(self)
    }
    
    @objc func showPreferences(_ sender: Any?) {
        showStockbarWindow(section: .settings)
    }

    @objc func showStockbarWindow(_ sender: Any?) {
        showStockbarWindow(section: .holdings)
    }

    func showStockbarWindow(section: StockbarMainSection) {
        if mainWindowController == nil {
            mainWindowController = StockbarMainWindowController(dataModel: data)
        }

        mainWindowController?.showWindow(section: section)
    }
    
    private func refreshPortfolio() {
        Task { await data.refreshAllTrades() }
    }
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshIntervalChanged(_:)),
            name: .refreshIntervalChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshRequested(_:)),
            name: .refreshRequested,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

    }
    
    @objc private func refreshIntervalChanged(_ notification: Notification) {
        // RefreshService in DataModel handles the timer update automatically via property observer
        Task { await logger.info("🔧 MenuBar: Refresh interval changed notification received") }
    }

    @objc private func refreshRequested(_ notification: Notification) {
        Task { await data.refreshAllTrades() }
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        refreshExternalDisplayState()
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        refreshExternalDisplayState()
    }

    private func refreshExternalDisplayState() {
        let isConnected = ExternalDisplayDetector.isExternalDisplayConnected()
        let previousValue = data.isExternalDisplayConnected
        data.isExternalDisplayConnected = isConnected
        syncSymbolItemsFromUserData(realTimeTrades: data.realTimeTrades)

        if previousValue != isConnected {
            Task {
                await logger.info(
                    "MenuBar: External display state changed: \(isConnected ? "connected" : "not connected")"
                )
            }
        }
    }

    private func startExternalDisplayPolling() {
        Timer.publish(every: 10, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshExternalDisplayState()
            }
            .store(in: &cancellables)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
}

enum ExternalDisplayDetector {
    static func isExternalDisplayConnected(screens: [NSScreen] = NSScreen.screens) -> Bool {
        if let onlineDisplayIDs = onlineDisplayIDs(), !onlineDisplayIDs.isEmpty {
            return hasExternalDisplay(displayIDs: onlineDisplayIDs)
        }

        var resolvedDisplayCount = 0
        var hasExternalDisplay = false

        for screen in screens {
            guard let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }

            resolvedDisplayCount += 1
            let displayID = CGDirectDisplayID(displayNumber.uint32Value)
            if CGDisplayIsBuiltin(displayID) == 0 {
                hasExternalDisplay = true
            }
        }

        guard resolvedDisplayCount == screens.count else {
            return screens.count > 1
        }

        return hasExternalDisplay
    }

    static func hasExternalDisplay(displayIDs: [CGDirectDisplayID]) -> Bool {
        hasExternalDisplay(builtinStates: displayIDs.map { CGDisplayIsBuiltin($0) != 0 })
    }

    static func hasExternalDisplay(builtinStates: [Bool]) -> Bool {
        builtinStates.contains(false)
    }

    private static func onlineDisplayIDs(maxDisplays: UInt32 = 32) -> [CGDirectDisplayID]? {
        var displayCount: UInt32 = 0
        let countResult = CGGetOnlineDisplayList(0, nil, &displayCount)
        guard countResult == .success, displayCount > 0 else {
            return nil
        }

        let capacity = min(displayCount, maxDisplays)
        var displayIDs = Array(repeating: CGDirectDisplayID(0), count: Int(capacity))
        var resolvedDisplayCount: UInt32 = 0
        let listResult = CGGetOnlineDisplayList(capacity, &displayIDs, &resolvedDisplayCount)
        guard listResult == .success else {
            return nil
        }

        return Array(displayIDs.prefix(Int(resolvedDisplayCount)))
    }
}
