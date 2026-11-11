import Foundation

struct HistoricalPortfolioCalculationInput: Sendable {
    let startDate: Date
    let endDate: Date
    let priceSnapshots: [String: [PriceSnapshot]]
    let composition: PortfolioComposition
    let preferredCurrency: String
}

struct HistoricalPortfolioCalculationService: Sendable {
    func calculateSnapshots(_ input: HistoricalPortfolioCalculationInput) async -> [HistoricalPortfolioSnapshot] {
        await Task.detached(priority: .utility) {
            await Self.calculate(input)
        }.value
    }

    private static func calculate(_ input: HistoricalPortfolioCalculationInput) async -> [HistoricalPortfolioSnapshot] {
        let calendar = Calendar(identifier: .gregorian)
        let sortedPriceSnapshots = input.priceSnapshots.mapValues { snapshots in
            snapshots.sorted { $0.timestamp < $1.timestamp }
        }

        let sortedDates = sortedPriceSnapshots.values
            .flatMap { snapshots in
                snapshots.compactMap { snapshot -> Date? in
                    guard snapshot.timestamp >= input.startDate, snapshot.timestamp <= input.endDate else {
                        return nil
                    }
                    return calendar.startOfDay(for: snapshot.timestamp)
                }
            }
            .reduce(into: Set<Date>()) { $0.insert($1) }
            .sorted()

        guard !sortedDates.isEmpty else {
            return []
        }

        guard sortedDates.count > 100 else {
            return calculateSnapshots(
                for: sortedDates,
                priceSnapshots: sortedPriceSnapshots,
                composition: input.composition,
                preferredCurrency: input.preferredCurrency
            )
        }

        let processorCount = ProcessInfo.processInfo.processorCount
        let chunkCount = min(max(processorCount, 1), 8)
        let chunkSize = max(10, sortedDates.count / chunkCount)
        let dateChunks = sortedDates.chunked(into: chunkSize)

        return await withTaskGroup(of: [HistoricalPortfolioSnapshot].self) { group in
            for dates in dateChunks {
                group.addTask {
                    calculateSnapshots(
                        for: dates,
                        priceSnapshots: sortedPriceSnapshots,
                        composition: input.composition,
                        preferredCurrency: input.preferredCurrency
                    )
                }
            }

            var snapshots: [HistoricalPortfolioSnapshot] = []
            for await chunk in group {
                snapshots.append(contentsOf: chunk)
            }
            return snapshots.sorted { $0.date < $1.date }
        }
    }

