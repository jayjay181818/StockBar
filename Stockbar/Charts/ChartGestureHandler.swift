//
//  ChartGestureHandler.swift
//  Stockbar
//
//  Created by Stockbar Development Team on 10/4/25.
//

import SwiftUI

/// Handles gesture recognition and coordination for chart interactions
struct ChartGestureHandler: ViewModifier {

    @ObservedObject var interactionManager: ChartInteractionManager

    @State private var lastMagnification: CGFloat = 1.0
    @State private var lastDragValue: DragGesture.Value?
    @State private var tapCount: Int = 0
    @State private var lastTapTime: Date = Date.distantPast
    @State private var hoverLocation: CGPoint = .zero

    func body(content: Content) -> some View {
        content
            .gesture(magnificationGesture, including: .all)
            .simultaneousGesture(dragGesture, including: .all)
            .simultaneousGesture(tapGesture, including: .all)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverLocation = location
                    interactionManager.showCrosshair(at: location)
                case .ended:
                    interactionManager.hideCrosshair()
                }
            }
            // Desktop scroll wheel zoom support
            .onScrollWheel { event in
                handleScrollWheel(event)
            }
    }

    // MARK: - Scroll Wheel Handling (Desktop)

    private func handleScrollWheel(_ event: NSEvent) {
        // Option/Alt + scroll = zoom (more intuitive for desktop)
        if event.modifierFlags.contains(.option) && event.scrollingDeltaY != 0 {
            let zoomFactor = 1.0 + (event.scrollingDeltaY * 0.01)
            interactionManager.handleZoom(zoomFactor, anchor: hoverLocation)
            return
        }

        // Vertical scroll = zoom by default
        if event.scrollingDeltaY != 0 && event.scrollingDeltaX == 0 {
            let zoomFactor = 1.0 + (event.scrollingDeltaY * 0.01)
            interactionManager.handleZoom(zoomFactor, anchor: hoverLocation)
        }

        // Horizontal scroll or shift+vertical = pan
        if event.scrollingDeltaX != 0 || (event.modifierFlags.contains(.shift) && event.scrollingDeltaY != 0) {
            let deltaX = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
            interactionManager.handlePan(CGSize(width: -deltaX, height: 0))
        }
    }

    // MARK: - Magnification Gesture (Zoom)

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let delta = value / lastMagnification
                lastMagnification = value

                // Use hover location as anchor point
                interactionManager.handleZoom(delta, anchor: hoverLocation)
            }
            .onEnded { _ in
                lastMagnification = 1.0
                interactionManager.endInteraction()
            }
    }

    // MARK: - Drag Gesture (Pan)

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                if let lastValue = lastDragValue {
                    let translation = CGSize(
                        width: value.location.x - lastValue.location.x,
                        height: value.location.y - lastValue.location.y
                    )
                    interactionManager.handlePan(translation)
                }
                lastDragValue = value
            }
            .onEnded { _ in
                lastDragValue = nil
                interactionManager.endPan()
            }
    }

    // MARK: - Tap Gesture (Reset & Crosshair)

    private var tapGesture: some Gesture {
        SpatialTapGesture(count: 1)
            .onEnded { event in
                let now = Date()
                let timeSinceLastTap = now.timeIntervalSince(lastTapTime)

                if timeSinceLastTap < 0.3 {
                    // Double-tap detected
                    tapCount += 1
                    if tapCount >= 2 {
                        interactionManager.resetZoom()
                        tapCount = 0
                    }
                } else {
                    // Single tap - show crosshair
                    tapCount = 1
                    interactionManager.showCrosshair(at: event.location)
                }

                lastTapTime = now
            }
    }
}

// MARK: - View Extension

extension View {
    func chartGestures(interactionManager: ChartInteractionManager) -> some View {
        self.modifier(ChartGestureHandler(interactionManager: interactionManager))
    }

    // Helper for scroll wheel events
    func onScrollWheel(perform action: @escaping (NSEvent) -> Void) -> some View {
        self.overlay(
            ScrollWheelHandler(action: action)
        )
    }
}

// MARK: - Scroll Wheel Handler

private struct ScrollWheelHandler: NSViewRepresentable {
    let action: (NSEvent) -> Void

    func makeNSView(context: Context) -> ScrollWheelView {
        let view = ScrollWheelView()
        view.scrollAction = action
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: ScrollWheelView, context: Context) {
        nsView.scrollAction = action
    }

    class ScrollWheelView: NSView {
        var scrollAction: ((NSEvent) -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func scrollWheel(with event: NSEvent) {
            scrollAction?(event)
            super.scrollWheel(with: event)
        }

        override func magnify(with event: NSEvent) {
            // Handle trackpad pinch-to-zoom
            let zoomFactor = 1.0 + event.magnification
            let fakeScrollEvent = NSEvent.otherEvent(
                with: .scrollWheel,
                location: event.locationInWindow,
                modifierFlags: event.modifierFlags,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                subtype: 0,
                data1: 0,
                data2: Int(event.magnification * 100)
            )
            if let scrollEvent = fakeScrollEvent {
                scrollAction?(scrollEvent)
            }
        }

        override var acceptsFirstResponder: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

// MARK: - Crosshair Overlay

struct CrosshairOverlay: View {
    let position: CGPoint
    let chartBounds: CGRect

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Vertical line
                Path { path in
                    path.move(to: CGPoint(x: position.x, y: chartBounds.minY))
                    path.addLine(to: CGPoint(x: position.x, y: chartBounds.maxY))
                }
                .stroke(Color.gray.opacity(0.5), lineWidth: 1)

                // Horizontal line
                Path { path in
                    path.move(to: CGPoint(x: chartBounds.minX, y: position.y))
                    path.addLine(to: CGPoint(x: chartBounds.maxX, y: position.y))
                }
                .stroke(Color.gray.opacity(0.5), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}
