import Foundation

// MARK: - Intelligent Cache Eviction Extensions

extension CacheManager {
    
    
    // MARK: - Intelligent Eviction Strategies
    
    /// Perform intelligent cache cleanup based on usage patterns and memory pressure
    func performIntelligentCleanup(memoryPressure: MemoryPressureLevel = .normal) async {
        await Logger.shared.info("🧹 Starting intelligent cache cleanup (pressure: \(memoryPressure))")
        
        let startTime = Date()
        var itemsEvicted = 0
        var bytesFreed = 0
        
        // Determine cleanup aggressiveness based on memory pressure
        let cleanupConfig = getCleanupConfiguration(for: memoryPressure)
        
        // 1. Clean memory cache using LRU strategy
        itemsEvicted += await cleanMemoryCacheLRU(maxItems: cleanupConfig.maxMemoryItems)
        
        // 2. Clean disk cache based on age and access patterns
        bytesFreed += await cleanDiskCacheByAge(maxAge: cleanupConfig.maxDiskAge)
        
        // 3. Compress old data to archive cache
        await compressOldDataToArchive(olderThan: cleanupConfig.compressionAge)
        
        // 4. Clean archive cache if needed
        if memoryPressure == .critical {
            bytesFreed += await cleanArchiveCacheBySize(maxSize: cleanupConfig.maxArchiveSize)
        }
        
        // Update statistics
        cacheStats.lastCleanup = Date()
        
        let duration = Date().timeIntervalSince(startTime)
        await Logger.shared.info("✅ Cache cleanup completed in \(String(format: "%.2f", duration))s: \(itemsEvicted) items evicted, \(bytesFreed / 1024) KB freed")
    }
    
    // MARK: - LRU Memory Cache Cleanup
    
    private func cleanMemoryCacheLRU(maxItems: Int) async -> Int {
        return await memoryCacheQueue.sync {
            let sortedEntries = memoryCache.sorted { entry1, entry2 in
                // Sort by access count and last accessed time (LRU)
                if entry1.value.accessCount != entry2.value.accessCount {
                    return entry1.value.accessCount < entry2.value.accessCount
                }
                return entry1.value.lastAccessed < entry2.value.lastAccessed
            }
            
            let itemsToRemove = max(0, sortedEntries.count - maxItems)
            guard itemsToRemove > 0 else { return 0 }
            
            for i in 0..<itemsToRemove {
                let key = sortedEntries[i].key
                memoryCache.removeValue(forKey: key)
            }
            
            return itemsToRemove
        }
    }
    
    // MARK: - Disk Cache Age-Based Cleanup
    
    private func cleanDiskCacheByAge(maxAge: TimeInterval) async -> Int {
        return await diskCacheQueue.sync {
            let fileManager = FileManager.default
            let cutoffDate = Date().addingTimeInterval(-maxAge)
            var bytesFreed = 0
            
            do {
                let files = try fileManager.contentsOfDirectory(at: diskCacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [])
                
                for fileURL in files {
                    let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
                    if let modificationDate = attributes[.modificationDate] as? Date,
                       modificationDate < cutoffDate {
                        
                        let fileSize = (attributes[.size] as? Int) ?? 0
                        try fileManager.removeItem(at: fileURL)
                        bytesFreed += fileSize
                    }
                }
            } catch {
                Task { await Logger.shared.error("Failed to clean disk cache: \(error)") }
            }
            
            return bytesFreed
        }
    }
    
    // MARK: - Archive Compression
    
    private func compressOldDataToArchive(olderThan age: TimeInterval) async {
        await Logger.shared.debug("🗜️ Compressing old data to archive cache")
        
        // Move old disk cache items to archive with compression
        await diskCacheQueue.async { [weak self] in
            guard let self = self else { return }
            
            let fileManager = FileManager.default
            let cutoffDate = Date().addingTimeInterval(-age)
            
            do {
                let files = try fileManager.contentsOfDirectory(at: self.diskCacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [])
                
                for fileURL in files {
                    let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
                    if let modificationDate = attributes[.modificationDate] as? Date,
                       modificationDate < cutoffDate {
                        
                        // Move to archive with compression
                        let data = try Data(contentsOf: fileURL)
                        let compressedData = try self.compressData(data)
                        
                        let archiveURL = self.archiveCacheDirectory.appendingPathComponent(fileURL.lastPathComponent)
                        try compressedData.write(to: archiveURL)
                        
                        // Remove from disk cache
                        try fileManager.removeItem(at: fileURL)
                    }
                }
            } catch {
                Task { await Logger.shared.error("Failed to compress data to archive: \(error)") }
            }
        }
    }
    
