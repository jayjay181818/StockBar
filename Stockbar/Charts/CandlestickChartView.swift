//
//  CandlestickChartView.swift
//  Stockbar
//
//  Created for Phase 2: Chart Enhancements
//  Candlestick chart visualization using Swift Charts
//

import Charts
import SwiftUI

// MARK: - Candlestick Chart View

struct CandlestickChartView: View {
    let data: [OHLCDataPoint]
    let currency: String
    let settings: CandlestickChartSettings
    let symbol: String?

    /// Candle held by a click or drag.
    @State private var selectedCandle: OHLCDataPoint?
    /// Candle under the pointer, shown as the crosshair when it is enabled.
    @State private var hoveredCandle: OHLCDataPoint?
    /// Last candle the pointer was over; the context menu uses it, since the menu has no pointer position.
    @State private var lastPointerCandle: OHLCDataPoint?
    /// Indicator and option toggles, remembered between reloads and launches.
    @State private var toggles: CandlestickChartToggles
    /// Indicator series for the candles on screen, computed once per data set
    /// rather than on every redraw.
    @State private var indicatorCache = CandleIndicatorCache()

    private let annotationService = ChartAnnotationService.shared
    
    @State private var showAnnotationEditor = false
    @State private var selectedAnnotation: ChartAnnotation?
    /// Annotation being edited. A new one is only stored when the editor saves it.
    @State private var draftAnnotation: ChartAnnotation?
    @State private var draftIsNew = false
    @State private var showClearAnnotationsConfirmation = false

    private let indicatorService = TechnicalIndicatorService.shared

