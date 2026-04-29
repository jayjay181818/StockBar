@preconcurrency import CoreData
@preconcurrency import Foundation

typealias CoreDataBatchValues = [String: any Sendable]

extension NSPredicate: @unchecked @retroactive Sendable {}

final class CoreDataStack: ObservableObject, @unchecked Sendable {
    static let shared = CoreDataStack()
    private let storeRecovery = CoreDataStoreRecovery()
    private let stateLock = NSLock()
    private var protectedStoreLoadState: CoreDataStoreLoadState = .notLoaded

    var storeLoadState: CoreDataStoreLoadState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return protectedStoreLoadState
    }
    
    private init() {}
    
    // MARK: - Core Data stack
    
    lazy var persistentContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "StockbarDataModel")
        
        // Configure the store for optimal performance
        let description = container.persistentStoreDescriptions.first
        description?.shouldInferMappingModelAutomatically = true
        description?.shouldMigrateStoreAutomatically = true
        description?.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description?.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        
        // Performance optimizations for SQLite
        description?.setOption("WAL" as NSString, forKey: "journal_mode")
        description?.setOption("1000" as NSString, forKey: "cache_size") 
        description?.setOption("NORMAL" as NSString, forKey: "synchronous")
        description?.setOption("10000" as NSString, forKey: "temp_store_directory")
        
        // Enable query optimization (NSPersistentStoreFileProtectionKey is iOS-only, skip on macOS)
        
        container.loadPersistentStores(completionHandler: { (storeDescription, error) in
            if let error = error as NSError? {
                Task { await Logger.shared.error("Core Data failed to load store: \(error), \(error.userInfo)") }
                self.handlePersistentStoreLoadFailure(error: error, storeDescription: storeDescription, container: container)
            } else {
                self.updateStoreLoadState(.loaded)
                Task { await Logger.shared.info("Core Data store loaded successfully with performance optimizations") }
            }
        })
        
        // Configure contexts for optimal performance
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = Self.objectTrumpMergePolicy()
        container.viewContext.undoManager = nil // Disable undo for better performance
        container.viewContext.stalenessInterval = 0.0 // Always use fresh data
        
        return container
    }()
    
    // MARK: - Contexts
    
    var viewContext: NSManagedObjectContext {
        return persistentContainer.viewContext
    }
    
    func newBackgroundContext() -> NSManagedObjectContext {
        let context = persistentContainer.newBackgroundContext()
        context.mergePolicy = Self.objectTrumpMergePolicy()
        context.undoManager = nil // Disable undo for better performance
        return context
    }
    
    func newOptimizedBackgroundContext() -> NSManagedObjectContext {
        let context = persistentContainer.newBackgroundContext()
        context.mergePolicy = Self.objectTrumpMergePolicy()
        context.undoManager = nil
        // Batch operations don't need to observe changes
        context.automaticallyMergesChangesFromParent = false
        return context
    }
    
    // MARK: - Save Context
    
    func save(context: NSManagedObjectContext? = nil) {
        let contextToSave = context ?? viewContext
        
        guard contextToSave.hasChanges else { return }
        
        do {
            try contextToSave.save()
            Task { await Logger.shared.debug("Core Data context saved successfully") }
        } catch {
            Task { await Logger.shared.error("Failed to save Core Data context: \(error)") }
        }
    }
    
    func saveViewContext() {
        save(context: viewContext)
    }
    
    // MARK: - Background Operations
    
    func performBackgroundTask<T: Sendable>(_ block: @Sendable @escaping (NSManagedObjectContext) throws -> T) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            persistentContainer.performBackgroundTask { context in
                do {
                    let result = try block(context)
                    try context.save()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Batch Operations
    
    func performOptimizedBatchTask<T: Sendable>(_ block: @Sendable @escaping (NSManagedObjectContext) throws -> T) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            let context = newOptimizedBackgroundContext()
            context.perform {
                do {
                    let result = try block(context)
                    try context.save()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func performBatchInsert<T: NSManagedObject>(
        entity: T.Type,
        objects: [CoreDataBatchValues],
        batchSize: Int = 1000
    ) async throws -> Int {
        guard !objects.isEmpty else { return 0 }
        
        var totalInserted = 0
        let chunks = objects.chunked(into: batchSize)
        
        for chunk in chunks {
            let insertedCount = try await performOptimizedBatchTask { context in
                let batchObjects = chunk.map { object in
                    object.reduce(into: [String: Any]()) { result, pair in
                        result[pair.key] = pair.value
                    }
                }
                let batchInsert = NSBatchInsertRequest(entity: T.entity(), objects: batchObjects)
                batchInsert.resultType = .count
                
                let result = try context.execute(batchInsert) as? NSBatchInsertResult
                return result?.result as? Int ?? 0
            }
            totalInserted += insertedCount
        }
        
        await Logger.shared.info("Batch inserted \(totalInserted) \(String(describing: T.self)) objects")
        return totalInserted
    }
    
    func performBatchUpdate(
        entityName: String,
        predicate: NSPredicate,
        propertiesToUpdate: CoreDataBatchValues
    ) async throws -> Int {
        return try await performOptimizedBatchTask { context in
            let batchUpdate = NSBatchUpdateRequest(entityName: entityName)
            batchUpdate.predicate = predicate
            batchUpdate.propertiesToUpdate = propertiesToUpdate.reduce(into: [String: Any]()) { result, pair in
                result[pair.key] = pair.value
            }
            batchUpdate.resultType = .updatedObjectsCountResultType
            
            let result = try context.execute(batchUpdate) as? NSBatchUpdateResult
            return result?.result as? Int ?? 0
        }
    }
    
    func performBatchDelete(
        entityName: String,
        predicate: NSPredicate
    ) async throws -> Int {
        return try await performOptimizedBatchTask { context in
            let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
            fetchRequest.predicate = predicate
            
            let batchDelete = NSBatchDeleteRequest(fetchRequest: fetchRequest)
            batchDelete.resultType = .resultTypeCount
            
            let result = try context.execute(batchDelete) as? NSBatchDeleteResult
            return result?.result as? Int ?? 0
        }
    }
    
    // MARK: - Store Management

    private static func objectTrumpMergePolicy() -> NSMergePolicy {
        NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
    }

    private func updateStoreLoadState(_ state: CoreDataStoreLoadState) {
        stateLock.lock()
        protectedStoreLoadState = state
        stateLock.unlock()
    }
    
    private func handlePersistentStoreLoadFailure(
        error: NSError,
        storeDescription: NSPersistentStoreDescription,
        container: NSPersistentContainer
    ) {
        guard let storeURL = storeDescription.url ?? container.persistentStoreDescriptions.first?.url else {
            updateStoreLoadState(.failedBackup("Persistent store URL was unavailable after load failure."))
            Task { await Logger.shared.error("Core Data recovery skipped because persistent store URL was unavailable.") }
            return
        }

        do {
            let result = try storeRecovery.createSafetyBackup(for: storeURL)
            updateStoreLoadState(.failedAndBackedUp(result.backupDirectory))
            Task {
                await Logger.shared.error(
                    "Core Data store load failed and was preserved at \(result.backupDirectory.path). " +
                    "Copied \(result.copiedFiles.count) store file(s). Original store was not deleted. Error: \(error.localizedDescription)"
                )
            }
        } catch {
            updateStoreLoadState(.failedBackup(error.localizedDescription))
            Task {
                await Logger.shared.error(
                    "Core Data store load failed and safety backup could not be created. " +
                    "Original store was not deleted. Error: \(error.localizedDescription)"
                )
            }
        }
    }
    
    // MARK: - Cleanup
    
    func deleteAllData() async throws {
        try await performBackgroundTask { context in
            // Delete all entities
            let entities = ["PriceSnapshotEntity", "PortfolioSnapshotEntity", "PositionSnapshotEntity"]
            
            for entityName in entities {
                let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
                let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
                
                try context.execute(deleteRequest)
            }
            
            Task { await Logger.shared.info("Deleted all Core Data entities") }
        }
    }
    
    // MARK: - Migration Support
    
    func migrationIsRequired() -> Bool {
        guard let storeURL = persistentContainer.persistentStoreDescriptions.first?.url else { return false }
        
        do {
            let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: storeURL, options: nil)
            let model = persistentContainer.managedObjectModel
            
            return !model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata)
        } catch {
            Task { await Logger.shared.error("Failed to check migration requirement: \(error)") }
            return false
        }
    }
}
