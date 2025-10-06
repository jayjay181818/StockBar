//
//  AttributionAnalysisService.swift
//  Stockbar
//
//  Created by Stockbar Development Team on 10/4/25.
//

import Foundation

/// Service for calculating performance attribution analysis
actor AttributionAnalysisService {

    static let shared = AttributionAnalysisService()

    private init() {
        // No logging in init - actor isolation
    }

    // MARK: - Main Attribution Calculation

    /// Calculate attribution using HistoricalPortfolioSnapshots (preferred - has actual position data)
    func calculateAttributionFromHistorical(
        startDate: Date,
        endDate: Date,
        historicalSnapshots: [HistoricalPortfolioSnapshot],
        cashFlows: [CashFlowEvent] = []
    ) async -> AttributionAnalysisResult? {

        await Logger.shared.debug("📊 Calculating attribution from historical snapshots: \(startDate) to \(endDate)")

        // Filter and sort data for date range
        let filteredData = historicalSnapshots
            .filter { $0.date >= startDate && $0.date <= endDate }
            .sorted { $0.date < $1.date }

        guard filteredData.count >= 2 else {
            await Logger.shared.warning("📊 Insufficient data for attribution calculation (need at least 2 snapshots)")
            return nil
        }

        guard let startSnapshot = filteredData.first,
              let endSnapshot = filteredData.last,
              startSnapshot.totalValue > 0 else {
            await Logger.shared.error("📊 Unable to determine start/end snapshots or start value is zero")
            return nil
        }

        let startValue = startSnapshot.totalValue
        let endValue = endSnapshot.totalValue
        let portfolioReturn = ((endValue - startValue) / startValue) * 100

        await Logger.shared.debug("📊 Attribution Debug:")
        await Logger.shared.debug("   Start Date: \(startSnapshot.date)")
        await Logger.shared.debug("   End Date: \(endSnapshot.date)")
        await Logger.shared.debug("   Start Value: £\(String(format: "%.2f", startValue))")
        await Logger.shared.debug("   End Value: £\(String(format: "%.2f", endValue))")
        await Logger.shared.debug("   Return: \(String(format: "%.2f", portfolioReturn))%")
        await Logger.shared.debug("   Snapshot Count: \(filteredData.count)")

        // Calculate stock contributions using actual position data
        var stockContributions: [StockContribution] = []

        // Get all symbols across the period
        var allSymbols = Set<String>()
        for snapshot in filteredData {
            allSymbols.formUnion(snapshot.portfolioComposition.keys)
        }

        for symbol in allSymbols {
            guard let startPosition = startSnapshot.portfolioComposition[symbol],
                  let endPosition = endSnapshot.portfolioComposition[symbol],
                  startPosition.priceAtDate > 0 else {
                continue
            }

            // Calculate stock return
            let stockReturn = ((endPosition.priceAtDate - startPosition.priceAtDate) / startPosition.priceAtDate) * 100

            // Calculate weight as percentage of portfolio
            let startWeight = (startPosition.valueAtDate / startValue) * 100
            let endWeight = (endPosition.valueAtDate / endValue) * 100
            let avgWeight = (startWeight + endWeight) / 2.0

            // Calculate contribution (weight × return)
            let contribution = (avgWeight / 100) * stockReturn

            // Calculate dollar contribution
            let dollarChange = endPosition.valueAtDate - startPosition.valueAtDate
            let dollarContribution = dollarChange

            // Get sector
            let sector = getSectorForSymbol(symbol)

            let stockContribution = StockContribution(
                symbol: symbol,
                weight: avgWeight,
                stockReturn: stockReturn,
                contribution: contribution,
                dollarContribution: dollarContribution,
                sector: sector
            )

            stockContributions.append(stockContribution)
        }

        stockContributions.sort { $0.dollarContribution > $1.dollarContribution }

        // Calculate sector contributions
        let sectorContributions = calculateSectorContributions(from: stockContributions)

        // Calculate TWR and MWR
        let twrMwrComparison = calculateTWRMWR(
            startValue: startValue,
            endValue: endValue,
            cashFlows: cashFlows
        )

        // Generate waterfall data
        let waterfallData = generateWaterfallData(
            stockContributions: stockContributions,
            startValue: startValue,
            endValue: endValue
        )

        // Calculate net cash flow
        let netCashFlow = cashFlows.reduce(0) { $0 + $1.amount }

        let result = AttributionAnalysisResult(
            startDate: startDate,
            endDate: endDate,
            portfolioReturn: portfolioReturn,
            stockContributions: stockContributions,
            sectorContributions: sectorContributions,
            twrMwrComparison: twrMwrComparison,
            waterfallData: waterfallData,
            startingValue: startValue,
            endingValue: endValue,
            netCashFlow: netCashFlow
        )

        await Logger.shared.debug("📊 Attribution calculation complete: \(String(format: "%.2f", portfolioReturn))% return, \(stockContributions.count) stocks")
        return result
    }

    /// Calculate attribution using PortfolioSnapshots (legacy - less accurate)
    func calculateAttribution(
        startDate: Date,
        endDate: Date,
        portfolioSnapshots: [PortfolioSnapshot],
        cashFlows: [CashFlowEvent] = []
    ) async -> AttributionAnalysisResult? {

        await Logger.shared.debug("📊 Calculating attribution from \(startDate) to \(endDate)")

        // Filter and sort data for date range
        let filteredData = portfolioSnapshots
            .filter { $0.timestamp >= startDate && $0.timestamp <= endDate }
            .sorted { $0.timestamp < $1.timestamp }

        guard filteredData.count >= 2 else {
            await Logger.shared.warning("📊 Insufficient data for attribution calculation (need at least 2 snapshots)")
            return nil
        }

        // Calculate portfolio values (now guaranteed to be in order)
        guard let startValue = filteredData.first?.totalValue,
              let endValue = filteredData.last?.totalValue,
              startValue > 0 else {
            await Logger.shared.error("📊 Unable to determine start/end values or start value is zero")
            return nil
        }

        // Calculate portfolio return
        let portfolioReturn = ((endValue - startValue) / startValue) * 100

        // Calculate stock contributions
        let stockContributions = await calculateStockContributions(
            startDate: startDate,
            endDate: endDate,
            portfolioSnapshots: filteredData
        )

        // Calculate sector contributions
        let sectorContributions = calculateSectorContributions(from: stockContributions)

        // Calculate TWR and MWR
        let twrMwrComparison = calculateTWRMWR(
            startValue: startValue,
            endValue: endValue,
            cashFlows: cashFlows
        )

        // Generate waterfall data
        let waterfallData = generateWaterfallData(
            stockContributions: stockContributions,
            startValue: startValue,
            endValue: endValue
        )

        // Calculate net cash flow
        let netCashFlow = cashFlows.reduce(0) { $0 + $1.amount }

        let result = AttributionAnalysisResult(
            startDate: startDate,
            endDate: endDate,
            portfolioReturn: portfolioReturn,
            stockContributions: stockContributions,
            sectorContributions: sectorContributions,
            twrMwrComparison: twrMwrComparison,
            waterfallData: waterfallData,
            startingValue: startValue,
            endingValue: endValue,
            netCashFlow: netCashFlow
        )

        await Logger.shared.debug("📊 Attribution calculation complete: \(portfolioReturn)% return")
        return result
    }

    // MARK: - Stock Contribution Calculation

    private func calculateStockContributions(
        startDate: Date,
        endDate: Date,
        portfolioSnapshots: [PortfolioSnapshot]
    ) async -> [StockContribution] {

        var contributions: [StockContribution] = []

        // Get all unique symbols
        var symbolData: [String: [PriceSnapshot]] = [:]

        for snapshot in portfolioSnapshots {
            for priceSnapshot in snapshot.priceSnapshots {
                if symbolData[priceSnapshot.symbol] == nil {
                    symbolData[priceSnapshot.symbol] = []
                }
                symbolData[priceSnapshot.symbol]?.append(priceSnapshot)
            }
        }

        for (symbol, snapshots) in symbolData {
            // Sort snapshots by timestamp
            let sortedSnapshots = snapshots.sorted { $0.timestamp < $1.timestamp }

            guard let startSnapshot = sortedSnapshots.first,
                  let endSnapshot = sortedSnapshots.last,
                  startSnapshot.price > 0,
                  sortedSnapshots.count >= 2 else {
                continue
            }

            // Calculate stock return
            let stockReturn = ((endSnapshot.price - startSnapshot.price) / startSnapshot.price) * 100

            // Get start and end portfolio snapshots
            guard let startPortfolio = portfolioSnapshots.sorted(by: { $0.timestamp < $1.timestamp }).first,
                  let endPortfolio = portfolioSnapshots.sorted(by: { $0.timestamp < $1.timestamp }).last,
                  startPortfolio.totalValue > 0 else {
                continue
            }

            // Find the stock's position in the portfolio snapshots to calculate actual weight
            // Use the average of start and end weights
            var startWeight = 0.0
            var endWeight = 0.0

            // Calculate start weight: find this stock's value in start portfolio
            if let startPrice = sortedSnapshots.first(where: { abs($0.timestamp.timeIntervalSince(startPortfolio.timestamp)) < 86400 }) {
                // Estimate position value (we don't have units, so we'll estimate from price contribution)
                startWeight = (startPrice.price / startPortfolio.totalValue) * 100
            }

            // Calculate end weight
            if let endPrice = sortedSnapshots.first(where: { abs($0.timestamp.timeIntervalSince(endPortfolio.timestamp)) < 86400 }) {
                endWeight = (endPrice.price / endPortfolio.totalValue) * 100
            }

            // Use average weight for the period
            let avgWeight = (startWeight + endWeight) / 2.0

            // Calculate contribution (weight × return)
            let contribution = (avgWeight / 100) * stockReturn

            // Calculate dollar contribution based on start portfolio value
            let dollarContribution = (startPortfolio.totalValue * avgWeight / 100) * (stockReturn / 100)

            // Get sector
            let sector = getSectorForSymbol(symbol)

            let stockContribution = StockContribution(
                symbol: symbol,
                weight: avgWeight,
                stockReturn: stockReturn,
                contribution: contribution,
                dollarContribution: dollarContribution,
                sector: sector
            )

            contributions.append(stockContribution)
        }

        await Logger.shared.debug("📊 Calculated \(contributions.count) stock contributions")
        return contributions.sorted { $0.contribution > $1.contribution }
    }

    // MARK: - Sector Contribution Calculation

    private func calculateSectorContributions(from stockContributions: [StockContribution]) -> [SectorContribution] {

        let sectorGroups = Dictionary(grouping: stockContributions) { $0.sector }

        var sectorContributions: [SectorContribution] = []

        for (sectorName, stocks) in sectorGroups {
            let totalWeight = stocks.map { $0.weight }.reduce(0, +)
            let totalContribution = stocks.map { $0.contribution }.reduce(0, +)
            let dollarContribution = stocks.map { $0.dollarContribution }.reduce(0, +)
            let stockCount = stocks.count
            let averageReturn = stockCount > 0 ? stocks.map { $0.stockReturn }.reduce(0, +) / Double(stockCount) : 0

            let sectorContribution = SectorContribution(
                sectorName: sectorName,
                totalWeight: totalWeight,
                totalContribution: totalContribution,
                dollarContribution: dollarContribution,
                stockCount: stockCount,
                averageReturn: averageReturn
            )

            sectorContributions.append(sectorContribution)
        }

        return sectorContributions.sorted { $0.totalContribution > $1.totalContribution }
    }

    // MARK: - TWR Calculation

    private func calculateTimeWeightedReturn(
        startValue: Double,
        endValue: Double
    ) -> Double {

        // TWR = geometric linking of sub-period returns
        // For simplicity, we'll use the holding period return
        guard startValue > 0 else { return 0 }

        let twr = ((endValue - startValue) / startValue) * 100

        return twr
    }

    // MARK: - MWR (IRR) Calculation

    private func calculateMoneyWeightedReturn(
        startValue: Double,
        endValue: Double,
        cashFlows: [CashFlowEvent]
    ) -> Double {

        // MWR = Internal Rate of Return (IRR)
        // Simplified calculation using Newton-Raphson method

        guard startValue > 0 else { return 0 }

        if cashFlows.isEmpty {
            // No cash flows, MWR = TWR
            return ((endValue - startValue) / startValue) * 100
        }

        // IRR calculation using iterative approach
        var irr = 0.1 // Initial guess: 10%
        let maxIterations = 200
        let tolerance = 0.0001

        for _ in 0..<maxIterations {
            var npv = -startValue
            var npvDerivative = 0.0

            for cashFlow in cashFlows {
                let daysSinceStart = Calendar.current.dateComponents([.day], from: cashFlows.first!.date, to: cashFlow.date).day ?? 0
                let timeFraction = Double(daysSinceStart) / 365.0

                npv += cashFlow.amount / pow(1 + irr, timeFraction)
                npvDerivative -= cashFlow.amount * timeFraction / pow(1 + irr, timeFraction + 1)
            }

            npv += endValue / pow(1 + irr, 1.0)
            npvDerivative -= endValue / pow(1 + irr, 2.0)

            if abs(npv) < tolerance {
                break
            }

            irr = irr - (npv / npvDerivative)
        }

        let mwr = irr * 100

        return mwr
    }

    // MARK: - TWR/MWR Comparison

    private func calculateTWRMWR(
        startValue: Double,
        endValue: Double,
        cashFlows: [CashFlowEvent]
    ) -> TWRMWRComparison? {

        let twr = calculateTimeWeightedReturn(
            startValue: startValue,
            endValue: endValue
        )

        let mwr = calculateMoneyWeightedReturn(
            startValue: startValue,
            endValue: endValue,
            cashFlows: cashFlows
        )

        return TWRMWRComparison(
            timeWeightedReturn: twr,
            moneyWeightedReturn: mwr
        )
    }

    // MARK: - Waterfall Data Generation

    private func generateWaterfallData(
        stockContributions: [StockContribution],
        startValue: Double,
        endValue: Double
    ) -> [WaterfallDataPoint] {

        var waterfallData: [WaterfallDataPoint] = []
        var cumulative = 0.0

        // Starting value
        waterfallData.append(WaterfallDataPoint(
            label: "Starting Value",
            value: startValue,
            cumulativeValue: startValue,
            isSummary: true
        ))

        cumulative = startValue

        // Top 10 contributors
        let topContributors = stockContributions
            .sorted { $0.dollarContribution > $1.dollarContribution }
            .prefix(10)

        for contribution in topContributors {
            cumulative += contribution.dollarContribution

            waterfallData.append(WaterfallDataPoint(
                label: contribution.symbol,
                value: contribution.dollarContribution,
                cumulativeValue: cumulative
            ))
        }

        // Ending value
        waterfallData.append(WaterfallDataPoint(
            label: "Ending Value",
            value: endValue,
            cumulativeValue: endValue,
            isSummary: true
        ))

        return waterfallData
    }

    // MARK: - Helper Methods

    private func getSectorForSymbol(_ symbol: String) -> String {
        // Basic sector mapping - should be expanded
        let sectorMap: [String: String] = [
            "AAPL": "Technology",
            "MSFT": "Technology",
            "GOOGL": "Technology",
            "GOOG": "Technology",
            "AMZN": "Consumer Cyclical",
            "TSLA": "Consumer Cyclical",
            "META": "Technology",
            "NVDA": "Technology",
            "JPM": "Financials",
            "V": "Financials",
            "JNJ": "Healthcare",
            "PFE": "Healthcare",
            "XOM": "Energy",
            "CVX": "Energy"
        ]

        return sectorMap[symbol] ?? "Unknown"
    }
}
