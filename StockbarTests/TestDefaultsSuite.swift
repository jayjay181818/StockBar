import Foundation

/// Names and removes the throwaway `UserDefaults` suites that tests create.
///
/// A suite named by an absolute path is stored at that path, so test suites
/// live in a temporary folder instead of `~/Library/Preferences`. There,
/// macOS keeps an empty `<suite>.plist` after the domain is removed, and
/// cfprefsd can write it back after it is deleted; test runs used to leave
/// hundreds of these behind.
enum TestDefaultsSuite {
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StockbarTestDefaults-\(UUID().uuidString)", isDirectory: true)

    /// A unique suite name stored under `directory`, for example
    /// `.../StockbarTestDefaults-<UUID>/CurrencyRetry-<UUID>`.
    static func makeName(_ prefix: String) -> String {
        directory.appendingPathComponent("\(prefix)\(UUID().uuidString)").path
    }

    static func remove(_ name: String) {
        guard isTestSuite(name) else {
            assertionFailure("Refusing to remove \(name): not a suite from TestDefaultsSuite.makeName")
            return
        }
        UserDefaults.standard.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(atPath: "\(name).plist")
    }

    static func isTestSuite(_ name: String) -> Bool {
        name.hasPrefix(directory.path + "/")
    }
}
