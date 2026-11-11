import Combine
import CoreData
import Foundation
import Observation

extension HistoricalDataManager {
    func folyncSourceStatus(
        for symbol: String,
        timeRange: ChartTimeRange,
        customFrom: Date? = nil,
        customTo: Date? = nil
    ) -> FolyncSupplementalSourceStatus? {
        folyncLineSeriesKeys(
            for: symbol,
            timeRange: timeRange,
            customFrom: customFrom,
            customTo: customTo
        ).compactMap { folyncSourceStatusBySeries[$0] }.first
    }

    func folyncCoverage(
        for symbol: String,
        timeRange: ChartTimeRange,
        customFrom: Date? = nil,
        customTo: Date? = nil
    ) -> String? {
        folyncLineSeriesKeys(
            for: symbol,
            timeRange: timeRange,
            customFrom: customFrom,
            customTo: customTo
        ).compactMap { folyncCoverageBySeries[$0] }.first
    }

    func folyncPortfolioSourceStatus(
        kind: String,
        timeRange: ChartTimeRange,
        customFrom: Date? = nil,
        customTo: Date? = nil
    ) -> FolyncSupplementalSourceStatus? {
        folyncSourceStatusBySeries[folyncPortfolioSeriesKey(
            kind: kind,
            timeRange: timeRange,
            customFrom: customFrom,
            customTo: customTo
        )]
    }

    func folyncPortfolioCoverage(
        kind: String,
        timeRange: ChartTimeRange,
        customFrom: Date? = nil,
        customTo: Date? = nil
    ) -> String? {
        folyncCoverageBySeries[folyncPortfolioSeriesKey(
            kind: kind,
            timeRange: timeRange,
            customFrom: customFrom,
            customTo: customTo
        )]
    }

    func clearFolyncSupplementalOverlays() {
        folyncPriceOverlays.removeAll()
        folyncUnavailableSeries.removeAll()
        folyncPortfolioHistoryContexts.removeAll()
        folyncPortfolioHistoryFetchRequestTimes.removeAll()
        folyncPortfolioValueOverlays.removeAll()
        folyncPortfolioGainOverlays.removeAll()
        folyncSourceStatusBySeries.removeAll()
        folyncCoverageBySeries.removeAll()
        stockDataCache.removeAll()
        stockDataCacheTimestamp.removeAll()
        folyncSupplementalConfigurationRevision &+= 1
        notePriceDataRevision(changed: nil)
    }

    func noteFolyncSupplementalConfigurationChanged() {
        folyncSupplementalConfigurationRevision &+= 1
        notePriceDataRevision(changed: nil)
    }

    func setFolyncPriceOverlay(
        _ snapshots: [PriceSnapshot],
        identity: FolyncInstrumentIdentity,
        requestedSymbol: String,
        status: FolyncSupplementalSourceStatus,
        metadata: FolyncSeriesMetadata,
        timeRange: ChartTimeRange,
        customFrom: Date?,
        customTo: Date?
    ) {
        let aliases = Set((identity.aliases + [
            identity.canonicalTicker,
            identity.displayTicker,
            identity.quoteSymbol,
            requestedSymbol
        ]).map(normalizedSeriesKey))
        for alias in aliases {
            let key = FolyncLineSeriesKey(
                symbol: alias,
                timeRange: timeRange,
                customFrom: customFrom,
                customTo: customTo
            ).storageKey
            folyncPriceOverlays[key] = snapshots
            folyncUnavailableSeries.remove(key)
            folyncSourceStatusBySeries[key] = status
            folyncCoverageBySeries[key] = metadata.coverageLabel
            invalidateStockDataCache(for: alias)
        }
        notePriceDataRevision(changed: aliases)
    }

    func markFolyncSeriesUnavailable(
        _ symbol: String,
        timeRange: ChartTimeRange,
        customFrom: Date?,
        customTo: Date?
    ) {
        let aliases = Set(([symbol] + instrumentAliasStore.aliases(for: symbol)).map(normalizedSeriesKey))
        for alias in aliases {
            let key = FolyncLineSeriesKey(
                symbol: alias,
                timeRange: timeRange,
                customFrom: customFrom,
                customTo: customTo
            ).storageKey
            folyncPriceOverlays.removeValue(forKey: key)
            folyncUnavailableSeries.insert(key)
            folyncSourceStatusBySeries[key] = .unavailable
            folyncCoverageBySeries.removeValue(forKey: key)
            invalidateStockDataCache(for: alias)
        }
        notePriceDataRevision(changed: aliases)
    }

