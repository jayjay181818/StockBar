import Cocoa
import SwiftUI

class PreferenceWindowController: NSWindowController {
    private var dataModel: DataModel!
    
    convenience init(dataModel: DataModel) {
        // Create the window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        // Configure window
        window.title = "Stockbar Preferences"
        window.center()
        window.setFrameAutosaveName("PreferencesWindow")
        window.isReleasedWhenClosed = false
        
        // Initialize with the window
        self.init(window: window)
        self.dataModel = dataModel
        
        // Set up the content view with SwiftUI
        setupContentView()
    }
    
    override init(window: NSWindow?) {
        super.init(window: window)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupContentView() {
        guard let window = window else { return }
        
        // Create the SwiftUI view
        let preferenceView = PreferenceView(userdata: dataModel)
        let hostingView = NSHostingView(rootView: preferenceView)
        
        // Set the content view
        window.contentView = hostingView
        
        // Set minimum size to ensure usability
        window.minSize = NSSize(width: 600, height: 400)
    }
    
    func showWindow() {
        // Bring the window to front and make it key
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    override func windowDidLoad() {
        super.windowDidLoad()
        
        // Additional window configuration if needed
        window?.delegate = self
    }
}

// MARK: - NSWindowDelegate
extension PreferenceWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Don't do anything special when window closes
        // The window will be hidden but not deallocated
    }
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Always allow window to close
        return true
    }
}