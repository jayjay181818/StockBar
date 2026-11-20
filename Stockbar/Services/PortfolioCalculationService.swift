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
    let valuationSource: PortfolioValuationSource
    /// Money paid into the account less money taken out, in `currency`, when
    /// the portfolio source reports it. Nil otherwise.
    let netDeposits: Double?

    init(
        totalValue: Double,
        totalGain: Double,
        totalGainPct: Double,
        dayGain: Double,
        dayGainPct: Double,
        totalCost: Double,
        ownedPositionCount: Int,
        currency: String,
        valuationSource: PortfolioValuationSource = .localCalculationFallback,
        netDeposits: Double? = nil
    ) {
        self.totalValue = totalValue
        self.totalGain = totalGain
        self.totalGainPct = totalGainPct
        self.dayGain = dayGain
        self.dayGainPct = dayGainPct
        self.totalCost = totalCost
        self.ownedPositionCount = ownedPositionCount
        self.currency = currency
        self.valuationSource = valuationSource
        self.netDeposits = netDeposits
    }

    /// The total P&L to show, measured against `basis` when the source reports
    /// net deposits, otherwise against the cost of the holdings.
    ///
    /// Against net deposits it is the whole account's value, cash included,
    /// less the money paid in: gains on shares already sold, dividends,
    /// interest and fees all count. Against cost it is the unrealised gain on
    /// the shares still held.
    func totalReturn(measuredAgainst basis: PortfolioGainBasis) -> PortfolioTotalReturn {
        if basis == .netDeposits, let netDeposits, netDeposits.isFinite, totalValue.isFinite {
            let gain = totalValue - netDeposits
            return PortfolioTotalReturn(
                gain: gain,
                // No percentage of nothing, or of more taken out than paid in.
                percent: netDeposits > 0 ? gain / netDeposits * 100 : .nan,
                basisAmount: netDeposits,
                isMeasuredAgainstNetDeposits: true
            )
        }
        return PortfolioTotalReturn(
            gain: totalGain,
            percent: totalGainPct,
            basisAmount: totalCost,
            isMeasuredAgainstNetDeposits: false
        )
    }
}

/// What the portfolio's total P&L is measured against (Settings → General).
enum PortfolioGainBasis: String, CaseIterable, Identifiable, Sendable {
    /// Money paid in less money taken out. Used where the portfolio source
    /// reports it (Folync); elsewhere P&L falls back to `holdingsCost`.
    case netDeposits
    /// What was paid for the shares still held.
    case holdingsCost

    static let userDefaultsKey = "portfolioGainBasis"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .netDeposits: "Net Deposits"
        case .holdingsCost: "Cost of Current Holdings"
        }
    }
}

/// The portfolio's total P&L as shown, and what it is measured against.
struct PortfolioTotalReturn: Equatable {
    let gain: Double
    let percent: Double
    /// The net deposits or the cost basis, whichever `gain` is measured against.
    let basisAmount: Double
    let isMeasuredAgainstNetDeposits: Bool

    var basisLabel: String { isMeasuredAgainstNetDeposits ? "Net Deposits" : "Cost Basis" }
}

/// What a portfolio's total is made of, for the Overview: net deposits,
/// unrealised and realised gains as the portfolio source gives them, and the
/// rest of the total as "Income, interest and fees".
///
/// Built only when the total and the three figures are known and in one
/// currency; nothing is converted. Every figure is held in whole minor units
/// (pennies), rounded as they are displayed, and the remainder takes the
/// rounding difference, so the four parts shown add up to the total shown.
struct PortfolioTotalComposition: Equatable {
    enum Kind: CaseIterable, Equatable {
        case netDeposits, unrealisedGains, realisedGains, incomeInterestAndFees

        var title: String {
            switch self {
            case .netDeposits: "Net deposits"
            case .unrealisedGains: "Unrealised gains"
            case .realisedGains: "Realised gains"
            case .incomeInterestAndFees: "Income, interest and fees"
            }
        }
    }

    struct Part: Equatable {
        let kind: Kind
        /// Whole minor units, as displayed.
        let minorUnits: Int64
        /// The source marks the figure partial; the remainder is partial when
        /// any figure it comes from is.
        var isPartial = false
        var amount: Double { PortfolioTotalComposition.amount(minorUnits) }
    }

    /// A figure and the currency the source gives it in. Either may be unknown.
    struct Figure: Equatable {
        let value: Double?
        let currency: String?
        var isPartial = false

