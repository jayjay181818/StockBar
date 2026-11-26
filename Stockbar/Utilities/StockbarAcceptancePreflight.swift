@preconcurrency import CoreData
import Foundation

struct StockbarAcceptancePreflightReport: Codable, Equatable, Sendable {
    let runID: String
    let root: String
    let bundleIdentifier: String
    let keychainService: String
    let liveProviderRequestsAllowed: Bool
    /// The one exception to the line above: Folync requests to this Mac.
    let loopbackFolyncAllowed: Bool
    /// The STOCKBAR_ACCEPTANCE_* launch options the app will apply.
    let launchOptions: StockbarAcceptanceLaunchOptions
    let resolvedWritablePaths: [String]
}

struct StockbarAcceptanceBootstrapReport: Codable, Equatable, Sendable {
    let runID: String
    let configured: Bool
    let scopeID: String
    let enabledRoutes: [String]
}

enum StockbarAcceptancePreflightError: Error, LocalizedError {
    case acceptanceEnvironmentRequired
    case storageProbeFailed
    case coreDataLoadTimedOut
    case coreDataLoadFailed(String)
    case manifestRequired
    case unsafeEndpoint
    case seedUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .acceptanceEnvironmentRequired:
            return "Acceptance preflight requires an isolated Stockbar acceptance environment."
        case .storageProbeFailed:
            return "Acceptance storage could not be verified."
        case .coreDataLoadTimedOut:
            return "Acceptance Core Data preflight timed out."
        case .coreDataLoadFailed(let message):
            return "Acceptance Core Data preflight failed: \(message)"
        case .manifestRequired:
            return "Acceptance bootstrap requires a Folync manifest."
        case .unsafeEndpoint:
            return "Acceptance bootstrap accepts loopback Folync endpoints only."
        case .seedUnreadable(let message):
            return "The acceptance Folync settings seed could not be read: \(message)"
        }
    }
}

enum StockbarAcceptancePreflight {
    private struct FolyncManifest: Decodable {
        let baseURL: String
        let tokenFile: String
    }

