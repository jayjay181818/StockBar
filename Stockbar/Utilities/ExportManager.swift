import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Manages export functionality for portfolio data to CSV and PDF formats
@MainActor
final class ExportManager {
    
    static let shared = ExportManager()
    private let logger = Logger.shared
    
    private init() {}
    
    // MARK: - CSV Export
    
    /// Exports chart data to CSV format
    func exportToCSV(
        chartData: [ChartDataPoint],
        chartType: ChartType,
        timeRange: ChartTimeRange,
        metrics: PerformanceMetrics?,
        filterNotes: [String] = []
    ) {
        let fileName = generateFileName(type: "csv", chartType: chartType, timeRange: timeRange)
        
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = fileName
        savePanel.allowedContentTypes = [UTType.commaSeparatedText]
        savePanel.canCreateDirectories = true
        
        savePanel.begin { result in
            if result == .OK, let url = savePanel.url {
                self.performCSVExport(
                    chartData: chartData,
                    chartType: chartType,
                    timeRange: timeRange,
                    metrics: metrics,
                    filterNotes: filterNotes,
                    to: url
                )
            }
        }
    }
    
    /// Exports portfolio snapshot data to CSV
    func exportPortfolioSnapshotsToCSV(
        snapshots: [HistoricalPortfolioSnapshot],
        timeRange: ChartTimeRange
    ) {
        let fileName = generateFileName(type: "csv", chartType: .portfolioValue, timeRange: timeRange, prefix: "portfolio-detailed")
        
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = fileName
        savePanel.allowedContentTypes = [UTType.commaSeparatedText]
        savePanel.canCreateDirectories = true
        
        savePanel.begin { result in
            if result == .OK, let url = savePanel.url {
                self.performPortfolioCSVExport(snapshots: snapshots, to: url)
            }
        }
    }
    
    private func performCSVExport(
        chartData: [ChartDataPoint],
        chartType: ChartType,
        timeRange: ChartTimeRange,
        metrics: PerformanceMetrics?,
        filterNotes: [String],
        to url: URL
    ) {
        do {
            var csvContent = generateCSVHeader(chartType: chartType, timeRange: timeRange, metrics: metrics, filterNotes: filterNotes)
            csvContent += generateCSVData(chartData: chartData)
            
            try csvContent.write(to: url, atomically: true, encoding: .utf8)
            Task { await logger.info("Successfully exported CSV to \(url.lastPathComponent)") }
            
            // Show success notification
            showExportNotification(fileName: url.lastPathComponent, success: true)
        } catch {
            Task { await logger.error("Failed to export CSV: \(error.localizedDescription)") }
            showExportNotification(fileName: url.lastPathComponent, success: false, error: error.localizedDescription)
        }
    }
    
    private func performPortfolioCSVExport(snapshots: [HistoricalPortfolioSnapshot], to url: URL) {
        do {
            let csvContent = CSVExportFormatter.portfolioSnapshotsCSV(snapshots)

            try csvContent.write(to: url, atomically: true, encoding: .utf8)
            Task { await logger.info("Successfully exported detailed portfolio CSV to \(url.lastPathComponent)") }
            showExportNotification(fileName: url.lastPathComponent, success: true)
        } catch {
            Task { await logger.error("Failed to export portfolio CSV: \(error.localizedDescription)") }
            showExportNotification(fileName: url.lastPathComponent, success: false, error: error.localizedDescription)
        }
    }
    
    // MARK: - PDF Export
    
    /// Exports chart and metrics to PDF format
    func exportToPDF(
        chartData: [ChartDataPoint],
        chartType: ChartType,
        timeRange: ChartTimeRange,
        metrics: PerformanceMetrics?,
        chartImage: NSImage?,
        filterNotes: [String] = []
    ) {
        let fileName = generateFileName(type: "pdf", chartType: chartType, timeRange: timeRange)
        
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = fileName
        savePanel.allowedContentTypes = [UTType.pdf]
        savePanel.canCreateDirectories = true
        
        savePanel.begin { result in
            if result == .OK, let url = savePanel.url {
                self.performPDFExport(
                    chartData: chartData,
                    chartType: chartType,
                    timeRange: timeRange,
                    metrics: metrics,
                    chartImage: chartImage,
                    filterNotes: filterNotes,
                    to: url
                )
            }
        }
    }
    
