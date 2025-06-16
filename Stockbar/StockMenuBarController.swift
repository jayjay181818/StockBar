import Foundation
import Combine
import Cocoa

class StockMenuBarController {
    // MARK: - Properties
    private var cancellables: AnyCancellable?
    private let statusBar: StockStatusBar
    private let data: DataModel
    private var preferenceWindowController: PreferenceWindowController?
    private lazy var timer = Timer()
    private lazy var mainMenuItems = [
        NSMenuItem(title: "Refresh", action: #selector(refreshButtonClicked(_:)), keyEquivalent: ""),
        NSMenuItem.separator(),
        NSMenuItem(title: "Preferences", action: #selector(showPreferences), keyEquivalent: ","),
        NSMenuItem(title: "Exit", action: #selector(quitApp), keyEquivalent: "q")
    ]
    
    // MARK: - Initialization
    init(data: DataModel) {
        self.data = data
        self.statusBar = StockStatusBar(dataModel: data)
        constructMainItem()
        setupTimer()
        setupDataBinding()
        setupNotifications()
    }
    
    // MARK: - Private Methods
    private func setupTimer() {
        Task { await data.refreshAllTrades() } // initial fetch
        self.timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            Task {
                await self?.data.refreshAllTrades()
            }
        }
    }
    
    private func setupDataBinding() {
        self.cancellables = self.data.$realTimeTrades
            .receive(on: DispatchQueue.main)
            .sink { [weak self] realTimeTrades in
                self?.updateSymbolItemsFromUserData(realTimeTrades: realTimeTrades)
            }
    }
    
    func constructMainItem() {
        for item in mainMenuItems {
            item.target = self
        }
        self.statusBar.constructMainItemMenu(items: mainMenuItems)
    }
    
    private func updateSymbolItemsFromUserData(realTimeTrades: [RealTimeTrade]) {
        statusBar.removeAllSymbolItems()
        for trade in realTimeTrades {
            statusBar.constructSymbolItem(from: trade, dataModel: data)
        }
    }
    
    
    // MARK: - Actions
    
    @objc private func quitApp() {
        NSApp.terminate(self)
    }
    
    @objc private func showPreferences(_ sender: Any?) {
        // Close any existing preferences window first
        preferenceWindowController?.close()
        preferenceWindowController = nil
        
        // Always create a fresh window controller to avoid SwiftUI hosting issues
        // This ensures the window content is properly initialized each time
        preferenceWindowController = PreferenceWindowController(dataModel: data)
        
        // Show the window
        preferenceWindowController?.showWindow()
    }
    
    @objc private func refreshButtonClicked(_ sender: Any?) {
        Task { await data.refreshAllTrades() }
    }
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshIntervalChanged(_:)),
            name: .refreshIntervalChanged,
            object: nil
        )
    }
    
    @objc private func refreshIntervalChanged(_ notification: Notification) {
        guard let newInterval = notification.object as? TimeInterval else { return }
        
        // Restart timer with new interval
        timer.invalidate()
        self.timer = Timer.scheduledTimer(withTimeInterval: newInterval, repeats: true) { [weak self] _ in
            Task {
                await self?.data.refreshAllTrades()
            }
        }
        
        Task { await Logger.shared.info("🔧 MenuBar: Restarted timer with \(newInterval) second interval") }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
}
