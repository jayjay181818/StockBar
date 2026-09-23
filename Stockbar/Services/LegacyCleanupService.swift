import Foundation

/// Reports legacy storage without deleting financial data.
@MainActor
final class LegacyCleanupService {
    static let shared = LegacyCleanupService()
    
    private let reportDoneKey = "legacyLocationReportV2"
    
    private init() {}
    
    /// Performs one-time cleanup of legacy data storage
    func performCleanupIfNeeded() {
        guard !StockbarRuntimeStorage.userDefaults.bool(forKey: reportDoneKey) else {
            return
        }

        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Application Support/com.fhl43211.Stockbar"),
            home.appendingPathComponent("Library/Containers/com.fhl43211.Stockbar"),
            home.appendingPathComponent("Library/Logs/com.fhl43211.Stockbar")
        ]
        let remaining = candidates.filter { fileManager.fileExists(atPath: $0.path) }.map(\.path)
        StockbarRuntimeStorage.userDefaults.set(true, forKey: reportDoneKey)

        Task {
            if remaining.isEmpty {
                await Logger.shared.info("No legacy Stockbar file locations remain")
            } else {
                await Logger.shared.info("Legacy Stockbar locations preserved for manual review: \(remaining)")
            }
        }
    }
}