    private func performPDFExport(
        chartData: [ChartDataPoint],
        chartType: ChartType,
        timeRange: ChartTimeRange,
        metrics: PerformanceMetrics?,
        chartImage: NSImage?,
        filterNotes: [String],
        to url: URL
    ) {
        do {
            let pdfData = generatePDFData(
                chartData: chartData,
                chartType: chartType,
                timeRange: timeRange,
                metrics: metrics,
                chartImage: chartImage,
                filterNotes: filterNotes
            )
            // An empty file must not be reported as a finished export.
            guard !pdfData.isEmpty else { throw CocoaError(.fileWriteUnknown) }

            try pdfData.write(to: url)
            Task { await logger.info("Successfully exported PDF to \(url.lastPathComponent)") }
            showExportNotification(fileName: url.lastPathComponent, success: true)
        } catch {
            Task { await logger.error("Failed to export PDF: \(error.localizedDescription)") }
            showExportNotification(fileName: url.lastPathComponent, success: false, error: error.localizedDescription)
        }
    }
    
    private func generatePDFData(
        chartData: [ChartDataPoint],
        chartType: ChartType,
        timeRange: ChartTimeRange,
        metrics: PerformanceMetrics?,
        chartImage: NSImage?,
        filterNotes: [String]
    ) -> Data {
        let pdfData = NSMutableData()
        let pageSize = CGSize(width: 612, height: 792) // US Letter size
        
        guard let consumer = CGDataConsumer(data: pdfData) else {
            return Data()
        }
        
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return Data()
        }
        
        context.beginPDFPage(nil)
        
        // Draw title
        let title = "\(chartType.title) - \(timeRange.description)"
        drawText(context: context, text: title, point: CGPoint(x: 50, y: 750), fontSize: 20, bold: true)
        
        // Draw export date
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .short
        let exportDate = "Generated on \(dateFormatter.string(from: Date()))"
        drawText(context: context, text: exportDate, point: CGPoint(x: 50, y: 720), fontSize: 12)
        for (index, note) in filterNotes.enumerated() {
            drawText(context: context, text: "Filter: \(note)", point: CGPoint(x: 50, y: 704 - CGFloat(index) * 14), fontSize: 10)
        }
        
