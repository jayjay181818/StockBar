import Cocoa

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var stockMenuBarController: StockMenuBarController?
    private var dataModel: DataModel!

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        guard !ProcessInfo.processInfo.isRunningUnitTests else {
            return
        }

        _ = CoreDataStack.shared.persistentContainer
        dataModel = DataModel()
        setupMainMenu()

        // Perform legacy cleanup on first launch
        LegacyCleanupService.shared.performCleanupIfNeeded()

        // Perform Core Data migration before initializing the UI
        Task {
            do {
                try await DataMigrationService.shared.performFullMigration()
                await Logger.shared.info("AppDelegate: Core Data migration completed successfully")
            } catch {
                await Logger.shared.error("AppDelegate: Core Data migration failed: \(error)")
            }
        }

        stockMenuBarController = StockMenuBarController(data: dataModel)
        stockMenuBarController?.showStockbarWindow(nil)

        // Check Python dependencies on first launch
        Task {
            await checkPythonDependencies()
        }

        // Schedule automatic daily backup
        Task {
            await scheduleAutomaticBackup()
        }

        Task {
            await RuntimeIssueMonitor.shared.start()
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            presentCoreDataRecoveryNoticeIfNeeded()
        }
    }

    // Handle dock icon clicks - reopen the main Stockbar window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            stockMenuBarController?.showStockbarWindow(nil)
        } else {
            // Windows exist, bring them to front
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    /// Performs automatic backup if needed (once per day)
    @MainActor
    private func scheduleAutomaticBackup() async {
        guard await dataModel.waitForInitialTradeLoad() else {
            await Logger.shared.warning("Automatic backup skipped because portfolio load did not complete")
            return
        }

        let portfolioTrades = dataModel.realTimeTrades.filter { trade in
            !trade.trade.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !SymbolMetadata.isBenchmarkSymbol(trade.trade.name)
        }
        guard !portfolioTrades.isEmpty else {
            await Logger.shared.debug("Automatic backup skipped because no portfolio stocks are loaded")
            return
        }

        let success = await BackupService.shared.performAutomaticBackupIfNeeded(trades: dataModel.realTimeTrades)
        if success {
            await Logger.shared.info("Automatic backup completed successfully")
        } else {
            await Logger.shared.debug("Automatic backup skipped (already done today or failed)")
        }
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        // Clean up if needed
    }

    @objc func showPreferences(_ sender: Any?) {
        stockMenuBarController?.showPreferences(sender)
    }

    @objc func showStockbarWindow(_ sender: Any?) {
        stockMenuBarController?.showStockbarWindow(sender)
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()

        mainMenu.addItem(appMenuItem)
        appMenuItem.submenu = appMenu

        let openItem = NSMenuItem(
            title: "Open Stockbar",
            action: #selector(showStockbarWindow(_:)),
            keyEquivalent: "o"
        )
        openItem.target = self
        appMenu.addItem(openItem)

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showPreferences(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)

        appMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit Stockbar",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        appMenu.addItem(quitItem)

        NSApp.mainMenu = mainMenu
    }

    private func presentCoreDataRecoveryNoticeIfNeeded() {
        guard let notice = CoreDataRecoveryNotice(state: CoreDataStack.shared.storeLoadState) else {
            return
        }

        let alert = NSAlert()
        alert.messageText = notice.title
        alert.informativeText = notice.message
        alert.alertStyle = .critical
        if notice.backupDirectory != nil {
            alert.addButton(withTitle: "Open Backup Folder")
        }
        alert.addButton(withTitle: "OK")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn,
              let backupDirectory = notice.backupDirectory else {
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([backupDirectory])
    }

    // MARK: - Python Dependency Management

    /// Checks if required Python dependencies are installed on first launch
    @MainActor
    private func checkPythonDependencies() async {
        // Check if we've already shown the dependency check
        let hasChecked = UserDefaults.standard.bool(forKey: "hasCheckedPythonDependencies")
        guard !hasChecked else { return }

        await Logger.shared.info("🐍 Checking Python dependencies...")

        // Check if yfinance is available
        let isYfinanceAvailable = await checkYfinanceInstalled()

        if !isYfinanceAvailable {
            await Logger.shared.warning("⚠️ yfinance not found - showing installation instructions")
            showPythonDependencyAlert()
        } else {
            await Logger.shared.info("✅ Python dependencies verified")
        }

        // Mark as checked
        UserDefaults.standard.set(true, forKey: "hasCheckedPythonDependencies")
    }

    /// Checks if yfinance is installed by running a simple import test
    private func checkYfinanceInstalled() async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import yfinance; print('OK')"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8), output.contains("OK") {
                return true
            }
        } catch {
            await Logger.shared.error("Failed to check yfinance: \(error)")
        }

        return false
    }

    /// Shows alert with Python dependency installation instructions
    @MainActor
    private func showPythonDependencyAlert() {
        let alert = NSAlert()
        alert.messageText = "Python Dependencies Required"
        alert.informativeText = """
        Stockbar requires the 'yfinance' Python package to fetch stock data.

        To install it, open Terminal and run:
        pip3 install yfinance

        Or install all requirements:
        pip3 install -r requirements.txt

        (The requirements.txt file is in the app bundle)

        Minimum Python version: 3.8+
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Open Terminal")
        alert.addButton(withTitle: "Dismiss")

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn: // Copy Command
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString("pip3 install yfinance", forType: .string)

            // Show confirmation
            let confirmAlert = NSAlert()
            confirmAlert.messageText = "Command Copied"
            confirmAlert.informativeText = "The installation command has been copied to your clipboard. Paste it into Terminal to install."
            confirmAlert.alertStyle = .informational
            confirmAlert.addButton(withTitle: "OK")
            confirmAlert.runModal()

        case .alertSecondButtonReturn: // Open Terminal
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))

        default: // Dismiss
            break
        }
    }
}

private extension ProcessInfo {
    var isRunningUnitTests: Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }
}
