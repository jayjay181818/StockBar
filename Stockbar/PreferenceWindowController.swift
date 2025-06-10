import Cocoa
import SwiftUI

class PreferenceWindowController: NSWindowController {
    private var dataModel: DataModel!
    
    convenience init(dataModel: DataModel) {
        // Create the window with better initial dimensions
        let initialWidth: CGFloat = 750
        let initialHeight: CGFloat = 550
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        // Configure window
        window.title = "Stockbar Preferences"
        window.center()
        window.setFrameAutosaveName("PreferencesWindow")
        window.isReleasedWhenClosed = false
        
        // Ensure window respects system appearance and is properly styled
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        
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
        
        // Set sizing constraints to ensure usability while allowing dynamic resizing
        window.minSize = NSSize(width: 650, height: 450)
        window.maxSize = NSSize(width: 1400, height: 1000) // Increased max width for horizontal scaling
        
        // Enable automatic window sizing based on content
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        
        // Configure the hosting view for proper content sizing
        if let contentView = window.contentView {
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
        }
    }
    
    func showWindow() {
        // Ensure proper window state before showing
        if let window = window {
            // Trigger a content size update to ensure proper sizing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NotificationCenter.default.post(name: .forceWindowResize, object: nil)
            }
            
            // Bring the window to front and make it key
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
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
    
    func windowDidResize(_ notification: Notification) {
        // Ensure content layout updates properly after manual resizing
        guard let window = notification.object as? NSWindow else { return }
        
        // Allow some time for the resize to complete, then notify content
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: .contentSizeChanged, object: window.frame.size)
        }
    }
    
    func windowWillBeginSheet(_ notification: Notification) {
        // Ensure proper sizing when sheets are presented
        if let window = window {
            window.standardWindowButton(.zoomButton)?.isEnabled = false
        }
    }
    
    func windowDidEndSheet(_ notification: Notification) {
        // Re-enable zoom button after sheet dismissal
        if let window = window {
            window.standardWindowButton(.zoomButton)?.isEnabled = true
        }
    }
}