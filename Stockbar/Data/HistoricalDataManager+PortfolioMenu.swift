import Combine
import CoreData
import Foundation
import Observation

extension HistoricalDataManager {
    /// Returns display-only portfolio menu values. For 1D, this reconstructs the
    /// current portfolio over the last day from available symbol snapshots.
    func getPortfolioMenuValues(
        for timeRange: ChartTimeRange,
        currentTrades: [RealTimeTrade],
        preferredCurrency: String,
        now: Date = Date(),
        scheduleMissingHistoryFetches: Bool = true,
        allowSyntheticPositionHistory: Bool = true
    ) -> [ChartDataPoint] {
        let startDate = timeRange.startDate(from: now)
        let storedAndLiveValues = storedAndLivePortfolioValues(from: startDate, to: now, currency: preferredCurrency)

        guard timeRange == .day, allowSyntheticPositionHistory else {
            return storedAndLiveValues
        }

        let positions = portfolioMenuPositions(
            from: currentTrades,
            preferredCurrency: preferredCurrency
        )
        guard !positions.isEmpty else {
            return storedAndLiveValues
        }

        let syntheticValues = syntheticPortfolioMenuValues(
            positions: positions,
            preferredCurrency: preferredCurrency,
            startDate: startDate,
            endDate: now
        )

        if scheduleMissingHistoryFetches {
            schedulePortfolioMenuHistoryFetchesIfNeeded(
                currentTrades: currentTrades,
                startDate: startDate,
                endDate: now,
                syntheticPointCount: syntheticValues.count
            )
        }

        guard syntheticValues.count >= 3 else {
            return storedAndLiveValues
        }

        return deduplicatedSortedChartPoints(storedAndLiveValues + syntheticValues)
    }

    func portfolioMenuHistoryFetchCandidates(
        currentTrades: [RealTimeTrade],
        startDate: Date,
        endDate: Date,
        minimumPoints: Int = 3
    ) -> [String] {
        currentTrades
            .filter { !$0.trade.isWatchlistOnly && $0.trade.position.unitSize > 0 }
            .compactMap { realTimeTrade -> String? in
                let symbol = realTimeTrade.trade.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !symbol.isEmpty else { return nil }

                let snapshotCount = allPortfolioMenuPriceSnapshots(for: symbol)
                    .filter { $0.timestamp >= startDate && $0.timestamp <= endDate }
                    .count
                return snapshotCount < minimumPoints ? symbol : nil
            }
    }

    func shouldFetchMenuPriceHistory(
        for symbol: String,
        from startDate: Date,
        to endDate: Date = Date(),
        minimumPoints: Int = 10
    ) -> Bool {
        let symbolKey = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !symbolKey.isEmpty, minimumPoints > 0 else { return false }

        let snapshotCount = getPriceSnapshots(for: symbolKey, from: startDate, to: endDate).count

        return snapshotCount < minimumPoints
    }

    struct PortfolioMenuPosition {
        let symbol: String
        let units: Double
        let currency: String
        let currentPrice: Double
        let currentValueInPreferredCurrency: Double
    }

    func storedAndLivePortfolioValues(from startDate: Date, to endDate: Date, currency: String?) -> [ChartDataPoint] {
        let storedValues = portfolioSnapshots(in: currency)
            .filter { $0.date >= startDate && $0.date <= endDate }
            .map { snapshot in
                ChartDataPoint(date: snapshot.date, value: snapshot.totalValue)
            }
        let liveValues = liveSamplesMatch(currency)
            ? livePortfolioValueSamples.filter { $0.date >= startDate && $0.date <= endDate }
            : []
        return deduplicatedSortedChartPoints(storedValues + liveValues)
    }

