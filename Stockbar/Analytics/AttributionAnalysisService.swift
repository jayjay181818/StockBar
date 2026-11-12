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
        cashFlows: [CashFlowEvent] = [],
        convert: @escaping @Sendable (_ amount: Double, _ from: String, _ to: String) -> Double = {
            CurrencyConverter.shared.convert(amount: $0, from: $1, to: $2)
        }
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
              startSnapshot.totalValue.isFinite, startSnapshot.totalValue > 0,
              endSnapshot.totalValue.isFinite else {
            await Logger.shared.error("📊 Unable to determine start/end snapshots or start/end value is zero or not finite")
            return nil
        }

        let startValue = startSnapshot.totalValue
        let endValue = endSnapshot.totalValue
        // Position values are in each position's own currency (GBX = pence) while
        // totalValue is in the snapshot currency, so convert before mixing them.
        let baseCurrency = startSnapshot.currency

        var stockContributions: [StockContribution] = []

        var allSymbols = Set<String>()
        for snapshot in filteredData {
            allSymbols.formUnion(snapshot.portfolioComposition.symbols.filter { !SymbolMetadata.isBenchmarkSymbol($0) })
        }

        for symbol in allSymbols {
            // A holding opened or closed inside the period is measured from the first
            // day it appears to the last day it appears, so its gain or loss is not lost.
            func usable(_ snapshot: HistoricalPortfolioSnapshot) -> PositionSnapshot? {
                guard let position = snapshot.portfolioComposition[symbol],
                      position.priceAtDate.isFinite, position.priceAtDate > 0,
                      position.units.isFinite, position.valueAtDate.isFinite else { return nil }
                return position
            }
            guard let firstIndex = filteredData.firstIndex(where: { usable($0) != nil }),
                  let lastIndex = filteredData.lastIndex(where: { usable($0) != nil }),
                  firstIndex < lastIndex,
                  let startPosition = usable(filteredData[firstIndex]),
                  let endPosition = usable(filteredData[lastIndex]) else {
                continue
            }
            let heldAtStart = firstIndex == 0
            let heldAtEnd = lastIndex == filteredData.count - 1

            let stockReturn = ((endPosition.priceAtDate - startPosition.priceAtDate) / startPosition.priceAtDate) * 100

            let startPositionValue = convert(startPosition.valueAtDate, startPosition.currency, baseCurrency)
            let endPositionValue = convert(endPosition.valueAtDate, endPosition.currency, baseCurrency)
            let startWeight = heldAtStart ? (startPositionValue / startValue) * 100 : 0
            let endWeight = heldAtEnd && endValue > 0 ? (endPositionValue / endValue) * 100 : 0
            let avgWeight = (startWeight + endWeight) / 2.0

            // Price effect on the units held when the holding first appears in the period.
            // Units bought or sold later are new money / withdrawals, not performance.
            let nativeGain = startPosition.units * (endPosition.priceAtDate - startPosition.priceAtDate)
            let dollarContribution = convert(nativeGain, startPosition.currency, baseCurrency)
            let contribution = (dollarContribution / startValue) * 100

            // A missing FX rate or bad data point must not poison totals and percentages.
            guard stockReturn.isFinite, startPositionValue.isFinite, endPositionValue.isFinite,
                  avgWeight.isFinite, dollarContribution.isFinite, contribution.isFinite else {
                continue
            }

            stockContributions.append(StockContribution(
                symbol: symbol,
                weight: avgWeight,
                stockReturn: stockReturn,
                contribution: contribution,
                dollarContribution: dollarContribution,
                sector: getSectorForSymbol(symbol)
            ))
        }

        stockContributions.sort { $0.dollarContribution > $1.dollarContribution }

        // Return on the starting holdings, excluding money added or withdrawn.
        let priceEffect = stockContributions.reduce(0) { $0 + $1.dollarContribution }
        let portfolioReturn = (priceEffect / startValue) * 100

        await Logger.shared.debug("📊 Attribution: \(startSnapshot.date) to \(endSnapshot.date), start \(String(format: "%.2f", startValue)) \(baseCurrency), end \(String(format: "%.2f", endValue)), price-effect return \(String(format: "%.2f", portfolioReturn))%, snapshots \(filteredData.count)")

        let sectorContributions = calculateSectorContributions(from: stockContributions)

        // TWR/MWR and net cash flow need real cash-flow data. Without it they would
        // simply restate the raw value change (new money counted as performance).
        let hasCashFlows = !cashFlows.isEmpty
        let twrMwrComparison = hasCashFlows
            ? calculateTWRMWR(startValue: startValue, endValue: endValue, cashFlows: cashFlows)
            : nil

        let waterfallData = generateWaterfallData(
            stockContributions: stockContributions,
            startValue: startValue,
            endValue: endValue
        )

        let netCashFlow: Double? = hasCashFlows ? cashFlows.reduce(0) { $0 + $1.amount } : nil

        let result = AttributionAnalysisResult(
            // The days actually measured, which can be fewer than the range asked for.
            startDate: startSnapshot.date,
            endDate: endSnapshot.date,
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

    // MARK: - Stock Contribution Calculation

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

            irr -= npv / npvDerivative
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

        // The ten largest moves in either direction, gains first. Taking the
        // ten largest gains hid the biggest losses inside "Trades & Other".
        let topContributors = stockContributions
            .sorted { abs($0.dollarContribution) > abs($1.dollarContribution) }
            .prefix(10)
            .sorted { $0.dollarContribution > $1.dollarContribution }

        for contribution in topContributors {
            cumulative += contribution.dollarContribution

            waterfallData.append(WaterfallDataPoint(
                label: contribution.symbol,
                value: contribution.dollarContribution,
                cumulativeValue: cumulative
            ))
        }

        // Reconcile to the ending value: deposits/withdrawals, FX moves and
        // holdings outside the ten largest moves all land here.
        let residual = endValue - cumulative
        if abs(residual) > 0.005 {
            cumulative += residual
            waterfallData.append(WaterfallDataPoint(
                label: "Trades & Other",
                value: residual,
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
        // One sector table for the whole app (see SectorAnalysisService.Sector).
        SectorAnalysisService.Sector.forSymbol(symbol).rawValue
    }
}
