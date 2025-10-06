//
//  CandlestickChartView.swift
//  Stockbar
//
//  Created for Phase 2: Chart Enhancements
//  Candlestick chart visualization using Swift Charts
//

import SwiftUI
import Charts

// MARK: - Candlestick Chart View

struct CandlestickChartView: View {
    let data: [OHLCDataPoint]
    let currency: String
    let settings: CandlestickChartSettings

    @State private var selectedCandle: OHLCDataPoint?
    @State private var showVolume: Bool = true
    @State private var showSMA20: Bool = false
    @State private var showSMA50: Bool = false
    @State private var showEMA12: Bool = false
    @State private var showBollingerBands: Bool = false
    @State private var showRSI: Bool = false
    @State private var showMACD: Bool = false

    // Interaction features (v2.3.1)
    @StateObject private var interactionManager = ChartInteractionManager()
    @StateObject private var annotationManager = AnnotationManager()
    @State private var showAnnotationEditor = false

    private let indicatorService = TechnicalIndicatorService.shared

    var body: some View {
        VStack(spacing: 0) {
            // Indicator toggles
            indicatorControlsView
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            // Price chart
            priceChartView
                .frame(height: settings.volumeDisplay == .separate ? 280 : 380)

            // Volume chart (if separate panel)
            if settings.volumeDisplay == .separate {
                volumeChartView
                    .frame(height: 80)
            }

            // RSI indicator (if enabled)
            if showRSI {
                rsiChartView
                    .frame(height: 100)
            }

            // MACD indicator (if enabled)
            if showMACD {
                macdChartView
                    .frame(height: 100)
            }
        }
    }

    // MARK: - Indicator Controls

    private var indicatorControlsView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Toggle("SMA 20", isOn: $showSMA20)
                    .toggleStyle(.button)
                    .controlSize(.small)

                Toggle("SMA 50", isOn: $showSMA50)
                    .toggleStyle(.button)
                    .controlSize(.small)

                Toggle("EMA 12", isOn: $showEMA12)
                    .toggleStyle(.button)
                    .controlSize(.small)

                Toggle("Bollinger", isOn: $showBollingerBands)
                    .toggleStyle(.button)
                    .controlSize(.small)

                Toggle("RSI", isOn: $showRSI)
                    .toggleStyle(.button)
                    .controlSize(.small)

                Toggle("MACD", isOn: $showMACD)
                    .toggleStyle(.button)
                    .controlSize(.small)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Price Chart

