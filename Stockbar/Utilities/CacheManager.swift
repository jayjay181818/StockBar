import Foundation
import Synchronization

/// A small key-value store for values that are cheap to lose and slow to
/// rebuild: the portfolio composition, two calculation dates and the earliest
/// history date of each symbol.
///
/// Each value is held in memory and in one file. This replaces a three-tier
/// cache with eviction, promotion, statistics and an hourly clean-up, all in
/// service of those four values.
final class CacheManager: Sendable {
    static let shared = CacheManager()

    let diskCacheDirectory: URL

    private let memory = Mutex<[String: Data]>([:])
    /// File work happens here, in order, so a store followed by a remove
    /// cannot land the wrong way round.
    private let fileQueue = DispatchQueue(label: "com.stockbar.cache.disk", qos: .utility)
    private let logger = Logger.shared

    /// The file layout used since the tiered cache. Kept as it was so files
    /// written by earlier versions stay readable, and the other way round.
    private struct Envelope: Codable {
        let key: String
        let data: Data
        let timestamp: Date
        let size: Int
        let compressionLevel: String
        let accessCount: Int
        let lastAccessed: Date
    }

    init(cacheRoot: URL? = nil, fileManager: FileManager = .default) {
        let root = cacheRoot ?? StockbarRuntimeStorage.cacheDirectory(fileManager: fileManager)
        diskCacheDirectory = root.appendingPathComponent("disk")
        try? fileManager.createDirectory(at: diskCacheDirectory, withIntermediateDirectories: true)
    }

    private func fileURL(for key: String) -> URL {
        diskCacheDirectory.appendingPathComponent("\(key).cache")
    }

    func store<T: Codable & Sendable>(_ value: T, forKey key: String) {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(value)
        } catch {
            Task { await logger.error("❌ Failed to encode \(key) for the cache: \(error)") }
            return
        }
        memory.withLock { $0[key] = payload }

        let url = fileURL(for: key)
        fileQueue.async { [logger] in
            let now = Date()
            let envelope = Envelope(
                key: key, data: payload, timestamp: now, size: payload.count,
                compressionLevel: "none", accessCount: 1, lastAccessed: now
            )
            do {
                try JSONEncoder().encode(envelope).write(to: url, options: .atomic)
            } catch {
                Task { await logger.error("❌ Failed to write the cache file for \(key): \(error)") }
            }
        }
    }

    func retrieve<T: Codable & Sendable>(_ type: T.Type, forKey key: String) -> T? {
        if let payload = memory.withLock({ $0[key] }) {
            if let value = try? JSONDecoder().decode(type, from: payload) {
                return value
            }
            // Asked for as another type than it was stored: fall through to the file.
        }

        let url = fileURL(for: key)
        let payload: Data? = fileQueue.sync {
            guard let raw = try? Data(contentsOf: url) else { return nil }
            guard let envelope = try? JSONDecoder().decode(Envelope.self, from: raw) else {
                // Unreadable: remove it so it is rebuilt rather than failing every launch.
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return envelope.data
        }
        guard let payload, let value = try? JSONDecoder().decode(type, from: payload) else { return nil }
        memory.withLock { $0[key] = payload }
        return value
    }

    func remove(forKey key: String) {
        memory.withLock { $0[key] = nil }
        let url = fileURL(for: key)
        fileQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Drops the in-memory copies; the files stay, so nothing is lost.
    func clearMemoryCache() {
        memory.withLock { $0.removeAll(keepingCapacity: false) }
    }

    /// Waits for pending file work. For tests.
    func flush() {
        fileQueue.sync {}
    }
}
