import XCTest
@testable import Stockbar

class LoggerTests: XCTestCase {
    
    func testLogLevels() {
        XCTAssertEqual(LogLevel.debug.emoji, "🔍")
        XCTAssertEqual(LogLevel.info.emoji, "ℹ️")
        XCTAssertEqual(LogLevel.warning.emoji, "⚠️")
        XCTAssertEqual(LogLevel.error.emoji, "🔴")
    }
    
    func testVeryLongLinesAreCutWhenReadBack() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoggerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let logger = Logger(fileURL: directory.appendingPathComponent("stockbar.log"))

        await logger.info(String(repeating: "A", count: 1_500))
        await logger.info("short")
        let logs = await logger.getRecentLogs(maxLines: 5)

        XCTAssertEqual(logs.count, 2)
        XCTAssertTrue(logs[0].hasSuffix(" ... [truncated]"), "A 1,500-character line is cut at 1,000")
        XCTAssertEqual(logs[0].count, 1_000 + " ... [truncated]".count)
        XCTAssertTrue(logs[1].hasSuffix("short"))
    }

    func testLoggerDoesNotPersistDuringXCTest() async {
        let logger = Logger.shared

        let path = await logger.getLogFilePath()

        XCTAssertNil(path, "XCTest must not write into a persistent Stockbar log")
    }
}

final class LocalFileLocationTests: XCTestCase {
    func testConfigurationPathAvoidsDocuments() {
        let path = ConfigurationManager.shared.getConfigFilePath() ?? ""
        let expectedRoot = StockbarRuntimeStorage.bundleApplicationSupportDirectory().path

        XCTAssertTrue(path.hasPrefix(expectedRoot + "/"), "Expected config path under the active Application Support root, got \(path)")
        XCTAssertFalse(path.contains("/Documents/"), "Config path should not require Documents access: \(path)")
        XCTAssertTrue(path.hasSuffix(".stockbar_config.json"))
    }

    func testPythonConfigurationPassesConfigPathToFetcher() {
        let config = PythonConfiguration.load()
        let expectedPath = ConfigurationManager.shared.getConfigFilePath()

        XCTAssertEqual(config.environment["STOCKBAR_CONFIG_FILE"], expectedPath)
        XCTAssertFalse(config.environment["STOCKBAR_CONFIG_FILE"]?.contains("/Documents/") ?? true)
    }
}