    private var priceChartView: some View {
        Chart {
            ForEach(data) { candle in
                // Candlestick body
                RectangleMark(
                    x: .value("Time", candle.timestamp),
                    yStart: .value("Open", candle.bodyBottom),
                    yEnd: .value("Close", candle.bodyTop),
                    width: .ratio(0.6)
                )
                .foregroundStyle(candle.isBullish ? settings.bullishSwiftUIColor : settings.bearishSwiftUIColor)
                .opacity(candle.id == selectedCandle?.id ? 0.7 : 1.0)

                // Upper wick
                RuleMark(
                    x: .value("Time", candle.timestamp),
                    yStart: .value("Body Top", candle.bodyTop),
                    yEnd: .value("High", candle.high)
                )
                .foregroundStyle(candle.isBullish ? settings.bullishSwiftUIColor : settings.bearishSwiftUIColor)
                .lineStyle(StrokeStyle(lineWidth: 1))

                // Lower wick
                RuleMark(
                    x: .value("Time", candle.timestamp),
                    yStart: .value("Low", candle.low),
                    yEnd: .value("Body Bottom", candle.bodyBottom)
                )
                .foregroundStyle(candle.isBullish ? settings.bullishSwiftUIColor : settings.bearishSwiftUIColor)
                .lineStyle(StrokeStyle(lineWidth: 1))

                // Selection indicator
                if let selected = selectedCandle, selected.id == candle.id {
                    RuleMark(x: .value("Time", candle.timestamp))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
                }
            }

            // SMA 20 overlay
            if showSMA20 {
                let sma20 = indicatorService.calculateSMA(data: data, period: 20)
                ForEach(Array(sma20.enumerated()), id: \.offset) { _, point in
                    LineMark(
                        x: .value("Time", point.0),
                        y: .value("SMA20", point.1)
                    )
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }

            // SMA 50 overlay
            if showSMA50 {
                let sma50 = indicatorService.calculateSMA(data: data, period: 50)
                ForEach(Array(sma50.enumerated()), id: \.offset) { _, point in
                    LineMark(
                        x: .value("Time", point.0),
                        y: .value("SMA50", point.1)
                    )
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }

            // EMA 12 overlay
            if showEMA12 {
                let ema12 = indicatorService.calculateEMA(data: data, period: 12)
                ForEach(Array(ema12.enumerated()), id: \.offset) { _, point in
                    LineMark(
                        x: .value("Time", point.0),
                        y: .value("EMA12", point.1)
                    )
                    .foregroundStyle(.purple)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }

            // Bollinger Bands overlay
            if showBollingerBands {
                let bb = indicatorService.calculateBollingerBands(data: data, period: 20, standardDeviations: 2.0)
                ForEach(Array(bb.enumerated()), id: \.offset) { _, band in
                    // Upper band
                    LineMark(
                        x: .value("Time", band.timestamp),
                        y: .value("Upper", band.upper)
                    )
                    .foregroundStyle(.blue.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

                    // Middle band
                    LineMark(
                        x: .value("Time", band.timestamp),
                        y: .value("Middle", band.middle)
                    )
                    .foregroundStyle(.blue.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1))

                    // Lower band
                    LineMark(
                        x: .value("Time", band.timestamp),
                        y: .value("Lower", band.lower)
                    )
                    .foregroundStyle(.blue.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                if let date = value.as(Date.self) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: settings.showGrid ? 0.5 : 0))
                        .foregroundStyle(.secondary.opacity(0.2))
                    AxisTick()
                    AxisValueLabel {
                        Text(formatXAxisDate(date))
                            .font(.caption2)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 6)) { value in
                if let price = value.as(Double.self) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: settings.showGrid ? 0.5 : 0))
                        .foregroundStyle(.secondary.opacity(0.2))
                    AxisTick()
                    AxisValueLabel {
                        Text(formatPrice(price))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .chartYScale(domain: yAxisRange)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                updateSelection(at: value.location, proxy: proxy, geometry: geometry)
                            }
                            .onEnded { _ in
                                selectedCandle = nil
                            }
                    )
                    .onAppear {
                        interactionManager.updateChartBounds(geometry.frame(in: .local))
                    }
            }
        }
        .overlay(alignment: .topLeading) {
            if let selected = selectedCandle {
                candleInfoOverlay(selected)
                    .padding(8)
            }
        }
        .overlay {
            // Crosshair overlay (v2.3.1)
            if let position = interactionManager.crosshairPosition {
                CrosshairOverlay(position: position, chartBounds: .zero)
            }
        }
        .overlay {
            // Annotations overlay (v2.3.1)
            AnnotationsOverlay(annotationManager: annotationManager, showEditor: $showAnnotationEditor)
        }
        .chartGestures(interactionManager: interactionManager)
        .contextMenu {
            Button("Add Annotation") {
                if let position = interactionManager.crosshairPosition {
                    let annotation = ChartAnnotation(
                        type: .text,
                        position: position,
                        text: "New Note"
                    )
                    annotationManager.addAnnotation(annotation)
                }
            }
            Button("Clear Annotations") {
                annotationManager.clearAnnotations()
            }
            Button("Reset Zoom") {
                interactionManager.resetZoom()
            }
        }
        .sheet(isPresented: $showAnnotationEditor) {
            if let selected = annotationManager.selectedAnnotation {
                AnnotationEditorView(
                    annotation: .init(
                        get: { selected },
                        set: { annotationManager.updateAnnotation($0) }
                    ),
                    isPresented: $showAnnotationEditor
                )
            }
        }
    }

    // MARK: - Volume Chart

