import SwiftUI

/// The Activity page: every transaction Folync holds for the portfolio, by
/// month, read-only. Its figures and loading are in `StockbarActivityModel.swift`.
@MainActor
struct StockbarActivityView: View {
    let dataModel: DataModel
    @State private var viewModel = StockbarActivityViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: StockbarLayout.sectionSpacing) {
            StockbarPageHeader(StockbarMainSection.activity.title, subtitle: "Every transaction, read-only") {
                if viewModel.phase != .needsFolync {
                    HStack(spacing: 10) {
                        StockbarSegmentedControl("Kind", selection: $viewModel.kind,
                                                 options: StockbarActivityKind.allCases) { $0.title }
                        refreshButton
                    }
                }
            }
            if viewModel.phase != .needsFolync {
                controls
            }
            content
        }
        .stockbarPage()
        .onAppear { viewModel.activate(isFolyncPortfolio: dataModel.isFolyncPortfolioActive) }
        .onDisappear { viewModel.deactivate() }
        .onChange(of: dataModel.isFolyncPortfolioActive) { _, isFolync in
            viewModel.activate(isFolyncPortfolio: isFolync)
        }
    }

    private var refreshButton: some View {
        Button {
            viewModel.refresh()
        } label: {
            StockbarRefreshIcon(isRefreshing: viewModel.isRefreshing)
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(viewModel.isRefreshing)
        .help("Ask Folync for these transactions again")
        .accessibilityLabel(viewModel.isRefreshing ? "Refreshing transactions" : "Refresh transactions")
    }

    private var holding: Binding<String> {
        Binding {
            viewModel.holding
        } set: { text in
            viewModel.holding = String(text.prefix(StockbarActivityQuery.maximumTickerLength))
        }
    }

    private var controls: some View {
        HStack(alignment: .top, spacing: 16) {
            StockbarSearchField(text: holding, prompt: "Search holdings")
                .frame(maxWidth: 340)
                .help("Show one holding's transactions, by its ticker")
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                StockbarSegmentedControl("Quantities and prices", selection: $viewModel.mode,
                                         options: StockbarActivityMode.allCases) { $0.title }
                Text("Adjusted restates quantities and prices for splits and similar events.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .needsFolync:
            emptyState("Activity needs a Folync portfolio", systemImage: "link",
                       message: "Transactions come from Folync, so this page shows them only while the portfolio comes from Folync. Choose Folync as the portfolio source in Settings → Connections to see them here.")
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading transactions from Folync…")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .stockbarEmptyState()
        case .unreachable:
            emptyState("Couldn't reach Folync", systemImage: "wifi.exclamationmark",
                       message: "No copy of these transactions is saved yet. Use the refresh button to try again.")
        case .unavailable:
            emptyState("Transactions aren't available", systemImage: "list.bullet",
                       message: "This Folync server doesn't offer transactions, or isn't ready to yet.")
        case .disabled:
            emptyState("Transactions are switched off", systemImage: "list.bullet",
                       message: "Folync isn't connected, or transactions are switched off for this connection.")
        case .loaded, .stale:
            loadedContent
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        if case .stale(let savedAt) = viewModel.phase {
            StockbarNotice(message: StockbarActivityText.staleNotice(savedAt: savedAt))
        }
        if viewModel.quality != .complete {
            StockbarNotice(message: StockbarActivityText.qualityNotice(viewModel.quality, reasons: viewModel.reasonCodes),
                           systemImage: "info.circle", tint: .secondary)
        }
        if viewModel.transactions.isEmpty {
            emptyState("No transactions", systemImage: "list.bullet",
                       message: StockbarActivityText.noRows(kind: viewModel.kind, holding: viewModel.query.instrument))
        } else {
            list
        }
    }

    private var list: some View {
        let months = StockbarActivityFormat.months(viewModel.transactions, names: holdingName)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(months) { month in
                Text(month.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, month.id == months.first?.id ? 0 : 14)
                    .padding(.bottom, 6)
                    .accessibilityAddTraits(.isHeader)
                ForEach(month.rows) { row in
                    Divider()
                    StockbarActivityRowView(row: row)
                }
            }
            Divider()
            footer
                .padding(.top, 10)
        }
        .opacity(viewModel.isQueryPending ? 0.6 : 1)
        .stockbarCard()
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(StockbarActivityText.shownCount(viewModel.transactions.count))
                .foregroundStyle(.secondary)
            if viewModel.continuation != nil {
                Button {
                    viewModel.loadMore()
                } label: {
                    if viewModel.isLoadingMore {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Load more")
                    }
                }
                .disabled(!viewModel.canLoadMore)
                .accessibilityLabel(viewModel.isLoadingMore ? "Loading more transactions" : "Load more transactions")
            }
            if viewModel.loadMoreFailed {
                Text("Couldn't load more. Try again.")
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 12)
            Text("Transactions are added and changed in Folync")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private func emptyState(_ title: String, systemImage: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .accessibilityElement(children: .combine)
        .stockbarEmptyState()
    }

    /// The holding's name, when Stockbar already has it; no request is made.
    private func holdingName(_ transaction: FolyncTransaction) -> String? {
        guard let identity = transaction.identity else { return nil }
        let aliases = identity.normalizedAliases
        return dataModel.realTimeTrades.first { aliases.contains($0.trade.name.uppercased()) }
            .flatMap { StockbarActivityFormat.spokenName($0.realTimeInfo.shortName) }
    }
}

/// One transaction: day, glyph and action, ticker, detail, amount.
private struct StockbarActivityRowView: View {
    let row: StockbarActivityRow
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(row.day)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            HStack(spacing: 8) {
                Image(systemName: row.glyph.systemImage)
                    .font(.system(size: row.glyph == .interest ? 6 : 12, weight: .semibold))
                    .foregroundStyle(glyphStyle)
                    .frame(width: 16)
                Text(row.actionTitle)
                    .lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
            Text(row.ticker)
                .fontWeight(.semibold)
                .foregroundStyle(row.ticker == StockbarActivityFormat.unknownFigure ? .secondary : .primary)
                .lineLimit(1)
                .frame(width: 70, alignment: .leading)
            Text(row.detail)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if let note = row.qualityNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .stockbarPill()
                        .help(row.reasons.isEmpty ? "Folync marks this figure \(note)" : row.reasons)
                }
                Text(row.amount)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(StockbarPalette.signedOnSurface(row.colourSign, neutral: .primary))
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 6)
        .stockbarRow(isHovered: isHovered, cornerRadius: 6)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }

    private var glyphStyle: Color {
        switch row.glyph {
        case .dividend: .yellow
        case .cashIn, .cashOut: .accentColor
        case .buy, .sell: .primary
        default: .secondary
        }
    }
}

