@preconcurrency import CoreData
import Foundation

struct StockbarAcceptancePreflightReport: Codable, Equatable, Sendable {
    let runID: String
    let root: String
    let bundleIdentifier: String
    let keychainService: String
    let liveProviderRequestsAllowed: Bool
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
              let suiteName = runtime.defaultsSuiteName,
              let manifestPath = environment["STOCKBAR_FOLYNC_MANIFEST"],
              !manifestPath.isEmpty else {
            throw StockbarAcceptancePreflightError.manifestRequired
        }

        let manifest = try JSONDecoder().decode(
            FolyncManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: manifestPath))
        )
        guard let endpoint = URL(string: manifest.baseURL),
              endpoint.scheme == "http",
              endpoint.user == nil,
              endpoint.password == nil,
              ["127.0.0.1", "localhost", "::1"].contains(endpoint.host?.lowercased() ?? "") else {
            throw StockbarAcceptancePreflightError.unsafeEndpoint
        }
        let token = try String(contentsOf: URL(fileURLWithPath: manifest.tokenFile), encoding: .utf8)
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw StockbarAcceptancePreflightError.storageProbeFailed
        }
        let supplemental = FolyncSupplementalSettings(
            historicalLineCharts: true,
            candlestickCharts: true,
            benchmarkMarketData: true,
            exchangeRates: true,
            allowLegacyFallback: false
        )
        FolyncSettingsStore(defaults: defaults).save(FolyncStoredSettings(
            isEnabled: true,
            baseURL: manifest.baseURL,
            scopeID: "all",
            pollingIntervalSeconds: 60,
            supplemental: supplemental
        ))
        try FolyncCredentialStore(service: runtime.folyncKeychainService).save(token: token, for: manifest.baseURL)

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
