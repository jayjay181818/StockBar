import XCTest
@testable import Stockbar

final class PythonRequirementsTests: XCTestCase {
    private let python39 = PythonVersion(major: 3, minor: 9)
    private let python313 = PythonVersion(major: 3, minor: 13)

    func testPlainPinsApplyToEveryInterpreter() {
        let requirements = PythonRequirements(contents: """
            # comment
            yfinance==1.2.0

            pandas<4
            """)

        XCTAssertEqual(requirements.packageNames, ["yfinance"])
        XCTAssertEqual(requirements.expectedVersions(pythonVersion: python39), ["yfinance": "1.2.0"])
        XCTAssertEqual(requirements.expectedVersions(pythonVersion: python313), ["yfinance": "1.2.0"])
    }

    func testMarkersSelectThePinForTheInterpreter() {
        let requirements = PythonRequirements(contents: """
            urllib3==2.8.0; python_version >= "3.10"
            urllib3==1.26.20; python_version < "3.10"
            requests==2.34.2 ; python_version>='3.10'
            requests==2.32.5 ; python_version<'3.10'
            """)

        XCTAssertEqual(requirements.packageNames, ["requests", "urllib3"])
        XCTAssertEqual(
            requirements.expectedVersions(pythonVersion: python39),
            ["urllib3": "1.26.20", "requests": "2.32.5"]
        )
        XCTAssertEqual(
            requirements.expectedVersions(pythonVersion: python313),
            ["urllib3": "2.8.0", "requests": "2.34.2"]
        )
    }

    func testVersionsCompareNumericallyNotAsText() {
        let marker = PythonVersionMarker(#"python_version >= "3.10""#)

        XCTAssertEqual(marker?.matches(PythonVersion(major: 3, minor: 9)), false)
        XCTAssertEqual(marker?.matches(PythonVersion(major: 3, minor: 10)), true)
        XCTAssertEqual(marker?.matches(PythonVersion(major: 3, minor: 13)), true)
    }

    func testEveryComparisonOperator() {
        let cases: [(String, [Bool])] = [
            ("<", [true, false, false]),
            ("<=", [true, true, false]),
            (">", [false, false, true]),
            (">=", [false, true, true]),
            ("==", [false, true, false]),
            ("!=", [true, false, true])
        ]
        let versions = [PythonVersion(major: 3, minor: 9), PythonVersion(major: 3, minor: 10), PythonVersion(major: 3, minor: 11)]

        for (comparison, expected) in cases {
            let marker = PythonVersionMarker("python_version \(comparison) \"3.10\"")
            XCTAssertEqual(versions.map { marker?.matches($0) }, expected, comparison)
        }
    }

    func testUnsupportedMarkersSkipThePinInsteadOfGuessing() {
        let requirements = PythonRequirements(contents: """
            alpha==1.0; sys_platform == "darwin"
            beta==1.0; python_version >= "3.10" and sys_platform == "darwin"
            gamma==1.0; python_version >= "3.10" or python_version < "3.8"
            delta==1.0; python_version >= 3.10
            epsilon==1.0;
            """)

        XCTAssertTrue(requirements.pins.isEmpty)
    }

    func testFingerprintChangesWithPinsButNotWithCommentsOrSpacing() {
        let original = PythonRequirements(contents: """
            urllib3==1.26.20; python_version < "3.10"
            """)
        let reformatted = PythonRequirements(contents: """
            # The 3.9 fallback
            urllib3 == 1.26.20 ;python_version<'3.10'
            """)
        let bumped = PythonRequirements(contents: """
            urllib3==2.8.0; python_version < "3.10"
            """)

        XCTAssertEqual(original.fingerprint, reformatted.fingerprint)
        XCTAssertNotEqual(original.fingerprint, bumped.fingerprint)
    }

    func testShippedRequirementsHaveOnePinPerPackageForEachSupportedPython() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let contents = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Stockbar/Resources/requirements.txt"),
            encoding: .utf8
        )
        let requirements = PythonRequirements(contents: contents)

        // Stockbar's own environment uses 3.13; 3.10 is the oldest supported Python.
        for python in [PythonVersion(major: 3, minor: 10), python313] {
            let matching = requirements.pins.filter { $0.marker?.matches(python) ?? true }
            XCTAssertEqual(
                Set(matching.map(\.name)),
                Set(requirements.packageNames),
                "Python \(python.major).\(python.minor) is missing a pin"
            )
            XCTAssertEqual(
                matching.count,
                Set(matching.map(\.name)).count,
                "Python \(python.major).\(python.minor) has more than one pin for a package"
            )
        }
    }
}
