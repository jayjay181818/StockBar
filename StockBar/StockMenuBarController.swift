import Foundation
import Combine
import Cocoa

class StockMenuBarController {
    // MARK: - Properties
    private var cancellables: AnyCancellable?
    private let statusBar: StockStatusBar
    private let data: DataModel
    private var prefPopover: PreferencePopover
    private lazy var timer = Timer()
    private lazy var mainMenuItems = [
        NSMenuItem(title: "Refresh", action: #selector(sendAllTradesToSubscriber), keyEquivalent: ""),
        NSMenuItem.separator(),
        NSMenuItem(title: "Preference", action: #selector(togglePopover), keyEquivalent: ""),
        NSMenuItem(title: "Exit", action: #selector(quitApp), keyEquivalent: "q")
    ]
    
    // MARK: - Initialization
    init(data: DataModel) {
        self.data = data
        self.statusBar = StockStatusBar(dataModel: data)
        self.prefPopover = PreferencePopover(data: data)
        constructMainItem()
        setupTimer()
        setupDataBinding()
    }
    
    // MARK: - Private Methods
    private func setupTimer() {
        self.timer = Timer.scheduledTimer(
            timeInterval: 60,
            target: self,
            selector: #selector(sendAllTradesToSubscriber),
            userInfo: nil,
            repeats: true
        )
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
    @objc private func sendAllTradesToSubscriber() {
        self.data.realTimeTrades.forEach { $0.sendTradeToPublisher() }
    }
    
    @objc private func quitApp() {
        NSApp.terminate(self)
    }
    
    @objc func togglePopover(_ sender: Any?) {
        showPopover(sender: sender)
    }
    
    func showPopover(sender: Any?) {
        if let button = self.statusBar.mainItem()?.button {
            prefPopover.show(relativeTo: button.bounds, of: button, preferredEdge: NSRectEdge.minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}