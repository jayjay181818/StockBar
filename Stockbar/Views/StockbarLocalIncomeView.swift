import SwiftUI

/// The Income page for a local or Trading 212 portfolio: an estimate from
/// Yahoo's record of each holding's dividends, at today's units, in the same
/// three views as Folync's page. Read-only; it asks Yahoo only through
/// `StockbarLocalIncomeModel`.
@MainActor
struct StockbarLocalIncomeView: View {
    let dataModel: DataModel
    @State private var model: StockbarLocalIncomeModel

    init(dataModel: DataModel, provider: any InstrumentEventsProviding = InstrumentEventsService.shared) {
        self.dataModel = dataModel
        _model = State(initialValue: StockbarLocalIncomeModel(provider: provider,
                                                             isAllowed: { InstrumentEventsService.canAnswer }))
    }

    private var holdings: [LocalIncomeHolding] {
        LocalIncomeFigures.holdings(from: dataModel.realTimeTrades)
    }

    private var estimate: LocalIncomeEstimate {
        let target = dataModel.preferredCurrency
        let converter = dataModel.currencyConverter
        return model.estimate(holdings: holdings, currency: target) { amount, from in
            converter.convertWithLoadedRates(amount: amount, from: from, to: target)
        }
    }

    var body: some View {
        let estimate = estimate
        VStack(alignment: .leading, spacing: StockbarLayout.sectionSpacing) {
            StockbarPageHeader(StockbarMainSection.income.title, subtitle: subtitle(estimate)) {
                if model.phase == .loaded || model.phase == .loading {
                    HStack(spacing: 12) {
                        Button { model.refresh(holdings: holdings) } label: {
                            StockbarRefreshIcon(isRefreshing: model.isLoading)
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.isRefreshing)
                        .help("Ask Yahoo for the latest dividend record")
                        .accessibilityLabel("Refresh income")
                        StockbarSegmentedControl("View", selection: $model.view,
                                                 options: StockbarIncomeModel.View.allCases) { $0.title }
                    }
                }
            }
            content(estimate)
        }
        .stockbarPage()
        .onAppear { model.activate(holdings: holdings) }
        .onDisappear { model.deactivate() }
    }

    private func subtitle(_ estimate: LocalIncomeEstimate) -> String {
        model.phase == .loaded ? LocalIncomeText.holdingsLine(estimate) : LocalIncomeText.subtitle
    }

