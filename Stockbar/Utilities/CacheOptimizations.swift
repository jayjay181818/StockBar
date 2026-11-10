import Foundation

// MARK: - Intelligent Cache Eviction Extensions

extension CacheManager {
    
    // MARK: - Intelligent Eviction Strategies
    
    
    // MARK: - LRU Memory Cache Cleanup
    
    
    // MARK: - Disk Cache Age-Based Cleanup
    
    
    // MARK: - Archive Compression
    
    
    // MARK: - Archive Size Management
    

    private static func removeOldestArchiveFiles(in archiveCacheDirectory: URL, maxSize: Int) -> Int {
        let fileManager = FileManager.default
        var totalSize = 0
        var bytesFreed = 0

        do {
            let files = try fileManager.contentsOfDirectory(at: archiveCacheDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [])
            
            // Sort by modification date (oldest first)
            // `try?` must wrap only the throwing call: a file deleted between
            // the directory listing and this sort makes resourceValues throw,
            // and folding that into the `??` would leave nil to force-unwrap.
            let sortedFiles = files.sorted { file1, file2 in
                let date1 = (try? file1.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? Date.distantPast
                let date2 = (try? file2.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? Date.distantPast
                return date1 < date2
            }

            // A file vanishing mid-pass is normal here (this routine is itself
            // deleting them), so skip it rather than aborting the whole cleanup.
            func fileSize(of fileURL: URL) -> Int {
                guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path) else {
                    return 0
                }
                return (attributes[.size] as? Int) ?? 0
            }

            // Calculate total size
            for fileURL in sortedFiles {
                totalSize += fileSize(of: fileURL)
            }

            // Remove oldest files if over limit
            if totalSize > maxSize {
                let targetReduction = totalSize - maxSize
                var currentReduction = 0

                for fileURL in sortedFiles {
                    let size = fileSize(of: fileURL)

                    do {
                        try fileManager.removeItem(at: fileURL)
                    } catch {
                        continue
                    }
                    currentReduction += size
                    bytesFreed += size

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
    
    
    // MARK: - Data Compression
    
    private func compressData(_ data: Data) throws -> Data {
        // Simple compression using NSData compression (iOS 13+)
        return try (data as NSData).compressed(using: .lzfse) as Data
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
