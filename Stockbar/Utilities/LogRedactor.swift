import Foundation

/// Removes credentials and personal details from text before it is logged,
/// shown in Diagnostics or exported.
///
/// Every pattern is compiled once. Compiling them again for each line made
/// reading the log back cost seconds of logger time.
enum LogRedactor {
    static let replacement = "[REDACTED]"

    private struct Rule {
        let regex: NSRegularExpression
        let template: String
        /// False for rules that tidy text (the home folder) rather than hide
        /// a credential; those never count as a leak.
        let isSecret: Bool
        /// False for rules too broad to prove a leak (bare numeric ids).
        let countsAsLeak: Bool
    }

    /// Names that mark the value beside them as a credential, whatever is
    /// wrapped around them: `apiKey`, `X-API-Key`, `FMP_API_KEY`,
    /// `client_secret`, `accessToken`, `password`.
    private static let secretName =
        #"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]*?(?:api[_-]?key|api[_-]?secret|secret|token|password|passwd|passphrase)[A-Za-z0-9_-]*?"#

    private static let rules: [Rule] = [
        // user:password@host in a URL.
        rule(#"(://)(?!\[REDACTED\]@)[^/\s:@]+:[^/\s@]+@"#, "$1[REDACTED]@"),
        // Credentials in a URL query string.
        rule(
            #"(?i)([?&](?:apikey|api_key|api-key|access_token|refresh_token|token|key|secret|password|signature)=)(?!\[REDACTED\])[^&\s"'<>)\]]+"#,
            "$1[REDACTED]"
        ),
        // "name": "value" and name='value', as in JSON and Python dicts. The
        // whole quoted value goes, spaces included.
        rule(
            "(?i)(" + secretName + #"["']?\s*[:=]\s*")(?!\[REDACTED\])[^"\r\n]*""#,
            "$1[REDACTED]\""
        ),
        rule(
            "(?i)(" + secretName + #"["']?\s*[:=]\s*')(?!\[REDACTED\])[^'\r\n]*'"#,
            "$1[REDACTED]'"
        ),
        // name=value and name: value without quotes, or with a quote that never closes.
        rule(
            "(?i)(" + secretName + #"["']?\s*[:=]\s*["']?)(?!\[REDACTED\])[^\s,;"'&)\]}]+"#,
            "$1[REDACTED]"
        ),
        // Cookie headers: everything to the end of the line.
        // The space after the colon is matched possessively: given back, it
        // let an already-hidden value match again and lose its space.
        rule(#"(?i)\b((?:Set-)?Cookie\s*[:=]\s*+)(?!\[REDACTED\])[^\r\n]+"#, "$1[REDACTED]"),
        rule(
            #"(?i)\b(Authorization\s*[:=]\s*(?:Basic|Bearer)\s+)(?!\[REDACTED\])[A-Za-z0-9._~+/\-=]+"#,
            "$1[REDACTED]"
        ),
        // "Basic" with no header name in front: only when what follows looks
        // like base64. Otherwise "Basic Materials", a sector name, was hidden
        // and then reported as a leaked credential.
        rule(
            #"(?i)\b(Basic\s+)(?!\[REDACTED\])(?=[A-Za-z0-9+/]{15,}={0,2}(?![A-Za-z0-9+/=]))[A-Za-z0-9+/=]+"#,
            "$1[REDACTED]"
        ),
        rule(#"(?i)\b(Bearer\s+)(?!\[REDACTED\])[A-Za-z0-9._~+/\-=]+"#, "$1[REDACTED]"),
        // JSON Web Tokens wherever they appear.
        rule(#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}"#, "[REDACTED]"),
        rule(
            #"(?i)\b((?:accountId|account_id|accountNumber|account_number|apiAccountId|api_account_id|id)\s*["']?\s*[:=]\s*)(?!\[REDACTED\])["']?[0-9]{5,}["']?"#,
            "$1[REDACTED]",
            countsAsLeak: false
        ),
        // The account name in file paths: /Users/name/… becomes ~/…
        rule(#"/Users/(?!Shared(?:/|\b))[^/\s"']+"#, "~", isSecret: false)
    ]

    /// Markers doubled up by older, non-idempotent rules.
    private static let corruptedMarker = try? NSRegularExpression(pattern: #"\[REDACTED\]\]+"#)

    private static func rule(
        _ pattern: String,
        _ template: String,
        isSecret: Bool = true,
        countsAsLeak: Bool = true
    ) -> Rule {
        // The patterns are constants; one that does not compile is a
        // programming error, caught by the redactor tests.
        // swiftlint:disable:next force_try
        let regex = try! NSRegularExpression(pattern: pattern)
        return Rule(regex: regex, template: template, isSecret: isSecret, countsAsLeak: isSecret && countsAsLeak)
    }

    static func redact(_ message: String) -> String {
        var current = message
        for rule in rules {
            let range = NSRange(current.startIndex..<current.endIndex, in: current)
            current = rule.regex.stringByReplacingMatches(
                in: current,
                options: [],
                range: range,
                withTemplate: rule.template
            )
        }

        // Repair values corrupted by older rules without touching correct markers.
        guard let corruptedMarker else { return current }
        let range = NSRange(current.startIndex..<current.endIndex, in: current)
        return corruptedMarker.stringByReplacingMatches(
            in: current,
            options: [],
            range: range,
            withTemplate: replacement
        )
    }

    /// True when the text still holds something a credential rule would hide.
    static func containsUnredactedSecret(_ message: String) -> Bool {
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        return rules.contains { rule in
            rule.countsAsLeak && rule.regex.firstMatch(in: message, range: range) != nil
        }
    }
}
