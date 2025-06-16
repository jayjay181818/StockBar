import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private var stockMenuBarController: StockMenuBarController?
    private let dataModel = DataModel()
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Perform Core Data migration before initializing the UI
        Task {
            do {
                try await DataMigrationService.shared.performFullMigration()
                Logger.shared.info("AppDelegate: Core Data migration completed successfully")
            } catch {
                Logger.shared.error("AppDelegate: Core Data migration failed: \(error)")
            }
        }
        
        stockMenuBarController = StockMenuBarController(data: dataModel)
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        // Clean up if needed
    }
}