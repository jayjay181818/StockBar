import Foundation
import Synchronization

/// A small key-value store for values that are cheap to lose and slow to
/// rebuild: the portfolio composition, two calculation dates and the earliest
/// history date of each symbol.
///
/// Each value is held in memory and in one file. This replaces a three-tier
/// cache with eviction, promotion, statistics and an hourly clean-up, all in
/// service of those four values.
///
/// The values are stored after every recorded portfolio snapshot and almost
/// never differ from one snapshot to the next, so storing a value its file
/// already holds leaves the file alone.
final class CacheManager: Sendable {
    static let shared = CacheManager()

    let diskCacheDirectory: URL

    private struct State {
        /// The encoded value of each key, as last stored or read.
        var payloads: [String: Data] = [:]
        /// Keys whose last file write failed, so the file may not hold the
        /// payload. A key leaves when a write of it succeeds.
        var failedWrites: Set<String> = []
        /// Counts the file work queued, so that a read can tell whether any
        /// was queued while it was reading.
        var queuedFileWork = 0
    }

    /// File work for a key is queued while this is held, so the files change
    /// in the same order as `payloads`. Once the queue has drained, a key's
    /// file holds its payload unless its write failed or something outside
    /// the app has changed the file.
    private let state = Mutex(State())
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
            // Sorted keys, so that a dictionary encodes to the same bytes each
            // time. Unsorted, the order of its keys varies from one encoding to
            // the next and an unchanged value would look changed.
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            payload = try encoder.encode(value)
        } catch {
            Task { await logger.error("❌ Failed to encode \(key) for the cache: \(error)") }
            return
        }

        let url = fileURL(for: key)
        state.withLock { state in
            // Unchanged: the file work last queued for this key wrote this
            // value, or the value was read from the file.
            let unchanged = state.payloads[key] == payload
            state.payloads[key] = payload
            state.queuedFileWork += 1
            fileQueue.async { [self] in
                if unchanged, fileIsCurrent(for: key, at: url) { return }
                let now = Date()
                let envelope = Envelope(
                    key: key, data: payload, timestamp: now, size: payload.count,
                    compressionLevel: "none", accessCount: 1, lastAccessed: now
                )
                do {
                    try JSONEncoder().encode(envelope).write(to: url, options: .atomic)
                    self.state.withLock { _ = $0.failedWrites.remove(key) }
                } catch {
                    self.state.withLock { _ = $0.failedWrites.insert(key) }
                    Task { [logger] in await logger.error("❌ Failed to write the cache file for \(key): \(error)") }
                }
            }
        }
    }

    /// Whether the file of a key whose value has not changed can be left
    /// alone: its last write did not fail, and it has not been deleted since.
    /// Runs on `fileQueue`, after the file work queued before it.
    private func fileIsCurrent(for key: String, at url: URL) -> Bool {
        let lastWriteFailed = state.withLock { $0.failedWrites.contains(key) }
        return !lastWriteFailed && FileManager.default.fileExists(atPath: url.path)
    }

    func retrieve<T: Codable & Sendable>(_ type: T.Type, forKey key: String) -> T? {
        let (held, workQueuedBefore) = state.withLock { ($0.payloads[key], $0.queuedFileWork) }
        if let held, let value = try? JSONDecoder().decode(type, from: held) {
            return value
        }
        // Not held, or asked for as another type than it was stored: read the file.

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
        state.withLock { state in
            // Hold what was read only if it is still what the file holds: a
            // store or a remove queued while the file was being read is newer.
            if state.queuedFileWork == workQueuedBefore {
                state.payloads[key] = payload
            }
        }
        return value
    }

    func remove(forKey key: String) {
        let url = fileURL(for: key)
        state.withLock { state in
            state.payloads[key] = nil
            state.queuedFileWork += 1
            fileQueue.async {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Drops the in-memory copies; the files stay, so nothing is lost. The
    /// next store of each key writes its file again, changed or not.
    func clearMemoryCache() {
        state.withLock { $0.payloads.removeAll(keepingCapacity: false) }
    }

    /// Waits for pending file work. For tests.
    func flush() {
        fileQueue.sync {}
    }
}
