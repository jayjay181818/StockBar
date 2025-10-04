//
//  VolumeChartView.swift
//  Stockbar
//
//  Created for Phase 2: Chart Enhancements
//  Standalone volume chart with volume profile and indicators
//

import SwiftUI
import Charts

// MARK: - Volume Chart View

struct VolumeChartView: View {
    let data: [OHLCDataPoint]
    let currency: String

    @State private var selectedBar: OHLCDataPoint?
    @State private var showVolumeMA: Bool = false
    @State private var volumeMAPeriod: Int = 20
    @State private var showOBV: Bool = false
    @State private var showVolumeProfile: Bool = false

    private let indicatorService = TechnicalIndicatorService.shared

    var body: some View {
        VStack(spacing: 0) {
            // Controls
            controlsView
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            // Main volume chart
            volumeChartView
                .frame(height: 300)

            // OBV chart (if enabled)
            if showOBV {
                obvChartView
                    .frame(height: 120)
            }

            // Volume profile (if enabled)
            if showVolumeProfile {
                volumeProfileView
                    .frame(height: 200)
            }
        }
    }

    // MARK: - Controls

    private var controlsView: some View {
        HStack(spacing: 12) {
            Toggle("Volume MA", isOn: $showVolumeMA)
                .toggleStyle(.button)
                .controlSize(.small)

            if showVolumeMA {
                Picker("Period", selection: $volumeMAPeriod) {
                    Text("10").tag(10)
                    Text("20").tag(20)
                    Text("50").tag(50)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
                .controlSize(.small)
            }

            Toggle("OBV", isOn: $showOBV)
                .toggleStyle(.button)
                .controlSize(.small)

            Toggle("Profile", isOn: $showVolumeProfile)
                .toggleStyle(.button)
                .controlSize(.small)

            Spacer()
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Volume Chart

    private var volumeChartView: some View {
        Chart {
            ForEach(data) { candle in
                BarMark(
                    x: .value("Time", candle.timestamp),
                    y: .value("Volume", candle.volume)
                )
                .foregroundStyle(volumeColor(for: candle))
                .opacity(candle.id == selectedBar?.id ? 0.5 : 1.0)

                // Selection indicator
                if let selected = selectedBar, selected.id == candle.id {
                    RuleMark(x: .value("Time", candle.timestamp))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
                }
            }

            // Volume MA overlay
            if showVolumeMA {
                let volumeMA = indicatorService.calculateVolumeMA(data: data, period: volumeMAPeriod)
                ForEach(Array(volumeMA.enumerated()), id: \.offset) { _, point in
                    LineMark(
                        x: .value("Time", point.0),
                        y: .value("Volume MA", point.1)
                    )
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                if let date = value.as(Date.self) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
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
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.secondary.opacity(0.2))
                AxisTick()
                AxisValueLabel {
                    if let volume = value.as(Int64.self) {
                        Text(formatVolume(volume))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
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
                                selectedBar = nil
                            }
                    )
            }
        }
        .overlay(alignment: .topLeading) {
            if let selected = selectedBar {
                volumeInfoOverlay(selected)
                    .padding(8)
            }
        }
    }

    // MARK: - OBV Chart

    private var obvChartView: some View {
        let obvData = indicatorService.calculateOBV(data: data)

        return Chart {
            ForEach(Array(obvData.enumerated()), id: \.offset) { _, point in
                LineMark(
                    x: .value("Time", point.0),
                    y: .value("OBV", point.1)
                )
                .foregroundStyle(.purple)
                .lineStyle(StrokeStyle(lineWidth: 1.5))

                AreaMark(
                    x: .value("Time", point.0),
                    yStart: .value("Zero", obvData.first?.1 ?? 0),
                    yEnd: .value("OBV", point.1)
                )
                .foregroundStyle(.purple.opacity(0.1))
            }

            // Zero line
            if let firstOBV = obvData.first?.1 {
                RuleMark(y: .value("Zero", firstOBV))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.secondary.opacity(0.2))
                AxisValueLabel {
                    if let obv = value.as(Int64.self) {
                        Text(formatVolume(obv))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            Text("On-Balance Volume (OBV)")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(4)
        }
    }

    // MARK: - Volume Profile

    private var volumeProfileView: some View {
        let priceRange = calculatePriceRange()
        let volumeProfile = calculateVolumeProfile(priceRange: priceRange)

        return Chart {
            ForEach(volumeProfile, id: \.priceLevel) { profile in
                BarMark(
                    x: .value("Volume", profile.volume),
                    y: .value("Price", profile.priceLevel),
                    height: .fixed(8)
                )
                .foregroundStyle(profile.isBullish ? Color.green.opacity(0.6) : Color.red.opacity(0.6))
            }
        }
        .chartXAxis {
            AxisMarks(position: .bottom, values: .automatic(desiredCount: 3)) { value in
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
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.secondary.opacity(0.2))
                AxisValueLabel {
                    if let price = value.as(Double.self) {
                        Text(String(format: "%.2f", price))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            Text("Volume Profile by Price")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(4)
        }
    }

    // MARK: - Helper Methods

    private func volumeColor(for candle: OHLCDataPoint) -> Color {
        if candle.isBullish {
            return .green.opacity(0.7)
        } else {
            return .red.opacity(0.7)
        }
    }

    private func updateSelection(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }

        let frame = geometry[plotFrame]
        let xPosition = location.x - frame.origin.x
        let relativeX = xPosition / frame.width

        if relativeX >= 0 && relativeX <= 1 {
            let index = Int(relativeX * Double(data.count))
            if index >= 0 && index < data.count {
                selectedBar = data[index]
            }
        }
    }

    private func volumeInfoOverlay(_ candle: OHLCDataPoint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(formatFullDate(candle.timestamp))
                .font(.caption)
                .fontWeight(.semibold)

            HStack(spacing: 8) {
                Text("Volume:")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(formatVolume(candle.volume))
                    .font(.caption2)
                    .fontWeight(.medium)
            }

            HStack(spacing: 8) {
                Text("Price:")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("\(currency) \(formatPrice(candle.close))")
                    .font(.caption2)
                    .fontWeight(.medium)
            }

            HStack(spacing: 8) {
                Text("Direction:")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(candle.isBullish ? "Bullish" : "Bearish")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(candle.isBullish ? .green : .red)
            }
        }
        .padding(8)
        .background(Color(.windowBackgroundColor).opacity(0.95))
        .cornerRadius(8)
        .shadow(radius: 2)
    }

    // MARK: - Volume Profile Calculation

    struct VolumeProfileLevel: Identifiable {
        let id = UUID()
        let priceLevel: Double
        let volume: Int64
        let isBullish: Bool
    }

    private func calculatePriceRange() -> (min: Double, max: Double) {
        guard !data.isEmpty else { return (0, 100) }

        let lows = data.map { $0.low }
        let highs = data.map { $0.high }

        let minPrice = lows.min() ?? 0
        let maxPrice = highs.max() ?? 100

        return (minPrice, maxPrice)
    }

    private func calculateVolumeProfile(priceRange: (min: Double, max: Double), bins: Int = 30) -> [VolumeProfileLevel] {
        guard !data.isEmpty else { return [] }

        let priceStep = (priceRange.max - priceRange.min) / Double(bins)
        var volumeByPrice: [Int: (volume: Int64, bullish: Int64, bearish: Int64)] = [:]

        // Distribute volume across price levels
        for candle in data {
            let avgPrice = (candle.high + candle.low) / 2
            let bin = Int((avgPrice - priceRange.min) / priceStep)
            let safeBin = max(0, min(bins - 1, bin))

            let current = volumeByPrice[safeBin] ?? (0, 0, 0)
            if candle.isBullish {
                volumeByPrice[safeBin] = (current.volume + candle.volume, current.bullish + candle.volume, current.bearish)
            } else {
                volumeByPrice[safeBin] = (current.volume + candle.volume, current.bullish, current.bearish + candle.volume)
            }
        }

        // Create profile levels
        return volumeByPrice.map { bin, values in
            let priceLevel = priceRange.min + (Double(bin) + 0.5) * priceStep
            let isBullish = values.bullish > values.bearish
            return VolumeProfileLevel(priceLevel: priceLevel, volume: values.volume, isBullish: isBullish)
        }.sorted { $0.priceLevel < $1.priceLevel }
    }

    // MARK: - Formatting

    private func formatXAxisDate(_ date: Date) -> String {
        let formatter = DateFormatter()

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
        let absVolume = abs(volume)
        let millions = Double(absVolume) / 1_000_000
        if millions >= 1 {
            let sign = volume < 0 ? "-" : ""
            return "\(sign)\(String(format: "%.1fM", millions))"
        } else {
            let thousands = Double(absVolume) / 1_000
            let sign = volume < 0 ? "-" : ""
            return "\(sign)\(String(format: "%.0fK", thousands))"
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

    return VolumeChartView(
        data: sampleData,
        currency: "USD"
    )
    .frame(height: 600)
    .padding()
}