    func clearFolyncPriceOverlayForLegacy(
        _ symbol: String,
        timeRange: ChartTimeRange,
        customFrom: Date?,
        customTo: Date?
    ) {
        let aliases = Set(([symbol] + instrumentAliasStore.aliases(for: symbol)).map(normalizedSeriesKey))
        for alias in aliases {
            let key = FolyncLineSeriesKey(
                symbol: alias,
                timeRange: timeRange,
                customFrom: customFrom,
                customTo: customTo
            ).storageKey
            folyncPriceOverlays.removeValue(forKey: key)
            folyncUnavailableSeries.remove(key)
            folyncSourceStatusBySeries[key] = .legacy
            folyncCoverageBySeries.removeValue(forKey: key)
            invalidateStockDataCache(for: alias)
        }
        notePriceDataRevision(changed: aliases)
    }

    func folyncLineSeriesKeys(
        for symbol: String,
        timeRange: ChartTimeRange,
        customFrom: Date?,
        customTo: Date?
    ) -> Set<String> {
        Set(([symbol] + instrumentAliasStore.aliases(for: symbol)).map {
            FolyncLineSeriesKey(
                symbol: $0,
                timeRange: timeRange,
                customFrom: customFrom,
                customTo: customTo
            ).storageKey
        })
    }

    func folyncPortfolioOverlay(
        kind: String,
        timeRange: ChartTimeRange,
        dataModel: DataModel?,
        customFrom: Date?,
        customTo: Date?
    ) -> [ChartDataPoint]? {
        guard dataModel?.isFolyncPortfolioActive == true else { return nil }
        let key = folyncPortfolioSeriesKey(
            kind: kind,
            timeRange: timeRange,
            customFrom: customFrom,
            customTo: customTo
        )
        let expectedScope = dataModel?.folyncPortfolioSnapshot?.scope.id ?? FolyncSettingsStore.shared.load().scopeID
        let expectedCurrency = dataModel?.preferredCurrency ?? "USD"
        let context = "\(expectedScope)|\(expectedCurrency)|\(timeRange.folyncRange)"
        if folyncPortfolioHistoryContexts[key] != context {
            folyncPortfolioValueOverlays.removeValue(forKey: key)
            folyncPortfolioGainOverlays.removeValue(forKey: key)
        }
        scheduleFolyncPortfolioHistoryIfNeeded(
            timeRange: timeRange,
            customFrom: customFrom,
            customTo: customTo, expectedScope: expectedScope, expectedCurrency: expectedCurrency
        )
        if let overlay = kind == "portfolio-value"
            ? folyncPortfolioValueOverlays[key]
            : folyncPortfolioGainOverlays[key] {
            return overlay
        }
        if folyncUnavailableSeries.contains(key) { return [] }
        if folyncSourceStatusBySeries[key] == .legacy { return [] }
        // An enabled Folync route owns the whole series while its first request
        // is pending; do not flash or splice the pre-existing local series.
        return []
    }

    func scheduleFolyncPortfolioHistoryIfNeeded(
        timeRange: ChartTimeRange,
        customFrom: Date?,
        customTo: Date?, expectedScope: String, expectedCurrency: String
    ) {
        let customKey = timeRange == .custom
            ? "|\(customFrom?.timeIntervalSince1970 ?? 0)|\(customTo?.timeIntervalSince1970 ?? 0)"
            : ""
        let key = "portfolio|\(expectedScope)|\(expectedCurrency)|\(timeRange.folyncRange)\(customKey)"
        let now = Date()
        if let lastRequest = folyncPortfolioHistoryFetchRequestTimes[key],
           now.timeIntervalSince(lastRequest) < menuPriceHistoryFetchCooldown {
            return
        }
        folyncPortfolioHistoryFetchRequestTimes[key] = now
        let configurationRevision = folyncSupplementalConfigurationRevision
        folyncPortfolioHistoryRequestsInFlight += 1
        Task { [weak self] in
            guard let self else { return }
            defer { self.folyncPortfolioHistoryRequestsInFlight -= 1 }
            let result = await FolyncSupplementalCoordinator.shared.routePortfolioHistory(
                range: timeRange.folyncRange,
                from: timeRange == .custom ? customFrom : nil,
                to: timeRange == .custom ? customTo : nil
            )
            guard configurationRevision == self.folyncSupplementalConfigurationRevision else { return }
            let validated: FolyncRoutedPortfolioResult
            if case .folync(let history, _) = result,
               (history.scope.id != expectedScope || history.currency?.uppercased() != expectedCurrency.uppercased()
                || history.range != (timeRange == .custom ? "custom" : timeRange.folyncRange)) {
                validated = .unavailable
            } else { validated = result }
            self.applyFolyncPortfolioHistory(
                validated,
                timeRange: timeRange,
                customFrom: customFrom,
                customTo: customTo
            )
        }
    }

