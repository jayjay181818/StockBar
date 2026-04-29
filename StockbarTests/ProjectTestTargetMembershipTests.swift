import XCTest

final class ProjectTestTargetMembershipTests: XCTestCase {
    func testAllSwiftTestFilesAreIncludedInXcodeTestTarget() throws {
        // Given: The test directory and Xcode project file in this checkout.
        let testFileURL = URL(fileURLWithPath: #filePath)
        let testsDirectory = testFileURL.deletingLastPathComponent()
        let repositoryRoot = testsDirectory.deletingLastPathComponent()
        let projectFile = repositoryRoot.appendingPathComponent("Stockbar.xcodeproj/project.pbxproj")

        // When: Comparing Swift files on disk with the test target source phase.
        let diskTestFiles = try FileManager.default.contentsOfDirectory(
            at: testsDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }
        .map(\.lastPathComponent)
        .sorted()

        let projectContents = try String(contentsOf: projectFile, encoding: .utf8)
        let missingFiles = diskTestFiles.filter { fileName in
            !projectContents.contains("\(fileName) in Sources")
        }

        // Then: Every test file must be compiled by the StockbarTests target.
        XCTAssertTrue(
            missingFiles.isEmpty,
            "Test files missing from StockbarTests source phase: \(missingFiles.joined(separator: ", "))"
        )
    }
}