        // Draw chart image if available
        if let chartImage = chartImage {
            let imageRect = CGRect(x: 50, y: 400, width: 512, height: 300)
            if let cgImage = chartImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                context.draw(cgImage, in: imageRect)
            }
        }
        
        // Draw metrics
        if let metrics = metrics {
            drawMetrics(context: context, metrics: metrics, startY: 380)
        }
        
        // Draw data summary
        drawDataSummary(context: context, chartData: chartData, startY: 200)
        
        context.endPDFPage()
        context.closePDF()
        
        return pdfData as Data
    }
    
    // MARK: - Helper Methods
    
    private func generateFileName(type: String, chartType: ChartType, timeRange: ChartTimeRange, prefix: String? = nil) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let timestamp = dateFormatter.string(from: Date())
        
        let chartName = chartType.title.replacingOccurrences(of: " ", with: "-")
        let rangeName = timeRange.rawValue
        
        let basePrefix = prefix ?? "stockbar"
        return "\(basePrefix)-\(chartName)-\(rangeName)-\(timestamp).\(type)"
    }
    
    private func generateCSVHeader(chartType: ChartType, timeRange: ChartTimeRange, metrics: PerformanceMetrics?, filterNotes: [String]) -> String {
        var header = CSVExportFormatter.comment("Stockbar Export Report")
        header += CSVExportFormatter.comment("Chart Type: \(chartType.title)")
        header += CSVExportFormatter.comment("Time Range: \(timeRange.description)")
        header += CSVExportFormatter.comment("Generated: \(CSVExportFormatter.isoDate(Date()))")
        for note in filterNotes {
            header += CSVExportFormatter.comment("Filter: \(note)")
        }
        
        if let metrics = metrics {
            header += CSVExportFormatter.comment("")
            header += CSVExportFormatter.comment("Performance Summary:")
            header += CSVExportFormatter.comment("Total Return: \(metrics.formattedTotalReturn)")
            header += CSVExportFormatter.comment("Total Return %: \(metrics.formattedTotalReturnPercent)")
            header += CSVExportFormatter.comment("Volatility: \(metrics.formattedVolatility)")
            header += CSVExportFormatter.comment("Sharpe Ratio: \(metrics.formattedSharpeRatio)")
            header += CSVExportFormatter.comment("Max Drawdown: \(metrics.formattedMaxDrawdown)")
            header += CSVExportFormatter.comment("Win Rate: \(metrics.formattedWinRate)")
            header += CSVExportFormatter.comment("Annualized Return: \(metrics.formattedAnnualizedReturn)")
        }
        
        header += CSVExportFormatter.comment("")
        header += CSVExportFormatter.row(["Date", "Value"])
        
        return header
    }
    
    /// Human-readable notes for every filter that narrowed an exported series.
    nonisolated static func filterNotes(
        valueThreshold: Double,
        dateWindow: (from: Date, toExclusive: Date)?,
        selectedPoints: Int,
        calendar: Calendar = .current
    ) -> [String] {
        var notes: [String] = []
        if valueThreshold > 0 {
            let threshold = valueThreshold.rounded() == valueThreshold && abs(valueThreshold) < 1e15
                ? String(Int(valueThreshold)) : CSVExportFormatter.number(valueThreshold)
            notes.append("values below \(threshold) excluded")
        }
        if let dateWindow {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let lastDay = calendar.date(byAdding: .day, value: -1, to: dateWindow.toExclusive) ?? dateWindow.toExclusive
            notes.append("dates \(formatter.string(from: dateWindow.from)) to \(formatter.string(from: lastDay))")
        }
        if selectedPoints > 0 {
            notes.append("only the \(selectedPoints) selected point(s)")
        }
        return notes
    }

    private func generateCSVData(chartData: [ChartDataPoint]) -> String {
        CSVExportFormatter.chartDataRows(chartData)
    }
    
    private func drawText(context: CGContext, text: String, point: CGPoint, fontSize: CGFloat, bold: Bool = false) {
        let font = bold ? NSFont.boldSystemFont(ofSize: fontSize) : NSFont.systemFont(ofSize: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        
        let attributedString = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributedString)
        
        context.textPosition = point
        CTLineDraw(line, context)
    }
    
    private func drawMetrics(context: CGContext, metrics: PerformanceMetrics, startY: CGFloat) {
        let metricsTitle = "Performance Metrics"
        drawText(context: context, text: metricsTitle, point: CGPoint(x: 50, y: startY), fontSize: 16, bold: true)
        
        let metricsData = [
            "Total Return: \(metrics.formattedTotalReturn)",
            "Total Return %: \(metrics.formattedTotalReturnPercent)",
            "Volatility: \(metrics.formattedVolatility)",
            "Sharpe Ratio: \(metrics.formattedSharpeRatio)",
            "Max Drawdown: \(metrics.formattedMaxDrawdown)",
            "Win Rate: \(metrics.formattedWinRate)",
            "Annualized Return: \(metrics.formattedAnnualizedReturn)",
            "Value at Risk (95%): \(metrics.formattedVaR)"
        ]
        
        for (index, metric) in metricsData.enumerated() {
            drawText(context: context, text: metric, point: CGPoint(x: 70, y: startY - 20 - CGFloat(index * 15)), fontSize: 12)
        }
    }
    
    private func drawDataSummary(context: CGContext, chartData: [ChartDataPoint], startY: CGFloat) {
        let summaryTitle = "Data Summary"
        drawText(context: context, text: summaryTitle, point: CGPoint(x: 50, y: startY), fontSize: 16, bold: true)
        
        let dataCount = chartData.count
        let firstDate = chartData.first?.date
        let lastDate = chartData.last?.date
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        
        let summaryData = [
            "Total Data Points: \(dataCount)",
            "Date Range: \(firstDate.map { dateFormatter.string(from: $0) } ?? "N/A") to \(lastDate.map { dateFormatter.string(from: $0) } ?? "N/A")",
            "First Value: \(String(format: "%.2f", chartData.first?.value ?? 0))",
            "Last Value: \(String(format: "%.2f", chartData.last?.value ?? 0))",
            "Min Value: \(String(format: "%.2f", chartData.map { $0.value }.min() ?? 0))",
            "Max Value: \(String(format: "%.2f", chartData.map { $0.value }.max() ?? 0))"
        ]
        
        for (index, summary) in summaryData.enumerated() {
            drawText(context: context, text: summary, point: CGPoint(x: 70, y: startY - 20 - CGFloat(index * 15)), fontSize: 12)
        }
    }
    
    private func showExportNotification(fileName: String, success: Bool, error: String? = nil) {
        let title = success ? "Export Successful" : "Export Failed"
        let body = success
            ? "Successfully exported \(fileName)"
            : "Failed to export \(fileName): \(error ?? "Unknown error")"
        Task {
            await StockbarNotificationPoster.post(title: title, body: body, playSound: success)
        }
    }
}


