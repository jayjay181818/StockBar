//
//  ChartInteractionManager.swift
//  Stockbar
//
//  Created by Stockbar Development Team on 10/4/25.
//

import SwiftUI
import Combine

/// Manages interaction state for chart views including zoom, pan, and crosshair
@MainActor
class ChartInteractionManager: ObservableObject {

    // MARK: - Published Properties

    @Published var zoomScale: CGFloat = 1.0
    @Published var panOffset: CGPoint = .zero
    @Published var crosshairPosition: CGPoint?
    @Published var isDragging: Bool = false
    @Published var isZooming: Bool = false

    // MARK: - Configuration

    let minZoom: CGFloat = 0.5
    let maxZoom: CGFloat = 8.0

    // MARK: - Private Properties

    private var chartBounds: CGRect = .zero
    private var contentSize: CGSize = .zero

    // MARK: - Initialization

    init() {
        // No logging in init due to actor isolation
    }

    // MARK: - Chart Bounds Management

    func updateChartBounds(_ bounds: CGRect) {
        chartBounds = bounds
        Task {
            await Logger.shared.debug("📊 Chart bounds updated: \(bounds)")
        }
    }

    func updateContentSize(_ size: CGSize) {
        contentSize = size
        Task {
            await Logger.shared.debug("📊 Content size updated: \(size)")
        }
    }

    // MARK: - Zoom Management

    func handleZoom(_ scale: CGFloat, anchor: CGPoint) {
        isZooming = true

        // Calculate new zoom scale with bounds
        let newScale = max(minZoom, min(maxZoom, zoomScale * scale))

        // Adjust pan offset to zoom around anchor point
        let scaleDelta = newScale / zoomScale
        let anchorOffset = CGPoint(
            x: anchor.x - chartBounds.midX,
            y: anchor.y - chartBounds.midY
        )

        panOffset.x = (panOffset.x - anchorOffset.x) * scaleDelta + anchorOffset.x
        panOffset.y = (panOffset.y - anchorOffset.y) * scaleDelta + anchorOffset.y

        zoomScale = newScale

        // Apply bounds checking
        applyPanBounds()

        Task {
            await Logger.shared.debug("📊 Zoom applied: scale=\(newScale), anchor=\(anchor)")
        }
    }

    func resetZoom() {
        withAnimation(.easeInOut(duration: 0.3)) {
            zoomScale = 1.0
            panOffset = .zero
        }
        Task {
            await Logger.shared.debug("📊 Zoom reset to default")
        }
    }

    // MARK: - Pan Management

    func handlePan(_ translation: CGSize) {
        isDragging = true

        panOffset.x += translation.width
        panOffset.y += translation.height

        applyPanBounds()
    }

    func endPan() {
        isDragging = false
    }

    private func applyPanBounds() {
        // Calculate maximum pan offsets based on zoom scale
        let scaledWidth = contentSize.width * zoomScale
        let scaledHeight = contentSize.height * zoomScale

        let maxOffsetX = max(0, (scaledWidth - chartBounds.width) / 2)
        let maxOffsetY = max(0, (scaledHeight - chartBounds.height) / 2)

        // Clamp pan offset to valid range
        panOffset.x = max(-maxOffsetX, min(maxOffsetX, panOffset.x))
        panOffset.y = max(-maxOffsetY, min(maxOffsetY, panOffset.y))
    }

    // MARK: - Crosshair Management

    func updateCrosshair(position: CGPoint?) {
        crosshairPosition = position
    }

    func showCrosshair(at position: CGPoint) {
        crosshairPosition = position
    }

    func hideCrosshair() {
        crosshairPosition = nil
    }

    // MARK: - Coordinate Conversion

    func chartToDataCoordinate(_ point: CGPoint) -> CGPoint {
        // Convert chart coordinate to data coordinate accounting for zoom and pan
        let x = (point.x - chartBounds.minX - panOffset.x) / zoomScale
        let y = (point.y - chartBounds.minY - panOffset.y) / zoomScale
        return CGPoint(x: x, y: y)
    }

    func dataToChartCoordinate(_ point: CGPoint) -> CGPoint {
        // Convert data coordinate to chart coordinate accounting for zoom and pan
        let x = point.x * zoomScale + panOffset.x + chartBounds.minX
        let y = point.y * zoomScale + panOffset.y + chartBounds.minY
        return CGPoint(x: x, y: y)
    }

    // MARK: - State Reset

    func reset() {
        zoomScale = 1.0
        panOffset = .zero
        crosshairPosition = nil
        isDragging = false
        isZooming = false
        Task {
            await Logger.shared.debug("📊 ChartInteractionManager reset")
        }
    }

    // MARK: - Gesture Coordination

    func beginInteraction() {
        // Called when any gesture begins
        Task {
            await Logger.shared.debug("📊 Chart interaction began")
        }
    }

    func endInteraction() {
        // Called when all gestures end
        isDragging = false
        isZooming = false
        Task {
            await Logger.shared.debug("📊 Chart interaction ended")
        }
    }
}
