import AppKit
import SwiftUI

@MainActor
final class StockbarMainWindowController: NSWindowController, NSWindowDelegate {
    private var hostingController: NSViewController!
    private let dataModel: DataModel

    init(dataModel: DataModel) {
        self.dataModel = dataModel
        super.init(window: nil)
        setupWindow()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupWindow() {
        let hostingController = NSHostingController(rootView: StockbarMainView(dataModel: dataModel))
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Stockbar"
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1500, height: 860))

        self.window = window
        self.hostingController = hostingController
        self.window?.delegate = self
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    func showWindow() {
        showWindow(nil)
    }
}