    @ViewBuilder
    private func content(_ estimate: LocalIncomeEstimate) -> some View {
        switch model.phase {
        case .idle, .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Asking Yahoo for your holdings' dividends…")
                    .foregroundStyle(.secondary)
            }
            .stockbarEmptyState()
        case .notAllowed:
            StockbarLocalIncomeMessage(
                systemImage: "pause.circle",
                title: "Income needs live market data",
                message: "For this portfolio, Income is an estimate from Yahoo's record of your holdings' dividends. "
                    + "Live market data is off, so Stockbar can't ask Yahoo."
            )
        case .noHoldings:
            StockbarLocalIncomeMessage(
                systemImage: "dollarsign.circle",
                title: "No holdings to estimate",
                message: "Add holdings with units to see an estimate of their dividends from Yahoo's record. "
                    + "Watchlist rows are left out."
            )
        case .loaded:
            VStack(alignment: .leading, spacing: StockbarLayout.sectionSpacing) {
                notices(estimate)
                switch model.view {
                case .outlook: outlook(estimate)
                case .history: lastYear(estimate)
                case .byHolding: byHolding(estimate)
                }
            }
        }
    }

    // MARK: Notices

    @ViewBuilder
    private func notices(_ estimate: LocalIncomeEstimate) -> some View {
        StockbarNotice(message: LocalIncomeText.estimateNotice, systemImage: "info.circle.fill", tint: .secondary)
        if let until = model.rateLimitedUntil {
            StockbarNotice(message: LocalIncomeText.rateLimitNotice(until: until))
        }
        let stale = model.staleCopies
        if let message = LocalIncomeText.staleNotice(count: stale.count, oldest: stale.oldest) {
            StockbarNotice(message: message)
        }
        if let message = LocalIncomeText.failedNotice(count: model.failedWithoutCopy) {
            StockbarNotice(message: message)
        }
        if let message = LocalIncomeText.leftOutNotice(estimate) {
            StockbarNotice(message: message, systemImage: "info.circle.fill", tint: .secondary)
        }
        if let message = LocalIncomeText.unknownNotice(estimate) {
            StockbarNotice(message: message, systemImage: "info.circle.fill", tint: .secondary)
        }
    }

    // MARK: Outlook

    private func outlook(_ estimate: LocalIncomeEstimate) -> some View {
        VStack(alignment: .leading, spacing: StockbarLayout.sectionSpacing) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 32) {
                    headline(estimate)
                    Spacer(minLength: 0)
                    figureLines(estimate).frame(maxWidth: 420)
                }
                VStack(alignment: .leading, spacing: 14) {
                    headline(estimate)
                    figureLines(estimate)
                }
            }
            StockbarLocalIncomeChart(chart: estimate.chart)
            nextYear(estimate)
        }
    }

    private func headline(_ estimate: LocalIncomeEstimate) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalIncomeText.headlineTitle)
                .font(.headline)
                .foregroundStyle(.secondary)
            StockbarHeroFigure(text: IncomeText.amount(estimate.nextYearTotal, currency: estimate.currency), size: 46)
            Label("Estimate: last year's payments at today's units", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func figureLines(_ estimate: LocalIncomeEstimate) -> some View {
        VStack(spacing: 6) {
            ForEach(LocalIncomeText.figureLines(estimate), id: \.title) { line in
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(line.title).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(line.value).fontWeight(.semibold).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func nextYear(_ estimate: LocalIncomeEstimate) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            StockbarSectionTitle(title: LocalIncomeText.nextYearTitle)
            Text(LocalIncomeText.nextYearCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)
            if estimate.nextYear.isEmpty {
                Text("No payments are estimated for the next 12 months.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(Array(estimate.nextYear.enumerated()), id: \.element.id) { index, payment in
                if index > 0 { Divider() }
                StockbarLocalIncomeNextRowView(payment: payment, currency: estimate.currency, today: estimate.today)
            }
        }
        .stockbarCard(padding: 16)
    }

    // MARK: History

    private func lastYear(_ estimate: LocalIncomeEstimate) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            StockbarSectionTitle(title: LocalIncomeText.lastYearTitle)
            Text(LocalIncomeText.lastYearCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)
            if estimate.lastYear.isEmpty {
                Text("Yahoo lists no payments in the last 12 months for your holdings.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(Array(estimate.lastYear.enumerated()), id: \.element.id) { index, payment in
                if index > 0 { Divider() }
                StockbarLocalIncomeLastRowView(payment: payment, currency: estimate.currency)
            }
        }
        .stockbarCard(padding: 16)
    }

    // MARK: By holding

    private func byHolding(_ estimate: LocalIncomeEstimate) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            StockbarSectionTitle(title: "By holding")
            Text(LocalIncomeText.byHoldingCaption(currency: estimate.currency))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
            HStack {
                Text("Holding").frame(maxWidth: .infinity, alignment: .leading)
                Text("Last 12 months").frame(width: 120, alignment: .trailing)
                Text("Next 12 months (estimate)").frame(width: 170, alignment: .trailing)
                Text("Next date (Yahoo)").frame(width: 170, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.bottom, 4)
            .accessibilityHidden(true)
            ForEach(estimate.holdings) { row in
                Divider()
                StockbarLocalIncomeHoldingRowView(row: row, currency: estimate.currency, today: estimate.today)
            }
        }
        .stockbarCard(padding: 16)
    }
}

// MARK: - Rows

private struct StockbarLocalIncomeNextRowView: View {
    let payment: LocalIncomePayment
    let currency: String
    let today: FolyncLedgerDay

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: payment.dateSource == .yahooUpcoming ? "circle.fill" : "circle.dashed")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(StockbarPalette.incomeToComeFill)
                .frame(width: 14)
            Text(IncomeText.upcomingDayLabel(payment.date, today: today))
                .foregroundStyle(.secondary)
                .frame(width: 115, alignment: .leading)
            Text(payment.holding)
                .fontWeight(.semibold)
                .frame(width: 90, alignment: .leading)
            description
            Spacer(minLength: 8)
            Text(LocalIncomeText.amount(payment, currency: currency))
                .monospacedDigit()
                .foregroundStyle(payment.amount == nil ? .secondary : .primary)
                .frame(width: 100, alignment: .trailing)
            Text(LocalIncomeText.pill(payment))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .stockbarPill()
                .frame(width: 210, alignment: .trailing)
        }
        .lineLimit(1)
        .padding(.vertical, 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LocalIncomeText.accessibilitySentence(nextYear: payment, currency: currency, today: today))
    }

    @ViewBuilder
    private var description: some View {
        if let pays = payment.payDay {
            (Text("Ex-dividend") + Text(", pays \(IncomeText.dayMonth(pays))").foregroundStyle(.secondary))
                .truncationMode(.tail)
        } else {
            Text("Ex-dividend")
        }
    }
}

private struct StockbarLocalIncomeLastRowView: View {
    let payment: LocalIncomePayment
    let currency: String

