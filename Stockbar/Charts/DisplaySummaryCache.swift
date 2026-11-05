import Foundation

/// Shares one `DisplayPortfolioSummary` across a single SwiftUI render pass.
///
/// The summary is derived from every holding, and a view's computed properties each asked for
/// it again (dozens of times per body, plus on every hover update). Call `beginPass()` at the
/// top of `body` so each render computes it once and always starts from fresh data.
@MainActor
final class DisplaySummaryCache {
    private var cached: DisplayPortfolioSummary?

    func beginPass() { cached = nil }

    func summary(_ compute: () -> DisplayPortfolioSummary) -> DisplayPortfolioSummary {
        if let cached { return cached }
        let value = compute()
        cached = value
        return value
    }
}