        /// A Folync metric. One Folync marks unavailable is unknown.
        init(_ metric: FolyncFinancialMetric, currency fallbackCurrency: String? = nil) {
            value = metric.quality == .unavailable ? nil : metric.value
            currency = metric.currency ?? fallbackCurrency
            isPartial = metric.quality == .partial
        }

        init(value: Double?, currency: String?, isPartial: Bool = false) {
            self.value = value
            self.currency = currency
            self.isPartial = isPartial
        }
    }

    let currency: String
    let totalMinorUnits: Int64
    /// In `Kind.allCases` order.
    let parts: [Part]

    var total: Double { Self.amount(totalMinorUnits) }

    /// Every amount Stockbar displays has two decimals (`HoldingsCurrencyFormatter`).
    static let minorUnitsPerUnit = 100.0

    /// `value` in whole minor units, rounded exactly as `HoldingsCurrencyFormatter`
    /// rounds it for display: by a number formatter with the same settings, whose
    /// output is read back. (Scaling the double by 100 can round the other way at
    /// a half penny: 1.015 prints as 1.02.) Nil for a value that is not finite or too large.
    static func minorUnits(_ value: Double) -> Int64? {
        guard value.isFinite, abs(value) < 1e13 else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        guard let text = formatter.string(from: NSNumber(value: value)),
              let digits = Int64(text.filter(\.isNumber)) else { return nil }
        return text.hasPrefix("-") ? -digits : digits
    }

    static func amount(_ minorUnits: Int64) -> Double {
        Double(minorUnits) / minorUnitsPerUnit
    }

    /// `value` as it is displayed: rounded to whole minor units.
    static func displayed(_ value: Double) -> Double {
        minorUnits(value).map(amount) ?? value
    }

    /// Nil unless all four figures are known and in `currency`.
    init?(currency: String, total: Figure, netDeposits: Figure, unrealised: Figure, realised: Figure) {
        let expected = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !expected.isEmpty else { return nil }
        var units: [Int64] = []
        for figure in [total, netDeposits, unrealised, realised] {
            guard let figureCurrency = figure.currency?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                  figureCurrency == expected,
                  let value = figure.value,
                  let minor = Self.minorUnits(value) else { return nil }
            units.append(minor)
        }
        let (remainder, overflow) = units[0].subtractingReportingOverflow(units[1] + units[2] + units[3])
        guard !overflow else { return nil }
        self.currency = expected
        totalMinorUnits = units[0]
        let anyPartial = [total, netDeposits, unrealised, realised].contains { $0.isPartial }
        parts = [
            Part(kind: .netDeposits, minorUnits: units[1], isPartial: netDeposits.isPartial),
            Part(kind: .unrealisedGains, minorUnits: units[2], isPartial: unrealised.isPartial),
            Part(kind: .realisedGains, minorUnits: units[3], isPartial: realised.isPartial),
            Part(kind: .incomeInterestAndFees, minorUnits: remainder, isPartial: anyPartial)
        ]
    }

    /// The Overview's card, for a Folync portfolio only: the other sources give
    /// neither net deposits nor realised gains. `summary.netDeposits` is the
    /// figure "Measure P&L Against" uses; its currency is the history's.
    static func overview(
        summary: DisplayPortfolioSummary,
        snapshot: FolyncPortfolioSnapshot?,
        netDeposits: FolyncNetDeposits?
    ) -> PortfolioTotalComposition? {
        guard summary.valuationSource == .folyncProvided, let snapshot, let netDeposits else { return nil }
        return PortfolioTotalComposition(
            currency: summary.currency,
            // The total's currency falls back to the scope's, as the summary's does.
            total: Figure(snapshot.totalValue, currency: snapshot.scope.currency),
            netDeposits: Figure(value: summary.netDeposits, currency: netDeposits.currency),
            unrealised: Figure(snapshot.profitLoss.unrealized),
            realised: Figure(snapshot.profitLoss.realized)
        )
    }

    /// The share of the bar each part takes. A bar cannot draw a negative
    /// length, so parts that are zero or negative take none and the positive
    /// parts share the bar in proportion to each other.
    var barFractions: [Double] {
        let positive = parts.map { max($0.minorUnits, 0) }
        let sum = positive.reduce(0, +)
        guard sum > 0 else { return parts.map { _ in 0 } }
        return positive.map { Double($0) / Double(sum) }
    }

