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

        let totalInvestmentCost = calculateTotalInvestmentCost(
            composition: input.composition,
            preferredCurrency: input.preferredCurrency
        )

        guard sortedDates.count > 100 else {
            return calculateSnapshots(
                for: sortedDates,
                priceSnapshots: sortedPriceSnapshots,
                composition: input.composition,
                totalInvestmentCost: totalInvestmentCost,
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
                        totalInvestmentCost: totalInvestmentCost,
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
        totalInvestmentCost: Double,
        preferredCurrency: String
    ) -> [HistoricalPortfolioSnapshot] {
        let converter = CurrencyConverter(refreshOnInit: false, loadHistoryOnInit: false)

        return dates.compactMap { date in
            var totalValueUSD = 0.0
            var positionSnapshots: [String: PositionSnapshot] = [:]
            var validPositions = 0

            for position in composition.positions {
                guard let symbolSnapshots = priceSnapshots[position.symbol],
                      let historicalSnapshot = findClosestSnapshot(in: symbolSnapshots, to: date) else {
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
                validPositions += 1
                positionSnapshots[position.symbol] = PositionSnapshot(
                    symbol: position.symbol,
                    units: position.units,
                    priceAtDate: price,
                    valueAtDate: valueAtDate,
                    currency: position.currency
                )
            }

            guard validPositions >= max(1, composition.positions.count / 2),
                  totalValueUSD.isFinite,
                  totalValueUSD > 0 else {
                return nil
            }

            let finalValue = convertFromUSD(
                amount: totalValueUSD,
                preferredCurrency: preferredCurrency,
                converter: converter
            )
            let totalGains = finalValue - totalInvestmentCost

            return HistoricalPortfolioSnapshot(
                date: date,
                totalValue: finalValue,
                totalGains: totalGains,
                totalCost: totalInvestmentCost,
                currency: preferredCurrency,
                portfolioComposition: positionSnapshots
            )
        }
    }

    private static func calculateTotalInvestmentCost(
        composition: PortfolioComposition,
        preferredCurrency: String
    ) -> Double {
        let converter = CurrencyConverter(refreshOnInit: false, loadHistoryOnInit: false)
        let totalCostUSD = composition.positions.reduce(0.0) { total, position in
            let positionCost = position.avgCost * position.units
            return total + convertToUSD(amount: positionCost, currency: position.currency, converter: converter)
        }
        return convertFromUSD(amount: totalCostUSD, preferredCurrency: preferredCurrency, converter: converter)
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

    private static func findClosestSnapshot(in sortedSnapshots: [PriceSnapshot], to targetDate: Date) -> PriceSnapshot? {
        guard !sortedSnapshots.isEmpty else {
            return nil
        }

        let calendar = Calendar(identifier: .gregorian)
        let targetDayStart = calendar.startOfDay(for: targetDate)
        var left = 0
        var right = sortedSnapshots.count - 1
        var bestMatch: PriceSnapshot?
        var bestDistance = TimeInterval.greatestFiniteMagnitude

        while left <= right {
            let mid = (left + right) / 2
            let snapshot = sortedSnapshots[mid]
            let snapshotDayStart = calendar.startOfDay(for: snapshot.timestamp)
            let distance = abs(snapshotDayStart.timeIntervalSince(targetDayStart))

            if distance < bestDistance {
                bestDistance = distance
                bestMatch = snapshot
            }

            if snapshotDayStart == targetDayStart {
                return snapshot
            } else if snapshotDayStart < targetDayStart {
                left = mid + 1
            } else {
                right = mid - 1
            }
        }

        guard bestDistance <= 30 * 24 * 60 * 60 else {
            return nil
        }
        return bestMatch
    }
}
