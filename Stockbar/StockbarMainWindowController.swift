import AppKit
import SwiftUI

/// Window frames and status-item positions are persisted by AppKit in the *standard*
/// defaults, bypassing the acceptance defaults suite. While acceptance isolation is
/// active the window frame is not saved at all and status items get run-specific names,
/// so the production layout is never overwritten.
enum StockbarAutosavePolicy {
    /// Autosave name for a window frame, or nil when it must not be saved or restored.
    static func windowFrameName(
        _ base: String,
        acceptance: StockbarAcceptanceRuntime = StockbarRuntimeStorage.acceptance
    ) -> String? {
        acceptance.isEnabled ? nil : base
    }

    /// Autosave name for a status item; suffixed with the run ID under acceptance.
    static func statusItemName(
        _ base: String,
        acceptance: StockbarAcceptanceRuntime = StockbarRuntimeStorage.acceptance
    ) -> String {
        guard acceptance.isEnabled else { return base }
        return "\(base).acceptance.\(acceptance.runID ?? "run")"
    }
}

@MainActor
final class StockbarMainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSToolbarDelegate {
    private enum WindowMetrics {
        static let preferredSize = NSSize(width: 1500, height: 860)
        static let minimumSize = NSSize(width: 1060, height: 680)
        static let visibleScreenInset: CGFloat = 24
    }

    private static let frameAutosaveName = "StockbarMainWindow"

    private var hostingController: NSViewController!
    private let dataModel: DataModel
    /// Centre only the very first time, when no saved frame exists.
    private var shouldCenterOnNextShow = true
    private let navigationState = StockbarMainNavigationState()

    init(dataModel: DataModel) {
        self.dataModel = dataModel
        super.init(window: nil)
        setupWindow()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupWindow() {
        let hostingController = NSHostingController(
            rootView: StockbarMainView(dataModel: dataModel, navigationState: navigationState)
        )
        // Enforce the minimum size only. Letting SwiftUI's ideal size drive the
        // window would resize it when switching to a section with a tall ideal
        // height, such as the Holdings table.
        hostingController.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hostingController)
        // The Glass shell: content runs under a transparent title bar, and the
        // window is see-through so the root view's behind-window backing shows
        // the desktop. Under Reduce Transparency the root draws an opaque fill.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        // A unified toolbar moves the traffic lights in and down, onto the
        // floating sidebar panel, and holds the sidebar button beside them. The
        // button lives in the toolbar because AppKit keeps clicks in the top
        // strip for itself: a SwiftUI button drawn there on the panel never
        // received a real click in the acceptance copy.
        let toolbar = NSToolbar(identifier: "StockbarMainWindowToolbar")
        toolbar.showsBaselineSeparator = false
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        toolbar.delegate = self
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.title = "Stockbar"
        window.isReleasedWhenClosed = false
        window.minSize = WindowMetrics.minimumSize
        window.setContentSize(initialContentSize())
        // Restore the user's last size/position and keep saving it.
        // Acceptance runs skip this: frames are stored in the standard defaults, which
        // isolation does not redirect, so they would overwrite the real window position.
        if let autosaveName = StockbarAutosavePolicy.windowFrameName(Self.frameAutosaveName) {
            shouldCenterOnNextShow = !window.setFrameUsingName(autosaveName)
            window.setFrameAutosaveName(autosaveName)
        }

        self.window = window
        self.hostingController = hostingController
        self.window?.delegate = self
    }

    override func showWindow(_ sender: Any?) {
        // Only a window coming back on screen needs checking: one already
        // showing is where the user put it.
        let wasVisible = window?.isVisible ?? false
        super.showWindow(sender)
        if shouldCenterOnNextShow {
            window?.center()
            shouldCenterOnNextShow = false
        }
        if !wasVisible {
            fitWindowToVisibleScreen()
        }
        NSApp.activate()
    }

    func showWindow() {
        showWindow(nil)
    }

    func showWindow(section: StockbarMainSection) {
        navigationState.selectedSection = section
        showWindow(nil)
    }

    /// View → Hide Sidebar / Show Sidebar. Reached through the responder chain
    /// while this window is key; the menu item is disabled otherwise.
    @objc func toggleStockbarSidebar(_ sender: Any?) {
        navigationState.toggleSidebar()
        updateSidebarToolbarItem()
    }

    private var sidebarToolbarItem: NSToolbarItem?

    private func updateSidebarToolbarItem() {
        guard let item = sidebarToolbarItem else { return }
        let title = StockbarSidebarMenu.title(sidebarHidden: navigationState.isSidebarHidden)
        item.label = title
        item.toolTip = "\(title) (⌃⌘S)"
        item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: title)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.stockbarToggleSidebar]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.stockbarToggleSidebar]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == .stockbarToggleSidebar else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.target = self
        item.action = #selector(toggleStockbarSidebar(_:))
        item.isBordered = true
        item.isNavigational = true
        sidebarToolbarItem = item
        updateSidebarToolbarItem()
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleStockbarSidebar(_:)) {
            menuItem.title = StockbarSidebarMenu.title(sidebarHidden: navigationState.isSidebarHidden)
        }
        return true
    }

    private func initialContentSize() -> NSSize {
        // An acceptance run can ask for the minimum size, to check the tightest layout.
        if StockbarAcceptanceLaunchOptions.current.opensAtMinimumSize {
            return WindowMetrics.minimumSize
        }
        guard let visibleFrame = NSScreen.main?.visibleFrame else {
            return WindowMetrics.preferredSize
        }

        let maxWidth = max(
            WindowMetrics.minimumSize.width,
            visibleFrame.width - WindowMetrics.visibleScreenInset * 2
        )
        let maxHeight = max(
            WindowMetrics.minimumSize.height,
            visibleFrame.height - WindowMetrics.visibleScreenInset * 2
        )

        return NSSize(
            width: min(WindowMetrics.preferredSize.width, maxWidth),
            height: min(WindowMetrics.preferredSize.height, maxHeight)
        )
    }

    /// Pulls a window back on screen after a display was unplugged or shrunk.
    /// A window already wholly on screen is left exactly where it is, and a
    /// full-screen window is never touched: its frame belongs to the system.
    private func fitWindowToVisibleScreen() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let fitted = Self.frame(window.frame, fittedTo: visibleFrame)
        guard fitted != window.frame else { return }
        window.setFrame(fitted, display: true)
    }

    /// `frame` moved and, only if it must be, shrunk so it lies inside `visibleFrame`.
    nonisolated static func frame(_ frame: NSRect, fittedTo visibleFrame: NSRect) -> NSRect {
        guard !visibleFrame.contains(frame) else { return frame }
        var fitted = frame
        fitted.size.width = min(frame.width, visibleFrame.width)
        fitted.size.height = min(frame.height, visibleFrame.height)
        fitted.origin.x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - fitted.width)
        fitted.origin.y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - fitted.height)
        return fitted
    }
}

extension NSToolbarItem.Identifier {
    /// Hides or shows the main window's sidebar; sits beside the traffic lights.
    static let stockbarToggleSidebar = NSToolbarItem.Identifier("StockbarToggleSidebar")
}
