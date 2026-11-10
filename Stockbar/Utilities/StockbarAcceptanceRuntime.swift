import Foundation

enum StockbarAcceptanceRuntimeError: Error, Equatable, LocalizedError {
    case incompleteEnvironment
    case liveProvidersMustBeDisabled
    case invalidRunID
    case unsafeRoot
    case rootContainsUnrelatedData

    var errorDescription: String? {
        switch self {
        case .incompleteEnvironment:
            return "Stockbar acceptance mode requires both a root and a run identifier."
        case .liveProvidersMustBeDisabled:
            return "Stockbar acceptance mode requires live providers to be disabled."
        case .invalidRunID:
            return "The Stockbar acceptance run identifier is invalid."
        case .unsafeRoot:
            return "The Stockbar acceptance root is not a safe temporary directory."
        case .rootContainsUnrelatedData:
            return "The Stockbar acceptance root contains data from another run."
        }
    }
}

struct StockbarAcceptanceRuntime: Sendable {
    static let productionFolyncKeychainService = "com.stockbar.folync"
    static let productionTrading212KeychainService = "com.stockbar.trading212"
    static let markerName = ".stockbar-acceptance-run"

    let root: URL?
    let runID: String?
    let folyncKeychainService: String
    let liveProviderRequestsAllowed: Bool

    var isEnabled: Bool { root != nil }

    /// Acceptance and XCTest runs keep Trading 212 credentials in their own
    /// Keychain service, like Folync, so they never read or replace the real item.
    var trading212KeychainService: String {
        guard let runID else { return Self.productionTrading212KeychainService }
        return "\(Self.productionTrading212KeychainService).acceptance.\(runID)"
    }

    var applicationSupportRoot: URL? {
        root?.appendingPathComponent("Application Support/Stockbar", isDirectory: true)
    }

    var bundleApplicationSupportRoot: URL? {
        root?.appendingPathComponent("Application Support/com.stockbar", isDirectory: true)
    }

    var cacheRoot: URL? {
        root?.appendingPathComponent("Caches/stockbar-cache", isDirectory: true)
    }

    /// An isolated run keeps its defaults inside its own root: a suite named by
    /// an absolute path is stored at that path. A named suite would live in
    /// ~/Library/Preferences, where macOS keeps an empty file after the domain
    /// is removed and cfprefsd can write it back after it is deleted.
    var defaultsSuiteName: String? {
        guard let runID else { return nil }
        let domain = "com.stockbar.acceptance.\(runID)"
        guard let root else { return domain }
        return root.appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent(domain).path
    }

    var coreDataStoreURL: URL? {
        applicationSupportRoot?.appendingPathComponent("StockbarDataModel.sqlite")
    }

    var folyncSnapshotCacheRoot: URL? {
        applicationSupportRoot?.appendingPathComponent("Folync", isDirectory: true)
    }

    var folyncSupplementalCacheRoot: URL? {
        applicationSupportRoot?.appendingPathComponent("FolyncSupplemental", isDirectory: true)
    }

    /// True for the per-process isolation created automatically under XCTest.
    /// All three must hold, so cleanup can never reach the production
    /// Keychain item or an explicit acceptance root.
    var isAutomaticXCTestIsolation: Bool {
        guard let runID, runID.hasPrefix("xctest-"), let root else { return false }
        let expectedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Stockbar-\(runID)", isDirectory: true)
            .standardizedFileURL
        return root.standardizedFileURL == expectedRoot
            && folyncKeychainService != Self.productionFolyncKeychainService
    }

