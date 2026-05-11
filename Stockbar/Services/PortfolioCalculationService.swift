//
//  PortfolioCalculationService.swift
//  Stockbar
//
//  Portfolio calculation service - handles all portfolio math
//  Extracted from DataModel for better separation of concerns
//

import Foundation

struct DisplayPortfolioSummary {
    let totalValue: Double
    let totalGain: Double
    let totalGainPct: Double
    let dayGain: Double
    let dayGainPct: Double
    let totalCost: Double
    let ownedPositionCount: Int
    let currency: String
}

struct PositionProfitLossSummary: Equatable {
    let dayAmount: Double
    let dayPercent: Double
    let totalAmount: Double
    let totalPercent: Double
    let currency: String
}

/// Service responsible for portfolio value and gains calculations
class PortfolioCalculationService {
    private let currencyConverter: CurrencyConverter
    private let logger = Logger.shared
    
    init(currencyConverter: CurrencyConverter) {
        self.currencyConverter = currencyConverter
    }
    
    // MARK: - Portfolio Calculations
    
    /// Calculates the total net gains across all trades in the preferred currency
    func calculateNetGains(
        trades: [RealTimeTrade],
        preferredCurrency: String
    ) -> (amount: Double, currency: String) {
        Task { await logger.debug("Calculating net gains in \(preferredCurrency)") }
        var totalGainsUSD = 0.0
        
        for realTimeTradeItem in trades {
            // Skip watchlist-only stocks from portfolio calculations
            guard !realTimeTradeItem.trade.isWatchlistOnly else {
                Task { await logger.debug("Skipping watchlist stock \(realTimeTradeItem.trade.name) from net gains calculation") }
                continue
            }
            
            // Ensure price is valid before calculation
            guard !realTimeTradeItem.realTimeInfo.currentPrice.isNaN,
                  realTimeTradeItem.realTimeInfo.currentPrice != 0 else {
                Task { await logger.debug("Skipping net gain calculation for \(realTimeTradeItem.trade.name) due to invalid price.") }
                continue
            }
            
            // Get normalized average cost (handles GBX to GBP conversion automatically)
            let adjustedCost = realTimeTradeItem.trade.position.getNormalizedAvgCost(for: realTimeTradeItem.trade.name)
            guard !adjustedCost.isNaN, adjustedCost > 0 else {
                Task { await logger.debug("Skipping net gain calculation for \(realTimeTradeItem.trade.name) due to invalid cost.") }
                continue
            }
            
            let currentPrice = realTimeTradeItem.realTimeInfo.currentPrice
            let units = realTimeTradeItem.trade.position.unitSize
            let currency = realTimeTradeItem.realTimeInfo.currency
            let symbol = realTimeTradeItem.trade.name
            
            Task { await logger.debug("Using normalized cost for \(symbol): \(adjustedCost) (from \(realTimeTradeItem.trade.position.positionAvgCostString) \(realTimeTradeItem.trade.position.costCurrency ?? "auto-detected"))") }
            
            // Calculate gains in the stock's currency (currentPrice and adjustedCost are now in same currency)
            let rawGains = (currentPrice - adjustedCost) * units
            
            // Convert to USD for aggregation
            var gainsInUSD = rawGains
            if let knownCurrency = currency {
                if knownCurrency == "GBP" {
                    gainsInUSD = currencyConverter.convert(amount: rawGains, from: "GBP", to: "USD")
                } else if knownCurrency != "USD" {
                    gainsInUSD = currencyConverter.convert(amount: rawGains, from: knownCurrency, to: "USD")
                }
            } else {
                Task { await logger.warning("Currency unknown for \(realTimeTradeItem.trade.name), assuming USD for gain calculation.") }
            }
            
            Task { await logger.debug("Gain calculation for \(symbol): currentPrice=\(currentPrice), adjustedCost=\(adjustedCost), units=\(units), currency=\(currency ?? "nil"), rawGains=\(rawGains), gainsInUSD=\(gainsInUSD)") }
            totalGainsUSD += gainsInUSD
        }
        
        // Convert final total to preferred currency
        var finalAmount = totalGainsUSD
        if preferredCurrency == "GBX" || preferredCurrency == "GBp" {
            let gbpAmount = currencyConverter.convert(amount: totalGainsUSD, from: "USD", to: "GBP")
            finalAmount = gbpAmount * 100.0
        } else if preferredCurrency != "USD" {
            finalAmount = currencyConverter.convert(amount: totalGainsUSD, from: "USD", to: preferredCurrency)
        }
        
        Task { await logger.debug("Net gains calculated: \(finalAmount) \(preferredCurrency)") }
        return (finalAmount, preferredCurrency)
    }
    
