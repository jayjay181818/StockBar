import SwiftUI

/// The Income page: Folync's dividends for a Folync portfolio, in three views.
/// Read-only; it asks Folync only through `StockbarIncomeModel`.
@MainActor
struct StockbarIncomeView: View {
    let dataModel: DataModel
    @State private var model: StockbarIncomeModel

    init(dataModel: DataModel, router: any StockbarIncomeRouting = FolyncSupplementalCoordinator.shared) {
        self.dataModel = dataModel
        _model = State(initialValue: StockbarIncomeModel(router: router))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StockbarLayout.sectionSpacing) {
            StockbarPageHeader(StockbarMainSection.income.title, subtitle: subtitle) {
                if model.phase != .needsFolync {
                    HStack(spacing: 12) {
                        Button(action: model.refresh) {
                            StockbarRefreshIcon(isRefreshing: model.isLoading)
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.isRefreshing)
                        .help("Ask Folync for the latest income")
                        .accessibilityLabel("Refresh income")
                        StockbarSegmentedControl("View", selection: $model.view,
                                                 options: StockbarIncomeModel.View.allCases) { $0.title }
                    }
                }
            }
            content
        }
        .stockbarPage()
        .onAppear { model.activate(isFolyncPortfolio: dataModel.isFolyncPortfolioActive) }
        .onDisappear { model.deactivate() }
        .onChange(of: dataModel.isFolyncPortfolioActive) { _, isFolync in
            model.portfolioSourceChanged(isFolyncPortfolio: isFolync)
        }
    }

    private var subtitle: String {
        if let response = model.response { return IncomeText.holdingsLine(response) }
        return "Dividends from your holdings, as Folync records them."
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Asking Folync for your income…")
                    .foregroundStyle(.secondary)
            }
            .stockbarEmptyState()
        case .needsFolync:
            StockbarIncomeMessage(
                systemImage: "dollarsign.circle",
                title: "Income needs a Folync portfolio",
                message: "This page shows the dividends Folync records for your holdings. Your portfolio comes from "
                    + "another source, so there is nothing to show here. Choose a Folync portfolio in "
                    + "Settings → Connections to use it."
            )
        case .unreachable:
            StockbarIncomeMessage(
                systemImage: "exclamationmark.triangle",
                tint: .orange,
                title: "Couldn't reach Folync",
                message: "Folync didn't answer, and nothing is saved for Income yet. This page fills in once Folync answers.",
                action: ("Try now", model.refresh)
            )
        case .unavailable:
            StockbarIncomeMessage(
                systemImage: "questionmark.circle",
                title: "Income isn't available from this Folync server",
                message: "This Folync server doesn't provide dividend records, or isn't ready to yet."
            )
        case .switchedOff:
            StockbarIncomeMessage(
                systemImage: "pause.circle",
                title: "Income is switched off",
                message: "Folync isn't connected, or dividends are switched off for this connection. "
                    + "Check Settings → Connections → Folync."
            )
        case .loaded, .saved:
            if let response = model.response {
                VStack(alignment: .leading, spacing: StockbarLayout.sectionSpacing) {
                    notices(response)
                    switch model.view {
                    case .outlook: outlook(response)
                    case .history: history
                    case .byHolding: byHolding
                    }
                }
            }
        }
    }

    // MARK: Notices

    @ViewBuilder
    private func notices(_ response: FolyncDividendsResponse) -> some View {
        if case .saved(let savedAt) = model.phase {
            StockbarNotice(message: IncomeText.savedNotice(savedAt: savedAt))
        }
        if let partial = IncomeText.partialNotice(response) {
            StockbarNotice(message: partial, systemImage: "info.circle.fill", tint: .secondary)
        }
    }

    // MARK: Outlook

    private func outlook(_ response: FolyncDividendsResponse) -> some View {
        VStack(alignment: .leading, spacing: StockbarLayout.sectionSpacing) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 32) {
                    headline(response)
                    Spacer(minLength: 0)
                    figureLines(response)
                        .frame(maxWidth: 420)
                }
                VStack(alignment: .leading, spacing: 14) {
                    headline(response)
                    figureLines(response)
                }
            }
            if let chart = model.chart {
                StockbarIncomeChart(chart: chart, isLoadingMore: model.isLoadingMore, loadMore: model.loadMore)
            }
            upcoming
        }
    }

    private func headline(_ response: FolyncDividendsResponse) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Expected in the next 12 months")
                .font(.headline)
                .foregroundStyle(.secondary)
            StockbarHeroFigure(text: IncomeText.projected(response), size: 46)
            if response.summary.incomplete {
                Label("Folync marks this projection incomplete", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func figureLines(_ response: FolyncDividendsResponse) -> some View {
        VStack(spacing: 6) {
            ForEach(IncomeText.figureLines(response), id: \.title) { line in
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(line.title).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(line.value)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var upcoming: some View {
        let rows = model.upcoming
        return VStack(alignment: .leading, spacing: 0) {
            StockbarSectionTitle(title: "What is coming")
                .padding(.bottom, 6)
            if rows.isEmpty {
                Text("No payments still to come are listed.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider() }
                StockbarIncomeUpcomingRowView(row: row, currency: model.currency, today: model.today)
            }
        }
        .stockbarCard(padding: 16)
    }

    // MARK: History

    private var history: some View {
        let rows = model.history
        return VStack(alignment: .leading, spacing: 0) {
            StockbarSectionTitle(title: "Received")
            Text("Payments received, newest first, with pay dates from \(IncomeText.queryStart(model.query)).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            if rows.isEmpty {
                Text("No payments received are listed.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider() }
                StockbarIncomeHistoryRowView(row: row, currency: model.currency)
            }
            loadMoreFooter
        }
        .stockbarCard(padding: 16)
    }

    @ViewBuilder
    private var loadMoreFooter: some View {
        if model.continuation != nil || model.loadMoreFailed {
            HStack(spacing: 10) {
                if model.continuation != nil {
                    Button("Load more", action: model.loadMore)
                        .disabled(model.isLoadingMore || model.isLoading)
                }
                if model.isLoadingMore { ProgressView().controlSize(.small) }
                if model.loadMoreFailed {
                    Text("Couldn't load more from Folync. The payments above are unchanged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 10)
        }
    }

    // MARK: By holding

    private var byHolding: some View {
        let rows = model.byHolding
        return VStack(alignment: .leading, spacing: 0) {
            StockbarSectionTitle(title: "By holding")
            Text("Sums of the payments listed for \(IncomeText.monthsSpan(around: model.today)), in \(model.currency). "
                 + "Holdings with no payment listed are not shown.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
            HStack {
                Text("Holding").frame(maxWidth: .infinity, alignment: .leading)
                Text("Received").frame(width: 110, alignment: .trailing)
                Text("To come").frame(width: 110, alignment: .trailing)
                Text("Next payment").frame(width: 200, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
            .accessibilityHidden(true)
            if rows.isEmpty {
                Text("No payments are listed.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                Divider()
                StockbarIncomeHoldingRowView(row: row, currency: model.currency)
            }
            if model.continuation != nil {
                Text("Folync has more payments than are loaded, so these sums may be short.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
        }
        .stockbarCard(padding: 16)
    }
}

// MARK: - Rows

private struct StockbarIncomeUpcomingRowView: View {
    let row: IncomeUpcomingRow
    let currency: String
    let today: FolyncLedgerDay

    var body: some View {
        HStack(spacing: 14) {
            // The marker's shape tells an ex-dividend date (a ring) from a payment (a dot).
            Image(systemName: row.kind == .payment ? "circle.fill" : "circle")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(StockbarPalette.incomeFill)
                .frame(width: 14)
            Text(IncomeText.upcomingDayLabel(row.date, today: today))
                .foregroundStyle(.secondary)
                .frame(width: 115, alignment: .leading)
            Text(row.holding)
                .fontWeight(.semibold)
                .frame(width: 70, alignment: .leading)
            description
            Spacer(minLength: 8)
            // Fixed columns, so amounts line up whatever the pill says.
            // An ex-dividend row's amount is the payment to follow: shown quieter.
            VStack(alignment: .trailing, spacing: 0) {
                Text(IncomeText.amount(row.amount, currency: currency))
                    .fontWeight(row.kind == .payment ? .semibold : .regular)
                    .foregroundStyle(row.kind == .payment ? .primary : .secondary)
                    .monospacedDigit()
                if row.amountIsPartial { partialTag }
            }
            .frame(width: 90, alignment: .trailing)
            Group {
                if let pill = row.pill {
                    Text(pill)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .stockbarPill()
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(width: 190, alignment: .trailing)
        }
        .lineLimit(1)
        .padding(.vertical, 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(IncomeText.accessibilitySentence(row, currency: currency, today: today))
    }

    @ViewBuilder
    private var description: some View {
        switch row.kind {
        case .exDividend(let payDay):
            (Text("Ex-dividend") + Text(", pays \(IncomeText.dayMonth(payDay))").foregroundStyle(.secondary))
                .truncationMode(.tail)
        case .payment:
            Text("Dividend")
        }
    }
}

private struct StockbarIncomeHistoryRowView: View {
    let row: IncomeHistoryRow
    let currency: String

    var body: some View {
        HStack(spacing: 14) {
            Text(IncomeText.shortDay(row.date, withYear: true))
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(row.holding)
                .fontWeight(.semibold)
                .frame(width: 80, alignment: .leading)
            Text("Dividend")
            Spacer(minLength: 8)
            if let own = row.ownAmount {
                Text(IncomeText.amount(own.value, currency: own.currency))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(IncomeText.amount(row.amount, currency: currency))
                .fontWeight(.semibold)
                .monospacedDigit()
                .frame(minWidth: 90, alignment: .trailing)
            // A fixed slot, so a "partial" tag does not push its amount out of line.
            Text(row.amountIsPartial ? "partial" : "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
                .help(row.amountIsPartial ? "Folync marks this amount partial" : "")
        }
        .lineLimit(1)
        .padding(.vertical, 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(IncomeText.accessibilitySentence(row, currency: currency))
    }
}

private struct StockbarIncomeHoldingRowView: View {
    let row: IncomeHoldingRow
    let currency: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.holding).fontWeight(.semibold)
                if let note = IncomeText.missingAmountsNote(row.missingAmounts) {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(IncomeText.amount(row.received, currency: currency))
                .frame(width: 110, alignment: .trailing)
            Text(IncomeText.amount(row.toCome, currency: currency))
                .frame(width: 110, alignment: .trailing)
            Text(row.nextPayment.map {
                "\(IncomeText.shortDay($0.date)), \(IncomeText.amount($0.amount, currency: currency))"
            } ?? IncomeText.unknownFigure)
                .foregroundStyle(.secondary)
                .frame(width: 200, alignment: .trailing)
        }
        .monospacedDigit()
        .lineLimit(1)
        .padding(.vertical, 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(IncomeText.accessibilitySentence(row, currency: currency))
    }
}

private var partialTag: some View {
    Text("partial")
        .font(.caption)
        .foregroundStyle(.secondary)
        .help("Folync marks this amount partial")
}

/// An empty state for the page: an icon, a title, a sentence and, at most, one button.
private struct StockbarIncomeMessage: View {
    let systemImage: String
    var tint: Color = .secondary
    let title: String
    let message: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
            if let action {
                Button(action.title, action: action.run)
                    .controlSize(.large)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .stockbarEmptyState(minHeight: 340)
    }
}

// MARK: - Chart

/// Twelve months of income, one bar a month, from the payments listed. Drawn
/// by hand so estimated amounts can be hatched. Each month reads as one
/// sentence to VoiceOver.
struct StockbarIncomeChart: View {
    let chart: IncomeChart
    var isLoadingMore = false
    var loadMore: () -> Void = {}

    private let plotHeight: CGFloat = 190
    private let spacing: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            legend
            plot
            footer
        }
        .stockbarCard(padding: 16)
    }

    private var legend: some View {
        HStack(spacing: 16) {
            ForEach(chart.partsShown.isEmpty ? [.received] : chart.partsShown, id: \.self) { part in
                HStack(spacing: 6) {
                    StockbarIncomeBarPart(part: part)
                        .frame(width: 12, height: 12)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    Text(part.title)
                }
            }
        }
        .font(.callout)
        .accessibilityHidden(true)
    }

    private var plot: some View {
        let maximum = max(chart.maximum, 1)
        return GeometryReader { proxy in
            let columns = CGFloat(chart.months.count)
            let width = max((proxy.size.width - spacing * (columns - 1)) / columns, 1)
            ZStack(alignment: .topLeading) {
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(chart.months) { month in
                        column(month, maximum: maximum)
                            .frame(width: width)
                    }
                }
                if let current = chart.currentIndex, current < chart.months.count - 1 {
                    divider(x: CGFloat(current + 1) * (width + spacing) - spacing / 2, height: proxy.size.height)
                }
            }
        }
        .frame(height: plotHeight + 64)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Income by month, from the payments listed")
    }

    private func column(_ month: IncomeChartMonth, maximum: Double) -> some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            if month.total > 0 {
                Text(IncomeText.wholeAmount(month.total, currency: chart.currency))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            VStack(spacing: 0) {
                // Top to bottom, so received sits on the axis.
                ForEach(IncomePart.allCases.reversed(), id: \.self) { part in
                    let value = month.amount(part)
                    if value > 0 {
                        StockbarIncomeBarPart(part: part)
                            .frame(height: max(CGFloat(value / maximum) * plotHeight, 2))
                    }
                }
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4, style: .continuous))
            Text(IncomeText.monthShort(month.month))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(IncomeText.accessibilitySentence(month, currency: chart.currency))
    }

    private func divider(x: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: height - 22))
            }
            .stroke(.secondary, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            Text("Received")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(width: 120, alignment: .trailing)
                .offset(x: x - 126)
            Text("Still to come")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
                .offset(x: x + 6)
        }
        .accessibilityHidden(true)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(IncomeText.chartCaption(chart))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if chart.isIncomplete {
                HStack(spacing: 10) {
                    Label("Incomplete: Folync has more payments than are loaded.", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Load more", action: loadMore)
                        .controlSize(.small)
                        .disabled(isLoadingMore)
                    if isLoadingMore { ProgressView().controlSize(.small) }
                }
            }
        }
    }
}

/// One part of a bar: received in gold, declared in a darker gold, estimated
/// hatched in that darker gold, and an amount not marked either way as a
/// paler darker gold.
private struct StockbarIncomeBarPart: View {
    let part: IncomePart

    var body: some View {
        switch part {
        case .received:
            Rectangle().fill(StockbarPalette.incomeFill)
        case .declared:
            Rectangle().fill(StockbarPalette.incomeToComeFill)
        case .toCome:
            Rectangle().fill(StockbarPalette.incomeToComeFill.opacity(0.45))
        case .estimated:
            ZStack {
                Rectangle().fill(StockbarPalette.incomeToComeFill.opacity(0.18))
                StockbarHatch()
                    .stroke(StockbarPalette.incomeToComeFill, lineWidth: 1.5)
                Rectangle().strokeBorder(StockbarPalette.incomeToComeFill, lineWidth: 1)
            }
            .clipped()
        }
    }
}

/// Diagonal lines across a rectangle.
private struct StockbarHatch: Shape {
    var gap: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var offset = -rect.height
        while offset < rect.width {
            path.move(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + offset + rect.height, y: rect.minY))
            offset += gap
        }
        return path
    }
}
