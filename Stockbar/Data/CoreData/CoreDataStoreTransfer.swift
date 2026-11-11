@preconcurrency import CoreData
import Foundation

/// The live Core Data store as seen by settings export and import.
protocol SettingsTransferStoreHost: AnyObject, Sendable {
    /// The loaded SQLite store, or nil when the stack is in memory or failed to load.
    var transferStoreURL: URL? { get }
    var transferModel: NSManagedObjectModel { get }
    /// Marks the live store read-only (or writable again). While suspended,
    /// saves fail with an error instead of writing stale in-memory state over
    /// an imported store before Stockbar relaunches.
    func setTransferWritesSuspended(_ suspended: Bool)
}

extension CoreDataStack: SettingsTransferStoreHost {
    var transferStoreURL: URL? {
        let coordinator = persistentContainer.persistentStoreCoordinator
        return coordinator.performAndWait {
            coordinator.persistentStores.first { $0.type == NSSQLiteStoreType }?.url
        }
    }

    var transferModel: NSManagedObjectModel {
        persistentContainer.managedObjectModel
    }

    func setTransferWritesSuspended(_ suspended: Bool) {
        let coordinator = persistentContainer.persistentStoreCoordinator
        coordinator.performAndWait {
            for store in coordinator.persistentStores {
                store.isReadOnly = suspended
            }
        }
    }
}

/// Store copies for settings transfer. Every copy goes through Core Data's
/// `replacePersistentStore`, which uses SQLite's backup machinery and folds in
/// the `-wal` contents, rather than copying files that may be open.
enum CoreDataStoreTransfer {
    static let fileSuffixes = ["", "-wal", "-shm"]

    struct StoreSummary: Equatable, Sendable {
        let tradeCount: Int
        let portfolioSnapshotCount: Int
        let priceSnapshotCount: Int
    }

    /// Options matching how `CoreDataStack` opens the store, so Core Data does
    /// not force a history-tracked store into read-only mode.
    static var storeOptions: [AnyHashable: Any] {
        [
            NSPersistentHistoryTrackingKey: true as NSNumber,
            NSMigratePersistentStoresAutomaticallyOption: false as NSNumber,
            NSInferMappingModelAutomaticallyOption: false as NSNumber
        ]
    }

    /// Makes a consistent copy of `sourceURL` at `destinationURL`.
    static func copyStore(from sourceURL: URL, to destinationURL: URL, model: NSManagedObjectModel) throws {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.replacePersistentStore(
            at: destinationURL,
            destinationOptions: storeOptions,
            withPersistentStoreFrom: sourceURL,
            sourceOptions: storeOptions,
            type: .sqlite
        )
    }

    /// Reads the store's files keyed by suffix. The SQLite file must exist.
    static func readStoreFiles(at storeURL: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for suffix in fileSuffixes {
            let url = URL(fileURLWithPath: storeURL.path + suffix)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            files[suffix] = try Data(contentsOf: url)
        }
        guard files[""] != nil else { throw SettingsTransferError.databaseUnavailable }
        return files
    }

    /// Writes store files (owner read/write only) next to `storeURL`.
    static func writeStoreFiles(_ files: [String: Data], to storeURL: URL) throws {
        guard files[""] != nil, Set(files.keys).isSubset(of: fileSuffixes) else {
            throw SettingsTransferError.damagedDatabase
        }
        for (suffix, data) in files {
            let url = URL(fileURLWithPath: storeURL.path + suffix)
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    static func totalFileSize(of storeURL: URL) -> Int64 {
        fileSuffixes.reduce(Int64(0)) { total, suffix in
            let path = storeURL.path + suffix
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            return total + size
        }
    }

    /// Confirms the store matches this app's model and opens cleanly, and
    /// counts its main rows for the import preview.
    static func validateStore(at storeURL: URL, model: NSManagedObjectModel) throws -> StoreSummary {
        let metadata: [String: Any]
        do {
            metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: storeURL)
        } catch {
            throw SettingsTransferError.damagedDatabase
        }
        guard model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) else {
            throw SettingsTransferError.incompatibleDatabase
        }

        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        do {
            let store = try coordinator.addPersistentStore(type: .sqlite, at: storeURL, options: storeOptions)
            defer { try? coordinator.remove(store) }
            let context = NSManagedObjectContext(.privateQueue)
            context.persistentStoreCoordinator = coordinator
            return try context.performAndWait {
                func count(_ entityName: String) throws -> Int {
                    try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: entityName))
                }
                return StoreSummary(
                    tradeCount: try count("TradeEntity"),
                    portfolioSnapshotCount: try count("PortfolioSnapshotEntity"),
                    priceSnapshotCount: try count("PriceSnapshotEntity")
                )
            }
        } catch {
            throw SettingsTransferError.damagedDatabase
        }
    }
}

extension CoreDataStoreRecovery {
    /// Consistent copy of an open store, taken before an import replaces it.
    /// Kept beside the store-load-failure copies under `StoreRecovery`.
    func createPreImportSafetyCopy(of storeURL: URL, model: NSManagedObjectModel) throws -> URL {
        let directory = try makeBackupDirectory(prefix: "pre-import")
        let destination = directory.appendingPathComponent(storeURL.lastPathComponent)
        do {
            try CoreDataStoreTransfer.copyStore(from: storeURL, to: destination, model: model)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return destination
    }
}
