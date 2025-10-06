//
//  AttributionData.swift
//  Stockbar
//
//  Created by Stockbar Development Team on 10/4/25.
//

import Foundation

// MARK: - Stock Contribution Model

struct StockContribution: Identifiable, Codable {
    let id: UUID
    let symbol: String
    let weight: Double // Portfolio weight as percentage
    let stockReturn: Double // Stock return as percentage
    let contribution: Double // Contribution to portfolio return (weight * return)
    let dollarContribution: Double // Dollar amount contribution
    let sector: String

    var isPositive: Bool {
        contribution >= 0
    }

    init(
        id: UUID = UUID(),
        symbol: String,
        weight: Double,
        stockReturn: Double,
        contribution: Double,
        dollarContribution: Double,
        sector: String = "Unknown"
    ) {
        self.id = id
        self.symbol = symbol
        self.weight = weight
        self.stockReturn = stockReturn
        self.contribution = contribution
        self.dollarContribution = dollarContribution
        self.sector = sector
    }
}

// MARK: - Sector Contribution Model

struct SectorContribution: Identifiable, Codable {
    let id: UUID
    let sectorName: String
    let totalWeight: Double // Sum of weights for stocks in sector
    let totalContribution: Double // Sum of contributions from sector
    let dollarContribution: Double
    let stockCount: Int
    let averageReturn: Double

    var isPositive: Bool {
        totalContribution >= 0
    }

    init(
        id: UUID = UUID(),
        sectorName: String,
        totalWeight: Double,
        totalContribution: Double,
        dollarContribution: Double,
        stockCount: Int,
        averageReturn: Double
    ) {
        self.id = id
        self.sectorName = sectorName
        self.totalWeight = totalWeight
        self.totalContribution = totalContribution
        self.dollarContribution = dollarContribution
        self.stockCount = stockCount
        self.averageReturn = averageReturn
    }
}

// MARK: - TWR/MWR Comparison Model

struct TWRMWRComparison: Codable {
    let timeWeightedReturn: Double // TWR in percentage
    let moneyWeightedReturn: Double // MWR (IRR) in percentage
    let difference: Double // TWR - MWR
    let interpretation: String

    var favorsTWR: Bool {
        difference > 0
    }

    init(
        timeWeightedReturn: Double,
        moneyWeightedReturn: Double
    ) {
        self.timeWeightedReturn = timeWeightedReturn
        self.moneyWeightedReturn = moneyWeightedReturn
        self.difference = timeWeightedReturn - moneyWeightedReturn

        // Interpretation logic
        if abs(difference) < 0.5 {
            self.interpretation = "TWR and MWR are nearly identical, indicating minimal impact from cash flow timing."
        } else if difference > 0 {
            self.interpretation = "TWR is higher than MWR, suggesting that withdrawals occurred during strong performance periods or deposits during weak periods."
        } else {
            self.interpretation = "MWR is higher than TWR, suggesting that deposits occurred during strong performance periods or withdrawals during weak periods."
        }
    }
}

// MARK: - Waterfall Data Model

struct WaterfallDataPoint: Identifiable, Codable {
    let id: UUID
    let label: String
    let value: Double
    let cumulativeValue: Double
    let isPositive: Bool
    let isSummary: Bool

    init(
        id: UUID = UUID(),
        label: String,
        value: Double,
        cumulativeValue: Double,
        isSummary: Bool = false
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.cumulativeValue = cumulativeValue
        self.isPositive = value >= 0
        self.isSummary = isSummary
    }
}

// MARK: - Attribution Analysis Result

struct AttributionAnalysisResult: Codable {
    let startDate: Date
    let endDate: Date
    let portfolioReturn: Double // Total portfolio return in percentage
    let stockContributions: [StockContribution]
    let sectorContributions: [SectorContribution]
    let twrMwrComparison: TWRMWRComparison?
    let waterfallData: [WaterfallDataPoint]
    let startingValue: Double
    let endingValue: Double
    let netCashFlow: Double

    var topContributors: [StockContribution] {
        stockContributions
            .sorted { $0.contribution > $1.contribution }
            .prefix(10)
            .map { $0 }
    }

    var topDetractors: [StockContribution] {
        stockContributions
            .filter { $0.contribution < 0 }
            .sorted { $0.contribution < $1.contribution }
            .prefix(10)
            .map { $0 }
    }

    var bestPerformingSector: SectorContribution? {
        sectorContributions.max(by: { $0.totalContribution < $1.totalContribution })
    }

    var worstPerformingSector: SectorContribution? {
        sectorContributions.filter { $0.totalContribution < 0 }
            .min(by: { $0.totalContribution < $1.totalContribution })
    }

    init(
        startDate: Date,
        endDate: Date,
        portfolioReturn: Double,
        stockContributions: [StockContribution],
        sectorContributions: [SectorContribution],
        twrMwrComparison: TWRMWRComparison?,
        waterfallData: [WaterfallDataPoint],
        startingValue: Double,
        endingValue: Double,
        netCashFlow: Double
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.portfolioReturn = portfolioReturn
        self.stockContributions = stockContributions
        self.sectorContributions = sectorContributions
        self.twrMwrComparison = twrMwrComparison
        self.waterfallData = waterfallData
        self.startingValue = startingValue
        self.endingValue = endingValue
        self.netCashFlow = netCashFlow
    }
}

// MARK: - Cash Flow Event

struct CashFlowEvent: Codable {
    let date: Date
    let amount: Double // Positive for deposits, negative for withdrawals
    let type: CashFlowType

    enum CashFlowType: String, Codable {
        case deposit = "Deposit"
        case withdrawal = "Withdrawal"
        case dividend = "Dividend"
        case split = "Split"
    }

    var isDeposit: Bool {
        amount > 0
    }
}

// MARK: - Validation Extensions

extension StockContribution {
    func validate() -> Bool {
        return !symbol.isEmpty &&
               weight >= 0 &&
               weight <= 100 &&
               !stockReturn.isNaN &&
               !contribution.isNaN &&
               !dollarContribution.isNaN
    }
}

extension SectorContribution {
    func validate() -> Bool {
        return !sectorName.isEmpty &&
               totalWeight >= 0 &&
               stockCount > 0 &&
               !totalContribution.isNaN &&
               !dollarContribution.isNaN &&
               !averageReturn.isNaN
    }
}

extension AttributionAnalysisResult {
    func validate() -> Bool {
        return startDate <= endDate &&
               !portfolioReturn.isNaN &&
               !startingValue.isNaN &&
               !endingValue.isNaN &&
               stockContributions.allSatisfy { $0.validate() } &&
               sectorContributions.allSatisfy { $0.validate() }
    }
}
