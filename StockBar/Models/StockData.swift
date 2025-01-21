import Foundation

struct StockData {
    let symbol: String
    let price: Double
    let dayGain: Double
    let dayGainPercentage: Double
    let marketValue: Double
    let positionCost: Double
    let totalPnL: Double
    let dayPnL: Double
    let units: Double
    let averagePositionCost: Double
    let timestamp: String
    
    var formattedDayGain: String {
        String(format: "%+.2f", dayGain)
    }
    
    var formattedDayGainPercentage: String {
        String(format: "%+.2f%%", dayGainPercentage)
    }
    
    var formattedPrice: String {
        String(format: "%.2f", price)
    }
    
    var formattedMarketValue: String {
        String(format: "%.2f", marketValue)
    }
    
    var formattedPositionCost: String {
        String(format: "%.2f", positionCost)
    }
    
    var formattedTotalPnL: String {
        String(format: "%+.2f", totalPnL)
    }
    
    var formattedDayPnL: String {
        String(format: "%+.2f", dayPnL)
    }
    
    var formattedUnits: String {
        String(format: "%.0f", units)
    }
    
    var formattedAveragePositionCost: String {
        String(format: "%.2f", averagePositionCost)
    }
}