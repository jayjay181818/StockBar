import AppKit
import Charts
import SwiftUI

extension PerformanceChartView {
    var metricsSection: some View {
        VStack {
            Button(action: { showingMetrics.toggle() }) {
                HStack {
                    Text("Performance Metrics")
                    Spacer()
                    Image(systemName: showingMetrics ? "chevron.up" : "chevron.down")
                }
            }
            .buttonStyle(PlainButtonStyle())
            
            if showingMetrics {
                performanceMetricsView
            }
        }
    }

    @ViewBuilder
    var performanceMetricsView: some View {
        if let metrics = getRelevantPerformanceMetrics() {
            VStack(alignment: .leading, spacing: 12) {
                // Basic Metrics Row
                HStack(spacing: 0) {
                    VStack(alignment: .leading) {
                        Text("Total Return")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(metrics.formattedTotalReturn)
                            .font(.headline)
                            .foregroundColor(metrics.totalReturn >= 0 ? .green : .red)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    VStack(spacing: 2) {
                        Text("Return %")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                        Text(metrics.formattedTotalReturnPercent)
                            .font(.headline)
                            .foregroundColor(metrics.totalReturnPercent >= 0 ? .green : .red)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    
                    VStack(alignment: .trailing) {
                        Text("Volatility")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(metrics.formattedVolatility)
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                
                // Advanced Analytics Row 1
                HStack(spacing: 0) {
                    VStack(alignment: .leading) {
                        Text("Sharpe Ratio")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(metrics.formattedSharpeRatio)
                            .font(.subheadline)
                            .foregroundColor(getSharpeRatioColor(metrics.sharpeRatio))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    VStack(spacing: 2) {
                        Text("Max Drawdown")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                        Text(metrics.formattedMaxDrawdown)
                            .font(.subheadline)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    
                    VStack(alignment: .trailing) {
                        Text("Win Rate")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(metrics.formattedWinRate)
                            .font(.subheadline)
                            .foregroundColor(getWinRateColor(metrics.winRate))
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                
                // Advanced Analytics Row 2
                HStack(spacing: 0) {
                    VStack(alignment: .leading) {
                        Text("Ann. Return")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(metrics.formattedAnnualizedReturn)
                            .font(.subheadline)
                            .foregroundColor(getAnnualizedReturnColor(metrics.annualizedReturn))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    VStack(spacing: 2) {
                        Text("VaR (95%)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                        Text(metrics.formattedVaR)
                            .font(.subheadline)
                            .foregroundColor(.orange)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    
                    VStack(alignment: .trailing) {
                        Text("Range")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(String(format: "%.2f", metrics.minValue)) - \(String(format: "%.2f", metrics.maxValue))")
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding()
            .background(StockbarPalette.panelFill)
            .cornerRadius(8)
        }
    }

    var portfolioReturnAnalysisSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Return Analysis")
                .font(.headline)
                .foregroundColor(.primary)
            
            HStack(alignment: .top, spacing: 20) {
                // Left: Total Portfolio Return vs Purchase Price
                VStack(alignment: .leading, spacing: 4) {
                    Text("Total Portfolio Return")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if let model = dataModel {
                        let totalReturn = model.calculateNetGains()
                        Text("\(formatCurrency(totalReturn.amount, currency: totalReturn.currency))")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(totalReturn.amount >= 0 ? .green : .red)
                        
                        let totalPurchaseValue = calculateTotalPurchaseValue()
                        if totalPurchaseValue.amount > 0 {
                            let percentage = (totalReturn.amount / totalPurchaseValue.amount) * 100
                            Text("\(String(format: "%+.2f%%", percentage)) vs Purchase Price")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                // Center: Return for Selected Period
                VStack(alignment: .center, spacing: 4) {
                    Text("Period Return (\(selectedTimeRange.description))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if let metrics = portfolioPerformanceMetrics {
                        Text(metrics.formattedTotalReturn)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(metrics.totalReturn >= 0 ? .green : .red)
                        
                        Text(metrics.formattedTotalReturnPercent)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Not enough history")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // Right: Current Value vs Average Price
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Portfolio Value")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if let model = dataModel {
                        let netValue = model.calculateNetValue()
                        Text("\(formatCurrency(netValue.amount, currency: netValue.currency))")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                    }
                }
            }
            
            // Additional insights row
            HStack {
                if let model = dataModel {
                    let totalReturn = model.calculateNetGains()
                    let netValue = model.calculateNetValue()
                    let totalPurchase = calculateTotalPurchaseValue()
                    
                    if totalPurchase.amount > 0 && netValue.amount > 0 {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Investment Performance")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            let roiPercentage = (totalReturn.amount / totalPurchase.amount) * 100
                            Text("ROI: \(String(format: "%.2f%%", roiPercentage))")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(roiPercentage >= 0 ? .green : .red)
                        }
                        
                        Spacer()
                        
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Total Invested")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(formatCurrency(totalPurchase.amount, currency: totalPurchase.currency))")
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.7))
        .cornerRadius(12)
    }

    @ViewBuilder
    func stockReturnAnalysisSection(for symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stock Analysis - \(symbol)")
                .font(.headline)
                .foregroundColor(.primary)
            
            if let stockTrade = dataModel?.realTimeTrades.first(where: { $0.trade.name == symbol }) {
                HStack(alignment: .top, spacing: 20) {
                    // Left: Current Price
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Current Price")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        let currentPrice = stockTrade.realTimeInfo.currentPrice
                        let currency = stockTrade.realTimeInfo.currency ?? "USD"
                        Text(formatCurrency(currentPrice, currency: currency))
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        
                        // Day change
                        let dayChange = currentPrice - stockTrade.realTimeInfo.prevClosePrice
                        let dayChangePercent = stockTrade.realTimeInfo.prevClosePrice > 0 ? 
                            (dayChange / stockTrade.realTimeInfo.prevClosePrice) * 100 : 0
                        
                        if !dayChange.isNaN && !dayChangePercent.isNaN {
                            Text("\(String(format: "%+.2f", dayChange)) (\(String(format: "%+.2f%%", dayChangePercent)))")
                                .font(.caption)
                                .foregroundColor(dayChange >= 0 ? .green : .red)
                        }
                    }
                    
                    Spacer()
                    
                    // Center: Period Return for selected time range
                    VStack(alignment: .center, spacing: 4) {
                        Text("Period Return (\(selectedTimeRange.description))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        if let metrics = stockPerformanceMetrics(for: symbol) {
                            Text(formatCurrency(metrics.totalReturn, currency: metrics.currency))
                                .font(.title2)
                                .fontWeight(.semibold)
                                .foregroundColor(metrics.totalReturn >= 0 ? .green : .red)
                            
                            Text(metrics.formattedTotalReturnPercent)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Not enough history")
                                .font(.title3)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    // Right: Your Position (if you own this stock)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Your Position")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        // The linked source's own profit figure when there is one,
                        // as in the Holdings table.
                        let units = stockTrade.trade.position.unitSize
                        let profitLoss = dataModel?.calculatePositionProfitLoss(for: stockTrade)
                        let positionGain = profitLoss?.totalAmount ?? .nan
                        let currency = profitLoss?.currency ?? stockTrade.realTimeInfo.currency ?? "USD"
                        
                        Text("\(units.formatted(.number.precision(.fractionLength(0...4)))) \(units == 1 ? "share" : "shares")")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        
                        if !positionGain.isNaN {
                            Text("\(String(format: "%+.2f", positionGain)) \(currency)")
                                .font(.caption)
                                .foregroundColor(positionGain >= 0 ? .green : .red)
                        }
                    }
                }
                
                // Additional stock insights row
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Avg Cost")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        let avgCost = stockTrade.trade.position.averageCost(
                            for: symbol, inQuoteCurrency: stockTrade.realTimeInfo.currency
                        )
                        let currency = stockTrade.realTimeInfo.currency ?? "USD"
                        Text(formatCurrency(avgCost, currency: currency))
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .center, spacing: 2) {
                        Text("Market Value")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        let marketValue = stockTrade.realTimeInfo.currentPrice * stockTrade.trade.position.unitSize
                        let currency = stockTrade.realTimeInfo.currency ?? "USD"
                        Text(formatCurrency(marketValue, currency: currency))
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    
                    Spacer()
                    
                    if let metrics = stockPerformanceMetrics(for: symbol) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Volatility")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text(metrics.formattedVolatility)
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                    }
                }
            } else {
                Text("Stock information not available")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.7))
        .cornerRadius(12)
    }

    func calculateTotalPurchaseValue() -> (amount: Double, currency: String) {
        guard let model = dataModel else { return (0, "USD") }
        
        let currencyConverter = CurrencyConverter.shared
        var totalCostUSD = 0.0
        
        for trade in model.realTimeTrades {
            // Use normalized average cost (handles GBX to GBP conversion automatically)
            let adjustedCost = trade.trade.position.averageCost(
                for: trade.trade.name, inQuoteCurrency: trade.realTimeInfo.currency
            )
            guard !adjustedCost.isNaN, adjustedCost > 0 else { 
                continue 
            }
            
            let units = trade.trade.position.unitSize
            let currency = trade.realTimeInfo.currency ?? "USD"
            
            let totalPositionCost = adjustedCost * units
            
            // Convert to USD for aggregation using actual currency converter
            var costInUSD = totalPositionCost
            if currency == "GBP" {
                costInUSD = currencyConverter.convert(amount: totalPositionCost, from: "GBP", to: "USD")
            } else if currency != "USD" {
                costInUSD = currencyConverter.convert(amount: totalPositionCost, from: currency, to: "USD")
            }
            
            totalCostUSD += costInUSD
        }
        
        // Convert to preferred currency using actual currency converter
        let preferredCurrency = model.preferredCurrency
        var finalAmount = totalCostUSD
        
        if preferredCurrency == "GBX" || preferredCurrency == "GBp" {
            let gbpAmount = currencyConverter.convert(amount: totalCostUSD, from: "USD", to: "GBP")
            finalAmount = gbpAmount * 100.0 // Convert GBP to GBX
        } else if preferredCurrency != "USD" { // Only convert if not already USD
            finalAmount = currencyConverter.convert(amount: totalCostUSD, from: "USD", to: preferredCurrency)
        }
        
        return (finalAmount, preferredCurrency)
    }

    /// Changes whenever the range or the loaded series does.
    func metricsKey(_ subject: String) -> String {
        let range = selectedTimeRange == .custom
            ? "\(customQueryRange.from.timeIntervalSince1970)-\(customQueryRange.toExclusive.timeIntervalSince1970)"
            : selectedTimeRange.rawValue
        let last = fullResolutionChartData.last
        return [
            subject, range, dataModel?.preferredCurrency ?? "",
            String(fullResolutionChartData.count),
            String(last?.date.timeIntervalSince1970 ?? 0), String(last?.value ?? 0)
        ].joined(separator: "|")
    }

    /// Period metrics over the same range the portfolio chart shows.
    var portfolioPerformanceMetrics: PerformanceMetrics? {
        metricsCache.value(for: metricsKey("portfolio")) {
            historicalDataManager.getPerformanceMetrics(
                for: selectedTimeRange,
                customFrom: queryCustomFrom,
                customTo: queryCustomTo,
                currency: dataModel?.preferredCurrency
            )
        }
    }

    func stockPerformanceMetrics(for symbol: String) -> PerformanceMetrics? {
        metricsCache.value(for: metricsKey("stock:" + symbol)) {
            historicalDataManager.getStockPerformanceMetrics(
                for: symbol,
                timeRange: selectedTimeRange,
                customFrom: queryCustomFrom,
                customTo: queryCustomTo
            )
        }
    }

    func getRelevantPerformanceMetrics() -> PerformanceMetrics? {
        // Legacy snapshot metrics are not returns on the authoritative Folync series.
        guard !isFolyncPortfolioChart else { return nil }
        switch selectedChartType {
        case .portfolioValue, .portfolioGains:
            return portfolioPerformanceMetrics
        case .individualStock(let symbol):
            return stockPerformanceMetrics(for: symbol)
        }
    }

    /// Gets color for Sharpe ratio display
    func getSharpeRatioColor(_ sharpeRatio: Double?) -> Color {
        guard let ratio = sharpeRatio else { return .secondary }
        if ratio > 1.0 {
            return .green
        } else if ratio > 0.5 {
            return .orange
        } else {
            return .red
        }
    }

    /// Gets color for win rate display
    func getWinRateColor(_ winRate: Double?) -> Color {
        guard let rate = winRate else { return .secondary }
        if rate >= 60.0 {
            return .green
        } else if rate >= 45.0 {
            return .orange
        } else {
            return .red
        }
    }

    /// Gets color for annualized return display
    func getAnnualizedReturnColor(_ annualizedReturn: Double?) -> Color {
        guard let returnValue = annualizedReturn else { return .secondary }
        if returnValue > 10.0 {
            return .green
        } else if returnValue > 0.0 {
            return .orange
        } else {
            return .red
        }
    }
}
