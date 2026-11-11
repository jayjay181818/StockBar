import AppKit
import Charts
import SwiftUI

// MARK: - Enhanced Chart Interaction View

struct EnhancedChartInteractionView: NSViewRepresentable {
    let chartData: [ChartDataPoint]
    @Binding var selectedDataPoints: Set<UUID>
    @Binding var hoveredDataPoint: ChartDataPoint?
    @Binding var chartScale: Double
    @Binding var chartOffset: CGSize
    let chartProxy: ChartProxy
    /// Origin of the plot area inside the interaction view; `ChartProxy` positions are relative to it.
    let plotOrigin: CGPoint
    let selectedTimeRange: ChartTimeRange
    /// How the chart places times along its x-axis; points are drawn at
    /// `timeCompression.plotDate(for:)`, not at their own dates.
    var timeCompression: ChartTimeCompression = .identity
    
    func makeNSView(context: Context) -> NSView {
        let view = EnhancedChartView()
        view.setup(
            chartData: chartData,
            selectedDataPoints: selectedDataPoints,
            hoveredDataPoint: hoveredDataPoint,
            chartScale: chartScale,
            chartOffset: chartOffset,
            chartProxy: chartProxy,
            plotOrigin: plotOrigin,
            selectedTimeRange: selectedTimeRange
        )
        view.updateProxy(chartProxy: chartProxy, plotOrigin: plotOrigin, timeCompression: timeCompression)
        view.onSelectionChanged = { newSelection in
            selectedDataPoints = newSelection
        }
        view.onHoverChanged = { newHover in
            hoveredDataPoint = newHover
        }
        view.onScaleChanged = { newScale in
            chartScale = newScale
            if newScale <= 1 { chartOffset = .zero }
        }
        view.onOffsetChanged = { newOffset in
            // Width is the pan as a fraction of the visible span; there is
            // nothing to pan to beyond the ends of the series.
            let limit = max(0, (chartScale - 1) / 2)
            chartOffset = CGSize(width: max(-limit, min(limit, newOffset.width)), height: 0)
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        if let chartView = nsView as? EnhancedChartView {
            chartView.updateData(
                chartData: chartData,
                selectedDataPoints: selectedDataPoints,
                hoveredDataPoint: hoveredDataPoint,
                chartScale: chartScale,
                chartOffset: chartOffset
            )
            chartView.updateProxy(chartProxy: chartProxy, plotOrigin: plotOrigin, timeCompression: timeCompression)
        }
    }
}

class EnhancedChartView: NSView {
    var onSelectionChanged: ((Set<UUID>) -> Void)?
    var onHoverChanged: ((ChartDataPoint?) -> Void)?
    var onScaleChanged: ((Double) -> Void)?
    var onOffsetChanged: ((CGSize) -> Void)?
    
    private var trackingArea: NSTrackingArea?
    private var chartData: [ChartDataPoint] = []
    private var selectedDataPoints: Set<UUID> = []
    private var hoveredDataPoint: ChartDataPoint?
    private var chartScale: Double = 1.0
    private var chartOffset: CGSize = .zero
    private var chartProxy: ChartProxy?
    private var plotOrigin: CGPoint = .zero
    private var selectedTimeRange: ChartTimeRange = .month
    private var timeCompression: ChartTimeCompression = .identity

    /// SwiftUI and `ChartProxy` use a top-left origin; match it so box selection is not upside down.
    override var isFlipped: Bool { true }
    
    private var isSelecting = false
    private var isPanning = false
    private var selectionStartPoint: CGPoint = .zero
    private var selectionEndPoint: CGPoint = .zero
    
    func setup(
        chartData: [ChartDataPoint],
        selectedDataPoints: Set<UUID>,
        hoveredDataPoint: ChartDataPoint?,
        chartScale: Double,
        chartOffset: CGSize,
        chartProxy: ChartProxy,
        plotOrigin: CGPoint,
        selectedTimeRange: ChartTimeRange
    ) {
        self.plotOrigin = plotOrigin
        self.chartData = chartData
        self.selectedDataPoints = selectedDataPoints
        self.hoveredDataPoint = hoveredDataPoint
        self.chartScale = chartScale
        self.chartOffset = chartOffset
        self.chartProxy = chartProxy
        self.selectedTimeRange = selectedTimeRange
    }
    