    func portfolioMenuPositions(
        from currentTrades: [RealTimeTrade],
        preferredCurrency: String
    ) -> [PortfolioMenuPosition] {
        let converter = CurrencyConverter.shared

        return currentTrades.compactMap { realTimeTrade -> PortfolioMenuPosition? in
            let trade = realTimeTrade.trade
            guard !trade.isWatchlistOnly else { return nil }

            let symbol = trade.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let units = trade.position.unitSize
            let currentPrice = realTimeTrade.realTimeInfo.getCurrentDisplayPrice()
            guard !symbol.isEmpty,
                  units.isFinite,
                  units > 0,
                  currentPrice.isFinite,
                  currentPrice > 0 else {
                return nil
            }

            let currency = portfolioMenuDisplayCurrency(for: realTimeTrade)
            let currentValue = convertPortfolioMenuValue(
                amount: currentPrice * units,
                from: currency,
                to: preferredCurrency,
                converter: converter
            )
            guard currentValue.isFinite, currentValue > 0 else {
                return nil
            }

            return PortfolioMenuPosition(
                symbol: symbol,
                units: units,
                currency: currency,
                currentPrice: currentPrice,
                currentValueInPreferredCurrency: currentValue
            )
        }
    }

    func syntheticPortfolioMenuValues(
        positions: [PortfolioMenuPosition],
        preferredCurrency: String,
        startDate: Date,
        endDate: Date
    ) -> [ChartDataPoint] {
        let snapshotsBySymbol = Dictionary(firstValuesFor: positions.map { position in
            (
                position.symbol,
                allPortfolioMenuPriceSnapshots(for: position.symbol)
                    .filter { $0.timestamp >= startDate && $0.timestamp <= endDate }
            )
        })

        let candidateDates = latestDatesPerBucket(
            snapshotsBySymbol.values.flatMap { snapshots in snapshots.map(\.timestamp) },
            bucketSize: 120
        )
        guard !candidateDates.isEmpty else { return [] }

        let converter = CurrencyConverter.shared
        let totalCurrentValue = positions
            .map(\.currentValueInPreferredCurrency)
            .reduce(0, +)
        guard totalCurrentValue.isFinite, totalCurrentValue > 0 else { return [] }

        let minimumCoveredPositionCount = max(1, Int(ceil(Double(positions.count) * 0.5)))
        let tolerance: TimeInterval = 10 * 60

        return candidateDates.compactMap { candidateDate in
            var coveredPositionCount = 0
            var coveredCurrentValue = 0.0
            var syntheticValue = 0.0

            for position in positions {
                // A position with no price at this time is carried at today's
                // value. Leaving it out made the total up to 30% too small,
                // which the chart then drew as a jump to the current value.
                let carried = position.currentValueInPreferredCurrency
                guard let snapshots = snapshotsBySymbol[position.symbol],
                      let snapshot = latestSnapshot(in: snapshots, atOrBefore: candidateDate, tolerance: tolerance) else {
                    if carried.isFinite, carried > 0 { syntheticValue += carried }
                    continue
                }

                let price = normalizedPortfolioMenuPrice(
                    snapshot.price,
                    currentPrice: position.currentPrice,
                    symbol: position.symbol
                )
                let positionValue = price.isFinite && price > 0
                    ? convertPortfolioMenuValue(
                        amount: price * position.units,
                        from: position.currency,
                        to: preferredCurrency,
                        converter: converter
                    )
                    : Double.nan
                guard positionValue.isFinite, positionValue > 0 else {
                    if carried.isFinite, carried > 0 { syntheticValue += carried }
                    continue
                }

                coveredPositionCount += 1
                coveredCurrentValue += carried
                syntheticValue += positionValue
            }

            guard coveredPositionCount >= minimumCoveredPositionCount,
                  coveredCurrentValue / totalCurrentValue >= 0.7,
                  syntheticValue.isFinite,
                  syntheticValue > 0 else {
                return nil
            }

            return ChartDataPoint(date: candidateDate, value: syntheticValue)
        }
    }

