import XCTest
@testable import Stockbar

final class AppUpdateServiceTests: XCTestCase {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func makeDefaults() throws -> UserDefaults {
        let name = TestDefaultsSuite.makeName("AppUpdateServiceTests-")
        addTeardownBlock { TestDefaultsSuite.remove(name) }
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    // MARK: Channel

    func testChannelIsStableUntilAnotherIsStored() throws {
        let defaults = try makeDefaults()

        XCTAssertEqual(UpdateChannel.stored(in: defaults), .stable)

        defaults.set(UpdateChannel.testing.rawValue, forKey: UpdateChannel.defaultsKey)
        XCTAssertEqual(UpdateChannel.stored(in: defaults), .testing)
    }

    func testUnknownStoredChannelFallsBackToStable() throws {
        let defaults = try makeDefaults()
        defaults.set("nightly", forKey: UpdateChannel.defaultsKey)

        XCTAssertEqual(UpdateChannel.stored(in: defaults), .stable)
    }

    func testOnlyTheTestingChannelSeesTestingBuilds() {
        XCTAssertTrue(UpdateChannel.stable.allowedFeedChannels.isEmpty)
        XCTAssertEqual(UpdateChannel.testing.allowedFeedChannels, [UpdateChannel.testingFeedChannel])
    }

    /// The feed is written by a Python script and read by the app; a testing
    /// build is only offered when both use the same channel name.
    func testFeedScriptWritesTheChannelNameTheAppAllows() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("Scripts/release_feed.py"),
            encoding: .utf8
        )

        XCTAssertTrue(script.contains("TESTING = \"\(UpdateChannel.testingFeedChannel)\""))
    }

    // MARK: Availability

    private func availability(
        isDevelopmentBuild: Bool = false,
        liveRequestsAllowed: Bool = true,
        feedURL: String? = "https://example.com/appcast.xml",
        publicKey: String? = "key"
    ) -> UpdaterAvailability {
        UpdaterAvailability.resolve(
            isDevelopmentBuild: isDevelopmentBuild,
            liveRequestsAllowed: liveRequestsAllowed,
            feedURL: feedURL,
            publicKey: publicKey
        )
    }

    func testReleasedBuildWithAFeedAndAKeyUpdates() {
        XCTAssertEqual(availability(), .available)
        XCTAssertNil(UpdaterAvailability.available.explanation)
    }

    func testDevelopmentBuildDoesNotUpdate() {
        XCTAssertEqual(availability(isDevelopmentBuild: true), .developmentBuild)
    }

    func testIsolatedRunDoesNotReachTheInternet() {
        XCTAssertEqual(availability(liveRequestsAllowed: false), .isolatedRun)
        XCTAssertEqual(availability(isDevelopmentBuild: true, liveRequestsAllowed: false), .isolatedRun)
    }

    func testIsolatedRunMayUseAFeedOnThisMac() {
        for feed in ["http://127.0.0.1:8123/appcast.xml", "http://localhost/appcast.xml", "http://[::1]:8123/appcast.xml"] {
            XCTAssertEqual(availability(liveRequestsAllowed: false, feedURL: feed), .available, feed)
        }
    }

    func testBuildWithoutAFeedOrAKeyDoesNotUpdate() {
        XCTAssertEqual(availability(feedURL: nil), .notConfigured)
        XCTAssertEqual(availability(feedURL: ""), .notConfigured)
        XCTAssertEqual(availability(feedURL: "appcast.xml"), .notConfigured)
        XCTAssertEqual(availability(publicKey: nil), .notConfigured)
        XCTAssertEqual(availability(publicKey: ""), .notConfigured)
    }

    func testEveryReasonUpdatesAreOffIsExplained() {
        for reason in [UpdaterAvailability.developmentBuild, .isolatedRun, .notConfigured] {
            XCTAssertNotNil(reason.explanation)
        }
    }

    func testTheTestRunItselfDoesNotStartTheUpdater() async {
        let state = await MainActor.run { AppUpdateService.shared.availability }

        XCTAssertNotEqual(state, .available)
    }

    // MARK: Shipped settings

    func testShippedUpdateSettingsRequireSignedUpdatesAndSendNoProfile() throws {
        let data = try Data(contentsOf: Self.repositoryRoot.appendingPathComponent("Stockbar/Info.plist"))
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        let feed = try XCTUnwrap(URL(string: try XCTUnwrap(info["SUFeedURL"] as? String)))
        XCTAssertEqual(feed.scheme, "https")
        XCTAssertEqual(feed.host, "raw.githubusercontent.com")

        let key = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(info["SUPublicEDKey"] as? String)))
        XCTAssertEqual(key.count, 32)

        XCTAssertEqual(info["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertEqual(info["SUEnableSystemProfiling"] as? Bool, false)
    }
}
