import Foundation

enum BrokerLinkStoreError: Error, LocalizedError, Equatable {
    case previewNotReady(String)
    /// The links file exists but cannot be read as links.
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .previewNotReady(let reason):
            return reason
        case .unreadableFile:
            return "The Trading 212 links file is damaged, so sync is paused and nothing was changed. "
                + "Restore a backup, or run Preview Import and link the holdings again."
        }
    }
}

struct BrokerLinkedAccount: Codable, Equatable, Identifiable {
    var id: String { brokerAccountKey }

    let brokerAccountKey: String
    let broker: String
    let accountLabel: String
    let accountType: Trading212AccountType
    let taxWrapper: String
    let environment: Trading212Environment
    let linkedAt: Date
    let updatedAt: Date
}

struct BrokerLinkedPosition: Codable, Equatable, Identifiable {
    var id: String { "\(brokerAccountKey)|\(normalizedProviderTicker)" }
    var instrumentLinkID: String { "\(brokerAccountKey)|\(instrumentId)" }
    var normalizedProviderTicker: String {
        providerTicker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    let brokerAccountKey: String
    let instrumentId: String
    let displaySymbol: String
    let displayName: String?
    let providerTicker: String
    let manualSymbol: String
    let manualQuantityAtLink: Double
    let brokerQuantityAtLink: Double
    let manualAverageCostAtLink: Double?
    let manualCurrency: String?
    let linkedAt: Date
    let updatedAt: Date
}

struct BrokerLinkStoreSnapshot: Codable, Equatable {
    let schemaVersion: Int
    var updatedAt: Date
    var accounts: [BrokerLinkedAccount]
    var positions: [BrokerLinkedPosition]

    static func empty(now: Date = Date()) -> BrokerLinkStoreSnapshot {
        BrokerLinkStoreSnapshot(schemaVersion: 2, updatedAt: now, accounts: [], positions: [])
    }

    /// Moves links saved under an older key for the same account onto
    /// `account`'s current key. Editing the account label or rotating the API
    /// key changes the key; without this every link would stop matching.
    /// Returns nil when nothing needs moving.
    func rekeyed(to account: BrokerAccountIdentity, now: Date = Date()) -> BrokerLinkStoreSnapshot? {
        guard let stable = BrokerAccountIdentity.stableIdentity(ofKey: account.brokerAccountKey) else {
            return nil
        }
        var staleKeys: Set<String> = []
        for key in accounts.map(\.brokerAccountKey) where key != account.brokerAccountKey {
            if BrokerAccountIdentity.stableIdentity(ofKey: key) == stable {
                staleKeys.insert(key)
            }
        }
        guard !staleKeys.isEmpty else { return nil }

        var result = self
        let currentIDs = Set(positions.filter { $0.brokerAccountKey == account.brokerAccountKey }.map(\.id))
        result.positions = positions.compactMap { position in
            guard staleKeys.contains(position.brokerAccountKey) else { return position }
            let moved = BrokerLinkedPosition(
                brokerAccountKey: account.brokerAccountKey,
                instrumentId: position.instrumentId,
                displaySymbol: position.displaySymbol,
                displayName: position.displayName,
                providerTicker: position.providerTicker,
                manualSymbol: position.manualSymbol,
                manualQuantityAtLink: position.manualQuantityAtLink,
                brokerQuantityAtLink: position.brokerQuantityAtLink,
                manualAverageCostAtLink: position.manualAverageCostAtLink,
                manualCurrency: position.manualCurrency,
                linkedAt: position.linkedAt,
                updatedAt: now
            )
            // A link already saved under the current key wins.
            return currentIDs.contains(moved.id) ? nil : moved
        }
        var replacedKeys = staleKeys
        replacedKeys.insert(account.brokerAccountKey)
        let linkedAt = accounts.filter { replacedKeys.contains($0.brokerAccountKey) }.map(\.linkedAt).min() ?? now
        result.accounts.removeAll { replacedKeys.contains($0.brokerAccountKey) }
        result.accounts.append(BrokerLinkedAccount(
            brokerAccountKey: account.brokerAccountKey,
            broker: account.broker,
            accountLabel: account.accountLabel,
            accountType: account.accountType,
            taxWrapper: account.taxWrapper,
            environment: account.environment,
            linkedAt: linkedAt,
            updatedAt: now
        ))
        result.updatedAt = now
        return result
    }
}

struct BrokerLinkSaveResult: Equatable {
    let linkedCount: Int
    let totalLinks: Int
    let fileURL: URL
}

struct BrokerLinkRemoveResult: Equatable {
    let removedCount: Int
    let remainingLinks: Int
    let fileURL: URL
}

actor BrokerLinkStore {
    static let shared = BrokerLinkStore()

    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? BrokerLinkStore.defaultFileURL(fileManager: fileManager)
    }