    /// Calculates the total portfolio value (market value) in the preferred currency
    func calculateNetValue(
        trades: [RealTimeTrade],
        preferredCurrency: String
    ) -> (amount: Double, currency: String) {
        Task { await logger.debug("Calculating net value in \(preferredCurrency)") }
        var totalValueUSD = 0.0
        
        for realTimeTradeItem in trades {
            // Skip watchlist-only stocks from portfolio calculations
            guard !realTimeTradeItem.trade.isWatchlistOnly else {
                Task { await logger.debug("Skipping watchlist stock \(realTimeTradeItem.trade.name) from net value calculation") }
                continue
            }
            
            // Ensure price is valid before calculation
            guard !realTimeTradeItem.realTimeInfo.currentPrice.isNaN,
                  realTimeTradeItem.realTimeInfo.currentPrice != 0 else {
                Task { await logger.debug("Skipping net value calculation for \(realTimeTradeItem.trade.name) due to invalid price.") }
                continue
            }
            
            let currentPrice = realTimeTradeItem.realTimeInfo.currentPrice
            let units = realTimeTradeItem.trade.position.unitSize
            let currency = realTimeTradeItem.realTimeInfo.currency
            let symbol = realTimeTradeItem.trade.name
            
            // Calculate market value in the stock's currency
            let marketValueInStockCurrency = currentPrice * units
            
            // Convert to USD for aggregation
            var marketValueInUSD = marketValueInStockCurrency
            if let knownCurrency = currency {
                if knownCurrency == "GBP" {
                    marketValueInUSD = currencyConverter.convert(amount: marketValueInStockCurrency, from: "GBP", to: "USD")
                } else if knownCurrency != "USD" {
                    marketValueInUSD = currencyConverter.convert(amount: marketValueInStockCurrency, from: knownCurrency, to: "USD")
                }
            } else {
                Task { await logger.warning("Currency unknown for \(realTimeTradeItem.trade.name), assuming USD for value calculation.") }
            }
            
            Task { await logger.debug("Value calculation for \(symbol): currentPrice=\(currentPrice), units=\(units), currency=\(currency ?? "nil"), marketValueInStockCurrency=\(marketValueInStockCurrency), marketValueInUSD=\(marketValueInUSD)") }
            totalValueUSD += marketValueInUSD
        }
        
        // Convert final total to preferred currency
        var finalAmount = totalValueUSD
        if preferredCurrency == "GBX" || preferredCurrency == "GBp" {
            let gbpAmount = currencyConverter.convert(amount: totalValueUSD, from: "USD", to: "GBP")
            finalAmount = gbpAmount * 100.0
        } else if preferredCurrency != "USD" {
            finalAmount = currencyConverter.convert(amount: totalValueUSD, from: "USD", to: preferredCurrency)
        }
        
        Task { await logger.debug("Net value calculated: \(finalAmount) \(preferredCurrency)") }
        return (finalAmount, preferredCurrency)
    }

    /// Calculates the menu bar portfolio summary using the same display-price semantics as symbol rows.
    func calculateDisplayPortfolioSummary(
        trades: [RealTimeTrade],
        preferredCurrency: String
    ) -> DisplayPortfolioSummary {
        Task { await logger.debug("Calculating display portfolio summary in \(preferredCurrency)") }

        var totalValueUSD = 0.0
        var totalPrevCloseUSD = 0.0
        var totalGainUSD = 0.0
        var totalCostUSD = 0.0
        var dayGainUSD = 0.0
        var ownedPositionCount = 0

        for realTimeTradeItem in trades {
            guard !realTimeTradeItem.trade.isWatchlistOnly else { continue }

            let info = realTimeTradeItem.realTimeInfo
            let displayPrice = info.getCurrentDisplayPrice()
            let prevClosePrice = info.prevClosePrice
            let units = realTimeTradeItem.trade.position.unitSize

            guard displayPrice.isFinite, displayPrice > 0 else { continue }
            guard units > 0 else { continue }

            let symbol = realTimeTradeItem.trade.name
            let currency = info.currency ?? "USD"
            let currentValueUSD = convertToUSD(amount: displayPrice * units, currency: currency)
            totalValueUSD += currentValueUSD
            ownedPositionCount += 1

            if prevClosePrice.isFinite, prevClosePrice > 0 {
                let prevValueUSD = convertToUSD(amount: prevClosePrice * units, currency: currency)
                totalPrevCloseUSD += prevValueUSD
                dayGainUSD += currentValueUSD - prevValueUSD
            }

            let adjustedCost = realTimeTradeItem.trade.position.getNormalizedAvgCost(for: symbol)
            if adjustedCost.isFinite, adjustedCost > 0 {
                let costUSD = convertToUSD(amount: adjustedCost * units, currency: currency)
                totalCostUSD += costUSD
                totalGainUSD += currentValueUSD - costUSD
            }
        }

        let totalValue = convertFromUSD(amount: totalValueUSD, preferredCurrency: preferredCurrency)
        let totalGain = convertFromUSD(amount: totalGainUSD, preferredCurrency: preferredCurrency)
        let dayGain = convertFromUSD(amount: dayGainUSD, preferredCurrency: preferredCurrency)
        let totalCost = convertFromUSD(amount: totalCostUSD, preferredCurrency: preferredCurrency)
        let totalGainPct = totalCostUSD > 0 ? (totalGainUSD / totalCostUSD) * 100 : 0
        let dayGainPct = totalPrevCloseUSD > 0 ? (dayGainUSD / totalPrevCloseUSD) * 100 : 0

        return DisplayPortfolioSummary(
            totalValue: totalValue,
            totalGain: totalGain,
            totalGainPct: totalGainPct,
            dayGain: dayGain,
            dayGainPct: dayGainPct,
            totalCost: totalCost,
            ownedPositionCount: ownedPositionCount,
            currency: preferredCurrency
        )
    }

