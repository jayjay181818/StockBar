import AppKit
import SwiftUI

class PreferenceWindowController: NSWindowController, NSWindowDelegate {

    // Keep a strong reference to the hosting controller
    private var hostingController: NSViewController!

    convenience init(dataModel: DataModel) {
        // Create the SwiftUI view
        let preferenceView = PreferenceView(userdata: dataModel)
        
        // Use our new AutoResizingHostingController
        let hostingController = PreferenceHostingController(rootView: preferenceView)
        
        // Create a resizable window that can auto-resize and be manually adjusted
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .resizable]
        window.title = "StockBar Preferences"
        window.isReleasedWhenClosed = false
        
        self.init(window: window)
        
        // Keep a strong reference to the hosting controller
        self.hostingController = hostingController
        self.window?.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        // This is good practice to ensure the window controller can be deallocated
        self.window?.contentViewController = nil
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // Center the window when it's first shown
        window?.center()
        // Bring it to the front
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func showWindow() {
        showWindow(nil)
    }
}