    /// Removes everything an automatic XCTest run created: temporary root, defaults
    /// suite, and its Folync and Trading 212 Keychain items. Never touches
    /// explicit acceptance runs.
    func removeAutomaticTestArtifacts(fileManager: FileManager = .default) {
        guard isAutomaticXCTestIsolation else { return }
        if let defaultsSuiteName { UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName) }
        if let root { try? fileManager.removeItem(at: root) }
        try? FolyncCredentialStore(service: folyncKeychainService).delete()
        let trading212Store = Trading212CredentialStore(service: trading212KeychainService)
        for environment in Trading212Environment.allCases {
            try? trading212Store.delete(environment: environment)
        }
    }

    nonisolated(unsafe) private static var runtimePendingCleanup: Self?

    /// Schedules `removeAutomaticTestArtifacts()` for process exit (XCTest has no
    /// process-level teardown hook for process-wide singletons).
    fileprivate func scheduleCleanupAtExit() {
        guard isAutomaticXCTestIsolation else { return }
        Self.runtimePendingCleanup = self
        atexit { StockbarAcceptanceRuntime.runtimePendingCleanup?.removeAutomaticTestArtifacts() }
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> Self {
        let rootValue = environment["STOCKBAR_ACCEPTANCE_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let runID = environment["STOCKBAR_ACCEPTANCE_RUN_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        if rootValue == nil, runID == nil {
            return Self(
                root: nil,
                runID: nil,
                folyncKeychainService: productionFolyncKeychainService,
                liveProviderRequestsAllowed: true
            )
        }

        guard let rootValue, !rootValue.isEmpty, let runID, !runID.isEmpty else {
            throw StockbarAcceptanceRuntimeError.incompleteEnvironment
        }
        guard environment["STOCKBAR_DISABLE_LIVE_PROVIDERS"] == "1" else {
            throw StockbarAcceptanceRuntimeError.liveProvidersMustBeDisabled
        }
        guard runID.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{7,63}$"#, options: .regularExpression) != nil else {
            throw StockbarAcceptanceRuntimeError.invalidRunID
        }
        guard rootValue.hasPrefix("/") else {
            throw StockbarAcceptanceRuntimeError.unsafeRoot
        }

        let root = URL(fileURLWithPath: rootValue, isDirectory: true).standardizedFileURL
        let rootPath = root.path
        let homePath = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL.path
        guard rootPath != "/", rootPath != homePath else {
            throw StockbarAcceptanceRuntimeError.unsafeRoot
        }
        let resolvedRootPath = root.resolvingSymlinksInPath().path
        let resolvedTemporaryPath = fileManager.temporaryDirectory.resolvingSymlinksInPath().path
        guard resolvedRootPath.hasPrefix(resolvedTemporaryPath + "/") else {
            throw StockbarAcceptanceRuntimeError.unsafeRoot
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: rootPath, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw StockbarAcceptanceRuntimeError.unsafeRoot
            }
            let contents = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            if !contents.isEmpty {
                let markerURL = root.appendingPathComponent(markerName)
                let marker = try? String(contentsOf: markerURL, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard marker == runID else {
                    throw StockbarAcceptanceRuntimeError.rootContainsUnrelatedData
                }
            }
        }

        return Self(
            root: root,
            runID: runID,
            folyncKeychainService: "\(productionFolyncKeychainService).acceptance.\(runID)",
            liveProviderRequestsAllowed: false
        )
    }

    static func resolveCurrent(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        uniqueSuffix: String = UUID().uuidString.lowercased(),
        isRunningUnderXCTest: Bool? = nil
    ) throws -> Self {
        let hasExplicitAcceptanceEnvironment = environment["STOCKBAR_ACCEPTANCE_ROOT"] != nil
            || environment["STOCKBAR_ACCEPTANCE_RUN_ID"] != nil
        if hasExplicitAcceptanceEnvironment {
            return try resolve(environment: environment, fileManager: fileManager)
        }

        let detectedXCTest = isRunningUnderXCTest
            ?? (environment["XCTestConfigurationFilePath"] != nil
                || environment["XCTestSessionIdentifier"] != nil
                || NSClassFromString("XCTestCase") != nil
                || NSClassFromString("XCTest.XCTestCase") != nil)
        guard detectedXCTest else {
            return try resolve(environment: environment, fileManager: fileManager)
        }

        // PIDs are reused across runs, so a PID alone could collide with (and
        // inherit) a previous run's leftover defaults, files or Keychain items.
        let runID = "xctest-\(processIdentifier)-\(uniqueSuffix)"
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("Stockbar-\(runID)", isDirectory: true)
            .standardizedFileURL
        return Self(
            root: root,
            runID: runID,
            folyncKeychainService: "\(productionFolyncKeychainService).acceptance.\(runID)",
            liveProviderRequestsAllowed: false
        )
    }
}

public enum StockbarRuntimeStorage {
    static let acceptance: StockbarAcceptanceRuntime = {
        do {
            let runtime = try StockbarAcceptanceRuntime.resolveCurrent()
            runtime.scheduleCleanupAtExit()
            return runtime
        } catch {
            fatalError("Invalid Stockbar acceptance environment: \(error.localizedDescription)")
        }
    }()

    public static var userDefaults: UserDefaults {
        guard let suiteName = acceptance.defaultsSuiteName else { return .standard }
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Unable to create isolated Stockbar acceptance defaults.")
        }
        return defaults
    }

    /// Where the folder normally is, for the rare case the system lookup
    /// returns nothing. The temporary directory used before is emptied by
    /// macOS, which would have silently discarded the portfolio.
    private static func libraryFallback(_ name: String, fileManager: FileManager) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    static func stockbarApplicationSupportDirectory(fileManager: FileManager = .default) -> URL {
        if let directory = acceptance.applicationSupportRoot { return directory }
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? libraryFallback("Application Support", fileManager: fileManager)
        return applicationSupport.appendingPathComponent("Stockbar", isDirectory: true)
    }

    static func bundleApplicationSupportDirectory(fileManager: FileManager = .default) -> URL {
        if let directory = acceptance.bundleApplicationSupportRoot { return directory }
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? libraryFallback("Application Support", fileManager: fileManager)
        let bundleIdentifier = Bundle.main.bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 }
            ?? "com.stockbar"
        return applicationSupport.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    static func cacheDirectory(fileManager: FileManager = .default) -> URL {
        if let directory = acceptance.cacheRoot { return directory }
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? libraryFallback("Caches", fileManager: fileManager)
        return caches.appendingPathComponent("stockbar-cache", isDirectory: true)
    }
}
