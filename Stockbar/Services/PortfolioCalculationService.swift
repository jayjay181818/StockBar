//
//  PortfolioCalculationService.swift
//  Stockbar
//
//  Portfolio calculation service - handles all portfolio math
//  Extracted from DataModel for better separation of concerns
//

import Foundation

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
}

