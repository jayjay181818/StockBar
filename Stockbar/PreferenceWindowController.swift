import AppKit
import SwiftUI

class PreferenceWindowController: NSWindowController, NSWindowDelegate {

    // Keep a strong reference to the hosting controller
    private var hostingController: NSViewController!
    private let dataModel: DataModel

    convenience init(dataModel: DataModel) {
        self.init(dataModel: dataModel, window: nil)
    }
    
    init(dataModel: DataModel, window: NSWindow?) {
        self.dataModel = dataModel
        super.init(window: window)
        setupWindow()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupWindow() {
        // Create a fresh SwiftUI view with the data model
        let preferenceView = PreferenceView(userdata: dataModel)
        
        // Use standard NSHostingController 
        let hostingController = NSHostingController(rootView: preferenceView)
        
        // Create a resizable window that can auto-resize and be manually adjusted
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .resizable]
        window.title = "StockBar Preferences"
        window.isReleasedWhenClosed = false
        
        // Set the initial window size to 1200px wide
        window.setContentSize(NSSize(width: 1200, height: 800))
        
        self.window = window
        
        // Keep a strong reference to the hosting controller
        self.hostingController = hostingController
        self.window?.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        // Perform any cleanup when window closes
        // The window controller will be recreated fresh next time
    }
    
    func windowDidBecomeKey(_ notification: Notification) {
        // Ensure the window is properly activated and responsive
        window?.makeFirstResponder(window?.contentView)
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
    
    deinit {
        // Ensure proper cleanup when the window controller is deallocated
        window?.delegate = nil
        hostingController = nil
    }
}