    private var volumeChartView: some View {
        Chart(data) { candle in
            BarMark(
                x: .value("Time", candle.timestamp),
                y: .value("Volume", candle.volume)
            )
            .foregroundStyle(candle.isBullish ? settings.bullishSwiftUIColor.opacity(0.6) : settings.bearishSwiftUIColor.opacity(0.6))
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.secondary.opacity(0.2))
                AxisValueLabel {
                    if let volume = value.as(Int64.self) {
                        Text(formatVolume(volume))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - RSI Chart

    private var rsiChartView: some View {
        let rsiData = indicatorService.calculateRSI(data: data, period: 14)

        return Chart {
            ForEach(Array(rsiData.enumerated()), id: \.offset) { _, point in
                LineMark(
                    x: .value("Time", point.0),
                    y: .value("RSI", point.1)
                )
                .foregroundStyle(.purple)
                .lineStyle(StrokeStyle(lineWidth: 1.5))

                AreaMark(
                    x: .value("Time", point.0),
                    yStart: .value("Zero", 0),
                    yEnd: .value("RSI", point.1)
                )
                .foregroundStyle(.purple.opacity(0.1))
            }

            // Overbought line (70)
            RuleMark(y: .value("Overbought", 70))
                .foregroundStyle(.red.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

            // Oversold line (30)
            RuleMark(y: .value("Oversold", 30))
                .foregroundStyle(.green.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 30, 50, 70, 100]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.secondary.opacity(0.2))
                AxisValueLabel {
                    if let rsi = value.as(Double.self) {
                        Text(String(format: "%.0f", rsi))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            Text("RSI (14)")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(4)
        }
    }

    // MARK: - MACD Chart

    private var macdChartView: some View {
        let macdData = indicatorService.calculateMACD(data: data, fastPeriod: 12, slowPeriod: 26, signalPeriod: 9)

        return Chart {
            ForEach(Array(macdData.enumerated()), id: \.offset) { _, point in
                // MACD line
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("MACD", point.macdLine)
                )
                .foregroundStyle(.blue)
                .lineStyle(StrokeStyle(lineWidth: 1.5))

                // Signal line
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Signal", point.signalLine)
                )
                .foregroundStyle(.orange)
                .lineStyle(StrokeStyle(lineWidth: 1.5))

                // Histogram
                BarMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Histogram", point.histogram)
                )
                .foregroundStyle(point.histogram >= 0 ? Color.green.opacity(0.5) : Color.red.opacity(0.5))
            }

            // Zero line
            RuleMark(y: .value("Zero", 0))
                .foregroundStyle(.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.secondary.opacity(0.2))
                AxisValueLabel {
                    if let macd = value.as(Double.self) {
                        Text(String(format: "%.2f", macd))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 8) {
                Text("MACD (12,26,9)")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                HStack(spacing: 4) {
                    Circle()
                        .fill(.blue)
                        .frame(width: 6, height: 6)
                    Text("MACD")
                        .font(.caption2)

                    Circle()
                        .fill(.orange)
                        .frame(width: 6, height: 6)
                    Text("Signal")
                        .font(.caption2)
                }
            }
            .padding(4)
        }
    }

    // MARK: - Info Overlay

    private func candleInfoOverlay(_ candle: OHLCDataPoint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(formatFullDate(candle.timestamp))
                .font(.caption)
                .fontWeight(.semibold)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("O: \(formatPrice(candle.open))", systemImage: "circle")
                        .font(.caption2)
                    Label("H: \(formatPrice(candle.high))", systemImage: "arrow.up")
                        .font(.caption2)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Label("L: \(formatPrice(candle.low))", systemImage: "arrow.down")
                        .font(.caption2)
                    Label("C: \(formatPrice(candle.close))", systemImage: "circle.fill")
                        .font(.caption2)
                }
            }

            Text("Vol: \(formatVolume(candle.volume))")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(Color(.windowBackgroundColor).opacity(0.95))
        .cornerRadius(8)
        .shadow(radius: 2)
    }

    // MARK: - Helper Methods

    private func updateSelection(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }

        let frame = geometry[plotFrame]
        let xPosition = location.x - frame.origin.x
        let relativeX = xPosition / frame.width

        if relativeX >= 0 && relativeX <= 1 {
            let index = Int(relativeX * Double(data.count))
            if index >= 0 && index < data.count {
                selectedCandle = data[index]
            }
        }
    }

    private var yAxisRange: ClosedRange<Double> {
        guard !data.isEmpty else { return 0...100 }

        let lows = data.map { $0.low }
        let highs = data.map { $0.high }

        guard let minLow = lows.min(), let maxHigh = highs.max() else {
            return 0...100
        }

        let range = maxHigh - minLow
        let buffer = range * 0.05
        return (minLow - buffer)...(maxHigh + buffer)
    }

    private func formatXAxisDate(_ date: Date) -> String {
        let formatter = DateFormatter()

        // Determine format based on data range
        if let firstDate = data.first?.timestamp,
           let lastDate = data.last?.timestamp {
            let daysDiff = Calendar.current.dateComponents([.day], from: firstDate, to: lastDate).day ?? 0

            if daysDiff <= 1 {
                formatter.dateFormat = "HH:mm"
            } else if daysDiff <= 30 {
                formatter.dateFormat = "MMM d"
            } else {
                formatter.dateFormat = "MMM yy"
            }
        } else {
            formatter.dateFormat = "MMM d"
        }

        return formatter.string(from: date)
    }

    private func formatFullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formatPrice(_ price: Double) -> String {
        String(format: "%.2f", price)
    }

    private func formatVolume(_ volume: Int64) -> String {
        let millions = Double(volume) / 1_000_000
        if millions >= 1 {
            return String(format: "%.1fM", millions)
        } else {
            let thousands = Double(volume) / 1_000
            return String(format: "%.0fK", thousands)
        }
    }
}

// MARK: - Preview

#Preview {
    let sampleData = (0..<30).map { i in
        let basePrice = 150.0 + Double.random(in: -10...10)
        let open = basePrice + Double.random(in: -2...2)
        let close = basePrice + Double.random(in: -2...2)
        let high = max(open, close) + Double.random(in: 0...3)
        let low = min(open, close) - Double.random(in: 0...3)

        return OHLCDataPoint(
            timestamp: Date().addingTimeInterval(TimeInterval(i * 86400)),
            open: open,
            high: high,
            low: low,
            close: close,
            volume: Int64.random(in: 10_000_000...50_000_000)
        )
    }

    return CandlestickChartView(
        data: sampleData,
        currency: "USD",
        settings: CandlestickChartSettings()
    )
    .frame(height: 500)
    .padding()
}
