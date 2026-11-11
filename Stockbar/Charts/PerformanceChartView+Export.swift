import AppKit
import Charts
import SwiftUI

extension PerformanceChartView {
    var exportSection: some View {
        VStack {
            Button(action: { showingExportOptions.toggle() }) {
                HStack {
                    Text("Export Options")
                    Spacer()
                    Image(systemName: showingExportOptions ? "chevron.up" : "chevron.down")
                }
            }
            .buttonStyle(PlainButtonStyle())
            
            if showingExportOptions {
                exportOptionsView
                    .onAppear {
                        // Auto-resizing will handle layout changes
                    }
            }
        }
    }

    @ViewBuilder
    var dataFiltersSection: some View {
        VStack {
            Button(action: { showingDataFilters.toggle() }) {
                HStack {
                    Text("Data Filters")
                    Spacer()
                    Image(systemName: showingDataFilters ? "chevron.up" : "chevron.down")
                }
            }
            .buttonStyle(PlainButtonStyle())
            
            if showingDataFilters {
                dataFiltersView
                    .onAppear {
                        // Auto-resizing will handle layout changes
                    }
            }
        }
    }

    @ViewBuilder
    var dataFiltersView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Value threshold filter
            HStack {
                Text("Value Threshold:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                TextField("0.0", value: $valueThreshold, format: .number)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 80)
                
                Button("Apply") {
                    // The load task also restarts when the threshold changes; Apply makes it explicit.
                    Task { await reloadAllSeries(showsLoading: false) }
                }
                .buttonStyle(PlainButtonStyle())
                .font(.caption)
                .foregroundColor(.blue)
            }
            
            // Date range filter
            HStack {
                Toggle("Custom Date Range", isOn: $dateFilterEnabled)
                    .font(.caption)
                
                if dateFilterEnabled {
                    DatePicker("From", selection: $customStartDate, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(CompactDatePickerStyle())
                    
                    Text("to")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    DatePicker("To", selection: $customEndDate, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(CompactDatePickerStyle())
                }
            }
            
            // Selection tools
            HStack {
                Button("Select All") {
                    selectedDataPoints = Set(displayableChartData.map { $0.id })
                }
                .buttonStyle(PlainButtonStyle())
                .font(.caption)
                .foregroundColor(.blue)
                
                Button("Clear Selection") {
                    selectedDataPoints.removeAll()
                }
                .buttonStyle(PlainButtonStyle())
                .font(.caption)
                .foregroundColor(.red)
                
                if !selectedDataPoints.isEmpty {
                    Text("\(selectedDataPoints.count) selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            // Chart zoom controls
            HStack {
                Text("Zoom:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Button("-") {
                    chartScale = max(1.0, chartScale - 0.25)
                    if chartScale <= 1 { chartOffset = .zero }
                }
                .buttonStyle(PlainButtonStyle())
                .font(.caption)
                .foregroundColor(.blue)
                .disabled(chartScale <= 1)
                .accessibilityLabel("Zoom out")
                
                Text(String(format: "%.0f%%", chartScale * 100))
                    .font(.caption)
                    .frame(width: 44)
                    .accessibilityLabel("Zoom \(Int((chartScale * 100).rounded())) percent")
                
                Button("+") {
                    chartScale = min(ChartSeriesProcessing.maxZoom, chartScale + 0.25)
                }
                .buttonStyle(PlainButtonStyle())
                .font(.caption)
                .foregroundColor(.blue)
                .disabled(chartScale >= ChartSeriesProcessing.maxZoom)
                .accessibilityLabel("Zoom in")
                
                Button("Reset") {
                    chartScale = 1.0
                    chartOffset = .zero
                }
                .buttonStyle(PlainButtonStyle())
                .font(.caption)
                .foregroundColor(.orange)
                .disabled(chartScale <= 1)
                .accessibilityLabel("Reset zoom")
                .help("Option-scroll or pinch to zoom, Option-drag to move")
                
                Spacer()
            }
        }
        .padding()
        .background(StockbarPalette.panelFill)
        .cornerRadius(8)
    }

    @ViewBuilder
    var exportOptionsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Chart Data")
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack(spacing: 16) {
                // CSV Export Button
                Button(action: exportToCSV) {
                    HStack {
                        Image(systemName: "doc.text")
                        Text("Export CSV")
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(6)
                .foregroundColor(.blue)
                
                // PDF Export Button
                Button(action: exportToPDF) {
                    HStack {
                        Image(systemName: "doc.richtext")
                        Text("Export PDF")
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.1))
                .cornerRadius(6)
                .foregroundColor(.green)
                
                Spacer()
            }
            
            // Additional export options for portfolio data
            if case .portfolioValue = selectedChartType, !historicalDataManager.historicalPortfolioSnapshots.isEmpty {
                HStack {
                    Button(action: exportDetailedPortfolioCSV) {
                        HStack {
                            Image(systemName: "tablecells")
                            Text("Detailed Portfolio CSV")
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(6)
                    .foregroundColor(.orange)
                    
                    Spacer()
                }
            }
            
            // Export selected data only
            if !selectedDataPoints.isEmpty {
                HStack {
                    Text("Export \(selectedDataPoints.count) selected points only")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .padding()
        .background(StockbarPalette.panelFill)
        .cornerRadius(8)
    }

    /// Full-resolution, filtered series (never the downsampled display copy), narrowed to the selection.
    func exportSeries() -> [ChartDataPoint] {
        ChartSeriesProcessing.exportSeries(
            full: fullResolutionChartData,
            displayed: displayableChartData,
            selected: selectedDataPoints
        )
    }

    /// Notes the filters that narrowed the exported series, so a file is never
    /// mistaken for the full history.
    var exportFilterNotes: [String] {
        ExportManager.filterNotes(
            valueThreshold: valueThreshold,
            dateWindow: (selectedTimeRange == .custom || dateFilterEnabled) ? customQueryRange : nil,
            selectedPoints: selectedDataPoints.count
        )
    }

    func exportToCSV() {
        let metrics = getRelevantPerformanceMetrics()
        let dataToExport = exportSeries()
        
        exportManager.exportToCSV(
            chartData: dataToExport,
            chartType: selectedChartType,
            timeRange: selectedTimeRange,
            metrics: metrics,
            filterNotes: exportFilterNotes
        )
    }

    func exportToPDF() {
        let metrics = getRelevantPerformanceMetrics()
        let chartImage = captureChartAsImage()
        let dataToExport = exportSeries()
        
        exportManager.exportToPDF(
            chartData: dataToExport,
            chartType: selectedChartType,
            timeRange: selectedTimeRange,
            metrics: metrics,
            chartImage: chartImage,
            filterNotes: exportFilterNotes
        )
    }

    func exportDetailedPortfolioCSV() {
        let startDate = queryCustomFrom ?? selectedTimeRange.startDate()
        let endDate = queryCustomTo ?? Date()
        let timeRange = selectedTimeRange
        Task {
            // Read every stored snapshot: the in-memory history keeps only one per
            // day for older dates.
            let snapshots = await historicalDataManager.fetchHistoricalPortfolioSnapshots(from: startDate, to: endDate)
                .sorted { $0.date < $1.date }
            exportManager.exportPortfolioSnapshotsToCSV(snapshots: snapshots, timeRange: timeRange)
        }
    }

    /// A plain line chart of the exported series for the PDF.
    func captureChartAsImage() -> NSImage? {
        let points = exportSeries().filter { $0.value.isFinite }
        guard points.count > 1 else { return nil }
        let domain = ChartSeriesProcessing.paddedDomain(points.map(\.value))
        let snapshot = Chart(points) { point in
            LineMark(x: .value("Date", point.date), y: .value("Value", point.value))
                .foregroundStyle(Color.blue)
        }
        .chartYScale(domain: domain)
        .frame(width: 720, height: 320)
        .padding(12)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: snapshot)
        renderer.scale = 2
        return renderer.nsImage
    }
}
