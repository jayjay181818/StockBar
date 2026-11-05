import Foundation

/// Detects London prices stored on the wrong pence/pound scale.
///
/// GBX/GBp is normalised to GBP once at the provider boundary. Older builds
/// stored some UK snapshots in pence, so a series could mix scales.
/// `UKPriceSnapshotScaleMigrationService` repairs stored data once using this
/// rule; display paths keep it only as a logged safety net.
enum UKPriceScale {
    /// A factor-of-20 gap is far outside plausible price movement between two
    /// observations but well inside the 100× pence/pound error.
    static let mismatchRatio = 20.0

    static func normalized(_ price: Double, reference: Double, symbol: String) -> Double {
        guard price.isFinite, price > 0,
              reference.isFinite, reference > 0,
              SymbolMetadata.isUKSymbol(symbol) else {
            return price
        }
        if price > reference * mismatchRatio {
            return price / 100.0
        }
        if price < reference / mismatchRatio {
            return price * 100.0
        }
        return price
    }
}
