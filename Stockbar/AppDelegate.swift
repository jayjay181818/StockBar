import Cocoa

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var stockMenuBarController: StockMenuBarController?
    private var dataModel: DataModel!
    private var automaticBackupTimer: Timer?

    private static let dependencyCheckInterpreterKey = "pythonDependencyCheck.interpreterPath"
    private static let dependencyCheckTimeoutSeconds: TimeInterval = 20
    /// Long-running menu-bar sessions re-check the once-a-day backup on this cadence.
    private static let automaticBackupCheckInterval: TimeInterval = 6 * 60 * 60

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        guard !ProcessInfo.processInfo.isRunningUnitTests else {
            return
        }

        _ = CoreDataStack.shared.persistentContainer
        dataModel = DataModel()
        setupMainMenu()

        // Perform legacy cleanup on first launch
        LegacyCleanupService.shared.performCleanupIfNeeded()

        stockMenuBarController = StockMenuBarController(data: dataModel)
        stockMenuBarController?.showStockbarWindow(nil)

        // Check Python dependencies on first launch
        Task {
            await checkPythonDependencies()
        }

        // Automatic daily backup: once at launch, then periodically so a
        // long-running menu-bar session still gets one backup per day.
        Task {
            await scheduleAutomaticBackup()
        }
        startAutomaticBackupTimer()

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
            NSApp.activate()
        }
        return true
    }

    private func startAutomaticBackupTimer() {
        automaticBackupTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.automaticBackupCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.scheduleAutomaticBackup() }
        }
        timer.tolerance = 10 * 60
        automaticBackupTimer = timer
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

        let success = await BackupService.shared.performAutomaticBackupIfNeeded(trades: dataModel.localPortfolioTradesForBackup)
        if success {
            await Logger.shared.info("Automatic backup completed successfully")
        } else {
            await Logger.shared.debug("Automatic backup skipped (already done today or failed)")
        }
    }
    
    /// Lets queued Core Data saves finish (bounded) before the process exits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let dataModel else { return .terminateNow }
        let reply = TerminationReply(application: sender)
        Task { @MainActor in
            await dataModel.flushPendingPersistence()
            reply.send()
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            reply.send()
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        automaticBackupTimer?.invalidate()
    }

    @objc func showPreferences(_ sender: Any?) {
        stockMenuBarController?.showPreferences(sender)
    }

    @objc func showStockbarWindow(_ sender: Any?) {
        stockMenuBarController?.showStockbarWindow(sender)
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        mainMenu.addItem(submenuItem(makeApplicationMenu()))
        mainMenu.addItem(submenuItem(makeEditMenu()))

        let windowMenu = makeWindowMenu()
        mainMenu.addItem(submenuItem(windowMenu))

        let helpMenu = NSMenu(title: "Help")
        mainMenu.addItem(submenuItem(helpMenu))

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
        // An empty Help menu still provides the system menu-search field.
        NSApp.helpMenu = helpMenu
    }

    private func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func makeApplicationMenu() -> NSMenu {
        let appMenu = NSMenu(title: "Stockbar")
        appMenu.addItem(
            withTitle: "About Stockbar",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())

        let openItem = NSMenuItem(title: "Open Stockbar", action: #selector(showStockbarWindow(_:)), keyEquivalent: "o")
        openItem.target = self
        appMenu.addItem(openItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showPreferences(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)

        appMenu.addItem(.separator())
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(servicesItem)

        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Stockbar", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )

        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Stockbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return appMenu
    }

    /// Standard editing commands. Without these menu items AppKit text fields
    /// receive no Cut/Copy/Paste/Select All/Undo key equivalents.
    private func makeEditMenu() -> NSMenu {
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return editMenu
    }

    private func makeWindowMenu() -> NSMenu {
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        return windowMenu
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

        // A sheet, not runModal(): an app-modal loop would stall @MainActor
        // startup work (trade loading, first refresh) until dismissed.
        presentAlert(alert) { response in
            guard response == .alertFirstButtonReturn,
                  let backupDirectory = notice.backupDirectory else {
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([backupDirectory])
        }
    }

    /// Presents an alert as a sheet on the main Stockbar window (never on a
    /// status-bar or popover window), falling back to a modal alert only when
    /// no main window can be created.
    private func presentAlert(_ alert: NSAlert, handler: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        guard let window = stockMenuBarController?.mainWindowForPresentation() else {
            handler(alert.runModal())
            return
        }
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { handler(response) }
        }
    }

    // MARK: - Python Dependency Management

    /// Checks if required Python dependencies are installed on first launch
    @MainActor
    private func checkPythonDependencies() async {
        // Re-check whenever the configured interpreter changes.
        let interpreterPath = PythonConfiguration.load().interpreterPath
        let checkedInterpreter = StockbarRuntimeStorage.userDefaults.string(forKey: Self.dependencyCheckInterpreterKey)
        let providerPolicy = StockbarProviderAccessPolicy.current
        guard Self.shouldCheckPythonDependencies(
            hasChecked: checkedInterpreter == interpreterPath,
            providerPolicy: providerPolicy
        ) else {
            if !providerPolicy.liveRequestsAllowed {
                await Logger.shared.info("Skipping Python dependency check because live providers are disabled.")
            }
            return
        }

        await Logger.shared.info("🐍 Checking Python dependencies...")

        let dependenciesAreCompatible = await checkPythonPackageVersions()

        // Mark as checked *before* presenting, so the prompt cannot re-appear on
        // every launch if the user leaves it unanswered.
        StockbarRuntimeStorage.userDefaults.set(interpreterPath, forKey: Self.dependencyCheckInterpreterKey)

        if !dependenciesAreCompatible {
            await Logger.shared.warning("Python packages are missing or do not match the supported versions")
            showPythonDependencyAlert()
        } else {
            await Logger.shared.info("✅ Python dependencies verified")
        }
    }

    nonisolated static func shouldCheckPythonDependencies(
        hasChecked: Bool,
        providerPolicy: StockbarProviderAccessPolicy
    ) -> Bool {
        !hasChecked && providerPolicy.liveRequestsAllowed
    }

    /// Parses the pinned `name==version` requirements shipped in the bundle.
    ///
    /// The expected versions used to be hardcoded here as well as in
    /// requirements.txt, so bumping one without the other produced a false
    /// "dependencies required" alert on every launch with no hint why. The
    /// shipped file is now the single source of truth.
    nonisolated static func parsePinnedRequirements(_ contents: String) -> [String: String] {
        var pins: [String: String] = [:]
        for rawLine in contents.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.components(separatedBy: "==")
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let version = parts[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !version.isEmpty else { continue }
            pins[name] = version
        }
        return pins
    }

    private func expectedPythonPackageVersions() -> [String: String] {
        guard let url = Bundle.main.url(forResource: "requirements", withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }
        return Self.parsePinnedRequirements(contents)
    }

    private func checkPythonPackageVersions() async -> Bool {
        do {
            try StockbarProviderAccessPolicy.current.authorize(.python)
        } catch {
            await Logger.shared.warning("Python dependency check blocked: \(error.localizedDescription)")
            return false
        }

        let expected = expectedPythonPackageVersions()
        guard !expected.isEmpty else {
            await Logger.shared.error("Could not read pinned requirements from the bundle; skipping version check")
            return true
        }

        let names = expected.keys.sorted()
        let nameList = names.map { "\"\($0)\"" }.joined(separator: ", ")
        // Embedded Python. Writes to stdout via sys.stdout.write so the
        // Swift-side logging ban in Scripts/validate_invariants.sh does not
        // need a special case for this string literal.
        let script = """
            import json, sys
            from importlib import metadata
            names = (\(nameList),)
            out = {}
            for name in names:
                try:
                    out[name] = metadata.version(name)
                except Exception:
                    out[name] = None
            sys.stdout.write(json.dumps(out))
            """

        // Run through the shared runner: off the main actor, with pipe
        // draining and a timeout so a hanging interpreter cannot stall startup.
        let result: PythonProcessResult
        do {
            result = try await PythonProcessRunner().run(
                arguments: ["-c", script],
                timeoutSeconds: Self.dependencyCheckTimeoutSeconds,
                logContext: "python dependency check"
            )
        } catch {
            await Logger.shared.error("Failed to check Python package versions: \(error.localizedDescription)")
            return false
        }

        guard result.exitCode == 0,
              let installed = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            return false
        }

        for (name, requiredVersion) in expected {
            guard let installedVersion = installed[name] as? String else {
                await Logger.shared.warning("Python package '\(name)' is not installed")
                return false
            }
            guard installedVersion == requiredVersion else {
                await Logger.shared.warning(
                    "Python package '\(name)' is \(installedVersion), expected \(requiredVersion)"
                )
                return false
            }
        }
        return true
    }

    /// Shows alert with Python dependency installation instructions.
    ///
    /// Presented as a **window-modal sheet**, never `runModal()`. An application
    /// modal spins a nested run loop in `.modalPanel` mode, which does not
    /// service `@MainActor` continuations scheduled in the default mode — so a
    /// blocking alert here silently froze the rest of startup (trade loading,
    /// the first refresh pass, every UI update) until it was dismissed.
    @MainActor
    private func showPythonDependencyAlert() {
        let installCommand = Self.pythonInstallCommand(
            interpreterPath: PythonConfiguration.load().interpreterPath,
            requirementsPath: Bundle.main.url(forResource: "requirements", withExtension: "txt")?.path
        )

        let alert = NSAlert()
        alert.messageText = "Python Dependencies Required"
        alert.informativeText = """
        Stockbar needs its pinned Python packages for the configured interpreter.

        To install them, open Terminal and run:
        \(installCommand)

        If pip reports an "externally managed environment" (common with Homebrew Python), create a virtual environment, then point Stockbar at it and relaunch:
        defaults write com.stockbar pythonInterpreterPath /path/to/venv/bin/python3
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Open Terminal")
        alert.addButton(withTitle: "Dismiss")

        presentAlert(alert) { response in
            switch response {
            case .alertFirstButtonReturn:
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(installCommand, forType: .string)
                Task { await Logger.shared.info("Python install command copied to clipboard") }
            case .alertSecondButtonReturn:
                if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                    NSWorkspace.shared.open(terminal)
                }
            default:
                break
            }
        }
    }

    /// Shell command using absolute, quoted paths so it works from any
    /// Terminal working directory.
    nonisolated static func pythonInstallCommand(interpreterPath: String, requirementsPath: String?) -> String {
        func quoted(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let requirements = requirementsPath.map(quoted) ?? "requirements.txt"
        return "\(quoted(interpreterPath)) -m pip install -r \(requirements)"
    }
}

/// Replies to a deferred termination exactly once (flush or timeout).
@MainActor
private final class TerminationReply {
    private let application: NSApplication
    private var hasReplied = false

    init(application: NSApplication) {
        self.application = application
    }

    func send() {
        guard !hasReplied else { return }
        hasReplied = true
        application.reply(toApplicationShouldTerminate: true)
    }
}

private extension ProcessInfo {
    var isRunningUnitTests: Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }
}
