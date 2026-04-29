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
    private var preferenceWindowController: PreferenceWindowController?
    
    private let logger = Logger.shared
    
    // MARK: - Initialization
    init(data: DataModel) {
        self.data = data
        self.statusBar = StockStatusBar(dataModel: data)
        super.init()
        configurePortfolioActions()
        // Timer management is now handled by DataModel/RefreshService
        setupDataBinding()
        setupNotifications()
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
        
        guard !data.hideAllMenuBarItems else {
            statusBar.removeAllSymbolItems()
            Task { await logger.debug("🔧 CONTROLLER: All menu bar items hidden by user preference") }
            return
        }
        
        let visibleTrades = realTimeTrades.filter { $0.trade.showInMenuBar }
        statusBar.syncSymbolItems(with: visibleTrades, dataModel: data)

        Task { await logger.debug("🔧 CONTROLLER: Synced \(visibleTrades.count) of \(realTimeTrades.count) symbol items (filtered by visibility)") }
    }

    // MARK: - Actions
    
    private func quitApp() {
        NSApp.terminate(self)
    }
    
    @objc func showPreferences(_ sender: Any?) {
        // Close any existing preferences window first
        preferenceWindowController?.close()
        preferenceWindowController = nil
        
        // Always create a fresh window controller to avoid SwiftUI hosting issues
        // This ensures the window content is properly initialized each time
        preferenceWindowController = PreferenceWindowController(dataModel: data)
        
        // Show the window
        preferenceWindowController?.showWindow()
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
    }
    
    @objc private func refreshIntervalChanged(_ notification: Notification) {
        // RefreshService in DataModel handles the timer update automatically via property observer
        Task { await logger.info("🔧 MenuBar: Refresh interval changed notification received") }
    }

    @objc private func refreshRequested(_ notification: Notification) {
        Task { await data.refreshAllTrades() }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
}
