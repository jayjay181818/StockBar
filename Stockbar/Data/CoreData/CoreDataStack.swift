import Foundation
import CoreData

class CoreDataStack: ObservableObject {
    static let shared = CoreDataStack()
    
    private init() {}
    
    // MARK: - Core Data stack
    
    lazy var persistentContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "StockbarDataModel")
        
        // Configure the store for better performance
        let description = container.persistentStoreDescriptions.first
        description?.shouldInferMappingModelAutomatically = true
        description?.shouldMigrateStoreAutomatically = true
        description?.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description?.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        
        container.loadPersistentStores(completionHandler: { (storeDescription, error) in
            if let error = error as NSError? {
                Logger.shared.error("Core Data failed to load store: \(error), \(error.userInfo)")
                
                // In case of persistent errors, remove and recreate the store
                self.recreateStore(container: container)
            } else {
                Logger.shared.info("Core Data store loaded successfully")
            }
        })
        
        // Configure contexts for automatic merging
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        
        return container
    }()
    
    // MARK: - Contexts
    
    var viewContext: NSManagedObjectContext {
        return persistentContainer.viewContext
    }
    
    func newBackgroundContext() -> NSManagedObjectContext {
        let context = persistentContainer.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }
    
    // MARK: - Save Context
    
    func save(context: NSManagedObjectContext? = nil) {
        let contextToSave = context ?? viewContext
        
        guard contextToSave.hasChanges else { return }
        
        do {
            try contextToSave.save()
            Logger.shared.debug("Core Data context saved successfully")
        } catch {
            Logger.shared.error("Failed to save Core Data context: \(error)")
        }
    }
    
    func saveViewContext() {
        save(context: viewContext)
    }
    
    // MARK: - Background Operations
    
    func performBackgroundTask<T>(_ block: @escaping (NSManagedObjectContext) throws -> T) async throws -> T {
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
    
    // MARK: - Store Management
    
    private func recreateStore(container: NSPersistentContainer) {
        guard let storeURL = container.persistentStoreDescriptions.first?.url else { return }
        
        do {
            try container.persistentStoreCoordinator.destroyPersistentStore(at: storeURL, ofType: NSSQLiteStoreType, options: nil)
            try FileManager.default.removeItem(at: storeURL)
            Logger.shared.info("Recreated Core Data store after error")
        } catch {
            Logger.shared.error("Failed to recreate Core Data store: \(error)")
        }
        
        // Reload the store
        container.loadPersistentStores { _, error in
            if let error = error {
                Logger.shared.error("Failed to reload Core Data store: \(error)")
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
            
            Logger.shared.info("Deleted all Core Data entities")
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
            Logger.shared.error("Failed to check migration requirement: \(error)")
            return false
        }
    }
}