// MARK: - CSV formatting

/// Locale-independent CSV building: ISO 8601 dates, `.` decimals, RFC 4180 quoting and
/// protection against spreadsheet formula injection in text cells.
enum CSVExportFormatter {
    /// Characters that make a spreadsheet treat a text cell as a formula.
    private static let formulaPrefixes: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]

    /// UTC ISO 8601 timestamp (`2026-11-04T10:30:00Z`); never contains a comma.
    static func isoDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// Plain decimal text in the POSIX locale; non-finite values become an empty cell.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        return "\(value)"
    }

    /// A text cell: neutralises leading `= + - @` (and tab / CR) with a single quote and
    /// applies RFC 4180 quoting when it contains a comma, quote or line break.
    static func text(_ value: String) -> String {
        var cell = value
        if let first = cell.first, formulaPrefixes.contains(first) {
            cell = "'" + cell
        }
        let needsQuotes = cell.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }
            || cell.hasPrefix(" ") || cell.hasSuffix(" ")
        guard needsQuotes else { return cell }
        return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// A "# …" note above the data, written as one quoted cell on one line, so
    /// a comma or line break in it cannot spill into other cells or rows.
    static func comment(_ note: String) -> String {
        let oneLine = note.components(separatedBy: .newlines).joined(separator: " ")
        return row([oneLine.isEmpty ? "#" : "# " + oneLine])
    }

    /// One CRLF-terminated record of raw text cells (each passes through `text`).
    static func row(_ fields: [String]) -> String {
        fields.map(text).joined(separator: ",") + "\r\n"
    }

    static func chartDataRows(_ chartData: [ChartDataPoint]) -> String {
        chartData.map { "\(isoDate($0.date)),\(number($0.value))\r\n" }.joined()
    }

    static func portfolioSnapshotsCSV(_ snapshots: [HistoricalPortfolioSnapshot]) -> String {
        let allSymbols = Set(snapshots.flatMap { $0.portfolioComposition.keys }).sorted()

        var header = ["Date", "Total Value", "Total Gains", "Total Cost", "Currency"]
        for symbol in allSymbols {
            header += ["\(symbol) Units", "\(symbol) Price", "\(symbol) Value"]
        }
        var csv = row(header)

        for snapshot in snapshots {
            var cells = [
                isoDate(snapshot.date),
                number(snapshot.totalValue),
                number(snapshot.totalGains),
                number(snapshot.totalCost),
                text(snapshot.currency)
            ]
            for symbol in allSymbols {
                if let position = snapshot.portfolioComposition[symbol] {
                    cells += [number(position.units), number(position.priceAtDate), number(position.valueAtDate)]
                } else {
                    // Not held on this date: empty, not a holding of zero units at a zero price.
                    cells += ["", "", ""]
                }
            }
            csv += cells.joined(separator: ",") + "\r\n"
        }
        return csv
    }
}