    // Initializer to allow symbol to be optional
    init(data: [OHLCDataPoint], currency: String, settings: CandlestickChartSettings, symbol: String? = nil) {
        self.data = data
        self.currency = currency
        self.settings = settings
        self.symbol = symbol
        _toggles = State(initialValue: CandlestickChartToggles.load(defaults: settings))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Indicator toggles
            chartToolbar
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
            if toggles.rsi {
                rsiChartView
                    .frame(height: 100)
            }

            // MACD indicator (if enabled)
            if toggles.macd {
                macdChartView
                    .frame(height: 100)
            }
        }
        .onChange(of: toggles) { _, newValue in newValue.save() }
    }

    /// One x-axis for the price chart and every panel under it, so a date sits
    /// at the same horizontal position in all of them.
    private var sharedXDomain: ClosedRange<Date> {
        ChartSeriesProcessing.paddedDateDomain(data.map(\.timestamp)) ?? Date.now...Date.now.addingTimeInterval(1)
    }

    /// Annotations inside the candles' date span; ones outside must not stretch the axis.
    private var annotationsInView: [ChartAnnotation] {
        guard let symbol else { return [] }
        let domain = sharedXDomain
        return annotationService.getAnnotations(for: symbol)
            .filter { domain.contains($0.date) }
            .sorted { $0.date < $1.date }
    }

    private func annotationMenuTitle(_ annotation: ChartAnnotation) -> String {
        let text = annotation.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = text.isEmpty ? "Untitled" : String(text.prefix(40))
        return "\(label) – \(annotation.date.formatted(date: .abbreviated, time: .omitted))"
    }

    private func indicator<T>(_ name: String, _ compute: () -> T) -> T {
        indicatorCache.value(name, for: data, compute: compute)
    }

    // MARK: - Indicator Controls

    private var chartToolbar: some View {
        HStack(spacing: 8) {
            Menu {
                Section("Moving averages") {
                    Toggle("SMA 20", isOn: $toggles.sma20)
                    Toggle("SMA 50", isOn: $toggles.sma50)
                    Toggle("EMA 12", isOn: $toggles.ema12)
                }

                Section("Bands and panels") {
                    Toggle("Bollinger Bands", isOn: $toggles.bollingerBands)
                    Toggle("RSI", isOn: $toggles.rsi)
                    Toggle("MACD", isOn: $toggles.macd)
                }
            } label: {
                Label("Indicators", systemImage: "chart.xyaxis.line")
            }
            .menuStyle(.borderedButton)
            .controlSize(.small)

            Menu {
                Text("Style: \(settings.style.description)")
                Text("Volume: \(settings.volumeDisplay.description)")
                Divider()
                Toggle("Grid lines", isOn: $toggles.gridLines)
                Toggle("Crosshair", isOn: $toggles.crosshair)
            } label: {
                Label("Options", systemImage: "slider.horizontal.3")
            }
            .menuStyle(.borderedButton)
            .controlSize(.small)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Price Chart

    private var priceChartView: some View {
        // The x axis spans the candles only; annotations outside them must not stretch it.
        let visibleAnnotations = annotationsInView

        return Chart {
            ForEach(data) { candle in
                // Candlestick body
                RectangleMark(
                    x: .value("Time", candle.timestamp),
                    yStart: .value("Open", candle.bodyBottom),
                    yEnd: .value("Close", candle.bodyTop),
                    width: .ratio(0.6)
                )
                .foregroundStyle(candle.isBullish ? settings.bullishSwiftUIColor : settings.bearishSwiftUIColor)
                .opacity(candle.id == displayedCandle?.id ? 0.7 : 1.0)

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
                if let selected = displayedCandle, selected.id == candle.id {
                    RuleMark(x: .value("Time", candle.timestamp))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
                }
            }
            
            // Annotations
            ForEach(visibleAnnotations) { annotation in
                PointMark(
                    x: .value("Time", annotation.date),
                    y: .value("Price", annotation.price)
                )
                .symbol {
                    AnnotationMarkView(annotation: annotation)
                }
                .annotation(position: .top) {
                    Text(annotation.text)
                        .font(.caption2)
                        .foregroundColor(annotation.color)
                        .padding(2)
                        .background(Color(.windowBackgroundColor).opacity(0.7))
                        .cornerRadius(4)
                }
            }

            // SMA 20 overlay
            if toggles.sma20 {
                let sma20 = indicator("sma20") { indicatorService.calculateSMA(data: data, period: 20) }
                ForEach(Array(sma20.enumerated()), id: \.offset) { _, point in
                    LineMark(
                        x: .value("Time", point.0),
                        y: .value("SMA20", point.1),
                        series: .value("Series", "SMA 20")
                    )
                        .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }

            // SMA 50 overlay
            if toggles.sma50 {
                let sma50 = indicator("sma50") { indicatorService.calculateSMA(data: data, period: 50) }
                ForEach(Array(sma50.enumerated()), id: \.offset) { _, point in
                    LineMark(
                        x: .value("Time", point.0),
                        y: .value("SMA50", point.1),
                        series: .value("Series", "SMA 50")
                    )
                        .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }

            // EMA 12 overlay
            if toggles.ema12 {
                let ema12 = indicator("ema12") { indicatorService.calculateEMA(data: data, period: 12) }
                ForEach(Array(ema12.enumerated()), id: \.offset) { _, point in
                    LineMark(
                        x: .value("Time", point.0),
                        y: .value("EMA12", point.1),
                        series: .value("Series", "EMA 12")
                    )
                        .foregroundStyle(.purple)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }

            // Bollinger Bands overlay
            if toggles.bollingerBands {
                let bb = indicator("bollinger") {
                    indicatorService.calculateBollingerBands(data: data, period: 20, standardDeviations: 2.0)
                }
                ForEach(Array(bb.enumerated()), id: \.offset) { _, band in
                    // Upper band
                    LineMark(
                        x: .value("Time", band.timestamp),
                        y: .value("Upper", band.upper),
                        series: .value("Series", "Bollinger upper")
                    )
                        .foregroundStyle(.blue.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

                    // Middle band
                    LineMark(
                        x: .value("Time", band.timestamp),
                        y: .value("Middle", band.middle),
                        series: .value("Series", "Bollinger middle")
                    )
                        .foregroundStyle(.blue.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1))

                    // Lower band
                    LineMark(
                        x: .value("Time", band.timestamp),
                        y: .value("Lower", band.lower),
                        series: .value("Series", "Bollinger lower")
                    )
                        .foregroundStyle(.blue.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                if let date = value.as(Date.self) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: toggles.gridLines ? 0.5 : 0))
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
                    AxisGridLine(stroke: StrokeStyle(lineWidth: toggles.gridLines ? 0.5 : 0))
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
        .chartXScale(domain: sharedXDomain)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let candle = candleNearPointer(at: location, proxy: proxy, geometry: geometry)
                            if candle?.id != hoveredCandle?.id { hoveredCandle = candle }
                            if let candle, candle.id != lastPointerCandle?.id { lastPointerCandle = candle }
                        case .ended:
                            // lastPointerCandle is kept: the context menu opens after the pointer leaves tracking.
                            if hoveredCandle != nil { hoveredCandle = nil }
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let candle = candleNearPointer(at: value.location, proxy: proxy, geometry: geometry)
                                if candle?.id != selectedCandle?.id { selectedCandle = candle }
                                if let candle { lastPointerCandle = candle }
                            }
                            .onEnded { _ in
                                selectedCandle = nil
                            }
                    )
            }
        }
        .overlay(alignment: .topLeading) {
            if let selected = displayedCandle {
                candleInfoOverlay(selected)
                    .padding(8)
            }
        }
        .accessibilityLabel("\(symbol ?? "Price") candlestick chart")
        .accessibilityValue(candlestickAccessibilitySummary)
        .contextMenu {
            Button("Add Annotation") {
                guard let currentSymbol = symbol,
                      let candle = lastPointerCandle ?? data.last else { return }

                // Nothing is stored until the editor's Save; Cancel leaves no annotation behind.
                draftAnnotation = ChartAnnotation(
                    type: .text,
                    date: candle.timestamp,
                    price: candle.close,
                    text: "New Note",
                    symbol: currentSymbol
                )
                draftIsNew = true
                showAnnotationEditor = true
            }
            .disabled(symbol == nil || data.isEmpty)

            // Each annotation in view can be edited or deleted on its own;
            // before, the only way to remove one was to clear them all.
            let annotations = annotationsInView
            if !annotations.isEmpty {
                Menu("Edit Annotation") {
                    ForEach(annotations) { annotation in
                        Button(annotationMenuTitle(annotation)) {
                            draftAnnotation = annotation
                            draftIsNew = false
                            showAnnotationEditor = true
                        }
                    }
                }
                Menu("Delete Annotation") {
                    ForEach(annotations) { annotation in
                        Button(annotationMenuTitle(annotation), role: .destructive) {
                            annotationService.removeAnnotation(id: annotation.id)
                            if selectedAnnotation?.id == annotation.id { selectedAnnotation = nil }
                        }
                    }
                }
            }
            Button("Clear Annotations…", role: .destructive) {
                showClearAnnotationsConfirmation = true
            }
            .disabled(symbol.map { annotationService.getAnnotations(for: $0).isEmpty } ?? true)
        }
        .confirmationDialog(
            "Clear all annotations for \(symbol ?? "this symbol")?",
            isPresented: $showClearAnnotationsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Annotations", role: .destructive) {
                if let currentSymbol = symbol {
                    annotationService.clearAnnotations(for: currentSymbol)
                    selectedAnnotation = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The notes and markers you added to this chart will be deleted. This can't be undone.")
        }
        .sheet(isPresented: $showAnnotationEditor, onDismiss: { draftAnnotation = nil }) {
            if let draft = draftAnnotation {
                AnnotationEditorView(
                    annotation: Binding(
                        get: { draftAnnotation ?? draft },
                        set: { updated in
                            // Only Save writes to this binding.
                            if draftIsNew {
                                annotationService.addAnnotation(updated)
                                draftIsNew = false
                            } else {
                                annotationService.updateAnnotation(updated)
                            }
                            draftAnnotation = updated
                            selectedAnnotation = updated
                        }
                    ),
                    isPresented: $showAnnotationEditor
                )
            }
        }
    }

    // MARK: - Volume Chart

    private var volumeChartView: some View {
        Chart(data) { candle in
            if let volume = candle.volume {
                BarMark(
                    x: .value("Time", candle.timestamp),
                    y: .value("Volume", volume)
                )
                .foregroundStyle(candle.isBullish ? settings.bullishSwiftUIColor.opacity(0.6) : settings.bearishSwiftUIColor.opacity(0.6))
            }
        }
        .chartXAxis(.hidden)
        .chartXScale(domain: sharedXDomain)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume")
        .accessibilityValue(data.last?.volume.map { "Latest \(formatVolume($0))" } ?? "No volume data")
    }

    // MARK: - RSI Chart

    private var rsiChartView: some View {
        let rsiData = indicator("rsi") { indicatorService.calculateRSI(data: data, period: 14) }

        return Chart {
            ForEach(Array(rsiData.enumerated()), id: \.offset) { _, point in
                LineMark(
                    x: .value("Time", point.0),
                    y: .value("RSI", point.1),
                    series: .value("Series", "RSI")
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
        .chartXScale(domain: sharedXDomain)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("RSI, 14 periods")
        .accessibilityValue(rsiData.last.map { String(format: "Latest %.0f", $0.1) } ?? "No data")
    }

    // MARK: - MACD Chart

    private var macdChartView: some View {
        let macdData = indicator("macd") {
            indicatorService.calculateMACD(data: data, fastPeriod: 12, slowPeriod: 26, signalPeriod: 9)
        }

        return Chart {
            ForEach(Array(macdData.enumerated()), id: \.offset) { _, point in
                // MACD line
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("MACD", point.macdLine),
                    series: .value("Series", "MACD")
                )
                .foregroundStyle(.blue)
                .lineStyle(StrokeStyle(lineWidth: 1.5))

                // Signal line
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Signal", point.signalLine),
                    series: .value("Series", "Signal")
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
        .chartXScale(domain: sharedXDomain)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("MACD, 12, 26 and 9 periods")
        .accessibilityValue(macdData.last.map {
            String(format: "MACD %.2f, signal %.2f", $0.macdLine, $0.signalLine)
        } ?? "No data")
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

            Text("Vol: \(candle.volume.map(formatVolume) ?? "Unavailable")")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(Color(.windowBackgroundColor).opacity(0.95))
        .cornerRadius(8)
        .shadow(radius: 2)
    }

    // MARK: - Helper Methods

    /// The candle nearest in time to the pointer, found from the chart's own x scale
    /// so uneven spacing (weekends, gaps) and the plot area's inset are respected.
    private func candleNearPointer(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> OHLCDataPoint? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let frame = geometry[plotFrame]
        let x = location.x - frame.origin.x
        guard x >= 0, x <= frame.width,
              let date: Date = proxy.value(atX: x),
              let index = ChartSeriesProcessing.nearestIndex(in: data.map(\.timestamp), to: date) else { return nil }
        return data[index]
    }

    private var displayedCandle: OHLCDataPoint? {
        selectedCandle ?? (toggles.crosshair ? hoveredCandle : nil)
    }

    private var candlestickAccessibilitySummary: String {
        guard let first = data.first, let last = data.last else { return "No data" }
        let low = data.map(\.low).min() ?? first.low
        let high = data.map(\.high).max() ?? last.high
        return "\(data.count) candles. Latest close \(formatPrice(last.close)). Low \(formatPrice(low)), high \(formatPrice(high))."
    }

    private var yAxisRange: ClosedRange<Double> {
        ChartSeriesProcessing.paddedDomain(data.map(\.low) + data.map(\.high), fallback: 0...100)
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

// MARK: - Annotation Mark View
struct AnnotationMarkView: View {
    let annotation: ChartAnnotation
    
    var body: some View {
        Group {
            switch annotation.type {
            case .text:
                Image(systemName: "text.bubble.fill")
            case .earningsMarker:
                Image(systemName: "dollarsign.circle.fill")
            case .note:
                Image(systemName: "note.text")
            case .buyMarker:
                Image(systemName: "arrow.up.circle.fill")
            case .sellMarker:
                Image(systemName: "arrow.down.circle.fill")
            }
        }
        .foregroundColor(annotation.color)
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
        settings: CandlestickChartSettings(),
        symbol: "AAPL"
    )
    .frame(height: 500)
    .padding()
}

// MARK: - Remembered toggles

/// Which indicators and options are switched on. Stored so they survive the
/// chart being rebuilt, which happens on every data reload.
struct CandlestickChartToggles: Codable, Equatable {
    var sma20 = false
    var sma50 = false
    var ema12 = false
    var bollingerBands = false
    var rsi = false
    var macd = false
    var gridLines = true
    var crosshair = true

    private static let storageKey = "candlestickChartToggles"

    static func load(
        defaults settings: CandlestickChartSettings,
        from store: UserDefaults = StockbarRuntimeStorage.userDefaults
    ) -> CandlestickChartToggles {
        if let data = store.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(CandlestickChartToggles.self, from: data) {
            return decoded
        }
        var toggles = CandlestickChartToggles()
        toggles.gridLines = settings.showGrid
        toggles.crosshair = settings.showCrosshair
        return toggles
    }

    func save(to store: UserDefaults = StockbarRuntimeStorage.userDefaults) {
        if let encoded = try? JSONEncoder().encode(self) {
            store.set(encoded, forKey: Self.storageKey)
        }
    }
}

/// Indicator series for one set of candles.
@MainActor
final class CandleIndicatorCache {
    private var signature: String?
    private var values: [String: Any] = [:]

    func value<T>(_ name: String, for data: [OHLCDataPoint], compute: () -> T) -> T {
        let current = [
            String(data.count),
            String(data.first?.timestamp.timeIntervalSince1970 ?? 0),
            String(data.last?.timestamp.timeIntervalSince1970 ?? 0),
            String(data.last?.close ?? 0)
        ].joined(separator: "|")
        if signature != current {
            signature = current
            values.removeAll()
        }
        if let cached = values[name] as? T { return cached }
        let computed = compute()
        values[name] = computed
        return computed
    }
}
