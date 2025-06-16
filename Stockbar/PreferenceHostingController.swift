import SwiftUI
import AppKit

/// A custom NSHostingController that automatically resizes its window
/// to fit the ideal size of its SwiftUI content.
class PreferenceHostingController<Content: View>: NSHostingController<AnyView> {

    private var windowSize: CGSize?

    // 1. Initialize with a standard SwiftUI View
    init(rootView: Content) {
        // First initialize with a simple wrapped view
        super.init(rootView: AnyView(rootView))
        
        // Then set up the size observation
        setupSizeObservation(for: rootView)
    }
    
    private func setupSizeObservation(for content: Content) {
        // Create a container view that will report its size
        let containerView = SizeReportingContainer(content: content) { [weak self] size in
            DispatchQueue.main.async {
                self?.updateWindowSize(to: size)
            }
        }
        
        // Update the root view
        self.rootView = AnyView(containerView)
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// This is the core logic. When the SwiftUI view's size preference changes,
    /// this function is called.
    private func updateWindowSize(to newSize: CGSize) {
        // 2. Only resize if the new size is different and valid
        guard let window = self.view.window, newSize.width > 0, newSize.height > 0 else {
            return
        }

        // 3. Get the current window frame and content frame
        let currentContentRect = window.contentRect(forFrameRect: window.frame)
        
        // Prevent unnecessary resizing
        if abs(currentContentRect.size.width - newSize.width) < 1 && 
           abs(currentContentRect.size.height - newSize.height) < 1 {
            return
        }

        // Apply reasonable minimum and maximum sizes with better defaults for preferences
        let minSize = CGSize(width: 650, height: 600)
        let maxSize = CGSize(width: 1200, height: 1200) // Increased max height
        
        // For width, prefer the ideal width (1200) if the content supports it
        // For height, prefer the natural size but ensure minimum
        let preferredWidth = max(minSize.width, min(maxSize.width, max(newSize.width, 1200)))
        let constrainedSize = CGSize(
            width: preferredWidth,
            height: max(minSize.height, min(maxSize.height, newSize.height))
        )

        // 4. Calculate the new window frame based on the new content size
        let newWindowFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: constrainedSize))
        
        // 5. To keep the window centered or top-left aligned, we adjust the origin
        var newFrame = window.frame
        newFrame.size = newWindowFrame.size
        // Keep the top-left corner stationary
        newFrame.origin.y += (currentContentRect.height - constrainedSize.height)
        
        // Ensure window stays on screen
        if let screen = window.screen {
            let screenFrame = screen.visibleFrame
            if newFrame.maxX > screenFrame.maxX {
                newFrame.origin.x = screenFrame.maxX - newFrame.width
            }
            if newFrame.minX < screenFrame.minX {
                newFrame.origin.x = screenFrame.minX
            }
            if newFrame.minY < screenFrame.minY {
                newFrame.origin.y = screenFrame.minY
            }
            if newFrame.maxY > screenFrame.maxY {
                newFrame.origin.y = screenFrame.maxY - newFrame.height
            }
        }

        // 6. Animate the resize for a smooth user experience
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            window.setFrame(newFrame, display: true, animate: true)
        }, completionHandler: nil)
    }
}

// MARK: - Supporting Container View

private struct SizeReportingContainer<Content: View>: View {
    let content: Content
    let onSizeChange: (CGSize) -> Void
    
    init(content: Content, onSizeChange: @escaping (CGSize) -> Void) {
        self.content = content
        self.onSizeChange = onSizeChange
    }
    
    var body: some View {
        content
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .preference(key: ViewSizeKey.self, value: geometry.size)
                        .onAppear {
                            // Report initial size immediately
                            onSizeChange(geometry.size)
                        }
                }
            )
            .onPreferenceChange(ViewSizeKey.self) { size in
                onSizeChange(size)
            }
    }
}