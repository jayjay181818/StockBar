import Foundation

/// Service to clean up legacy data storage on first app launch after migration
class LegacyCleanupService {
    static let shared = LegacyCleanupService()
    
    private let cleanupDoneKey = "legacyCleanupDone"
    private let legacyUserTradesKey = "usertrades"
    
    private init() {}
    
    /// Performs one-time cleanup of legacy data storage
    func performCleanupIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: cleanupDoneKey) else {
            return // Cleanup already performed
        }
        
        // Remove legacy usertrades JSON blob
        UserDefaults.standard.removeObject(forKey: legacyUserTradesKey)
        
        // Mark cleanup as done
        UserDefaults.standard.set(true, forKey: cleanupDoneKey)
        
        Task { await Logger.shared.info("Legacy cleanup completed - removed usertrades UserDefaults key") }
    }
} 