@MainActor
enum StockbarActivityText {
    /// The amber notice over a saved copy.
    static func staleNotice(savedAt: Date?, now: Date = Date(),
                            locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let lead = "Couldn't get current transactions from Folync."
        guard let savedAt else { return "\(lead) Showing the copy saved earlier." }
        let time = StockbarOverviewView.savedTime(savedAt, now: now, locale: locale, timeZone: timeZone)
        return "\(lead) Showing the copy saved \(time)."
    }

    static func qualityNotice(_ quality: FolyncFinancialQuality, reasons: [String]) -> String {
        let lead = quality == .partial ? "Folync marks these transactions partial" : "Folync marks these transactions unavailable"
        let readable = FolyncConnectionState.readable(reasons: reasons)
        return readable.isEmpty ? "\(lead)." : "\(lead): \(readable)."
    }

    static func shownCount(_ count: Int) -> String {
        count == 1 ? "Showing 1 transaction" : "Showing \(count) transactions"
    }

    static func noRows(kind: StockbarActivityKind, holding: FolyncTransactionsQuery.Instrument?) -> String {
        if case .ticker(let ticker) = holding {
            return kind == .all ? "Folync has no transactions for \(ticker)."
                : "Folync has no \(kind.title.lowercased()) transactions for \(ticker)."
        }
        return kind == .all ? "Folync has no transactions for this portfolio."
            : "Folync has no \(kind.title.lowercased()) transactions for this portfolio."
    }
}
