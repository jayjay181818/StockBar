import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private var stockMenuBarController: StockMenuBarController?
    private let dataModel = DataModel()
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        stockMenuBarController = StockMenuBarController(data: dataModel)
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        // Clean up if needed
    }
}