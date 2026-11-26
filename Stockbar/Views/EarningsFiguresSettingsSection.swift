import SwiftUI

/// Settings → Advanced → Earnings Figures: for each holding Calendar asks
/// Yahoo earnings for, how its past EPS figures are shown. Display only.
@MainActor
struct EarningsFiguresSettingsSection: View {
    let dataModel: DataModel
    private let settings: EarningsFiguresSettings

    static let title = "Earnings Figures"
    static let explanation = "Yahoo gives a company's earnings per share in the currency of its accounts, "
        + "which it doesn't name and which may differ from the share's price currency. "
        + "Choose a holding's currency to show it with the figures in Calendar, or hide them."
    static let noHoldings = "No holdings yet. Each holding you add is listed here."
    static let noYahooSymbols = "None of your holdings has a symbol Calendar can ask Yahoo about, so none has "
        + "earnings figures to show."

    /// The one line the card shows instead of rows: nil when there are rows.
    static func emptyLine(holdings: [CalendarHolding]) -> String? {
        guard CalendarFigures.earningsFigureSymbols(holdings).isEmpty else { return nil }
        return holdings.isEmpty ? noHoldings : noYahooSymbols
    }
    static let asGivenTitle = "As Given"
    static let hiddenTitle = "Hide Figures"

    /// "FAKEUS earnings figures", what VoiceOver names the pop-up.
    static func pickerLabel(_ symbol: String) -> String { "\(symbol) earnings figures" }

    init(dataModel: DataModel, settings: EarningsFiguresSettings = .shared) {
        self.dataModel = dataModel
        self.settings = settings
    }

    var body: some View {
        // The holdings Calendar asks earnings for, from the app's state.
        let holdings = StockbarCalendarInputs.current(dataModel).holdings
        let symbols = CalendarFigures.earningsFigureSymbols(holdings)
        StockbarSettingsSection(Self.title, subtitle: Self.explanation) {
            if let line = Self.emptyLine(holdings: holdings) {
                Text(line)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(symbols, id: \.self) { symbol in
                    StockbarSettingsRow(symbol) {
                        // The row's title is the symbol; the pop-up's own
                        // (hidden) label says what it sets, for VoiceOver.
                        Picker(Self.pickerLabel(symbol), selection: choice(for: symbol)) {
                            Text(Self.asGivenTitle).tag(EarningsFiguresChoice.asGiven)
                            Text(Self.hiddenTitle).tag(EarningsFiguresChoice.hidden)
                            Divider()
                            ForEach(EarningsFiguresSettings.supportedFirst, id: \.self) { code in
                                Text(EarningsFiguresSettings.menuTitle(code))
                                    .tag(EarningsFiguresChoice.currency(code))
                                if code == DataModel.supportedCurrencies.last { Divider() }
                            }
                        }
                    }
                }
            }
        }
    }

    private func choice(for symbol: String) -> Binding<EarningsFiguresChoice> {
        Binding(get: { settings.choice(for: symbol) },
                set: { settings.set($0, for: symbol) })
    }
}
