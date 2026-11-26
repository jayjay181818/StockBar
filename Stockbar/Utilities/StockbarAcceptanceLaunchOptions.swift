import AppKit
import Foundation

/// Launch options that let the acceptance copy open straight onto one page,
/// in one appearance and currency, so a redesign can be looked at quickly.
///
/// Read once at launch, and only in an explicit acceptance run: one with its
/// own root and run identifier, live providers disabled, started by the
/// acceptance harness. A normal run and the automatic XCTest isolation ignore
/// them, and so does an unknown value. They change only the acceptance copy's
/// own isolated settings.
///
/// - `STOCKBAR_ACCEPTANCE_APPEARANCE`: `light` or `dark`.
/// - `STOCKBAR_ACCEPTANCE_SECTION`: the raw value of a `StockbarMainSection`.
/// - `STOCKBAR_ACCEPTANCE_CURRENCY`: a supported currency code, such as `GBP`.
/// - `STOCKBAR_ACCEPTANCE_WINDOW`: `min` opens the main window at its minimum size.
/// - `STOCKBAR_ACCEPTANCE_POPOVER`: `portfolio` opens the portfolio popover
///   once, a few seconds after launch, as a click on its menu-bar item would.
///   It can then be looked at without anything clicking in the menu bar.
/// - `STOCKBAR_ACCEPTANCE_CALENDAR`: `upcoming` or `past`, the view the
///   Calendar page opens on, so Past can be looked at without a click.
/// - `STOCKBAR_ACCEPTANCE_EVENTS`: the path of a fixture of made-up dividend
///   and date answers (`StockbarAcceptanceEventsFixture`). The bootstrap checks
///   it and copies it into the run's root; the app reads only that copy and
///   answers instrument events from it instead of asking Yahoo.
/// - `STOCKBAR_ACCEPTANCE_ALERTS`: the path of a fixture of made-up price
///   alerts (`StockbarAcceptanceAlertsFixture`), checked and copied the same
///   way. The Alerts page shows them; they are never stored and never fire.
/// - `STOCKBAR_ACCEPTANCE_HOLDINGS`: the path of a fixture of made-up local
///   holdings (`StockbarAcceptanceHoldingsFixture`), checked and copied the
///   same way. A fresh copy starts on the local portfolio with them, Folync off.
/// - `STOCKBAR_ACCEPTANCE_SETTINGS_TAB`: the raw value of a `SettingsTab`, the
///   tab Settings opens on, so Advanced can be looked at without a click.
/// - `STOCKBAR_ACCEPTANCE_EARNINGS_FIGURES`: choices for past EPS figures, as
///   `SYMBOL=CHOICE` pairs separated by commas (`FAKEUS=EUR,FAKEGR=hide`).
///   Each symbol must be a made-up one starting with `FAKE`; each choice is
///   `hide` or a currency the Advanced card offers. Other pairs are dropped.
struct StockbarAcceptanceLaunchOptions: Codable, Equatable, Sendable {
    enum Appearance: String, Codable, Sendable {
        case light
        case dark
    }

    static let appearanceKey = "STOCKBAR_ACCEPTANCE_APPEARANCE"
    static let sectionKey = "STOCKBAR_ACCEPTANCE_SECTION"
    static let currencyKey = "STOCKBAR_ACCEPTANCE_CURRENCY"
    static let windowKey = "STOCKBAR_ACCEPTANCE_WINDOW"
    static let popoverKey = "STOCKBAR_ACCEPTANCE_POPOVER"
    static let calendarKey = "STOCKBAR_ACCEPTANCE_CALENDAR"
    static let eventsKey = "STOCKBAR_ACCEPTANCE_EVENTS"
    static let alertsKey = "STOCKBAR_ACCEPTANCE_ALERTS"
    static let holdingsKey = "STOCKBAR_ACCEPTANCE_HOLDINGS"
    static let settingsTabKey = "STOCKBAR_ACCEPTANCE_SETTINGS_TAB"
    static let earningsFiguresKey = "STOCKBAR_ACCEPTANCE_EARNINGS_FIGURES"
    /// How long after launch the portfolio popover opens, so the first
    /// figures and the graph have arrived.
    static let popoverDelay: TimeInterval = 6

