import SwiftUI

/// The Trades page: every position opened, and how it did, from Folync's trade
/// analysis. Read-only; see `StockbarTradesViewModel` for when it asks Folync.
@MainActor
struct StockbarTradesView: View {
    let isFolyncPortfolio: Bool
    let openConnections: () -> Void
    @State private var model: StockbarTradesViewModel
    @State private var chosenYear: String?
    @State private var hoveredLot: String?

    init(isFolyncPortfolio: Bool, openConnections: @escaping () -> Void) {
        self.isFolyncPortfolio = isFolyncPortfolio
        self.openConnections = openConnections
        _model = State(initialValue: StockbarTradesViewModel(isFolyncPortfolio: isFolyncPortfolio))
    }

    static let subtitle = "Every position you've opened, and how it did"
    static let needsFolyncReason = "Needs a Folync portfolio"

    var body: some View {
        VStack(alignment: .leading, spacing: StockbarLayout.sectionSpacing) {
            header
            content
        }
        .stockbarPage()
        .onAppear { model.activate() }
        .onDisappear { model.deactivate() }
        .onChange(of: isFolyncPortfolio) { _, isFolync in model.setFolyncPortfolio(isFolync) }
    }

    private var header: some View {
        StockbarPageHeader(StockbarMainSection.trades.title, subtitle: Self.subtitle) {
            if model.isFolyncPortfolio {
                HStack(spacing: 10) {
                    Button(action: model.refresh) {
                        StockbarRefreshIcon(isRefreshing: model.isRefreshing || model.state == .loading)
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isRefreshing || model.state == .loading)
                    .help("Ask Folync for the latest trades")
                    .accessibilityLabel("Refresh trades")
                    StockbarSegmentedControl("Trades shown", selection: filterBinding,
                                             options: StockbarTradesViewModel.Filter.allCases) { $0.title }
                }
            }
        }
    }