    var body: some View {
        HStack(spacing: 14) {
            Text(IncomeText.shortDay(payment.date, withYear: true))
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(payment.holding)
                .fontWeight(.semibold)
                .frame(width: 90, alignment: .leading)
            Text("Ex-dividend")
            Spacer(minLength: 8)
            if payment.amount != nil, let own = payment.ownAmount,
               payment.ownCurrency.uppercased() != currency.uppercased() {
                Text(IncomeText.amount(own, currency: payment.ownCurrency))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(LocalIncomeText.amount(payment, currency: currency))
                .fontWeight(payment.amount == nil ? .regular : .semibold)
                .foregroundStyle(payment.amount == nil ? .secondary : .primary)
                .monospacedDigit()
                .frame(minWidth: 90, alignment: .trailing)
            Text(LocalIncomeText.estimatePill)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .stockbarPill()
        }
        .lineLimit(1)
        .padding(.vertical, 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LocalIncomeText.accessibilitySentence(lastYear: payment, currency: currency))
    }
}

private struct StockbarLocalIncomeHoldingRowView: View {
    let row: LocalIncomeHoldingRow
    let currency: String
    let today: FolyncLedgerDay

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.symbol).fontWeight(.semibold)
                if row.isLeftOut {
                    Text("Not in the totals: no rate loaded").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(LocalIncomeText.holdingFigure(row, nextYear: false, currency: currency))
                .frame(width: 120, alignment: .trailing)
            Text(LocalIncomeText.holdingFigure(row, nextYear: true, currency: currency))
                .frame(width: 170, alignment: .trailing)
            Text(LocalIncomeText.nextDate(row, today: today))
                .foregroundStyle(.secondary)
                .frame(width: 170, alignment: .trailing)
        }
        .monospacedDigit()
        .lineLimit(1)
        .padding(.vertical, 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LocalIncomeText.accessibilitySentence(row, currency: currency, today: today))
    }
}

/// An empty state for the page: an icon, a title and a sentence.
private struct StockbarLocalIncomeMessage: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
        }
        .padding(24)
        .stockbarEmptyState(minHeight: 340)
    }
}

// MARK: - Chart

/// Twenty-five months of the estimate, one bar a month: Yahoo's payments of
/// the last twelve months at today's units, solid, and the estimate for the
/// next twelve, hatched. Each month reads as one sentence to VoiceOver.
struct StockbarLocalIncomeChart: View {
    let chart: LocalIncomeChart

    private let plotHeight: CGFloat = 170
    private let spacing: CGFloat = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            legend
            plot
            Text(LocalIncomeText.chartCaption(chart))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .stockbarCard(padding: 16)
    }

    private var legend: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                StockbarLocalIncomeBarPart(isEstimate: false)
                    .frame(width: 12, height: 12)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                Text(LocalIncomeText.chartLastYear)
            }
            HStack(spacing: 6) {
                StockbarLocalIncomeBarPart(isEstimate: true)
                    .frame(width: 12, height: 12)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                Text(LocalIncomeText.chartNextYear)
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
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(chart.months) { month in
                    column(month, maximum: maximum)
                        .frame(width: width)
                }
            }
        }
        .frame(height: plotHeight + 44)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Estimated income by month")
    }

    private func column(_ month: LocalIncomeChartMonth, maximum: Double) -> some View {
        let isCurrent = month.month == chart.currentMonth
        return VStack(spacing: 4) {
            Spacer(minLength: 0)
            if month.total > 0 {
                Text(IncomeText.wholeAmount(month.total, currency: chart.currency))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            VStack(spacing: 0) {
                if month.nextYear > 0 {
                    StockbarLocalIncomeBarPart(isEstimate: true)
                        .frame(height: max(CGFloat(month.nextYear / maximum) * plotHeight, 2))
                }
                if month.lastYear > 0 {
                    StockbarLocalIncomeBarPart(isEstimate: false)
                        .frame(height: max(CGFloat(month.lastYear / maximum) * plotHeight, 2))
                }
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3, style: .continuous))
            Text(IncomeText.monthShort(month.month))
                .font(.caption2.weight(isCurrent ? .bold : .regular))
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LocalIncomeText.accessibilitySentence(month, currency: chart.currency))
    }
}

/// One part of a bar: the last twelve months in gold, the estimate hatched.
private struct StockbarLocalIncomeBarPart: View {
    let isEstimate: Bool

    var body: some View {
        if isEstimate {
            ZStack {
                Rectangle().fill(StockbarPalette.incomeToComeFill.opacity(0.18))
                StockbarHatch()
                    .stroke(StockbarPalette.incomeToComeFill, lineWidth: 1.5)
                Rectangle().strokeBorder(StockbarPalette.incomeToComeFill, lineWidth: 1)
            }
            .clipped()
        } else {
            Rectangle().fill(StockbarPalette.incomeFill)
        }
    }
}