    func updateData(
        chartData: [ChartDataPoint],
        selectedDataPoints: Set<UUID>,
        hoveredDataPoint: ChartDataPoint?,
        chartScale: Double,
        chartOffset: CGSize
    ) {
        self.chartData = chartData
        self.selectedDataPoints = selectedDataPoints
        self.hoveredDataPoint = hoveredDataPoint
        self.chartScale = chartScale
        self.chartOffset = chartOffset
    }
    
    /// The proxy and plot frame change whenever the chart relays out; a stale one maps to the wrong point.
    func updateProxy(chartProxy: ChartProxy, plotOrigin: CGPoint, timeCompression: ChartTimeCompression) {
        self.chartProxy = chartProxy
        self.plotOrigin = plotOrigin
        self.timeCompression = timeCompression
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        
        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }
        
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .mouseMoved,
            .activeInKeyWindow
        ]
        
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: options,
            owner: self,
            userInfo: nil
        )
        
        if let trackingArea = trackingArea {
            addTrackingArea(trackingArea)
        }
    }
    
    override func mouseMoved(with event: NSEvent) {
        guard let chartProxy = chartProxy else { return }
        
        let location = convert(event.locationInWindow, from: nil)
        updateHoveredDataPoint(at: location, chartProxy: chartProxy)
    }
    
    override func mouseEntered(with event: NSEvent) {
        guard let chartProxy = chartProxy else { return }
        
        let location = convert(event.locationInWindow, from: nil)
        updateHoveredDataPoint(at: location, chartProxy: chartProxy)
    }
    
    override func mouseExited(with event: NSEvent) {
        guard hoveredDataPoint != nil else { return }
        hoveredDataPoint = nil
        onHoverChanged?(nil)
    }
    
    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        
        // Always the start of this gesture; a stale point made the first drag jump.
        selectionStartPoint = location
        selectionEndPoint = location
        isSelecting = false
        isPanning = false

        if event.modifierFlags.contains(.option) {
            isPanning = chartScale > 1
        } else if event.modifierFlags.contains(.command) {
            // Multi-selection mode
            if let clickedPoint = findDataPointAt(location: location) {
                var newSelection = selectedDataPoints
                if newSelection.contains(clickedPoint.id) {
                    newSelection.remove(clickedPoint.id)
                } else {
                    newSelection.insert(clickedPoint.id)
                }
                onSelectionChanged?(newSelection)
            }
        } else if event.modifierFlags.contains(.shift) {
            // Range selection mode
            if let clickedPoint = findDataPointAt(location: location),
               let lastSelected = chartData.first(where: { selectedDataPoints.contains($0.id) }) {
                let rangeSelection = selectDataPointsInRange(from: lastSelected, to: clickedPoint)
                onSelectionChanged?(rangeSelection)
            }
        } else {
            // Start selection rectangle
            isSelecting = true
        }
    }
    
    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        
        if isSelecting {
            selectionEndPoint = location
            needsDisplay = true
            
            // Select points within rectangle
            let selectionRect = CGRect(
                x: min(selectionStartPoint.x, selectionEndPoint.x),
                y: min(selectionStartPoint.y, selectionEndPoint.y),
                width: abs(selectionEndPoint.x - selectionStartPoint.x),
                height: abs(selectionEndPoint.y - selectionStartPoint.y)
            )
            
            let pointsInRect = findDataPointsInRect(selectionRect)
            onSelectionChanged?(Set(pointsInRect.map { $0.id }))
        } else if isPanning, bounds.width > 0 {
            // Option-drag pans a zoomed chart, as a fraction of what is visible.
            let deltaX = location.x - selectionStartPoint.x
            onOffsetChanged?(CGSize(width: chartOffset.width + deltaX / bounds.width, height: 0))
            selectionStartPoint = location
        }
    }
    
    override func mouseUp(with event: NSEvent) {
        isSelecting = false
        isPanning = false
        needsDisplay = true
    }
    
    override func scrollWheel(with event: NSEvent) {
        // A plain scroll belongs to the page; only Option+scroll zooms the chart.
        guard event.modifierFlags.contains(.option), event.scrollingDeltaY != 0 else {
            super.scrollWheel(with: event)
            return
        }
        let zoomFactor = 1.0 + (event.scrollingDeltaY * 0.01)
        onScaleChanged?(max(1.0, min(ChartSeriesProcessing.maxZoom, chartScale * zoomFactor)))
    }

    override func magnify(with event: NSEvent) {
        // Trackpad pinch
        onScaleChanged?(max(1.0, min(ChartSeriesProcessing.maxZoom, chartScale * (1.0 + event.magnification))))
    }
    
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape key
            onSelectionChanged?(Set())
        case 0: // A key
            if event.modifierFlags.contains(.command) {
                onSelectionChanged?(Set(chartData.map { $0.id }))
            }
        default:
            super.keyDown(with: event)
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        if isSelecting {
            let selectionRect = CGRect(
                x: min(selectionStartPoint.x, selectionEndPoint.x),
                y: min(selectionStartPoint.y, selectionEndPoint.y),
                width: abs(selectionEndPoint.x - selectionStartPoint.x),
                height: abs(selectionEndPoint.y - selectionStartPoint.y)
            )
            
            NSColor.blue.withAlphaComponent(0.2).setFill()
            NSBezierPath(rect: selectionRect).fill()
            
            NSColor.blue.withAlphaComponent(0.8).setStroke()
            NSBezierPath(rect: selectionRect).stroke()
        }
    }
    
    override var acceptsFirstResponder: Bool {
        return true
    }
    
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
    
    // MARK: - Helper Methods
    
    private func updateHoveredDataPoint(at location: CGPoint, chartProxy: ChartProxy) {
        guard let closest = findDataPointAt(location: location) else { return }
        let plotX = ChartHitTesting.plotPoint(fromViewPoint: location, plotOrigin: plotOrigin).x
        guard let pointerDate: Date = chartProxy.value(atX: plotX) else { return }

        // Measured along the axis as drawn, so a squeezed overnight gap does
        // not count as hours away from the nearest point.
        let timeDifference = abs(timeCompression.plotDate(for: closest.date).timeIntervalSince(pointerDate))
        let tolerance: TimeInterval = {
            switch selectedTimeRange {
            case .day: return 3600
            case .week: return 21600
            case .month: return 86400
            case .threeMonths: return 259200
            case .sixMonths: return 604800
            case .year, .all: return 1209600
            case .custom: return 86400  // Default to day tolerance for custom range
            }
        }()

        // Only report a change when the hovered point actually changes; mouse-moved events are frequent.
        if timeDifference <= tolerance {
            guard hoveredDataPoint?.id != closest.id else { return }
            hoveredDataPoint = closest
            onHoverChanged?(closest)
        } else if hoveredDataPoint != nil {
            hoveredDataPoint = nil
            onHoverChanged?(nil)
        }
    }
    
    private func findDataPointAt(location: CGPoint) -> ChartDataPoint? {
        guard let chartProxy = chartProxy else { return nil }
        let plotX = ChartHitTesting.plotPoint(fromViewPoint: location, plotOrigin: plotOrigin).x
        guard let date: Date = chartProxy.value(atX: plotX),
              let index = ChartSeriesProcessing.nearestIndex(
                in: chartData.map { timeCompression.plotDate(for: $0.date) },
                to: date
              ) else { return nil }
        return chartData[index]
    }
    
    private func findDataPointsInRect(_ rect: CGRect) -> [ChartDataPoint] {
        guard let chartProxy = chartProxy else { return [] }

        let positions: [(id: UUID, point: CGPoint)] = chartData.compactMap { dataPoint in
            guard let x: CGFloat = chartProxy.position(forX: timeCompression.plotDate(for: dataPoint.date)),
                  let y: CGFloat = chartProxy.position(forY: dataPoint.value) else {
                return nil
            }
            return (dataPoint.id, CGPoint(x: x, y: y))
        }
        let ids = ChartHitTesting.selectedIDs(inViewRect: rect, plotOrigin: plotOrigin, positions: positions)
        return chartData.filter { ids.contains($0.id) }
    }
    
    private func selectDataPointsInRange(from start: ChartDataPoint, to end: ChartDataPoint) -> Set<UUID> {
        let sortedData = chartData.sorted { $0.date < $1.date }
        guard let startIndex = sortedData.firstIndex(where: { $0.id == start.id }),
              let endIndex = sortedData.firstIndex(where: { $0.id == end.id }) else {
            return selectedDataPoints
        }
        
        let range = min(startIndex, endIndex)...max(startIndex, endIndex)
        let rangePoints = Array(sortedData[range])
        
        var newSelection = selectedDataPoints
        for point in rangePoints {
            newSelection.insert(point.id)
        }
        
        return newSelection
    }
}
