import Foundation
import Observation

/// How the Calendar shows one holding's past EPS figures.
///
/// Yahoo gives a company's earnings per share in the currency of its accounts,
/// which it does not name and which may differ from the share's price
/// currency. So the figures are shown as given, with no currency, unless the
/// owner names one for the holding or hides them. Display only: nothing here
/// reaches the helper, the events service or its saved copies.
enum EarningsFiguresChoice: Hashable, Sendable {
    /// The figures as Yahoo gives them, with no currency. The default.
    case asGiven
    /// The figures written in this ISO currency (upper-cased).
    case currency(String)
    /// The date and the surprise only.
    case hidden

    /// How `hidden` is stored.
    static let hiddenValue = "hide"

    /// The stored value, or nil for `asGiven`, which is never stored.
    var storedValue: String? {
        switch self {
        case .asGiven: nil
        case .currency(let code): code
        case .hidden: Self.hiddenValue
        }
    }

    /// A stored value read back: `hide`, or a currency the card offers.
    /// Anything else is nil, and the holding then reads as given.
    init?(storedValue: String) {
        if storedValue == Self.hiddenValue {
            self = .hidden
        } else if EarningsFiguresSettings.offeredCurrencies.contains(storedValue) {
            self = .currency(storedValue)
        } else {
            return nil
        }
    }
}

/// The per-holding choices for past EPS figures, kept in the app's defaults
/// under `key` as `[SYMBOL: value]`: only holdings set away from "As given",
/// keyed by the upper-cased symbol Calendar asks Yahoo about. A choice for a
/// holding that goes stays stored, and applies again if the holding returns.
///
/// One instance (`shared`) is read by the Advanced card and by the Calendar,
/// so a change shows in an open Calendar at once, without asking anything.
@MainActor
@Observable
final class EarningsFiguresSettings {
    nonisolated static let key = "calendar.earningsFigures.v1"
    static let shared = EarningsFiguresSettings()

    /// The app's own currencies first, then the other common ISO codes in
    /// alphabetical order. The pop-up offers these and nothing else is stored.
    nonisolated static let supportedFirst: [String] = {
        let supported = DataModel.supportedCurrencies
        let others = Set(Locale.commonISOCurrencyCodes.map { $0.uppercased() }).subtracting(supported)
        return supported + others.sorted()
    }()

    nonisolated static let offeredCurrencies = Set(supportedFirst)

    /// The entries of a stored or imported dictionary that are usable: a
    /// symbol the Python bridge accepts, upper-cased, with `hide` or an offered
    /// currency. Everything else is dropped, never guessed at.
    nonisolated static func validated(_ raw: [String: String]) -> [String: String] {
        var kept: [String: String] = [:]
        for (symbol, value) in raw {
            let upper = symbol.uppercased()
            guard upper == symbol, PythonConfiguration.validateSymbol(upper),
                  let choice = EarningsFiguresChoice(storedValue: value), let stored = choice.storedValue else { continue }
            kept[upper] = stored
        }
        return kept
    }

    /// The choices, by upper-cased symbol; a symbol not here reads as given.
    private(set) var choices: [String: EarningsFiguresChoice]

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = StockbarRuntimeStorage.userDefaults) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.key)?.compactMapValues { $0 as? String } ?? [:]
        choices = Self.validated(stored).compactMapValues(EarningsFiguresChoice.init(storedValue:))
    }

    func choice(for symbol: String) -> EarningsFiguresChoice {
        choices[symbol.uppercased()] ?? .asGiven
    }

    /// Sets a holding's choice; "As given" removes its entry.
    func set(_ choice: EarningsFiguresChoice, for symbol: String) {
        let upper = symbol.uppercased()
        guard PythonConfiguration.validateSymbol(upper) else { return }
        if case .currency(let code) = choice, !Self.offeredCurrencies.contains(code) { return }
        if choice == .asGiven {
            choices.removeValue(forKey: upper)
        } else {
            choices[upper] = choice
        }
        let stored = choices.compactMapValues(\.storedValue)
        if stored.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else {
            defaults.set(stored, forKey: Self.key)
        }
    }

    /// The currency's name for the pop-up: "EUR – Euro".
    nonisolated static func menuTitle(_ code: String, locale: Locale = .current) -> String {
        guard let name = locale.localizedString(forCurrencyCode: code) else { return code }
        return "\(code) – \(name)"
    }
}
