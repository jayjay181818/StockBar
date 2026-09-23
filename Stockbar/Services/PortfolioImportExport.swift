//
//  PortfolioImportExport.swift
//  StockBar
//
//  Portfolio CSV/JSON import-export model and the app-wide notification names.
//  Extracted from the retired PreferenceView.swift, which mixed these shared
//  types in with the legacy preferences UI.
//

import Combine
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let chartMetricsToggled = Notification.Name("chartMetricsToggled")
    static let refreshIntervalChanged = Notification.Name("refreshIntervalChanged")
    static let realTimeTradesUIUpdateNeeded = Notification.Name("realTimeTradesUIUpdateNeeded")
    static let menuBarVisibilityChanged = Notification.Name("menuBarVisibilityChanged")
    static let refreshRequested = Notification.Name("refreshRequested")
}

// MARK: - Portfolio Export/Import Data Structure
struct PortfolioExportData: Codable {
    let symbol: String
    let units: Double
    let avgPositionCost: Double
    let costCurrency: String?
    
    init(from trade: Trade) {
        self.symbol = trade.name
        self.units = trade.position.unitSize
        self.avgPositionCost = trade.position.positionAvgCost
        self.costCurrency = trade.position.costCurrency
    }
    
    func toTrade() -> Trade {
        let position = Position(unitSize: String(units), 
                               positionAvgCost: String(avgPositionCost),
                               currency: costCurrency,
                               costCurrency: costCurrency)
        return Trade(name: symbol, position: position)
    }
}

// MARK: - CSV Document for Export/Import
struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    
    var text: String
    
    init(text: String = "") {
        self.text = text
    }
    
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let string = String(data: data, encoding: .utf8)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = string
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = text.data(using: .utf8)!
        return .init(regularFileWithContents: data)
    }
}

// MARK: - Portfolio Export/Import Manager
class PortfolioManager {
    static func exportToCSV(trades: [RealTimeTrade]) -> String {
        var csvString = "Symbol,Units,AvgPositionCost,CostCurrency\n"
        
        for trade in trades {
            let symbol = trade.trade.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let units = trade.trade.position.unitSize
            let avgCost = trade.trade.position.positionAvgCost
            let currency = trade.trade.position.costCurrency ?? (SymbolMetadata.isUKSymbol(symbol) ? "GBX" : "USD")
            
            // Skip empty/internal rows
            if !symbol.isEmpty && units > 0 && !SymbolMetadata.isBenchmarkSymbol(symbol) {
                csvString += "\(symbol),\(units),\(avgCost),\(currency)\n"
            }
        }
        
        return csvString
    }
    
    static func importFromCSV(_ csvString: String) -> (trades: [Trade], errors: [String]) {
        var trades: [Trade] = []
        var errors: [String] = []
        
        let lines = csvString.components(separatedBy: .newlines)
        
        // Skip header line
        for (index, line) in lines.enumerated() {
            if index == 0 || line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            
            let components = line.components(separatedBy: ",")
            if components.count >= 3 {
                let symbol = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let unitsString = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let avgCostString = components[2].trimmingCharacters(in: .whitespacesAndNewlines)
                let currency = components.count > 3 ? components[3].trimmingCharacters(in: .whitespacesAndNewlines) : nil
                
                // Validate data
                guard !symbol.isEmpty else {
                    errors.append("Line \(index + 1): Empty symbol")
                    continue
                }

                guard !SymbolMetadata.isBenchmarkSymbol(symbol) else {
                    errors.append("Line \(index + 1): \(symbol) is an internal benchmark symbol")
                    continue
                }
                
                guard let units = Double(unitsString), units > 0 else {
                    errors.append("Line \(index + 1): Invalid units value '\(unitsString)'")
                    continue
                }
                
                guard let avgCost = Double(avgCostString), avgCost > 0 else {
                    errors.append("Line \(index + 1): Invalid average cost value '\(avgCostString)'")
                    continue
                }
                
                // Create trade
                let position = Position(unitSize: String(units),
                                       positionAvgCost: String(avgCost),
                                       currency: currency,
                                       costCurrency: currency)
                let trade = Trade(name: symbol, position: position)
                
                trades.append(trade)
            } else {
                errors.append("Line \(index + 1): Invalid format - expected at least 3 columns")
            }
        }
        
        return (trades, errors)
    }
}