    /// Calculates per-position day and total P/L in the position display currency.
    func calculatePositionProfitLoss(for realTimeTrade: RealTimeTrade) -> PositionProfitLossSummary {
        let info = realTimeTrade.realTimeInfo
        let displayPrice = info.getCurrentDisplayPrice()
        let previousClose = info.prevClosePrice
        let units = realTimeTrade.trade.position.unitSize
        let symbol = realTimeTrade.trade.name
        let averageCost = realTimeTrade.trade.position.getNormalizedAvgCost(for: symbol)
        let currency = info.currency
            ?? realTimeTrade.trade.position.currency
            ?? realTimeTrade.trade.position.costCurrency
            ?? ""

        let dayAmount: Double
        let dayPercent: Double
        if displayPrice.isFinite,
           previousClose.isFinite,
           previousClose > 0,
           units > 0 {
            let dayDelta = displayPrice - previousClose
            dayAmount = dayDelta * units
            dayPercent = (dayDelta / previousClose) * 100.0
        } else {
            dayAmount = .nan
            dayPercent = .nan
        }

        let totalAmount: Double
        let totalPercent: Double
        if displayPrice.isFinite,
           averageCost.isFinite,
           averageCost > 0,
           units > 0 {
            let totalDelta = displayPrice - averageCost
            totalAmount = totalDelta * units
            totalPercent = (totalDelta / averageCost) * 100.0
        } else {
            totalAmount = .nan
            totalPercent = .nan
        }

        return PositionProfitLossSummary(
            dayAmount: dayAmount,
            dayPercent: dayPercent,
            totalAmount: totalAmount,
            totalPercent: totalPercent,
            currency: currency
        )
    }
    
    /// Memory-efficient calculation of portfolio metrics
    func calculatePortfolioMetricsEfficiently(
        trades: [RealTimeTrade],
        preferredCurrency: String,
        memoryOptimizer: MemoryOptimizedDataModel?
    ) -> (gains: Double, value: Double, currency: String) {
        guard let optimizer = memoryOptimizer else {
            // Fallback to standard methods
            let gains = calculateNetGains(trades: trades, preferredCurrency: preferredCurrency)
            let value = calculateNetValue(trades: trades, preferredCurrency: preferredCurrency)
            return (gains.amount, value.amount, preferredCurrency)
        }
        
        let metrics = optimizer.calculatePortfolioMetricsEfficiently(trades: trades)
        
        // Convert to preferred currency
        var finalGains = metrics.totalGains
        var finalValue = metrics.totalValue
        
        if preferredCurrency != "USD" {
            finalGains = currencyConverter.convert(amount: metrics.totalGains, from: "USD", to: preferredCurrency)
            finalValue = currencyConverter.convert(amount: metrics.totalValue, from: "USD", to: preferredCurrency)
        }
        
        return (finalGains, finalValue, preferredCurrency)
    }

    private func convertToUSD(amount: Double, currency: String) -> Double {
        if currency == "GBX" || currency == "GBp" {
            let gbpAmount = amount / 100.0
            return currencyConverter.convert(amount: gbpAmount, from: "GBP", to: "USD")
        }

        if currency == "GBP" {
            return currencyConverter.convert(amount: amount, from: "GBP", to: "USD")
        }

        if currency == "USD" {
            return amount
        }

        return currencyConverter.convert(amount: amount, from: currency, to: "USD")
    }

    private func convertFromUSD(amount: Double, preferredCurrency: String) -> Double {
        if preferredCurrency == "GBX" || preferredCurrency == "GBp" {
            let gbpAmount = currencyConverter.convert(amount: amount, from: "USD", to: "GBP")
            return gbpAmount * 100.0
        }

        if preferredCurrency == "USD" {
            return amount
        }

        return currencyConverter.convert(amount: amount, from: "USD", to: preferredCurrency)
    }
}
