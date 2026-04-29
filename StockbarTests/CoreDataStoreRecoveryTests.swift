import XCTest
@testable import Stockbar

final class CoreDataStoreRecoveryTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StockbarRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory, FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testCreateSafetyBackupCopiesSQLiteStoreAndSidecars() throws {
        // Given: A Core Data SQLite store with WAL sidecar files.
        let storeURL = temporaryDirectory.appendingPathComponent("StockbarDataModel.sqlite")
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: storeURL.path + "-shm")
        try Data("sqlite".utf8).write(to: storeURL)
        try Data("wal".utf8).write(to: walURL)
        try Data("shm".utf8).write(to: shmURL)

        let recoveryRoot = temporaryDirectory.appendingPathComponent("StoreRecovery", isDirectory: true)
        let recovery = CoreDataStoreRecovery(
            recoveryRoot: recoveryRoot,
            timestampProvider: { Date(timeIntervalSince1970: 1_777_777_777) }
        )

        // When: A safety backup is created.
        let result = try recovery.createSafetyBackup(for: storeURL)

        // Then: The original files are copied and left in place.
        let copiedNames = Set(result.copiedFiles.map(\.lastPathComponent))
        XCTAssertEqual(copiedNames, ["StockbarDataModel.sqlite", "StockbarDataModel.sqlite-wal", "StockbarDataModel.sqlite-shm"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: walURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shmURL.path))
    }

    func testCreateSafetyBackupFailsWhenNoStoreFilesExist() {
        // Given: A missing store path.
        let missingStore = temporaryDirectory.appendingPathComponent("Missing.sqlite")
        let recovery = CoreDataStoreRecovery(recoveryRoot: temporaryDirectory)

        // When/Then: Recovery refuses to report success without copying data.
        XCTAssertThrowsError(try recovery.createSafetyBackup(for: missingStore)) { error in
            XCTAssertEqual(error as? CoreDataStoreRecoveryError, .noStoreFilesFound)
        }
    }

    func testRecoveryNoticeForBackedUpStoreIncludesBackupLocationAndNoDeletionMessage() {
        // Given: Core Data has failed to load but the store was safety-copied first.
        let backupDirectory = URL(fileURLWithPath: "/tmp/StockbarRecovery/store-load-failure-20260428")
        let state = CoreDataStoreLoadState.failedAndBackedUp(backupDirectory)

        // When: The startup recovery notice is built.
        let notice = CoreDataRecoveryNotice(state: state)

        // Then: The user-facing text explains that their original store was preserved.
        XCTAssertEqual(notice?.title, "Stockbar Preserved Your Portfolio Store")
        XCTAssertTrue(notice?.message.contains(backupDirectory.path) == true)
        XCTAssertTrue(notice?.message.contains("was not deleted") == true)
    }

    func testRecoveryNoticeForBackupFailureExplainsManualRecoveryRisk() {
        // Given: Core Data failed and even the safety copy could not be created.
        let state = CoreDataStoreLoadState.failedBackup("permission denied")

        // When: The startup recovery notice is built.
        let notice = CoreDataRecoveryNotice(state: state)

        // Then: The message tells the user not to keep working silently.
        XCTAssertEqual(notice?.title, "Stockbar Could Not Load Portfolio Storage")
        XCTAssertTrue(notice?.message.contains("permission denied") == true)
        XCTAssertTrue(notice?.message.contains("avoid making portfolio changes") == true)
    }
}
