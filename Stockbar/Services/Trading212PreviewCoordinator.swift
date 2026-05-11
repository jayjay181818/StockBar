import Foundation

actor Trading212PreviewCache {
    private struct Entry {
        let snapshot: Trading212PreviewSnapshot
        let expiresAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 120) {
        self.ttl = ttl
    }

    func store(_ snapshot: Trading212PreviewSnapshot, for key: String) {
        entries[key] = Entry(snapshot: snapshot, expiresAt: Date().addingTimeInterval(ttl))
    }

    func snapshot(for key: String) -> Trading212PreviewSnapshot? {
        guard let entry = entries[key] else {
            return nil
        }
        if entry.expiresAt < Date() {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.snapshot
    }

    func clear() {
        entries.removeAll()
    }
}

extension Trading212ImportPreviewRow {
    static func make(
        account: BrokerAccountIdentity,
        position: Trading212Position,
        resolution: InstrumentResolutionResult,
        existingManualHoldings: [Trading212ManualHoldingSnapshot]
    ) -> Trading212ImportPreviewRow {
        let providerTicker = position.instrument.ticker
        let displaySymbol = resolution.identity?.displaySymbol ?? providerTicker
        let manualMatches = manualMatches(for: resolution.identity?.instrumentId, in: existingManualHoldings)
        let manualMatch = manualMatches.first
        let quantityDelta = manualMatch.flatMap { match in
            position.quantity.map { $0 - match.quantity }
        }
        let conflictStatus: Trading212PreviewConflictStatus
        if resolution.identity == nil {
            conflictStatus = .unresolvedInstrument
        } else if manualMatches.count > 1 {
            conflictStatus = .duplicateManualMatches
        } else if let manualMatch {
            if manualMatch.isWatchlistOnly {
                conflictStatus = .manualWatchlistMatch
            } else if let quantityDelta, abs(quantityDelta) > 0.01 {
                conflictStatus = .manualQuantityMismatch
            } else {
                conflictStatus = .manualHoldingMatch
            }
        } else {
            conflictStatus = .none
        }
        var warnings = resolution.warnings
        if manualMatches.count > 1 {
            warnings.append("Multiple manual holdings resolve to this instrument; review before linking.")
        }

        return Trading212ImportPreviewRow(
            id: "\(account.brokerAccountKey)|\(resolution.identity?.instrumentId ?? providerTicker)",
            account: account,
            providerTicker: providerTicker,
            instrumentId: resolution.identity?.instrumentId,
            displaySymbol: displaySymbol,
            displayName: resolution.identity?.displayName ?? position.instrument.name,
            quantity: position.quantity,
            averagePrice: position.averagePricePaid,
            brokerProvidedPrice: position.currentPrice,
            currentValue: position.walletImpact?.currentValue,
            unrealizedProfitLoss: position.walletImpact?.unrealizedProfitLoss,
            fxImpact: position.walletImpact?.fxImpact,
            mappingConfidence: resolution.confidence,
            manualMatch: manualMatch,
            additionalManualMatchCount: max(0, manualMatches.count - 1),
            conflictStatus: conflictStatus,
            valueSource: position.currentPrice == nil && position.walletImpact?.currentValue == nil
                ? .unavailable
                : .brokerProvidedLivePositionData,
            warnings: warnings
        )
    }

    private static func manualMatches(
        for instrumentId: String?,
        in holdings: [Trading212ManualHoldingSnapshot]
    ) -> [Trading212ManualHoldingMatch] {
        guard let instrumentId else {
            return []
        }
        let resolver = InstrumentResolver()
        return holdings.compactMap { holding in
            let resolution = resolver.resolveLegacySymbol(
                holding.symbol,
                displayName: holding.displayName,
                currency: holding.currency
            )
            guard let identity = resolution.identity, identity.instrumentId == instrumentId else {
                return nil
            }
            return Trading212ManualHoldingMatch(
                symbol: holding.symbol,
                instrumentId: identity.instrumentId,
                displayName: holding.displayName,
                quantity: holding.quantity,
                averageCost: holding.averageCost,
                currency: SymbolMetadata.normalizeCurrency(holding.currency),
                isWatchlistOnly: holding.isWatchlistOnly,
                resolutionConfidence: resolution.confidence
            )
        }
    }
}

struct Trading212ConnectionTestResult: Equatable {
    let accountDataAvailable: Bool
    let metadataAvailable: Bool
    let environment: Trading212Environment
    let accountCurrency: String?
    let positionCount: Int
    let safeMessage: String
}

struct Trading212PreviewCoordinator {
    private let provider: Trading212Provider
    private let resolver: InstrumentResolver
    private let cache: Trading212PreviewCache

    init(
        provider: Trading212Provider = Trading212Provider(),
        resolver: InstrumentResolver = InstrumentResolver(),
        cache: Trading212PreviewCache = Trading212PreviewCache()
    ) {
        self.provider = provider
        self.resolver = resolver
        self.cache = cache
    }

    func testConnection(
        settings: Trading212StoredSettings,
        credentials: Trading212AuthConfiguration
    ) async -> Trading212ConnectionTestResult {
        do {
            let snapshot = try await fetchSnapshot(settings: settings, credentials: credentials)
            return Trading212ConnectionTestResult(
                accountDataAvailable: true,
                metadataAvailable: snapshot.metadataAvailable,
                environment: settings.environment,
                accountCurrency: snapshot.accountSummary?.currency,
                positionCount: snapshot.positions.count,
                safeMessage: snapshot.metadataAvailable
                    ? "Trading 212 Account data and Metadata are available."
                    : "Trading 212 Account data is available. Metadata permission is missing or unavailable, so mappings may need review."
            )
        } catch {
            return Trading212ConnectionTestResult(
                accountDataAvailable: false,
                metadataAvailable: false,
                environment: settings.environment,
                accountCurrency: nil,
                positionCount: 0,
                safeMessage: LogRedactor.redact(error.localizedDescription)
            )
        }
    }

    func preview(
        settings: Trading212StoredSettings,
        credentials: Trading212AuthConfiguration,
        existingManualHoldings: [Trading212ManualHoldingSnapshot],
        includeMetadata: Bool = true,
        useCache: Bool = true
    ) async throws -> Trading212ImportPreview {
        let snapshot = try await fetchSnapshot(
            settings: settings,
            credentials: credentials,
            includeMetadata: includeMetadata,
            useCache: useCache
        )
        let metadataByTicker = Dictionary(uniqueKeysWithValues: snapshot.instruments.map { ($0.ticker.uppercased(), $0) })
        let rows = snapshot.positions.map { position in
            let metadata = metadataByTicker[position.instrument.ticker.uppercased()]
            let resolution = resolver.resolveTrading212Position(
                position,
                metadata: metadata,
                exchangeName: nil
            )
            return Trading212ImportPreviewRow.make(
                account: snapshot.account,
                position: position,
                resolution: resolution,
                existingManualHoldings: existingManualHoldings
            )
        }
        return Trading212ImportPreview(
            account: snapshot.account,
            accountSummary: snapshot.accountSummary,
            rows: rows,
            metadataAvailable: snapshot.metadataAvailable,
            generatedAt: Date(),
            warnings: snapshot.metadataAvailable ? [] : ["Metadata permission unavailable; mappings use lower-confidence position fields."]
        )
    }

    private func fetchSnapshot(
        settings: Trading212StoredSettings,
        credentials: Trading212AuthConfiguration,
        includeMetadata: Bool = true,
        useCache: Bool = true
    ) async throws -> Trading212PreviewSnapshot {
        let provisionalAccount = BrokerAccountIdentity.preview(
            broker: "Trading212",
            environment: settings.environment,
            accountType: settings.accountType,
            accountLabel: settings.accountLabel,
            credentialFingerprint: credentials.credentialFingerprint,
            apiAccountId: nil
        )
        if useCache, let cached = await cache.snapshot(for: provisionalAccount.brokerAccountKey) {
            return cached
        }

        async let summaryRequest = provider.accountSummary(credentials: credentials, environment: settings.environment)
        async let positionsRequest = provider.positions(credentials: credentials, environment: settings.environment)

        let summary = try await summaryRequest
        let positions = try await positionsRequest
        let instruments = includeMetadata
            ? await fetchInstruments(credentials: credentials, environment: settings.environment)
            : []
        let account = BrokerAccountIdentity.preview(
            broker: "Trading212",
            environment: settings.environment,
            accountType: settings.accountType,
            accountLabel: settings.accountLabel,
            credentialFingerprint: credentials.credentialFingerprint,
            apiAccountId: summary.id
        )
        let snapshot = Trading212PreviewSnapshot(
            account: account,
            accountSummary: summary,
            positions: positions,
            instruments: instruments,
            metadataAvailable: !instruments.isEmpty
        )
        await Logger.shared.debug(
            "Trading 212 broker snapshot fetched from network: environment=\(settings.environment.displayName), positions=\(positions.count), metadata=\(!instruments.isEmpty), cache=false"
        )
        await cache.store(snapshot, for: provisionalAccount.brokerAccountKey)
        await cache.store(snapshot, for: account.brokerAccountKey)
        return snapshot
    }

    private func fetchInstruments(
        credentials: Trading212AuthConfiguration,
        environment: Trading212Environment
    ) async -> [Trading212InstrumentMetadata] {
        do {
            return try await provider.instruments(credentials: credentials, environment: environment)
        } catch Trading212ProviderError.forbidden, Trading212ProviderError.unauthorized {
            return []
        } catch {
            return []
        }
    }
}
