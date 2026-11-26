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
    static let asGivenTitle = "As Given"
    static let hiddenTitle = "Hide Figures"

    init(dataModel: DataModel, settings: EarningsFiguresSettings = .shared) {
        self.dataModel = dataModel
        self.settings = settings
    }

    /// The rows: the symbols Calendar asks earnings for, from the app's state.
    static func symbols(_ dataModel: DataModel) -> [String] {
        CalendarFigures.earningsFigureSymbols(StockbarCalendarInputs.current(dataModel).holdings)
    }

    var body: some View {
        let symbols = Self.symbols(dataModel)
        StockbarSettingsSection(Self.title, subtitle: Self.explanation) {
            if symbols.isEmpty {
                Text(Self.noHoldings)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(symbols, id: \.self) { symbol in
                    StockbarSettingsRow(symbol) {
                        Picker(symbol, selection: choice(for: symbol)) {
                            Text(Self.asGivenTitle).tag(EarningsFiguresChoice.asGiven)
                            Text(Self.hiddenTitle).tag(EarningsFiguresChoice.hidden)
                            Divider()
                            ForEach(EarningsFiguresSettings.supportedFirst, id: \.self) { code in
                                Text(EarningsFiguresSettings.menuTitle(code))
                                    .tag(EarningsFiguresChoice.currency(code))
                                if code == DataModel.supportedCurrencies.last { Divider() }
                            }
                        }
                        .accessibilityLabel("\(symbol) earnings figures")
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
