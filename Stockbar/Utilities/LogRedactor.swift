import Foundation

enum LogRedactor {
    static let replacement = "[REDACTED]"

    private static let redactionRules: [(pattern: String, template: String)] = [
        (
            #"(?i)([?&](?:apikey|api_key|access_token|token|key)=)[^&\s"'<>)\]]+"#,
            "$1[REDACTED]"
        ),
        (
            #"(?i)\b((?:FMP_API_KEY|TWELVE_DATA_API_KEY|API_KEY|TOKEN|ACCESS_TOKEN)\s*[:=]\s*)[^\s,;"')\]]+"#,
            "$1[REDACTED]"
        ),
        (
            #"(?i)\b(Authorization\s*[:=]\s*Bearer\s+)[A-Za-z0-9._~+/\-=]+"#,
            "$1[REDACTED]"
        ),
        (
            #"(?i)\b(Bearer\s+)[A-Za-z0-9._~+/\-=]+"#,
            "$1[REDACTED]"
        )
    ]

    static func redact(_ message: String) -> String {
        redactionRules.reduce(message) { current, rule in
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else {
                return current
            }
            let range = NSRange(current.startIndex..<current.endIndex, in: current)
            return regex.stringByReplacingMatches(
                in: current,
                options: [],
                range: range,
                withTemplate: rule.template
            )
        }
    }

    static func containsUnredactedSecret(_ message: String) -> Bool {
        redactedSecretPatterns.contains { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return false
            }
            let range = NSRange(message.startIndex..<message.endIndex, in: message)
            return regex.firstMatch(in: message, range: range) != nil
        }
    }

    private static let redactedSecretPatterns: [String] = [
        #"(?i)[?&](?:apikey|api_key|access_token|token|key)=(?!\[REDACTED\])[^&\s"'<>)\]]+"#,
        #"(?i)\b(?:FMP_API_KEY|TWELVE_DATA_API_KEY|API_KEY|TOKEN|ACCESS_TOKEN)\s*[:=]\s*(?!\[REDACTED\])[^\s,;"')\]]+"#,
        #"(?i)\bAuthorization\s*[:=]\s*Bearer\s+(?!\[REDACTED\])[A-Za-z0-9._~+/\-=]+"#,
        #"(?i)\bBearer\s+(?!\[REDACTED\])[A-Za-z0-9._~+/\-=]+"#
    ]
}