    static func runIfRequested(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        output: (Data) -> Void
    ) throws -> Int? {
        guard arguments.contains("--acceptance-preflight") else { return nil }

        let runtime = try StockbarAcceptanceRuntime.resolve(
            environment: environment,
            fileManager: fileManager
        )
        guard let root = runtime.root,
              let runID = runtime.runID,
              let applicationSupport = runtime.applicationSupportRoot,
              let bundleSupport = runtime.bundleApplicationSupportRoot,
              let cacheRoot = runtime.cacheRoot,
              let coreDataStore = runtime.coreDataStoreURL,
              let snapshotCache = runtime.folyncSnapshotCacheRoot,
              let supplementalCache = runtime.folyncSupplementalCacheRoot else {
            throw StockbarAcceptancePreflightError.acceptanceEnvironmentRequired
        }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("\(runID)\n".utf8).write(
            to: root.appendingPathComponent(StockbarAcceptanceRuntime.markerName),
            options: .atomic
        )

        let directories = [applicationSupport, bundleSupport, cacheRoot, snapshotCache, supplementalCache]
        for directory in directories {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let probeURL = root.appendingPathComponent(".write-probe-\(UUID().uuidString)")
        let probeData = Data(UUID().uuidString.utf8)
        try probeData.write(to: probeURL, options: .atomic)
        guard try Data(contentsOf: probeURL) == probeData else {
            throw StockbarAcceptancePreflightError.storageProbeFailed
        }
        try fileManager.removeItem(at: probeURL)

        try validateCoreData(runtime: runtime, fileManager: fileManager)

        let report = StockbarAcceptancePreflightReport(
            runID: runID,
            root: root.path,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.stockbar",
            keychainService: runtime.folyncKeychainService,
            liveProviderRequestsAllowed: runtime.liveProviderRequestsAllowed,
            loopbackFolyncAllowed: runtime.loopbackFolyncAllowed,
            launchOptions: StockbarAcceptanceLaunchOptions.resolve(environment: environment, runtime: runtime),
            resolvedWritablePaths: (directories + [coreDataStore]).map(\.path).sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var encoded = try encoder.encode(report)
        encoded.append(0x0A)
        output(encoded)
        return 0
    }

    static func bootstrapIfRequested(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        output: (Data) -> Void
    ) throws -> Int? {
        guard arguments.contains("--acceptance-bootstrap") else { return nil }
        let runtime = try StockbarAcceptanceRuntime.resolve(environment: environment, fileManager: fileManager)
        guard runtime.isEnabled, let runID = runtime.runID,
              let seedURL = runtime.folyncSettingsSeedURL,
              let manifestPath = environment["STOCKBAR_FOLYNC_MANIFEST"],
              !manifestPath.isEmpty else {
            throw StockbarAcceptancePreflightError.manifestRequired
        }

        let manifest = try JSONDecoder().decode(
            FolyncManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: manifestPath))
        )
        guard isLoopbackFolyncEndpoint(manifest.baseURL) else {
            throw StockbarAcceptancePreflightError.unsafeEndpoint
        }
        let token = try String(contentsOf: URL(fileURLWithPath: manifest.tokenFile), encoding: .utf8)
        let supplemental = FolyncSupplementalSettings(
            historicalLineCharts: true,
            candlestickCharts: true,
            benchmarkMarketData: true,
            exchangeRates: true,
            allowLegacyFallback: false,
            dividends: true,
            tradeAnalysis: true,
            transactions: true
        )
        // The app adopts these at launch (`adoptSeededSettingsIfPresent`)
        // rather than this process writing them into the defaults suite: a
        // key already in a path-named suite when the app starts cannot be
        // changed by the app on macOS 27.
        try writeSeed(
            FolyncStoredSettings(
                isEnabled: true,
                baseURL: manifest.baseURL,
                scopeID: "all",
                pollingIntervalSeconds: 60,
                supplemental: supplemental
            ),
            to: seedURL,
            fileManager: fileManager
        )
        try FolyncCredentialStore(service: runtime.folyncKeychainService).save(token: token, for: manifest.baseURL)
        // `STOCKBAR_ACCEPTANCE_EVENTS`: the made-up instrument events, checked
        // and copied owner-only into the root, where the app reads them.
        try StockbarAcceptanceEventsFixture.installCopy(environment: environment, runtime: runtime,
                                                        fileManager: fileManager)
        // `STOCKBAR_ACCEPTANCE_ALERTS`: the made-up price alerts, the same way.
        try StockbarAcceptanceAlertsFixture.installCopy(environment: environment, runtime: runtime,
                                                        fileManager: fileManager)

        let report = StockbarAcceptanceBootstrapReport(
            runID: runID,
            configured: true,
            scopeID: "all",
            enabledRoutes: FolyncSupplementalRoute.allCases.map(\.rawValue).sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var encoded = try encoder.encode(report)
        encoded.append(0x0A)
        output(encoded)
        return 0
    }

    /// Moves the Folync settings that `--acceptance-bootstrap` left in the
    /// run's root into the app's own defaults, then deletes the seed. Call
    /// once at launch, before anything reads the defaults, so that the app
    /// process is the one that first writes those keys.
    ///
    /// Only an explicit acceptance run looks for a seed. A missing seed does
    /// nothing; one that cannot be read, or names anything but a loopback
    /// Folync, throws and leaves the defaults and the file as they were.
    ///
    /// - Returns: True when a seed was adopted.
    @discardableResult
    static func adoptSeededSettingsIfPresent(
        runtime: StockbarAcceptanceRuntime,
        defaults: @autoclosure () -> UserDefaults,
        fileManager: FileManager = .default
    ) throws -> Bool {
        guard runtime.isExplicitAcceptanceRun, let seedURL = runtime.folyncSettingsSeedURL else {
            return false
        }
        guard fileManager.fileExists(atPath: seedURL.path) else { return false }

        let settings: FolyncStoredSettings
        do {
            let attributes = try fileManager.attributesOfItem(atPath: seedURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw StockbarAcceptancePreflightError.seedUnreadable("it is not a regular file")
            }
            settings = try JSONDecoder().decode(FolyncStoredSettings.self, from: Data(contentsOf: seedURL))
        } catch let error as StockbarAcceptancePreflightError {
            throw error
        } catch {
            throw StockbarAcceptancePreflightError.seedUnreadable(error.localizedDescription)
        }
        guard isLoopbackFolyncEndpoint(settings.baseURL) else {
            throw StockbarAcceptancePreflightError.unsafeEndpoint
        }

        FolyncSettingsStore(defaults: defaults()).save(settings)
        try fileManager.removeItem(at: seedURL)
        return true
    }

    /// Plain HTTP to this Mac, with no credentials in the address: the only
    /// Folync an acceptance run may be pointed at.
    static func isLoopbackFolyncEndpoint(_ baseURL: String) -> Bool {
        guard let endpoint = URL(string: baseURL),
              endpoint.scheme == "http",
              endpoint.user == nil,
              endpoint.password == nil else { return false }
        return ["127.0.0.1", "localhost", "::1"].contains(endpoint.host?.lowercased() ?? "")
    }

    /// Writes the seed owner-only and atomically: a temporary file created
    /// with mode 0600 beside it, then renamed over it.
    private static func writeSeed(
        _ settings: FolyncStoredSettings,
        to seedURL: URL,
        fileManager: FileManager
    ) throws {
        let data = try JSONEncoder().encode(settings)
        let directory = seedURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent(".\(seedURL.lastPathComponent).\(UUID().uuidString)")
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw StockbarAcceptancePreflightError.storageProbeFailed
        }
        guard rename(temporaryURL.path, seedURL.path) == 0 else {
            try? fileManager.removeItem(at: temporaryURL)
            throw StockbarAcceptancePreflightError.storageProbeFailed
        }
    }

    private static func validateCoreData(
        runtime: StockbarAcceptanceRuntime,
        fileManager: FileManager
    ) throws {
        let container = NSPersistentContainer(name: "StockbarDataModel")
        guard let description = container.persistentStoreDescriptions.first else {
            throw StockbarAcceptancePreflightError.coreDataLoadFailed("persistent store description is missing")
        }
        try CoreDataStack.configureStoreDescription(
            description,
            runtime: runtime,
            isRunningUnderXCTest: false,
            fileManager: fileManager
        )

        let result = CoreDataPreflightResult()
        let semaphore = DispatchSemaphore(value: 0)
        container.loadPersistentStores { _, error in
            result.error = error
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 30) == .success else {
            throw StockbarAcceptancePreflightError.coreDataLoadTimedOut
        }
        if let error = result.error {
            throw StockbarAcceptancePreflightError.coreDataLoadFailed(error.localizedDescription)
        }
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
    }
}

private final class CoreDataPreflightResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    var error: Error? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedError
        }
        set {
            lock.lock()
            storedError = newValue
            lock.unlock()
        }
    }
}
