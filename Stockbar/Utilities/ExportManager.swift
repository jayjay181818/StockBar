import Foundation
import CoreGraphics
import AppKit
import UniformTypeIdentifiers

/// Manages export functionality for portfolio data to CSV and PDF formats
class ExportManager {
    
    static let shared = ExportManager()
    private let logger = Logger.shared
    
    private init() {}
    
    // MARK: - CSV Export
    
    /// Exports chart data to CSV format
    func exportToCSV(
        chartData: [ChartDataPoint],
        chartType: ChartType,
        timeRange: ChartTimeRange,
        metrics: PerformanceMetrics?
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
        to url: URL
    ) {
        do {
            var csvContent = generateCSVHeader(chartType: chartType, timeRange: timeRange, metrics: metrics)
            csvContent += generateCSVData(chartData: chartData)
            
            try csvContent.write(to: url, atomically: true, encoding: .utf8)
            logger.info("Successfully exported CSV to \(url.lastPathComponent)")
            
            // Show success notification
            showExportNotification(fileName: url.lastPathComponent, success: true)
            
        } catch {
            logger.error("Failed to export CSV: \(error.localizedDescription)")
            showExportNotification(fileName: url.lastPathComponent, success: false, error: error.localizedDescription)
        }
    }
    
    private func performPortfolioCSVExport(snapshots: [HistoricalPortfolioSnapshot], to url: URL) {
        do {
            var csvContent = "Date,Total Value,Total Gains,Total Cost,Currency"
            
            // Add individual position headers
            let allSymbols = Set(snapshots.flatMap { $0.portfolioComposition.keys }).sorted()
            for symbol in allSymbols {
                csvContent += ",\(symbol) Units,\(symbol) Price,\(symbol) Value"
            }
            csvContent += "\n"
            
            // Add data rows
            for snapshot in snapshots {
                let dateFormatter = DateFormatter()
                dateFormatter.dateStyle = .short
                dateFormatter.timeStyle = .none
                
                csvContent += "\(dateFormatter.string(from: snapshot.date)),"
                csvContent += "\(snapshot.totalValue),"
                csvContent += "\(snapshot.totalGains),"
                csvContent += "\(snapshot.totalCost),"
                csvContent += "\(snapshot.currency)"
                
                // Add position data
                for symbol in allSymbols {
                    if let position = snapshot.portfolioComposition[symbol] {
                        csvContent += ",\(position.units),\(position.priceAtDate),\(position.valueAtDate)"
                    } else {
                        csvContent += ",0,0,0"
                    }
                }
                csvContent += "\n"
            }
            
            try csvContent.write(to: url, atomically: true, encoding: .utf8)
            logger.info("Successfully exported detailed portfolio CSV to \(url.lastPathComponent)")
            showExportNotification(fileName: url.lastPathComponent, success: true)
            
        } catch {
            logger.error("Failed to export portfolio CSV: \(error.localizedDescription)")
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
        chartImage: NSImage?
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
        to url: URL
    ) {
        do {
            let pdfData = generatePDFData(
                chartData: chartData,
                chartType: chartType,
                timeRange: timeRange,
                metrics: metrics,
                chartImage: chartImage
            )
            
            try pdfData.write(to: url)
            logger.info("Successfully exported PDF to \(url.lastPathComponent)")
            showExportNotification(fileName: url.lastPathComponent, success: true)
            
        } catch {
            logger.error("Failed to export PDF: \(error.localizedDescription)")
            showExportNotification(fileName: url.lastPathComponent, success: false, error: error.localizedDescription)
        }
    }
    
    private func generatePDFData(
        chartData: [ChartDataPoint],
        chartType: ChartType,
        timeRange: ChartTimeRange,
        metrics: PerformanceMetrics?,
        chartImage: NSImage?
    ) -> Data {
        let pdfData = NSMutableData()
        let pageSize = CGSize(width: 612, height: 792) // US Letter size
        
        guard let consumer = CGDataConsumer(data: pdfData) else {
            return Data()
        }
        
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        
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
    
    private func generateCSVHeader(chartType: ChartType, timeRange: ChartTimeRange, metrics: PerformanceMetrics?) -> String {
        var header = "# Stockbar Export Report\n"
        header += "# Chart Type: \(chartType.title)\n"
        header += "# Time Range: \(timeRange.description)\n"
        header += "# Generated: \(DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .short))\n"
        
        if let metrics = metrics {
            header += "# \n"
            header += "# Performance Summary:\n"
            header += "# Total Return: \(metrics.formattedTotalReturn)\n"
            header += "# Total Return %: \(metrics.formattedTotalReturnPercent)\n"
            header += "# Volatility: \(metrics.formattedVolatility)\n"
            header += "# Sharpe Ratio: \(metrics.formattedSharpeRatio)\n"
            header += "# Max Drawdown: \(metrics.formattedMaxDrawdown)\n"
            header += "# Win Rate: \(metrics.formattedWinRate)\n"
            header += "# Annualized Return: \(metrics.formattedAnnualizedReturn)\n"
        }
        
        header += "# \n"
        header += "Date,Value\n"
        
        return header
    }
    
    private func generateCSVData(chartData: [ChartDataPoint]) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short
        
        var csvData = ""
        for dataPoint in chartData {
            csvData += "\(dateFormatter.string(from: dataPoint.date)),\(dataPoint.value)\n"
        }
        
        return csvData
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
        DispatchQueue.main.async {
            let notification = NSUserNotification()
            notification.title = success ? "Export Successful" : "Export Failed"
            notification.informativeText = success ? 
                "Successfully exported \(fileName)" : 
                "Failed to export \(fileName): \(error ?? "Unknown error")"
            notification.soundName = success ? NSUserNotificationDefaultSoundName : nil
            
            NSUserNotificationCenter.default.deliver(notification)
        }
    }
}