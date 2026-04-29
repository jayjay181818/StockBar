import Foundation

enum CoreDataStoreLoadState: Equatable {
    case notLoaded
    case loaded
    case failedAndBackedUp(URL)
    case failedBackup(String)
}

struct CoreDataRecoveryNotice: Equatable {
    let title: String
    let message: String
    let backupDirectory: URL?

    init?(state: CoreDataStoreLoadState) {
        switch state {
        case .notLoaded, .loaded:
            return nil
        case .failedAndBackedUp(let backupDirectory):
            title = "Stockbar Preserved Your Portfolio Store"
            self.backupDirectory = backupDirectory
            message = """
            Stockbar could not load its local portfolio database, so it created a safety copy before continuing.

            Backup location:
            \(backupDirectory.path)

            The original store was not deleted. Please keep this backup until your portfolio has been checked or restored.
            """
        case .failedBackup(let reason):
            title = "Stockbar Could Not Load Portfolio Storage"
            backupDirectory = nil
            message = """
            Stockbar could not load its local portfolio database, and it could not create a safety copy.

            Reason:
            \(reason)

            To protect your data, avoid making portfolio changes until the store has been recovered from an app backup or filesystem copy.
            """
        }
    }
}

enum CoreDataStoreRecoveryError: Error, Equatable, LocalizedError {
    case noStoreFilesFound

    var errorDescription: String? {
        switch self {
        case .noStoreFilesFound:
            return "No Core Data store files were found to back up."
        }
    }
}

struct CoreDataStoreRecoveryResult: Equatable {
    let backupDirectory: URL
    let copiedFiles: [URL]
}

struct CoreDataStoreRecovery {
    private let fileManager: FileManager
    private let recoveryRoot: URL
    private let timestampProvider: () -> Date

    init(
        fileManager: FileManager = .default,
        recoveryRoot: URL? = nil,
        timestampProvider: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.recoveryRoot = recoveryRoot ?? Self.defaultRecoveryRoot(fileManager: fileManager)
        self.timestampProvider = timestampProvider
    }

    func createSafetyBackup(for storeURL: URL) throws -> CoreDataStoreRecoveryResult {
        let sourceFiles = Self.storeFileURLs(for: storeURL)
            .filter { fileManager.fileExists(atPath: $0.path) }

        guard !sourceFiles.isEmpty else {
            throw CoreDataStoreRecoveryError.noStoreFilesFound
        }

        let backupDirectory = recoveryRoot.appendingPathComponent(makeBackupDirectoryName(), isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        let copiedFiles = try sourceFiles.map { sourceURL in
            let destinationURL = backupDirectory.appendingPathComponent(sourceURL.lastPathComponent)
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        }

        return CoreDataStoreRecoveryResult(backupDirectory: backupDirectory, copiedFiles: copiedFiles)
    }

    static func storeFileURLs(for storeURL: URL) -> [URL] {
        [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm")
        ]
    }

    private static func defaultRecoveryRoot(fileManager: FileManager) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let bundleIdentifier = Bundle.main.bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "Stockbar"
        return applicationSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("StoreRecovery", isDirectory: true)
    }

    private func makeBackupDirectoryName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "store-load-failure-\(formatter.string(from: timestampProvider()))-\(UUID().uuidString.prefix(8))"
    }
}