    func applyFolyncPortfolioHistory(
        _ result: FolyncRoutedPortfolioResult,
        timeRange: ChartTimeRange,
        customFrom: Date?,
        customTo: Date?
    ) {
        let valueKey = folyncPortfolioSeriesKey(
            kind: "portfolio-value",
            timeRange: timeRange,
            customFrom: customFrom,
            customTo: customTo
        )
        let gainKey = folyncPortfolioSeriesKey(
            kind: "portfolio-gain",
            timeRange: timeRange,
            customFrom: customFrom,
            customTo: customTo
        )
        switch result {
        case .folync(let history, let status):
            let context = "\(history.scope.id)|\(history.currency ?? "")|\(timeRange.folyncRange)"
            folyncPortfolioHistoryContexts[valueKey] = context
            folyncPortfolioHistoryContexts[gainKey] = context
            let values = history.portfolioSeries.compactMap(Self.chartPoint).sorted { $0.date < $1.date }
            let gains = history.gainSeries.compactMap(Self.chartPoint).sorted { $0.date < $1.date }
            folyncPortfolioValueOverlays[valueKey] = values
            folyncPortfolioGainOverlays[gainKey] = gains
            folyncUnavailableSeries.remove(valueKey)
            folyncUnavailableSeries.remove(gainKey)
            folyncSourceStatusBySeries[valueKey] = status
            folyncSourceStatusBySeries[gainKey] = status
            let completeness = history.coverage.complete.map { $0 ? "complete coverage" : "partial coverage" } ?? "coverage unavailable"
            let coverage = "\(history.coverage.pointCount) points · \(history.interval) · \(completeness)"
            folyncCoverageBySeries[valueKey] = coverage
            folyncCoverageBySeries[gainKey] = coverage
        case .unavailable:
            folyncPortfolioValueOverlays.removeValue(forKey: valueKey)
            folyncPortfolioGainOverlays.removeValue(forKey: gainKey)
            folyncUnavailableSeries.insert(valueKey)
            folyncUnavailableSeries.insert(gainKey)
            folyncSourceStatusBySeries[valueKey] = .unavailable
            folyncSourceStatusBySeries[gainKey] = .unavailable
            folyncCoverageBySeries.removeValue(forKey: valueKey)
            folyncCoverageBySeries.removeValue(forKey: gainKey)
        case .legacy:
            folyncPortfolioValueOverlays.removeValue(forKey: valueKey)
            folyncPortfolioGainOverlays.removeValue(forKey: gainKey)
            folyncUnavailableSeries.remove(valueKey)
            folyncUnavailableSeries.remove(gainKey)
            folyncSourceStatusBySeries[valueKey] = .legacy
            folyncSourceStatusBySeries[gainKey] = .legacy
            folyncCoverageBySeries.removeValue(forKey: valueKey)
            folyncCoverageBySeries.removeValue(forKey: gainKey)
        }
        portfolioHistoryRevision &+= 1
    }

    func folyncPortfolioSeriesKey(
        kind: String,
        timeRange: ChartTimeRange,
        customFrom: Date?,
        customTo: Date?
    ) -> String {
        let bounds = timeRange == .custom
            ? "|\(customFrom.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded()) } ?? 0)|\(customTo.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded()) } ?? 0)"
            : ""
        return "\(kind)|\(timeRange.folyncRange)\(bounds)"
    }
}
