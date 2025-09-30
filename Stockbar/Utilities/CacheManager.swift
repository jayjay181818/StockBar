import Foundation
import OSLog

/// Tiered caching system for optimal performance across different data access patterns
class CacheManager: ObservableObject {
    static let shared = CacheManager()
    
    private let logger = Logger.shared
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    // MARK: - Cache Level Definitions
    
    enum CacheLevel: String, CaseIterable {
        case memory = "memory"      // Recent 30 days - fastest access
        case disk = "disk"          // 1 year - fast local storage  
        case archived = "archived"  // Older data with compression - slower but space efficient
        
        var maxAge: TimeInterval {
            switch self {
            case .memory: return 30 * 24 * 3600    // 30 days
            case .disk: return 365 * 24 * 3600     // 1 year
            case .archived: return .infinity        // No age limit for archived data
            }
        }
        
        var maxItems: Int {
            switch self {
            case .memory: return 500               // Recent data - fast access
            case .disk: return 2000                // More data but still reasonable
            case .archived: return 10000           // Large capacity for historical data
            }
        }
        
        var compressionLevel: CompressionLevel {
            switch self {
            case .memory: return .none
            case .disk: return .light
            case .archived: return .heavy
            }
        }
    }
    
    enum CompressionLevel: String {
        case none = "none"
        case light = "light"
        case heavy = "heavy"
    }
    
    // MARK: - Cache Storage
    
    // Memory Cache - fastest access for recent data
    internal var memoryCache: [String: CacheEntry] = [:]
    internal let memoryCacheQueue = DispatchQueue(label: "com.stockbar.cache.memory", qos: .userInteractive)
    
    // Disk Cache - file-based storage for medium-term data
    internal var diskCacheDirectory: URL
    internal let diskCacheQueue = DispatchQueue(label: "com.stockbar.cache.disk", qos: .utility)
    
    // Archived Cache - compressed long-term storage
    internal var archiveCacheDirectory: URL
    internal let archiveCacheQueue = DispatchQueue(label: "com.stockbar.cache.archive", qos: .background)
    
    // Cache statistics for monitoring
    @Published var cacheStats = CacheStatistics()

    // Limit for entries stored directly in memory (bytes)
    private let maxMemoryEntrySize = 512 * 1024 // 512 KB per entry
    
    // MARK: - Cache Entry Structure
    
    internal struct CacheEntry: Codable {
        internal let key: String
        internal let data: Data
        internal let timestamp: Date
        internal let size: Int
        internal let compressionLevel: String
        internal var accessCount: Int
        internal var lastAccessed: Date
        
        init<T: Codable>(key: String, value: T, compressionLevel: CompressionLevel = .none, encoder: JSONEncoder = JSONEncoder()) throws {
            self.key = key
            self.timestamp = Date()
            self.lastAccessed = Date()
            self.accessCount = 1
            self.compressionLevel = compressionLevel.rawValue
            
            // Encode the data
            let rawData = try encoder.encode(value)
            
            // Apply compression if needed
            switch compressionLevel {
            case .none:
                self.data = rawData
            case .light:
                // For now, use no compression to avoid API compatibility issues
                self.data = rawData
            case .heavy:
                // For now, use no compression to avoid API compatibility issues
                self.data = rawData
            }
            
            self.size = self.data.count
        }
        
        func getValue<T: Codable>(as type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
            // Decompress if needed
            let decompressedData: Data
            switch CompressionLevel(rawValue: compressionLevel) ?? .none {
            case .none:
                decompressedData = data
            case .light:
                // For now, no decompression needed since we're not compressing
                decompressedData = data
            case .heavy:
                // For now, no decompression needed since we're not compressing
                decompressedData = data
            }
            
            return try decoder.decode(type, from: decompressedData)
        }
        
        func withUpdatedAccess() -> CacheEntry {
            var updatedEntry = self
            updatedEntry.accessCount += 1
            updatedEntry.lastAccessed = Date()
            return updatedEntry
        }
    }
    
    // MARK: - Cache Statistics
    
    struct CacheStatistics: Codable {
        var memoryHits: Int = 0
        var memoryMisses: Int = 0
        var diskHits: Int = 0
        var diskMisses: Int = 0
        var archiveHits: Int = 0
        var archiveMisses: Int = 0
        
        var memorySize: Int = 0  // bytes
        var diskSize: Int = 0    // bytes
        var archiveSize: Int = 0 // bytes
        