    /// True when some part has no segment because it is negative.
    var barShowsPositivePartsOnly: Bool { parts.contains { $0.minorUnits < 0 } }

    /// The total less net deposits, from the figures shown, so it matches the parts.
    var gainOnDeposits: Double { Self.amount(totalMinorUnits - parts[0].minorUnits) }
}

struct PositionProfitLossSummary: Equatable {
    let dayAmount: Double
    let dayPercent: Double
    let totalAmount: Double
    let totalPercent: Double
    let currency: String
}

/// Service responsible for portfolio value and gains calculations
@MainActor
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
        preferredCurrency: String,
        brokerValuationSnapshot: Trading212BrokerValuationSnapshot? = nil
    ) -> (amount: Double, currency: String) {
        if let brokerValuationSnapshot,
           let brokerGain = brokerValuationSnapshot.totalUnrealizedProfitLoss,
           brokerGain.isFinite {
            let convertedGain = convertBrokerAmount(
                brokerGain,
                from: brokerValuationSnapshot.currency,
                to: preferredCurrency
            )
            logger.post(.debug, "Using Trading 212 broker-provided net gains in \(preferredCurrency)")
            return (convertedGain, preferredCurrency)
        }

        logger.post(.debug, "Calculating net gains in \(preferredCurrency)")
        var totalGainsUSD = 0.0
        
        for realTimeTradeItem in trades {
            // Skip watchlist-only stocks from portfolio calculations
            guard !realTimeTradeItem.trade.isWatchlistOnly else {
                logger.post(.debug, "Skipping watchlist stock \(realTimeTradeItem.trade.name) from net gains calculation")
                continue
            }
            
            // Ensure price is valid before calculation
            let currentPrice = realTimeTradeItem.realTimeInfo.getCurrentDisplayPrice()
            guard currentPrice.isFinite,
                  currentPrice > 0 else {
                logger.post(.debug, "Skipping net gain calculation for \(realTimeTradeItem.trade.name) due to invalid price.")
                continue
            }
            
            // Get normalized average cost (handles GBX to GBP conversion automatically)
            let adjustedCost = realTimeTradeItem.trade.position.averageCost(
                for: realTimeTradeItem.trade.name,
                inQuoteCurrency: realTimeTradeItem.realTimeInfo.currency,
                converter: currencyConverter
            )
            guard !adjustedCost.isNaN, adjustedCost > 0 else {
                logger.post(.debug, "Skipping net gain calculation for \(realTimeTradeItem.trade.name) due to invalid cost.")
                continue
            }
            
            let units = realTimeTradeItem.trade.position.unitSize
            let currency = realTimeTradeItem.realTimeInfo.currency
            let symbol = realTimeTradeItem.trade.name
            
            logger.post(.debug, "Using normalized cost for \(symbol): \(adjustedCost) (from \(realTimeTradeItem.trade.position.positionAvgCostString) \(realTimeTradeItem.trade.position.costCurrency ?? "auto-detected"))")
            
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
                logger.post(.warning, "Currency unknown for \(realTimeTradeItem.trade.name), assuming USD for gain calculation.")
            }
            
            logger.post(.debug, "Gain calculation for \(symbol): currentPrice=\(currentPrice), adjustedCost=\(adjustedCost), units=\(units), currency=\(currency ?? "nil"), rawGains=\(rawGains), gainsInUSD=\(gainsInUSD)")
            guard gainsInUSD.isFinite else { continue } // no exchange rate for this currency
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
        
        logger.post(.debug, "Net gains calculated: \(finalAmount) \(preferredCurrency)")
        return (finalAmount, preferredCurrency)
    }
    
    /// Calculates the total portfolio value (market value) in the preferred currency
    func calculateNetValue(
        trades: [RealTimeTrade],
        preferredCurrency: String,
        brokerValuationSnapshot: Trading212BrokerValuationSnapshot? = nil
    ) -> (amount: Double, currency: String) {
        if let brokerValuationSnapshot {
            let convertedValue = convertBrokerAmount(
                brokerValuationSnapshot.accountValue,
                from: brokerValuationSnapshot.currency,
                to: preferredCurrency
            )
            logger.post(.debug, "Using Trading 212 broker-provided account value in \(preferredCurrency)")
            return (convertedValue, preferredCurrency)
        }

        logger.post(.debug, "Calculating net value in \(preferredCurrency)")
        var totalValueUSD = 0.0
        
        for realTimeTradeItem in trades {
            // Skip watchlist-only stocks from portfolio calculations
            guard !realTimeTradeItem.trade.isWatchlistOnly else {
                logger.post(.debug, "Skipping watchlist stock \(realTimeTradeItem.trade.name) from net value calculation")
                continue
            }
            
            // Ensure price is valid before calculation
            let currentPrice = realTimeTradeItem.realTimeInfo.getCurrentDisplayPrice()
            guard currentPrice.isFinite,
                  currentPrice > 0 else {
                logger.post(.debug, "Skipping net value calculation for \(realTimeTradeItem.trade.name) due to invalid price.")
                continue
            }
            
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
                logger.post(.warning, "Currency unknown for \(realTimeTradeItem.trade.name), assuming USD for value calculation.")
            }
            
            logger.post(.debug, "Value calculation for \(symbol): currentPrice=\(currentPrice), units=\(units), currency=\(currency ?? "nil"), marketValueInStockCurrency=\(marketValueInStockCurrency), marketValueInUSD=\(marketValueInUSD)")
            guard marketValueInUSD.isFinite else { continue } // no exchange rate for this currency
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
        
        logger.post(.debug, "Net value calculated: \(finalAmount) \(preferredCurrency)")
        return (finalAmount, preferredCurrency)
    }

    /// Calculates the menu bar portfolio summary using the same display-price semantics as symbol rows.
    func calculateDisplayPortfolioSummary(
        trades: [RealTimeTrade],
        preferredCurrency: String,
        brokerValuationSnapshot: Trading212BrokerValuationSnapshot? = nil
    ) -> DisplayPortfolioSummary {
        if let brokerValuationSnapshot {
            return calculateBrokerProvidedPortfolioSummary(
                trades: trades,
                preferredCurrency: preferredCurrency,
                brokerValuationSnapshot: brokerValuationSnapshot
            )
        }

        logger.post(.debug, "Calculating display portfolio summary in \(preferredCurrency)")

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
            // A currency with no available rate converts to NaN; one such
            // position must not turn every total and the menu-bar title into NaN.
            guard currentValueUSD.isFinite else {
                logger.post(.warning, "No exchange rate for \(currency); \(symbol) is left out of portfolio totals")
                continue
            }
            totalValueUSD += currentValueUSD
            ownedPositionCount += 1

            if prevClosePrice.isFinite, prevClosePrice > 0 {
                let prevValueUSD = convertToUSD(amount: prevClosePrice * units, currency: currency)
                if prevValueUSD.isFinite {
                    totalPrevCloseUSD += prevValueUSD
                    dayGainUSD += currentValueUSD - prevValueUSD
                }
            }

            let adjustedCost = realTimeTradeItem.trade.position.averageCost(
                for: symbol, inQuoteCurrency: realTimeTradeItem.realTimeInfo.currency, converter: currencyConverter
            )
            if adjustedCost.isFinite, adjustedCost > 0 {
                let costUSD = convertToUSD(amount: adjustedCost * units, currency: currency)
                if costUSD.isFinite {
                    totalCostUSD += costUSD
                    totalGainUSD += currentValueUSD - costUSD
                }
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
            currency: preferredCurrency,
            valuationSource: .localCalculationFallback
        )
    }

    /// Calculates per-position day and total P/L in the position display currency.
    func calculatePositionProfitLoss(
        for realTimeTrade: RealTimeTrade,
        brokerValuation: Trading212BrokerPositionValuation? = nil
    ) -> PositionProfitLossSummary {
        let info = realTimeTrade.realTimeInfo
        let displayPrice = info.getCurrentDisplayPrice()
        let previousClose = info.prevClosePrice
        let units = realTimeTrade.trade.position.unitSize
        let symbol = realTimeTrade.trade.name
        let averageCost = realTimeTrade.trade.position.averageCost(
            for: symbol, inQuoteCurrency: info.currency, converter: currencyConverter
        )
        // Amounts here are already in pounds for a pence-quoted holding, so a
        // cost entered in pence must not label them "GBX" before a quote arrives.
        let statedCurrency = info.currency
            ?? realTimeTrade.trade.position.currency
            ?? realTimeTrade.trade.position.costCurrency
            ?? ""
        let currency = CurrencyConverter.isPenceCurrency(statedCurrency) ? "GBP" : statedCurrency

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
        } else if let brokerValuation,
                  let brokerAmount = brokerValuation.brokerUnrealizedProfitLoss,
                  brokerAmount.isFinite {
            totalAmount = brokerAmount
            totalPercent = brokerValuation.totalGainPercent
        } else {
            totalAmount = .nan
            totalPercent = .nan
        }

        if let brokerValuation,
           let brokerAmount = brokerValuation.brokerUnrealizedProfitLoss,
           brokerAmount.isFinite {
            // The row carries one currency label, the broker's. The day amount
            // was worked out in the quote currency, so it is converted to match.
            let brokerCurrency = brokerValuation.currency
            let dayInBrokerCurrency = dayAmount.isFinite && !currency.isEmpty
                && currency.uppercased() != brokerCurrency.uppercased()
                ? currencyConverter.convert(amount: dayAmount, from: currency, to: brokerCurrency)
                : dayAmount
            return PositionProfitLossSummary(
                dayAmount: dayInBrokerCurrency,
                dayPercent: dayPercent,
                totalAmount: brokerAmount,
                totalPercent: brokerValuation.totalGainPercent,
                currency: brokerCurrency
            )
        }

        return PositionProfitLossSummary(
            dayAmount: dayAmount,
            dayPercent: dayPercent,
            totalAmount: totalAmount,
            totalPercent: totalPercent,
            currency: currency
        )
    }

    private func calculateBrokerProvidedPortfolioSummary(
        trades: [RealTimeTrade],
        preferredCurrency: String,
        brokerValuationSnapshot: Trading212BrokerValuationSnapshot
    ) -> DisplayPortfolioSummary {
        let localSummary = calculateDisplayPortfolioSummary(
            trades: trades,
            preferredCurrency: preferredCurrency,
            brokerValuationSnapshot: nil
        )
        let totalValue = convertBrokerAmount(
            brokerValuationSnapshot.accountValue,
            from: brokerValuationSnapshot.currency,
            to: preferredCurrency
        )
        let totalGainSource = brokerValuationSnapshot.totalUnrealizedProfitLoss ?? localSummary.totalGain
        let totalGain = convertBrokerAmount(
            totalGainSource,
            from: brokerValuationSnapshot.totalUnrealizedProfitLoss == nil ? preferredCurrency : brokerValuationSnapshot.currency,
            to: preferredCurrency
        )
        let totalCostSource = brokerValuationSnapshot.totalCost
            ?? (brokerValuationSnapshot.investmentsValue.flatMap { investmentsValue in
                brokerValuationSnapshot.totalUnrealizedProfitLoss.map { investmentsValue - $0 }
            })
        let totalCost = totalCostSource.map {
            convertBrokerAmount($0, from: brokerValuationSnapshot.currency, to: preferredCurrency)
        } ?? max(totalValue - totalGain, 0)
        let totalGainPct: Double
        if let totalCostSource, totalCostSource > 0,
           let unrealized = brokerValuationSnapshot.totalUnrealizedProfitLoss {
            totalGainPct = (unrealized / totalCostSource) * 100.0
        } else {
            totalGainPct = localSummary.totalGainPct
        }

        return DisplayPortfolioSummary(
            totalValue: totalValue,
            totalGain: totalGain,
            totalGainPct: totalGainPct,
            dayGain: localSummary.dayGain,
            dayGainPct: localSummary.dayGainPct,
            totalCost: totalCost,
            ownedPositionCount: localSummary.ownedPositionCount,
            currency: preferredCurrency,
            valuationSource: .brokerProvided
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

    private func convertBrokerAmount(_ amount: Double, from sourceCurrency: String, to targetCurrency: String) -> Double {
        let normalizedSource = CurrencyConverter.isPenceCurrency(sourceCurrency) ? "GBP" : sourceCurrency.uppercased()
        let normalizedTarget = CurrencyConverter.isPenceCurrency(targetCurrency) ? "GBP" : targetCurrency.uppercased()
        // A pence amount is divided once here; relabelling it as pounds would overstate it 100 times.
        let sourceAmount = CurrencyConverter.isPenceCurrency(sourceCurrency) ? amount / 100.0 : amount
        let converted = normalizedSource == normalizedTarget
            ? sourceAmount
            : currencyConverter.convert(amount: sourceAmount, from: normalizedSource, to: normalizedTarget)
        return CurrencyConverter.isPenceCurrency(targetCurrency) ? converted * 100.0 : converted
    }
}