    func loadSnapshot() throws -> BrokerLinkStoreSnapshot {
        Self.normalized(try loadSnapshotPreservingDuplicates())
    }

    func loadSnapshotPreservingDuplicates() throws -> BrokerLinkStoreSnapshot {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .empty()
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(BrokerLinkStoreSnapshot.self, from: data)
        } catch {
            throw BrokerLinkStoreError.unreadableFile
        }
    }

    func replaceSnapshot(_ snapshot: BrokerLinkStoreSnapshot) throws {
        try save(BrokerLinkStoreSnapshot(
            schemaVersion: 2,
            updatedAt: snapshot.updatedAt,
            accounts: snapshot.accounts,
            positions: snapshot.positions
        ))
    }

    func restoreSnapshot(_ snapshot: BrokerLinkStoreSnapshot) throws {
        try save(snapshot)
    }

    /// Re-keys links saved for the same account under an older key. Returns
    /// true when links were moved, so callers reload the snapshot.
    func adoptLinks(for account: BrokerAccountIdentity) throws -> Bool {
        guard let rekeyed = try loadSnapshot().rekeyed(to: account) else { return false }
        try save(rekeyed)
        return true
    }

    func linkExactMatches(
        from preview: Trading212ImportPreview,
        linkedAt: Date = Date()
    ) throws -> BrokerLinkSaveResult {
        try validateReadyForLinking(preview)
        return try linkRows(preview.rows, account: preview.account, linkedAt: linkedAt)
    }

    func linkMatchedHoldings(
        from preview: Trading212ImportPreview,
        linkedAt: Date = Date()
    ) throws -> BrokerLinkSaveResult {
        let rows = preview.rows.filter { row in
            row.conflictStatus == .manualHoldingMatch || row.conflictStatus == .manualQuantityMismatch
        }
        guard !rows.isEmpty else {
            throw BrokerLinkStoreError.previewNotReady("Preview has no manual matches ready to link.")
        }
        return try linkRows(rows, account: preview.account, linkedAt: linkedAt)
    }

    func upsertImportedPositions(
        account: BrokerAccountIdentity,
        positions: [BrokerLinkedPosition],
        linkedAt: Date = Date()
    ) throws -> BrokerLinkSaveResult {
        guard !positions.isEmpty else {
            throw BrokerLinkStoreError.previewNotReady("There are no imported broker positions to link.")
        }
        return try linkPositions(positions, account: account, linkedAt: linkedAt)
    }

    private func linkRows(
        _ rows: [Trading212ImportPreviewRow],
        account: BrokerAccountIdentity,
        linkedAt: Date
    ) throws -> BrokerLinkSaveResult {
        var snapshot = try loadSnapshot()
        upsertAccount(account, in: &snapshot, now: linkedAt)

        var positions: [BrokerLinkedPosition] = []
        for row in rows {
            guard let position = makeLinkedPosition(from: row, linkedAt: linkedAt) else {
                throw BrokerLinkStoreError.previewNotReady("Preview is not ready to link. Missing manual match or instrument identity.")
            }
            positions.append(position)
        }

        return try saveLinkedPositions(positions, in: &snapshot, linkedAt: linkedAt)
    }

    private func linkPositions(
        _ positions: [BrokerLinkedPosition],
        account: BrokerAccountIdentity,
        linkedAt: Date
    ) throws -> BrokerLinkSaveResult {
        var snapshot = try loadSnapshot()
        upsertAccount(account, in: &snapshot, now: linkedAt)
        return try saveLinkedPositions(positions, in: &snapshot, linkedAt: linkedAt)
    }

    private func saveLinkedPositions(
        _ positions: [BrokerLinkedPosition],
        in snapshot: inout BrokerLinkStoreSnapshot,
        linkedAt: Date
    ) throws -> BrokerLinkSaveResult {
        for position in positions {
            upsertPosition(position, in: &snapshot)
        }
        snapshot = Self.normalized(snapshot)
        snapshot.positions.sort { $0.id < $1.id }
        snapshot.accounts.sort { $0.id < $1.id }
        snapshot.updatedAt = linkedAt
        try save(snapshot)

        return BrokerLinkSaveResult(
            linkedCount: positions.count,
            totalLinks: snapshot.positions.count,
            fileURL: fileURL
        )
    }

    func removePositions(
        ids: [String],
        removedAt: Date = Date()
    ) throws -> BrokerLinkRemoveResult {
        let targetIDs = Set(ids)
        guard !targetIDs.isEmpty else {
            let snapshot = try loadSnapshot()
            return BrokerLinkRemoveResult(removedCount: 0, remainingLinks: snapshot.positions.count, fileURL: fileURL)
        }

        var snapshot = try loadSnapshot()
        let originalCount = snapshot.positions.count
        snapshot.positions.removeAll { targetIDs.contains($0.id) }
        let removedCount = originalCount - snapshot.positions.count

        if removedCount > 0 {
            snapshot.updatedAt = removedAt
            try save(snapshot)
        }

        return BrokerLinkRemoveResult(
            removedCount: removedCount,
            remainingLinks: snapshot.positions.count,
            fileURL: fileURL
        )
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        StockbarRuntimeStorage
            .stockbarApplicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("BrokerLinks", isDirectory: true)
            .appendingPathComponent("broker_links.json")
    }

    private func validateReadyForLinking(_ preview: Trading212ImportPreview) throws {
        guard !preview.rows.isEmpty else {
            throw BrokerLinkStoreError.previewNotReady("Preview is not ready to link. There are no broker rows.")
        }

        let exactMatches = preview.rows.filter { $0.conflictStatus == .manualHoldingMatch }
        guard exactMatches.count == preview.rows.count,
              preview.brokerOnlyCount == 0,
              preview.quantityMismatchCount == 0,
              preview.needsReviewCount == 0 else {
            throw BrokerLinkStoreError.previewNotReady("Preview is not ready to link. Resolve broker-only, quantity, duplicate, watchlist, or unresolved rows first.")
        }
    }

    private func upsertAccount(
        _ account: BrokerAccountIdentity,
        in snapshot: inout BrokerLinkStoreSnapshot,
        now: Date
    ) {
        let existing = snapshot.accounts.first { $0.brokerAccountKey == account.brokerAccountKey }
        let linkedAt = existing?.linkedAt ?? now
        let record = BrokerLinkedAccount(
            brokerAccountKey: account.brokerAccountKey,
            broker: account.broker,
            accountLabel: account.accountLabel,
            accountType: account.accountType,
            taxWrapper: account.taxWrapper,
            environment: account.environment,
            linkedAt: linkedAt,
            updatedAt: now
        )
        snapshot.accounts.removeAll { $0.brokerAccountKey == account.brokerAccountKey }
        snapshot.accounts.append(record)
    }

    private func makeLinkedPosition(
        from row: Trading212ImportPreviewRow,
        linkedAt: Date
    ) -> BrokerLinkedPosition? {
        guard let instrumentId = row.instrumentId,
              let manualMatch = row.manualMatch,
              let brokerQuantity = row.quantity else {
            return nil
        }

        return BrokerLinkedPosition(
            brokerAccountKey: row.account.brokerAccountKey,
            instrumentId: instrumentId,
            displaySymbol: row.displaySymbol,
            displayName: row.displayName,
            providerTicker: row.providerTicker,
            manualSymbol: manualMatch.symbol,
            manualQuantityAtLink: manualMatch.quantity,
            brokerQuantityAtLink: brokerQuantity,
            manualAverageCostAtLink: manualMatch.averageCost,
            manualCurrency: manualMatch.currency,
            linkedAt: linkedAt,
            updatedAt: linkedAt
        )
    }

    private func upsertPosition(
        _ position: BrokerLinkedPosition,
        in snapshot: inout BrokerLinkStoreSnapshot
    ) {
        let existing = snapshot.positions.first { $0.id == position.id }
        let linkedAt = existing?.linkedAt ?? position.linkedAt
        let updated = BrokerLinkedPosition(
            brokerAccountKey: position.brokerAccountKey,
            instrumentId: position.instrumentId,
            displaySymbol: position.displaySymbol,
            displayName: position.displayName,
            providerTicker: position.providerTicker,
            manualSymbol: existing?.manualSymbol ?? position.manualSymbol,
            manualQuantityAtLink: existing?.manualQuantityAtLink ?? position.manualQuantityAtLink,
            brokerQuantityAtLink: position.brokerQuantityAtLink,
            manualAverageCostAtLink: existing?.manualAverageCostAtLink ?? position.manualAverageCostAtLink,
            manualCurrency: existing?.manualCurrency ?? position.manualCurrency,
            linkedAt: linkedAt,
            updatedAt: position.updatedAt
        )
        snapshot.positions.removeAll { $0.id == position.id }
        snapshot.positions.append(updated)
    }

    private static func normalized(_ snapshot: BrokerLinkStoreSnapshot) -> BrokerLinkStoreSnapshot {
        let positions = Dictionary(grouping: snapshot.positions, by: \.id).values.flatMap { group -> [BrokerLinkedPosition] in
            guard group.count > 1, economicallyEquivalentLinkMetadata(group) else {
                return group
            }
            let earliest = group.min { $0.linkedAt < $1.linkedAt }!
            let latest = group.max { $0.updatedAt < $1.updatedAt }!
            return [BrokerLinkedPosition(
                brokerAccountKey: latest.brokerAccountKey,
                instrumentId: latest.instrumentId,
                displaySymbol: latest.displaySymbol,
                displayName: latest.displayName,
                providerTicker: latest.providerTicker,
                manualSymbol: earliest.manualSymbol,
                manualQuantityAtLink: earliest.manualQuantityAtLink,
                brokerQuantityAtLink: latest.brokerQuantityAtLink,
                manualAverageCostAtLink: earliest.manualAverageCostAtLink,
                manualCurrency: earliest.manualCurrency,
                linkedAt: earliest.linkedAt,
                updatedAt: latest.updatedAt
            )]
        }.sorted { $0.id < $1.id }
        return BrokerLinkStoreSnapshot(
            schemaVersion: 2,
            updatedAt: snapshot.updatedAt,
            accounts: snapshot.accounts,
            positions: positions
        )
    }

    private static func economicallyEquivalentLinkMetadata(_ positions: [BrokerLinkedPosition]) -> Bool {
        guard let first = positions.first else { return false }
        return positions.dropFirst().allSatisfy { position in
            approximatelyEqual(position.manualQuantityAtLink, first.manualQuantityAtLink)
                && optionalApproximatelyEqual(position.manualAverageCostAtLink, first.manualAverageCostAtLink)
                && normalizedCurrency(position.manualCurrency) == normalizedCurrency(first.manualCurrency)
        }
    }

    private static func approximatelyEqual(_ left: Double, _ right: Double) -> Bool {
        left.isFinite && right.isFinite && abs(left - right) <= 0.00000001
    }

    private static func optionalApproximatelyEqual(_ left: Double?, _ right: Double?) -> Bool {
        switch (left, right) {
        case (nil, nil): return true
        case (.some(let left), .some(let right)): return approximatelyEqual(left, right)
        default: return false
        }
    }

    private static func normalizedCurrency(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
    }

    private func save(_ snapshot: BrokerLinkStoreSnapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }
}
