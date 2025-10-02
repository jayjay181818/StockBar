import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private var stockMenuBarController: StockMenuBarController?
    private let dataModel = DataModel()
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
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

        // Check Python dependencies on first launch
        Task {
            await checkPythonDependencies()
        }

        // Schedule automatic daily backup
        Task {
            await scheduleAutomaticBackup()
        }
    }

    /// Performs automatic backup if needed (once per day)
    @MainActor
    private func scheduleAutomaticBackup() async {
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
