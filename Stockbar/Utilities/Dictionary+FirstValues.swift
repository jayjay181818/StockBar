import Foundation

extension Dictionary {
    /// Like `init(uniqueKeysWithValues:)`, but keeps the first value for a
    /// repeated key instead of trapping. Keys built from holdings, broker or
    /// provider data can repeat (two blank rows, a duplicated symbol, a
    /// provider listing a currency twice), and a trap there crashes the app.
    init<S: Sequence>(firstValuesFor pairs: S) where S.Element == (Key, Value) {
        self.init(pairs, uniquingKeysWith: { first, _ in first })
    }
}
