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
    /// How long after launch the portfolio popover opens, so the first
    /// figures and the graph have arrived.
    static let popoverDelay: TimeInterval = 6

    var appearance: Appearance?
    /// The raw value of a `StockbarMainSection`.
    var section: String?
    var currency: String?
    var opensAtMinimumSize = false
    var opensPortfolioPopover = false

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
        return options
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
    }
}