    private var filterBinding: Binding<StockbarTradesViewModel.Filter> {
        Binding(get: { model.filter }, set: { model.select($0) })
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            emptyState(icon: nil, title: "Loading trades from Folync…", message: nil)
        case .needsFolync:
            emptyState(
                icon: "arrow.left.arrow.right",
                title: "Trades needs a Folync portfolio",
                message: "A local or Trading 212 portfolio stores only what you hold now, so Stockbar can't tell when you bought or sold. Trades fills in when the portfolio comes from Folync.",
                action: ("Open Connections", openConnections)
            )
        case .unreachable:
            emptyState(icon: "wifi.exclamationmark", title: "Couldn't reach Folync",
                       message: "Nothing is saved to show yet. Use the refresh button to try again.")
        case .unavailable:
            emptyState(icon: "questionmark.folder", title: "Trade analysis isn't available",
                       message: "This Folync server doesn't provide trade analysis.")
        case .disabled:
            emptyState(icon: "switch.2", title: "Trade analysis is switched off",
                       message: "Folync isn't connected, or trade analysis is turned off in Settings → Connections.")
        case .loaded, .stale:
            if let answer = model.answer {
                loaded(answer)
            }
        }
    }

    // MARK: Loaded

    @ViewBuilder
    private func loaded(_ answer: FolyncTradeAnalysisResponse) -> some View {
        let currency = answer.currency ?? answer.scope.currency
        if let savedAt = model.savedAt {
            StockbarNotice(message: "Couldn't get new trades from Folync. Showing the copy saved "
                + "\(StockbarOverviewView.savedTime(savedAt, now: Date(), locale: .current, timeZone: .current)).")
                .accessibilityAddTraits(.isStaticText)
        } else if model.state == .stale {
            StockbarNotice(message: "Couldn't get new trades from Folync. Showing the copy saved earlier.")
                .accessibilityAddTraits(.isStaticText)
        }
        if answer.quality != .complete {
            StockbarNotice(message: Self.qualityNotice(answer), systemImage: "info.circle.fill", tint: .secondary)
                .accessibilityAddTraits(.isStaticText)
        }
        strip(answer, currency: currency)
        table(answer)
        costs(answer, currency: currency)
    }

    static func qualityNotice(_ answer: FolyncTradeAnalysisResponse) -> String {
        let lead = answer.quality == .partial ? "Folync marks some of these figures partial" : "Folync marks these figures unavailable"
        let reasons = FolyncConnectionState.readable(reasons: answer.reasonCodes)
        return reasons.isEmpty ? "\(lead)." : "\(lead): \(reasons)."
    }

    private func strip(_ answer: FolyncTradeAnalysisResponse, currency: String?) -> some View {
        let stats = answer.stats
        let gain = StockbarTradesText.signedAmount(stats.totalTradeGain, currency: currency)
        let thisYear = StockbarTradesText.activity(answer.activity, year: Self.currentYear)
        return StockbarMetricStrip {
            StockbarMetricTile(title: "Win rate", value: StockbarTradesText.wholePercent(stats.winRatePct),
                               detail: StockbarTradesText.winRateCaption(wins: stats.wins, losses: stats.losses))
            StockbarMetricTile(title: "Beat the S&P 500", value: StockbarTradesText.wholePercent(stats.winRateVsSp500Pct),
                               detail: StockbarTradesText.beatIndexCaption(wins: stats.winsVsSp500, losses: stats.lossesVsSp500))
            StockbarMetricTile(title: "Gain on trades", value: gain.text,
                               detail: Self.gainCaption, valueColor: Self.color(gain.tone))
            StockbarMetricTile(title: "Costs this year",
                               value: StockbarTradesText.amount(thisYear?.fees, currency: currency),
                               detail: StockbarTradesText.percentOfAverageValue(thisYear?.feesPctOfAvgValue))
        }
    }

    /// Folync's `totalTradeGain` is a whole-portfolio figure over every lot,
    /// open and closed, whatever the switch shows.
    static let gainCaption = "Open and closed trades, all time"

    static var currentYear: Int {
        Calendar(identifier: .gregorian).component(.year, from: Date())
    }

    // MARK: Table

    private enum Column {
        static let opened: CGFloat = 96
        static let held: CGFloat = 58
        static let cost: CGFloat = 100
        static let gain: CGFloat = 104
        static let returned: CGFloat = 64
        static let versus: CGFloat = 64
    }

    private func table(_ answer: FolyncTradeAnalysisResponse) -> some View {
        let lots = model.lots
        return VStack(alignment: .leading, spacing: 0) {
            tableHeader(comparison: StockbarTradesText.comparisonHeading(lots))
            Divider()
            if model.isLoadingRows {
                ProgressView("Loading trades…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if lots.isEmpty {
                Text(Self.noRowsText(model.filter))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(lots.enumerated()), id: \.element.id) { index, lot in
                        row(lot)
                        if index < lots.count - 1 {
                            Divider()
                        }
                    }
                }
            }
            Divider()
            footer(answer, lots: lots)
        }
        .stockbarCard(padding: 18)
    }

    static func noRowsText(_ filter: StockbarTradesViewModel.Filter) -> String {
        switch filter {
        case .all: "No trades to show."
        case .open: "No open trades."
        case .closed: "No closed trades."
        }
    }

    private func tableHeader(comparison: String) -> some View {
        HStack(spacing: 8) {
            Text("Holding").frame(maxWidth: .infinity, alignment: .leading)
            Text("Opened").frame(width: Column.opened, alignment: .leading)
            Text("Held").frame(width: Column.held, alignment: .leading)
            Text("Cost").frame(width: Column.cost, alignment: .trailing)
            Text("Gain").frame(width: Column.gain, alignment: .trailing)
            Text("Return").frame(width: Column.returned, alignment: .trailing)
            Text(comparison).frame(width: Column.versus, alignment: .trailing)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.bottom, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(true)
    }

    private func row(_ lot: FolyncTradeLot) -> some View {
        let pill = StockbarTradesText.pill(lot.status)
        let gain = StockbarTradesText.signedAmount(lot.totalGain, currency: lot.currency)
        let returned = StockbarTradesText.signedPercent(lot.totalReturnPct)
        let index = StockbarTradesText.indexName(lot)
        let versus = StockbarTradesText.signedPoints(lot.alphaPct, index: index)
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(StockbarTradesText.holding(lot))
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(pill.title)
                    .font(.caption)
                    .foregroundStyle(pill.kind == .closed ? .secondary : .primary)
                    .stockbarPill(tint: pill.kind == .partial ? .orange : nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(StockbarTradesText.openedOn(lot.openDate))
                .foregroundStyle(.secondary)
                .frame(width: Column.opened, alignment: .leading)
            Text(StockbarTradesText.heldFor(days: lot.holdingDays).text)
                .foregroundStyle(.secondary)
                .frame(width: Column.held, alignment: .leading)
            Text(StockbarTradesText.amount(lot.costBasis, currency: lot.currency))
                .frame(width: Column.cost, alignment: .trailing)
            HStack(spacing: 3) {
                if lot.valuation.quality != .complete {
                    Image(systemName: "exclamationmark.circle")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .help(Self.valuationHelp(lot.valuation))
                }
                Text(gain.text).foregroundStyle(Self.color(gain.tone))
            }
            .frame(width: Column.gain, alignment: .trailing)
            Text(returned.text)
                .foregroundStyle(Self.color(returned.tone))
                .frame(width: Column.returned, alignment: .trailing)
            Text(versus.text)
                .foregroundStyle(Self.color(versus.tone))
                .frame(width: Column.versus, alignment: .trailing)
                .help(Self.comparisonHelp(lot))
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .stockbarRow(isHovered: hoveredLot == lot.id, cornerRadius: 6)
        .onHover { inside in hoveredLot = inside ? lot.id : (hoveredLot == lot.id ? nil : hoveredLot) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StockbarTradesText.rowSentence(lot))
    }

    static func valuationHelp(_ valuation: FolyncFinancialMetric) -> String {
        let reasons = FolyncConnectionState.readable(reasons: valuation.reasonCodes)
        let lead = valuation.quality == .partial ? "Folync marks this value partial" : "Folync has no value for this trade"
        return reasons.isEmpty ? lead : "\(lead): \(reasons)"
    }

    static func comparisonHelp(_ lot: FolyncTradeLot) -> String {
        let index = StockbarTradesText.indexName(lot)
        guard lot.alphaPct != nil else {
            let reasons = FolyncConnectionState.readable(reasons: lot.benchmarkComparison?.reasonCodes ?? [])
            return reasons.isEmpty ? "No comparison with the \(index)" : "No comparison with the \(index): \(reasons)"
        }
        return "Points ahead of or behind the \(index) over the same days"
    }

    private func footer(_ answer: FolyncTradeAnalysisResponse, lots: [FolyncTradeLot]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(StockbarTradesText.shownCount(lots.count))
                    .foregroundStyle(.secondary)
                if model.hasMore, !model.isLoadingRows {
                    Button(model.isLoadingMore ? "Loading…" : "Load more", action: model.loadMore)
                        .disabled(model.isLoadingMore || model.isRefreshing)
                }
                if model.loadMoreFailed {
                    Text("Couldn't load more trades. Try again.")
                        .foregroundStyle(.secondary)
                }
            }
            Text(StockbarTradesText.tableNote(lots: lots, method: answer.costBasisMethod))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 10)
    }

    // MARK: Costs

    private func costs(_ answer: FolyncTradeAnalysisResponse, currency: String?) -> some View {
        let years = StockbarTradesText.costYears(answer.activity, currentYear: Self.currentYear)
        let year = chosenYear.flatMap { years.offered.contains($0) ? $0 : nil } ?? years.chosen
        let period = year.flatMap { chosen in answer.activity.first { $0.period == chosen } }
        let title = year.map { $0 == String(Self.currentYear) ? "Costs this year" : "Costs in \($0)" } ?? "Costs this year"
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                StockbarSectionTitle(title: title)
                Spacer(minLength: 12)
                if years.offered.count > 1, let year {
                    StockbarSegmentedControl("Year", selection: Binding(get: { year }, set: { chosenYear = $0 }),
                                             options: years.offered) { $0 }
                }
            }
            HStack(alignment: .top, spacing: 24) {
                costFigure("Fees", StockbarTradesText.amount(period?.fees, currency: currency),
                           detail: StockbarTradesText.percentOfAverageValue(period?.feesPctOfAvgValue))
                costFigure("Bought", StockbarTradesText.amount(period?.buyValue, currency: currency),
                           detail: period.map { "\($0.buyCount) \($0.buyCount == 1 ? "buy" : "buys")" })
                costFigure("Sold", StockbarTradesText.amount(period?.sellValue, currency: currency),
                           detail: period.map { "\($0.sellCount) \($0.sellCount == 1 ? "sale" : "sales")" })
                costFigure("Turnover", StockbarTradesText.percent(period?.turnoverPct),
                           detail: period?.turnoverPct == nil ? nil : "of average value")
            }
        }
        .stockbarCard(padding: 18)
    }

    private func costFigure(_ title: String, _ value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Shared

    static func color(_ tone: StockbarTradesFigure.Tone) -> Color {
        switch tone {
        case .gain: StockbarPalette.gain
        case .loss: StockbarPalette.loss
        case .neutral: .primary
        }
    }

    private func emptyState(icon: String?, title: String, message: String?,
                            action: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(title).font(.title3.weight(.semibold))
            if let message {
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action {
                Button(action.0, action: action.1)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .stockbarEmptyState(minHeight: 360)
    }
}