        var totalEntries: Int = 0
        var lastCleanup: Date = Date()
        
        var memoryHitRate: Double {
            let total = memoryHits + memoryMisses
            return total > 0 ? Double(memoryHits) / Double(total) : 0.0
        }
        
        var diskHitRate: Double {
            let total = diskHits + diskMisses
            return total > 0 ? Double(diskHits) / Double(total) : 0.0
        }
        
        var overallHitRate: Double {
            let totalHits = memoryHits + diskHits + archiveHits
            let totalRequests = totalHits + memoryMisses + diskMisses + archiveMisses
            return totalRequests > 0 ? Double(totalHits) / Double(totalRequests) : 0.0
        }
        
        var totalSizeFormatted: String {
            let totalBytes = memorySize + diskSize + archiveSize
            return ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .memory)
        }
    }
    
    // MARK: - Initialization
    
    private init() {
        // Setup cache directories
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let stockbarCacheDirectory = cachesDirectory.appendingPathComponent("stockbar-cache")
        
        diskCacheDirectory = stockbarCacheDirectory.appendingPathComponent("disk")
        archiveCacheDirectory = stockbarCacheDirectory.appendingPathComponent("archive")
        
        // Create directories if they don't exist
        try? FileManager.default.createDirectory(at: diskCacheDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: archiveCacheDirectory, withIntermediateDirectories: true)
        
        // Load existing cache statistics
        loadCacheStatistics()
        
        // Setup periodic cleanup
        setupPeriodicCleanup()
        
        Task { await logger.info("🗄️ CacheManager initialized with tiered storage") }
        Task { await logger.info("📂 Disk cache: \(diskCacheDirectory.path)") }
        Task { await logger.info("📦 Archive cache: \(archiveCacheDirectory.path)") }
    }
    
    // MARK: - Cache Operations
    
    /// Store value in appropriate cache tier based on access patterns
    func store<T: Codable>(_ value: T, forKey key: String, level: CacheLevel? = nil) {
        var targetLevel = level ?? determineOptimalCacheLevel(for: key)
        
        do {
            var entry = try CacheEntry(key: key, value: value, compressionLevel: targetLevel.compressionLevel, encoder: encoder)

            if targetLevel == .memory && entry.size > maxMemoryEntrySize {
                Task { await logger.debug("⚖️ Cache entry \(key) is \(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .memory)); using disk cache instead of memory") }
                targetLevel = .disk
                entry = try CacheEntry(key: key, value: value, compressionLevel: targetLevel.compressionLevel, encoder: encoder)
            }
            
            switch targetLevel {
            case .memory:
                storeInMemoryCache(entry)
            case .disk:
                storeInDiskCache(entry)
            case .archived:
                storeInArchiveCache(entry)
            }
            
            updateStatistics(for: targetLevel, operation: .store, size: entry.size)
            Task { await logger.debug("🗄️ Stored \(key) in \(targetLevel.rawValue) cache (\(entry.size) bytes)") }
            
        } catch {
            Task { await logger.error("❌ Failed to store \(key) in cache: \(error)") }
        }
    }
    
    /// Retrieve value from cache, checking all tiers in order of speed
    func retrieve<T: Codable>(_ type: T.Type, forKey key: String) -> T? {
        // Check memory cache first (fastest)
        if let value = retrieveFromMemoryCache(type, key: key) {
            updateStatistics(for: .memory, operation: .hit)
            return value
        }
        updateStatistics(for: .memory, operation: .miss)
        
        // Check disk cache (medium speed)
        if let value = retrieveFromDiskCache(type, key: key) {
            updateStatistics(for: .disk, operation: .hit)
            // Promote frequently accessed data to memory cache
            promoteToMemoryCache(value, key: key)
            return value
        }
        updateStatistics(for: .disk, operation: .miss)
        
        // Check archive cache (slowest)
        if let value = retrieveFromArchiveCache(type, key: key) {
            updateStatistics(for: .archived, operation: .hit)
            // Consider promoting to disk cache for future access
            promoteToHigherTier(value, key: key)
            return value
        }
        updateStatistics(for: .archived, operation: .miss)
        
        Task { await logger.debug("🔍 Cache miss for key: \(key)") }
        return nil
    }
    
    /// Remove value from all cache tiers
    func remove(forKey key: String) {
        memoryCacheQueue.async { [weak self] in
            self?.memoryCache.removeValue(forKey: key)
        }
        
        diskCacheQueue.async { [weak self] in
            guard let self = self else { return }
            let fileURL = self.diskCacheDirectory.appendingPathComponent("\(key).cache")
            try? FileManager.default.removeItem(at: fileURL)
        }
        
        archiveCacheQueue.async { [weak self] in
            guard let self = self else { return }
            let fileURL = self.archiveCacheDirectory.appendingPathComponent("\(key).archive")
            try? FileManager.default.removeItem(at: fileURL)
        }
        
        Task { await logger.debug("🗑️ Removed \(key) from all cache tiers") }
    }
    
    /// Clear all cache data
    func clearAll() {
        memoryCacheQueue.async { [weak self] in
            self?.memoryCache.removeAll()
        }
        
        diskCacheQueue.async { [weak self] in
            guard let self = self else { return }
            try? FileManager.default.removeItem(at: self.diskCacheDirectory)
            try? FileManager.default.createDirectory(at: self.diskCacheDirectory, withIntermediateDirectories: true)
        }
        
        archiveCacheQueue.async { [weak self] in
            guard let self = self else { return }
            try? FileManager.default.removeItem(at: self.archiveCacheDirectory)
            try? FileManager.default.createDirectory(at: self.archiveCacheDirectory, withIntermediateDirectories: true)
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.cacheStats = CacheStatistics()
        }
        
        Task { await logger.info("🧹 Cleared all cache data") }
    }
    
    // MARK: - Cache Tier Operations
    
    private func storeInMemoryCache(_ entry: CacheEntry) {
        memoryCacheQueue.async { [weak self] in
            self?.memoryCache[entry.key] = entry
            self?.enforceMemoryCacheLimit()
        }
    }
    
    private func storeInDiskCache(_ entry: CacheEntry) {
        diskCacheQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let fileURL = self.diskCacheDirectory.appendingPathComponent("\(entry.key).cache")
                let data = try self.encoder.encode(entry)
                try data.write(to: fileURL)
            } catch {
                Task { await self.logger.error("❌ Failed to write disk cache for \(entry.key): \(error)") }
            }
        }
    }
    
    private func storeInArchiveCache(_ entry: CacheEntry) {
        archiveCacheQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let fileURL = self.archiveCacheDirectory.appendingPathComponent("\(entry.key).archive")
                let data = try self.encoder.encode(entry)
                try data.write(to: fileURL)
            } catch {
                Task { await self.logger.error("❌ Failed to write archive cache for \(entry.key): \(error)") }
            }
        }
    }
    
    private func retrieveFromMemoryCache<T: Codable>(_ type: T.Type, key: String) -> T? {
        return memoryCacheQueue.sync {
            guard let entry = memoryCache[key] else { return nil }
            
            // Update access count and timestamp
            memoryCache[key] = entry.withUpdatedAccess()
            
            do {
                return try entry.getValue(as: type, decoder: decoder)
            } catch {
                Task { await logger.error("❌ Failed to decode memory cache entry for \(key): \(error)") }
                memoryCache.removeValue(forKey: key)
                return nil
            }
        }
    }
    
    private func retrieveFromDiskCache<T: Codable>(_ type: T.Type, key: String) -> T? {
        return diskCacheQueue.sync {
            let fileURL = diskCacheDirectory.appendingPathComponent("\(key).cache")
            
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            
            do {
                let data = try Data(contentsOf: fileURL)
                let entry = try decoder.decode(CacheEntry.self, from: data)
                
                // Update access time by rewriting the entry
                let updatedEntry = entry.withUpdatedAccess()
                let updatedData = try encoder.encode(updatedEntry)
                try updatedData.write(to: fileURL)
                
                return try entry.getValue(as: type, decoder: decoder)
            } catch {
                Task { await logger.error("❌ Failed to read disk cache for \(key): \(error)") }
                try? FileManager.default.removeItem(at: fileURL)
                return nil
            }
        }
    }
    
    private func retrieveFromArchiveCache<T: Codable>(_ type: T.Type, key: String) -> T? {
        return archiveCacheQueue.sync {
            let fileURL = archiveCacheDirectory.appendingPathComponent("\(key).archive")
            
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            
            do {
                let data = try Data(contentsOf: fileURL)
                let entry = try decoder.decode(CacheEntry.self, from: data)
                return try entry.getValue(as: type, decoder: decoder)
            } catch {
                Task { await logger.error("❌ Failed to read archive cache for \(key): \(error)") }
                try? FileManager.default.removeItem(at: fileURL)
                return nil
            }
        }
    }
    
    // MARK: - Cache Management
    
    private func determineOptimalCacheLevel(for key: String) -> CacheLevel {
        // Simple heuristic: recent data goes to memory, older data to disk/archive
        let now = Date()
        
        // Extract date information from key if possible
        if key.contains("recent") || key.contains("current") {
            return .memory
        } else if key.contains("historical") || key.contains("archive") {
            return .archived
        } else {
            return .disk
        }
    }
    
    private func promoteToMemoryCache<T: Codable>(_ value: T, key: String) {
        // Only promote if there's space and the data is recent
        memoryCacheQueue.async { [weak self] in
            guard let self = self,
                  self.memoryCache.count < CacheLevel.memory.maxItems else { return }
            
            do {
                let entry = try CacheEntry(key: key, value: value, compressionLevel: .none, encoder: self.encoder)
                guard entry.size <= self.maxMemoryEntrySize else {
                    Task { await self.logger.debug("⚖️ Skipping memory promotion for \(key) (\(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .memory)))") }
                    return
                }
                self.memoryCache[key] = entry
                Task { await self.logger.debug("⬆️ Promoted \(key) to memory cache") }
            } catch {
                Task { await self.logger.error("❌ Failed to promote \(key) to memory cache: \(error)") }
            }
        }
    }
    
    private func promoteToHigherTier<T: Codable>(_ value: T, key: String) {
        // Promote frequently accessed archive data to disk cache
        diskCacheQueue.async { [weak self] in
            guard let self = self else { return }
            
            do {
                let entry = try CacheEntry(key: key, value: value, compressionLevel: .light, encoder: self.encoder)
                let fileURL = self.diskCacheDirectory.appendingPathComponent("\(key).cache")
                let data = try self.encoder.encode(entry)
                try data.write(to: fileURL)
                Task { await self.logger.debug("⬆️ Promoted \(key) to disk cache") }
            } catch {
                Task { await self.logger.error("❌ Failed to promote \(key) to disk cache: \(error)") }
            }
        }
    }
    
    private func enforceMemoryCacheLimit() {
        guard memoryCache.count > CacheLevel.memory.maxItems else { return }
        
        // Remove least recently used items
        let sortedEntries = memoryCache.values.sorted { $0.lastAccessed < $1.lastAccessed }
        let itemsToRemove = sortedEntries.prefix(memoryCache.count - CacheLevel.memory.maxItems)
        let removedSize = itemsToRemove.reduce(0) { $0 + $1.size }
        
        for entry in itemsToRemove {
            memoryCache.removeValue(forKey: entry.key)
        }
        
        Task { await logger.debug("🧹 Evicted \(itemsToRemove.count) items from memory cache") }

        if removedSize > 0 || !itemsToRemove.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.cacheStats.memorySize = max(0, self.cacheStats.memorySize - removedSize)
                self.cacheStats.totalEntries = max(0, self.cacheStats.totalEntries - itemsToRemove.count)
            }
        }
    }
    
    // MARK: - Statistics and Monitoring
    
    private enum CacheOperation {
        case hit, miss, store
    }
    
    private func updateStatistics(for level: CacheLevel, operation: CacheOperation, size: Int = 0) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            switch level {
            case .memory:
                switch operation {
                case .hit: self.cacheStats.memoryHits += 1
                case .miss: self.cacheStats.memoryMisses += 1
                case .store: self.cacheStats.memorySize += size
                }
            case .disk:
                switch operation {
                case .hit: self.cacheStats.diskHits += 1
                case .miss: self.cacheStats.diskMisses += 1
                case .store: self.cacheStats.diskSize += size
                }
            case .archived:
                switch operation {
                case .hit: self.cacheStats.archiveHits += 1
                case .miss: self.cacheStats.archiveMisses += 1
                case .store: self.cacheStats.archiveSize += size
                }
            }
            
            if operation == .store {
                self.cacheStats.totalEntries += 1
            }
        }
    }
    
    private func loadCacheStatistics() {
        if let data = UserDefaults.standard.data(forKey: "cacheStatistics"),
           let stats = try? decoder.decode(CacheStatistics.self, from: data) {
            DispatchQueue.main.async { [weak self] in
                self?.cacheStats = stats
            }
        }
    }
    
    private func saveCacheStatistics() {
        if let data = try? encoder.encode(cacheStats) {
            UserDefaults.standard.set(data, forKey: "cacheStatistics")
        }
    }
    
    private func setupPeriodicCleanup() {
        // Run cleanup every hour
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.performCleanup()
        }
    }
    
    func performCleanup() {
        Task { await logger.info("🧹 Starting cache cleanup") }
        
        // Cleanup memory cache (remove expired items)
        memoryCacheQueue.async { [weak self] in
            guard let self = self else { return }
            let now = Date()
            let expiredKeys = self.memoryCache.compactMap { key, entry in
                now.timeIntervalSince(entry.timestamp) > CacheLevel.memory.maxAge ? key : nil
            }
            
            for key in expiredKeys {
                self.memoryCache.removeValue(forKey: key)
            }
            
            if !expiredKeys.isEmpty {
                Task { await self.logger.debug("🧹 Removed \(expiredKeys.count) expired items from memory cache") }
            }
        }
        
        // Cleanup disk cache
        diskCacheQueue.async { [weak self] in
            self?.cleanupDiskCache()
        }
        
        // Cleanup archive cache
        archiveCacheQueue.async { [weak self] in
            self?.cleanupArchiveCache()
        }
        
        // Update statistics
        DispatchQueue.main.async { [weak self] in
            self?.cacheStats.lastCleanup = Date()
            self?.saveCacheStatistics()
        }
    }
    
    private func cleanupDiskCache() {
        // Implementation for disk cache cleanup
        // Remove files older than the disk cache max age
        guard let enumerator = FileManager.default.enumerator(at: diskCacheDirectory, includingPropertiesForKeys: [.creationDateKey]) else { return }
        
        let now = Date()
        var removedCount = 0
        
        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.creationDateKey])
                if let creationDate = resourceValues.creationDate,
                   now.timeIntervalSince(creationDate) > CacheLevel.disk.maxAge {
                    try FileManager.default.removeItem(at: fileURL)
                    removedCount += 1
                }
            } catch {
                Task { await logger.error("❌ Failed to process disk cache file \(fileURL): \(error)") }
            }
        }
        
        if removedCount > 0 {
            Task { await logger.debug("🧹 Removed \(removedCount) expired files from disk cache") }
        }
    }
    
    private func cleanupArchiveCache() {
        // Archive cache doesn't have age limits, but we can clean up corrupted files
        guard let enumerator = FileManager.default.enumerator(at: archiveCacheDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return }
        
        var removedCount = 0
        
        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                if let fileSize = resourceValues.fileSize, fileSize == 0 {
                    // Remove empty files (likely corrupted)
                    try FileManager.default.removeItem(at: fileURL)
                    removedCount += 1
                }
            } catch {
                Task { await logger.error("❌ Failed to process archive cache file \(fileURL): \(error)") }
            }
        }
        
        if removedCount > 0 {
            Task { await logger.debug("🧹 Removed \(removedCount) corrupted files from archive cache") }
        }
    }
    
    // MARK: - Public API for Cache Information
    
    func getCacheInfo() -> String {
        let stats = cacheStats
        return """
        Cache Statistics:
        Memory: \(stats.memoryHits) hits, \(stats.memoryMisses) misses (\(String(format: "%.1f", stats.memoryHitRate * 100))%)
        Disk: \(stats.diskHits) hits, \(stats.diskMisses) misses (\(String(format: "%.1f", stats.diskHitRate * 100))%)
        Archive: \(stats.archiveHits) hits, \(stats.archiveMisses) misses
        
        Overall Hit Rate: \(String(format: "%.1f", stats.overallHitRate * 100))%
        Total Size: \(stats.totalSizeFormatted)
        Total Entries: \(stats.totalEntries)
        Last Cleanup: \(DateFormatter.debug.string(from: stats.lastCleanup))
        """
    }
}

// MARK: - Compression Extensions

extension Data {
    func compressed(using algorithm: NSData.CompressionAlgorithm) throws -> Data {
        #if os(macOS)
        if #available(macOS 10.11, *) {
            return try (self as NSData).compressed(using: algorithm) as Data
        } else {
            // Fallback: return original data if compression is not available
            return self
        }
        #else
        return self
        #endif
    }
    
    func decompressed(using algorithm: NSData.CompressionAlgorithm) throws -> Data {
        #if os(macOS)
        if #available(macOS 10.11, *) {
            return try (self as NSData).decompressed(using: algorithm) as Data
        } else {
            // Fallback: return original data if decompression is not available
            return self
        }
        #else
        return self
        #endif
    }
}
