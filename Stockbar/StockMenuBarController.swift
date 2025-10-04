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
    private var portfolioSummaryItem: NSMenuItem?

    private lazy var mainMenuItems: [NSMenuItem] = {
        // Create portfolio summary item
        let summaryItem = NSMenuItem(title: "Portfolio Summary", action: nil, keyEquivalent: "")
        summaryItem.isEnabled = false // Make it non-clickable (header style)
        self.portfolioSummaryItem = summaryItem

        return [
            summaryItem,
            NSMenuItem.separator(),
            NSMenuItem(title: "Refresh", action: #selector(refreshButtonClicked(_:)), keyEquivalent: ""),
            NSMenuItem.separator(),
            NSMenuItem(title: "Preferences", action: #selector(showPreferences(_:)), keyEquivalent: ","),
            NSMenuItem(title: "Exit", action: #selector(quitApp), keyEquivalent: "q")
        ]
    }()
    
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
        self.timer = Timer.scheduledTimer(withTimeInterval: data.refreshInterval, repeats: true) { [weak self] _ in
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
                self?.updatePortfolioSummary()
            }
    }
    
    func constructMainItem() {
        for item in mainMenuItems {
            item.target = self
        }
        self.statusBar.constructMainItemMenu(items: mainMenuItems)
    }
    
    private func updateSymbolItemsFromUserData(realTimeTrades: [RealTimeTrade]) {
        print("🔧 CONTROLLER: Updating symbol items, count: \(realTimeTrades.count)")
        print("🔧 CONTROLLER: Symbols: \(realTimeTrades.map { $0.trade.name }.joined(separator: ", "))")

        statusBar.removeAllSymbolItems()
        for trade in realTimeTrades {
            statusBar.constructSymbolItem(from: trade, dataModel: data)
        }

        print("🔧 CONTROLLER: Finished creating \(realTimeTrades.count) symbol items")
    }

    private func updatePortfolioSummary() {
        guard let summaryItem = portfolioSummaryItem else { return }

        // Calculate portfolio metrics
        let netGains = data.calculateNetGains()
        let netValue = data.calculateNetValue()

        // Calculate daily P&L
        var dailyPnL: Double = 0
        for trade in data.realTimeTrades {
            let info = trade.realTimeInfo
            if !info.currentPrice.isNaN && !info.prevClosePrice.isNaN {
                dailyPnL += (info.currentPrice - info.prevClosePrice) * trade.trade.position.unitSize
            }
        }

        // Format values
        let gainsString = String(format: "%+.2f", netGains.amount)
        let valueString = String(format: "%.2f", netValue.amount)
        let dailyString = String(format: "%+.2f", dailyPnL)

        // Build attributed string with colors
        let title = NSMutableAttributedString()

        // Portfolio Summary header
        let headerAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor
        ]
        title.append(NSAttributedString(string: "Portfolio Summary\n", attributes: headerAttributes))

        // Total Value
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        title.append(NSAttributedString(string: "Value: ", attributes: labelAttributes))

        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor
        ]
        title.append(NSAttributedString(string: "\(netGains.currency) \(valueString)", attributes: valueAttributes))

        // Daily P&L
        title.append(NSAttributedString(string: "  |  Daily: ", attributes: labelAttributes))
        let dailyColor = dailyPnL >= 0 ? NSColor.systemGreen : NSColor.systemRed
        let dailyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: data.showColorCoding ? dailyColor : NSColor.labelColor
        ]
        title.append(NSAttributedString(string: "\(netGains.currency) \(dailyString)", attributes: dailyAttributes))

        // Total Gains
        title.append(NSAttributedString(string: "  |  Gains: ", attributes: labelAttributes))
        let gainsColor = netGains.amount >= 0 ? NSColor.systemGreen : NSColor.systemRed
        let gainsAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: data.showColorCoding ? gainsColor : NSColor.labelColor
        ]
        title.append(NSAttributedString(string: "\(netGains.currency) \(gainsString)", attributes: gainsAttributes))

        summaryItem.attributedTitle = title
    }


    // MARK: - Actions
    
    @objc private func quitApp() {
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