    func schedulePortfolioMenuHistoryFetchesIfNeeded(
        currentTrades: [RealTimeTrade],
        startDate: Date,
        endDate: Date,
        syntheticPointCount: Int
    ) {
        guard syntheticPointCount < 6 else { return }

        let candidates = portfolioMenuHistoryFetchCandidates(
            currentTrades: currentTrades,
            startDate: startDate,
            endDate: endDate
        )

        for symbol in candidates {
            schedulePriceHistoryFetchIfNeeded(
                for: symbol,
                timeRange: .day,
                startDate: startDate,
                endDate: endDate
            )
        }
    }

    func allPortfolioMenuPriceSnapshots(for symbol: String) -> [PriceSnapshot] {
        aliasAwarePriceSnapshots(for: symbol)
    }

    func latestSnapshot(
        in snapshots: [PriceSnapshot],
        atOrBefore date: Date,
        tolerance: TimeInterval
    ) -> PriceSnapshot? {
        guard !snapshots.isEmpty else { return nil }

        var lowerBound = 0
        var upperBound = snapshots.count - 1
        var candidate: PriceSnapshot?

        while lowerBound <= upperBound {
            let middle = (lowerBound + upperBound) / 2
            let snapshot = snapshots[middle]

            if snapshot.timestamp <= date {
                candidate = snapshot
                lowerBound = middle + 1
            } else {
                upperBound = middle - 1
            }
        }

        guard let candidate,
              date.timeIntervalSince(candidate.timestamp) <= tolerance else {
            return nil
        }
        return candidate
    }

    func latestDatesPerBucket(_ dates: [Date], bucketSize: TimeInterval) -> [Date] {
        guard bucketSize > 0, !dates.isEmpty else { return dates.sorted() }

        var latestByBucket: [Int: Date] = [:]
        for date in dates {
            let bucket = Int(floor(date.timeIntervalSince1970 / bucketSize))
            if let existing = latestByBucket[bucket], existing > date {
                continue
            }
            latestByBucket[bucket] = date
        }

        return latestByBucket.keys.sorted().compactMap { latestByBucket[$0] }
    }

    func normalizedPortfolioMenuPrice(
        _ price: Double,
        currentPrice: Double,
        symbol: String
    ) -> Double {
        UKPriceScale.normalized(price, reference: currentPrice, symbol: symbol)
    }

    func portfolioMenuDisplayCurrency(for realTimeTrade: RealTimeTrade) -> String {
        let symbol = realTimeTrade.trade.name
        let currency = realTimeTrade.realTimeInfo.currency
            ?? realTimeTrade.trade.position.currency
            ?? realTimeTrade.trade.position.costCurrency
            ?? "USD"

        if SymbolMetadata.isUKSymbol(symbol),
           ["GBX", "GBPENCE", "GBPENNY", "GBPEN"].contains(currency.uppercased()) || currency == "GBp" {
            return "GBP"
        }

        return currency
    }

    func convertPortfolioMenuValue(
        amount: Double,
        from currency: String,
        to preferredCurrency: String,
        converter: CurrencyConverter
    ) -> Double {
        let normalizedCurrency = currency.uppercased()
        let normalizedPreferredCurrency = preferredCurrency.uppercased()

        let amountInUSD: Double
        if normalizedCurrency == "USD" {
            amountInUSD = amount
        } else if normalizedCurrency == "GBX" || normalizedCurrency == "GBPENCE" || currency == "GBp" {
            amountInUSD = converter.convert(amount: amount / 100.0, from: "GBP", to: "USD")
        } else {
            amountInUSD = converter.convert(amount: amount, from: currency, to: "USD")
        }

        if normalizedPreferredCurrency == "USD" {
            return amountInUSD
        }
        if normalizedPreferredCurrency == "GBX" || normalizedPreferredCurrency == "GBPENCE" || preferredCurrency == "GBp" {
            return converter.convert(amount: amountInUSD, from: "USD", to: "GBP") * 100.0
        }
        return converter.convert(amount: amountInUSD, from: "USD", to: preferredCurrency)
    }
}