    private static func calculateSnapshots(
        for dates: [Date],
        priceSnapshots: [String: [PriceSnapshot]],
        composition: PortfolioComposition,
        preferredCurrency: String
    ) -> [HistoricalPortfolioSnapshot] {
        let converter = CurrencyConverter.shared

        // Each holding's latest known value, used to weigh how much of the
        // portfolio is priced on a given day. Holdings with no usable price at
        // all are left out, as they are from every total.
        var referenceValueUSD: [String: Double] = [:]
        for position in composition.positions where position.units.isFinite && position.units > 0 {
            guard let price = priceSnapshots[position.symbol]?.last(where: { $0.price.isFinite && $0.price > 0 })?.price else {
                continue
            }
            let value = convertToUSD(amount: price * position.units, currency: position.currency, converter: converter)
            if value.isFinite, value > 0 { referenceValueUSD[position.symbol] = value }
        }
        let totalReferenceUSD = referenceValueUSD.values.reduce(0, +)

        return dates.compactMap { date in
            var totalValueUSD = 0.0
            // Cost and gains cover only valued positions with a readable cost,
            // so a missing price or a blank Avg Cost cannot skew or NaN them.
            var costedValueUSD = 0.0
            var totalCostUSD = 0.0
            var positionSnapshots: [String: PositionSnapshot] = [:]
            var pricedReferenceUSD = 0.0

            for position in composition.positions {
                guard let symbolSnapshots = priceSnapshots[position.symbol],
                      let historicalSnapshot = latestSnapshot(in: symbolSnapshots, onOrBefore: date) else {
                    continue
                }

                let price = historicalSnapshot.price
                guard price.isFinite,
                      price > 0,
                      position.units.isFinite,
                      position.units > 0 else {
                    continue
                }

                let valueAtDate = price * position.units
                guard valueAtDate.isFinite, valueAtDate > 0 else {
                    continue
                }

                let valueInUSD = convertToUSD(
                    amount: valueAtDate,
                    currency: position.currency,
                    converter: converter
                )
                guard valueInUSD.isFinite, valueInUSD > 0 else {
                    continue
                }

                totalValueUSD += valueInUSD
                pricedReferenceUSD += referenceValueUSD[position.symbol] ?? 0
                let costInUSD = convertToUSD(
                    amount: position.avgCost * position.units,
                    currency: position.currency,
                    converter: converter
                )
                if costInUSD.isFinite, costInUSD > 0 {
                    costedValueUSD += valueInUSD
                    totalCostUSD += costInUSD
                }
                positionSnapshots[position.symbol] = PositionSnapshot(
                    symbol: position.symbol,
                    units: position.units,
                    priceAtDate: price,
                    valueAtDate: valueAtDate,
                    currency: position.currency
                )
            }

            // Half the holdings by count could be a tenth of the value; a total
            // missing a large holding is a step in the chart, not an estimate.
            guard totalReferenceUSD > 0,
                  pricedReferenceUSD / totalReferenceUSD >= minimumPricedShare,
                  totalValueUSD.isFinite,
                  totalValueUSD > 0 else {
                return nil
            }

            let finalValue = convertFromUSD(
                amount: totalValueUSD,
                preferredCurrency: preferredCurrency,
                converter: converter
            )
            let totalCost = convertFromUSD(
                amount: totalCostUSD,
                preferredCurrency: preferredCurrency,
                converter: converter
            )
            let totalGains = convertFromUSD(
                amount: costedValueUSD - totalCostUSD,
                preferredCurrency: preferredCurrency,
                converter: converter
            )

            return HistoricalPortfolioSnapshot(
                date: date,
                totalValue: finalValue,
                totalGains: totalGains,
                totalCost: totalCost,
                currency: preferredCurrency,
                portfolioComposition: positionSnapshots
            )
        }
    }

    private static func convertToUSD(amount: Double, currency: String, converter: CurrencyConverter) -> Double {
        let normalizedCurrency = currency.uppercased()
        if normalizedCurrency == "USD" {
            return amount
        }
        if normalizedCurrency == "GBX" || normalizedCurrency == "GBPENCE" || currency == "GBp" {
            return converter.convert(amount: amount / 100.0, from: "GBP", to: "USD")
        }
        return converter.convert(amount: amount, from: currency, to: "USD")
    }

    private static func convertFromUSD(
        amount: Double,
        preferredCurrency: String,
        converter: CurrencyConverter
    ) -> Double {
        let normalizedCurrency = preferredCurrency.uppercased()
        if normalizedCurrency == "USD" {
            return amount
        }
        if normalizedCurrency == "GBX" || normalizedCurrency == "GBPENCE" || preferredCurrency == "GBp" {
            return converter.convert(amount: amount, from: "USD", to: "GBP") * 100.0
        }
        return converter.convert(amount: amount, from: "USD", to: preferredCurrency)
    }

    /// How long a price is carried forward: long enough for a holiday week,
    /// short enough that a stale price does not stand in for a real one.
    static let maximumPriceAge: TimeInterval = 10 * 24 * 60 * 60
    /// The share of the portfolio (by its latest known value) that must have a
    /// price on a day for that day's total to be recorded.
    static let minimumPricedShare = 0.9

    /// The latest price on or before the target day, no older than `maximumPriceAge`.
    /// A later price is never used: it would put tomorrow's move into today's total.
    private static func latestSnapshot(in sortedSnapshots: [PriceSnapshot], onOrBefore targetDate: Date) -> PriceSnapshot? {
        let calendar = Calendar(identifier: .gregorian)
        let targetDayStart = calendar.startOfDay(for: targetDate)
        var left = 0
        var right = sortedSnapshots.count - 1
        var match: PriceSnapshot?

        while left <= right {
            let mid = (left + right) / 2
            let snapshot = sortedSnapshots[mid]
            if calendar.startOfDay(for: snapshot.timestamp) <= targetDayStart {
                match = snapshot
                left = mid + 1
            } else {
                right = mid - 1
            }
        }

        guard let match,
              targetDayStart.timeIntervalSince(calendar.startOfDay(for: match.timestamp)) <= maximumPriceAge else {
            return nil
        }
        return match
    }
}
