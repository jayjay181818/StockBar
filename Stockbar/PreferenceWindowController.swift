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
        
        // Set the initial window size to 1200px wide
        window.setContentSize(NSSize(width: 1200, height: 800))
        
        self.init(window: window)
        
        // Keep a strong reference to the hosting controller
        self.hostingController = hostingController
        self.window?.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        // Window is closing but we keep the content view controller
        // so it can be reopened properly
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