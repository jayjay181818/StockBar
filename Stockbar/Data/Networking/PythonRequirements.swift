import Foundation

/// The pinned `name==version` requirements shipped in the app bundle.
///
/// `requirements.txt` is the single source of truth for the launch-time
/// dependency check. A pin may carry a `python_version` environment marker
/// when different Pythons need different versions, for example:
///
///     urllib3==2.8.0; python_version >= "3.10"
///     urllib3==1.26.20; python_version < "3.10"
///
/// Pins with any other marker are skipped rather than guessed at, so an
/// unsupported marker can never produce a false "dependencies required" alert.
struct PythonRequirements: Equatable, Sendable {
    struct Pin: Equatable, Sendable {
        let name: String
        let version: String
        let marker: PythonVersionMarker?
    }

    let pins: [Pin]

    init(contents: String) {
        pins = contents.split(whereSeparator: \.isNewline).compactMap(Self.parsePin)
    }

    /// Every package named by a pin, whatever its marker.
    var packageNames: [String] {
        Array(Set(pins.map(\.name))).sorted()
    }

    /// The pins in a canonical form that ignores comments and spacing, so the
    /// launch check can tell when an update changed them.
    var fingerprint: String {
        pins.map { pin in
            let marker = pin.marker.map { "; python_version \($0.comparison.rawValue) \($0.version.major).\($0.version.minor)" }
            return "\(pin.name)==\(pin.version)\(marker ?? "")"
        }
        .joined(separator: "\n")
    }

    /// The versions expected on an interpreter of the given `major.minor` version.
    func expectedVersions(pythonVersion: PythonVersion) -> [String: String] {
        var expected: [String: String] = [:]
        for pin in pins where pin.marker?.matches(pythonVersion) ?? true {
            expected[pin.name] = pin.version
        }
        return expected
    }

    private static func parsePin(_ rawLine: Substring) -> Pin? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }

        let requirement: String
        let marker: PythonVersionMarker?
        if let separator = line.firstIndex(of: ";") {
            requirement = String(line[..<separator])
            guard let parsed = PythonVersionMarker(String(line[line.index(after: separator)...])) else {
                return nil
            }
            marker = parsed
        } else {
            requirement = line
            marker = nil
        }

        let parts = requirement.components(separatedBy: "==")
        guard parts.count == 2 else { return nil }
        let name = parts[0].trimmingCharacters(in: .whitespaces)
        let version = parts[1].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !version.isEmpty else { return nil }
        return Pin(name: name, version: version, marker: marker)
    }
}

/// A Python `major.minor` version, as compared by `python_version` markers.
struct PythonVersion: Comparable, Sendable {
    let major: Int
    let minor: Int

    init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// Parses `"3.10"`; any further components are ignored.
    init?(_ text: String) {
        let parts = text.split(separator: ".")
        guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        self.init(major: major, minor: minor)
    }

    static func < (lhs: PythonVersion, rhs: PythonVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }
}

/// A single `python_version <op> "X.Y"` environment marker.
struct PythonVersionMarker: Equatable, Sendable {
    enum Comparison: String, CaseIterable, Sendable {
        // Two-character operators first so "<=" is not read as "<".
        case lessThanOrEqual = "<="
        case greaterThanOrEqual = ">="
        case equal = "=="
        case notEqual = "!="
        case lessThan = "<"
        case greaterThan = ">"
    }

    let comparison: Comparison
    let version: PythonVersion

    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let key = "python_version"
        guard trimmed.hasPrefix(key) else { return nil }
        let rest = trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        guard let comparison = Comparison.allCases.first(where: { rest.hasPrefix($0.rawValue) }) else {
            return nil
        }
        let operand = rest.dropFirst(comparison.rawValue.count).trimmingCharacters(in: .whitespaces)
        guard operand.count >= 2,
              let quote = operand.first, quote == "\"" || quote == "'",
              operand.last == quote,
              !operand.dropFirst().dropLast().contains(quote),
              let version = PythonVersion(String(operand.dropFirst().dropLast())) else {
            return nil
        }
        self.comparison = comparison
        self.version = version
    }

    func matches(_ python: PythonVersion) -> Bool {
        switch comparison {
        case .lessThan: return python < version
        case .lessThanOrEqual: return python <= version
        case .greaterThan: return python > version
        case .greaterThanOrEqual: return python >= version
        case .equal: return python == version
        case .notEqual: return python != version
        }
    }
}
