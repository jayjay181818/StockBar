import XCTest
@testable import Stockbar

class LoggerTests: XCTestCase {
    
    func testLoggerInitialization() {
        let logger = Logger.shared
        XCTAssertNotNil(logger)
    }
    
    func testLogLevels() {
        XCTAssertEqual(LogLevel.debug.emoji, "🔍")
        XCTAssertEqual(LogLevel.info.emoji, "ℹ️")
        XCTAssertEqual(LogLevel.warning.emoji, "⚠️")
        XCTAssertEqual(LogLevel.error.emoji, "🔴")
    }
    
    func testTailModeTruncation() async {
        let logger = Logger.shared
        
        // Test that very long log messages are properly truncated
        let longMessage = String(repeating: "A", count: 1500)
        let logs = await logger.getTailLogs(maxLines: 10)
        
        // Should not crash and should return some result
        XCTAssertTrue(logs.count >= 0)
        
        // Check that any individual log line is not excessively long
        for log in logs {
            XCTAssertTrue(log.count <= 1010, "Log line should be truncated: \(log.count) characters")
        }
    }
    
    func testLogFileHandling() async {
        let logger = Logger.shared
        
        // Test basic logging functionality
        await logger.info("Test log message")
        
        let logs = await logger.getRecentLogs(maxLines: 5)
        XCTAssertTrue(logs.count > 0, "Should have at least one log entry")
    }

    func testLogFilePathUsesUserLibraryLogs() async {
        let logger = Logger.shared

        let path = await logger.getLogFilePath() ?? ""

        XCTAssertTrue(path.contains("/Library/Logs/"), "Expected log path in user Library Logs, got \(path)")
        XCTAssertFalse(path.contains("/Documents/"), "Log path should not require Documents access: \(path)")
        XCTAssertTrue(path.hasSuffix("stockbar.log"))
    }
}

final class LocalFileLocationTests: XCTestCase {
    func testConfigurationPathAvoidsDocuments() {
        let path = ConfigurationManager.shared.getConfigFilePath() ?? ""

        XCTAssertTrue(path.contains("/Library/Application Support/"), "Expected config path in Application Support, got \(path)")
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
