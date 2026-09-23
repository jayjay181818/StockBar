import AppKit
import SwiftUI

@MainActor
final class StockbarMainWindowController: NSWindowController, NSWindowDelegate {
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
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Stockbar"
        window.isReleasedWhenClosed = false
        window.minSize = WindowMetrics.minimumSize
        window.setContentSize(initialContentSize())
        // Restore the user's last size/position and keep saving it.
        shouldCenterOnNextShow = !window.setFrameUsingName(Self.frameAutosaveName)
        window.setFrameAutosaveName(Self.frameAutosaveName)

        self.window = window
        self.hostingController = hostingController
        self.window?.delegate = self
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if shouldCenterOnNextShow {
            window?.center()
            shouldCenterOnNextShow = false
        }
        fitWindowToVisibleScreen()
        NSApp.activate()
    }

    func showWindow() {
        showWindow(nil)
    }

    func showWindow(section: StockbarMainSection) {
        navigationState.selectedSection = section
        showWindow(nil)
    }

    private func initialContentSize() -> NSSize {
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

    private func fitWindowToVisibleScreen() {
        guard let window else { return }
        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame
            .insetBy(dx: WindowMetrics.visibleScreenInset, dy: WindowMetrics.visibleScreenInset)
        guard let visibleFrame else { return }

        var frame = window.frame
        frame.size.width = min(frame.width, visibleFrame.width)
        frame.size.height = min(frame.height, visibleFrame.height)
        frame.origin.x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - frame.height)
        window.setFrame(frame, display: true)
    }
}