    // MARK: - Archive Size Management
    
    private func cleanArchiveCacheBySize(maxSize: Int) async -> Int {
        return await archiveCacheQueue.sync {
            let fileManager = FileManager.default
            var totalSize = 0
            var bytesFreed = 0
            
            do {
                let files = try fileManager.contentsOfDirectory(at: archiveCacheDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [])
                
                // Sort by modification date (oldest first)
                let sortedFiles = files.sorted { file1, file2 in
                    let date1 = try? file1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date.distantPast
                    let date2 = try? file2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date.distantPast
                    return date1! < date2!
                }
                
                // Calculate total size
                for fileURL in sortedFiles {
                    let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
                    totalSize += (attributes[.size] as? Int) ?? 0
                }
                
                // Remove oldest files if over limit
                if totalSize > maxSize {
                    let targetReduction = totalSize - maxSize
                    var currentReduction = 0
                    
                    for fileURL in sortedFiles {
                        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
                        let fileSize = (attributes[.size] as? Int) ?? 0
                        
                        try fileManager.removeItem(at: fileURL)
                        currentReduction += fileSize
                        bytesFreed += fileSize
                        
                        if currentReduction >= targetReduction {
                            break
                        }
                    }
                }
            } catch {
                Task { await Logger.shared.error("Failed to clean archive cache: \(error)") }
            }
            
            return bytesFreed
        }
    }
    
    // MARK: - Cleanup Configuration
    
    enum MemoryPressureLevel {
        case normal
        case warning
        case critical
    }
    
    private struct CleanupConfiguration {
        let maxMemoryItems: Int
        let maxDiskAge: TimeInterval
        let compressionAge: TimeInterval
        let maxArchiveSize: Int
    }
    
    private func getCleanupConfiguration(for pressure: MemoryPressureLevel) -> CleanupConfiguration {
        switch pressure {
        case .normal:
            return CleanupConfiguration(
                maxMemoryItems: 300,
                maxDiskAge: 24 * 3600 * 7, // 7 days
                compressionAge: 24 * 3600 * 3, // 3 days
                maxArchiveSize: 100 * 1024 * 1024 // 100MB
            )
        case .warning:
            return CleanupConfiguration(
                maxMemoryItems: 200,
                maxDiskAge: 24 * 3600 * 3, // 3 days
                compressionAge: 24 * 3600 * 1, // 1 day
                maxArchiveSize: 50 * 1024 * 1024 // 50MB
            )
        case .critical:
            return CleanupConfiguration(
                maxMemoryItems: 100,
                maxDiskAge: 24 * 3600 * 1, // 1 day
                compressionAge: 12 * 3600, // 12 hours
                maxArchiveSize: 25 * 1024 * 1024 // 25MB
            )
        }
    }
    
    // MARK: - Data Compression
    
    private func compressData(_ data: Data) throws -> Data {
        // Simple compression using NSData compression (iOS 13+)
        return try (data as NSData).compressed(using: .lzfse) as Data
    }
    
    private func decompressData(_ data: Data) throws -> Data {
        return try (data as NSData).decompressed(using: .lzfse) as Data
    }
    
    // MARK: - Cache Statistics Update
    
    func updateStatistics(hit: Bool, level: CacheLevel) {
        switch level {
        case .memory:
            if hit {
                cacheStats.memoryHits += 1
            } else {
                cacheStats.memoryMisses += 1
            }
        case .disk:
            if hit {
                cacheStats.diskHits += 1
            } else {
                cacheStats.diskMisses += 1
            }
        case .archived:
            if hit {
                cacheStats.archiveHits += 1
            } else {
                cacheStats.archiveMisses += 1
            }
        }
    }
}

// MARK: - Date Formatter Extension

extension DateFormatter {
    static let shortDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}