    var appearance: Appearance?
    /// The raw value of a `StockbarMainSection`.
    var section: String?
    var currency: String?
    var opensAtMinimumSize = false
    var opensPortfolioPopover = false
    /// The raw value of a `CalendarMode`: the view Calendar opens on.
    var calendarMode: String?
    /// Instrument events come from the run's copy of the fixture, not Yahoo.
    var usesInstrumentEventsFixture = false
    /// The Alerts page shows the run's copy of the alerts fixture, for looking only.
    var usesAlertsFixture = false
    /// A fresh copy starts on the local portfolio with the run's copy of the holdings fixture.
    var usesHoldingsFixture = false
    /// The raw value of a `SettingsTab`: the tab Settings opens on.
    var settingsTab: String?
    /// Past EPS figure choices by made-up symbol, as `EarningsFiguresSettings` stores them.
    var earningsFigures: [String: String]?

    static let none = Self()

    var isEmpty: Bool { self == .none }

    /// The options for this process, read once.
    static let current = resolve(
        environment: ProcessInfo.processInfo.environment,
        runtime: StockbarRuntimeStorage.acceptance
    )

    /// The options `environment` asks for, or none unless `runtime` is an
    /// explicit acceptance run. Unknown values are dropped one by one.
    static func resolve(environment: [String: String], runtime: StockbarAcceptanceRuntime) -> Self {
        guard runtime.isExplicitAcceptanceRun else { return .none }
        func value(_ key: String) -> String? {
            let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.isEmpty ? nil : raw
        }
        var options = Self()
        options.appearance = value(appearanceKey).flatMap { Appearance(rawValue: $0.lowercased()) }
        options.section = value(sectionKey).flatMap(StockbarMainSection.init(rawValue:))?.rawValue
        options.currency = value(currencyKey)
            .map { $0.uppercased() }
            .flatMap { DataModel.supportedCurrencies.contains($0) ? $0 : nil }
        options.opensAtMinimumSize = value(windowKey)?.lowercased() == "min"
        options.opensPortfolioPopover = value(popoverKey)?.lowercased() == "portfolio"
        options.calendarMode = value(calendarKey).flatMap { CalendarMode(rawValue: $0.lowercased()) }?.rawValue
        options.usesInstrumentEventsFixture = value(eventsKey) != nil
        options.usesAlertsFixture = value(alertsKey) != nil
        options.usesHoldingsFixture = value(holdingsKey) != nil
        options.settingsTab = value(settingsTabKey).flatMap(SettingsTab.init(rawValue:))?.rawValue
        options.earningsFigures = value(earningsFiguresKey).flatMap(Self.earningsFigures(from:))
        return options
    }

    /// `FAKEUS=EUR,FAKEGR=hide` read into stored choices: made-up symbols
    /// only, and only choices the Advanced card can show. Nil when none is left.
    static func earningsFigures(from text: String) -> [String: String]? {
        var choices: [String: String] = [:]
        for pair in text.split(separator: ",") {
            let parts = pair.split(separator: "=", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, StockbarAcceptanceEventsFixture.isMadeUp(parts[0]) else { continue }
            let value = parts[1] == EarningsFiguresChoice.hiddenValue ? parts[1] : parts[1].uppercased()
            guard let stored = EarningsFiguresChoice(storedValue: value)?.storedValue else { continue }
            choices[parts[0]] = stored
        }
        let kept = EarningsFiguresSettings.validated(choices)
        return kept.isEmpty ? nil : kept
    }

    /// Writes the options into the acceptance copy's own defaults, where the
    /// app reads its theme, its currency and the page the window opens on.
    /// Call before the data model or any window exists.
    func apply(to defaults: UserDefaults) {
        if let appearance {
            defaults.set(appearance.rawValue, forKey: "appearanceMode")
        }
        if let currency {
            defaults.set(currency, forKey: "preferredCurrency")
        }
        if let section {
            defaults.set(section, forKey: "mainWindow.selectedSection")
        }
        if let settingsTab {
            defaults.set(settingsTab, forKey: "settings.selectedTab")
        }
        if let earningsFigures {
            defaults.set(earningsFigures, forKey: EarningsFiguresSettings.key)
        }
    }
}
