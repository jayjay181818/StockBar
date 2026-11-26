import SwiftUI

extension StockbarCalendarInputs {
    /// Read from the app's state; makes no request.
    @MainActor
    static func current(_ dataModel: DataModel) -> StockbarCalendarInputs {
        let local = LocalIncomeFigures.holdings(from: dataModel.realTimeTrades)
        let folyncHoldings = dataModel.isFolyncPortfolioActive ? dataModel.folyncPortfolioSnapshot?.displayHoldings : nil
        return StockbarCalendarInputs(
            isFolyncEnabled: dataModel.isFolyncEnabled,
            isFolyncPortfolio: dataModel.isFolyncPortfolioActive,
            holdings: CalendarFigures.holdings(local: local, folyncHoldings: dataModel.isFolyncPortfolioActive ? folyncHoldings ?? [] : nil),
            localHoldings: local
        )
    }
}

/// The Calendar page: dividend and earnings dates for the holdings, as a
/// month grid and a list, Upcoming or Past. Read-only; it asks for anything
/// only through `StockbarCalendarModel`.
@MainActor
struct StockbarCalendarView: View {
    let dataModel: DataModel
    @State private var model: StockbarCalendarModel
    @State private var hoveredRow: String?
    /// Each holding's choice for its past EPS figures (Settings → Advanced).
    /// Read in `body`, so a change shows at once; it asks for nothing.
    private let figuresSettings = EarningsFiguresSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(dataModel: DataModel, router: any StockbarIncomeRouting = FolyncSupplementalCoordinator.shared,
         provider: any InstrumentEventsProviding = InstrumentEventsService.shared,
         historyProvider: any InstrumentEarningsHistoryProviding = InstrumentEventsService.shared) {
        self.dataModel = dataModel
        let model = StockbarCalendarModel(router: router, provider: provider, historyProvider: historyProvider,
                                          isAllowed: { InstrumentEventsService.canAnswer })
        // An acceptance copy can open on Past (`STOCKBAR_ACCEPTANCE_CALENDAR`); nil otherwise.
        if let mode = StockbarAcceptanceLaunchOptions.current.calendarMode.flatMap(CalendarMode.init(rawValue:)) {
            model.mode = mode
        }
        _model = State(initialValue: model)
    }

    private var inputs: StockbarCalendarInputs { .current(dataModel) }

    private func rows(_ inputs: StockbarCalendarInputs) -> CalendarRows {
        let target = dataModel.preferredCurrency
        let converter = dataModel.currencyConverter
        let rows = model.rows(inputs, currency: target) { amount, from in
            converter.convertWithLoadedRates(amount: amount, from: from, to: target)
        }
        return CalendarFigures.applying(figuresSettings.choices, to: rows)
    }

    var body: some View {
        let inputs = inputs
        let rows = rows(inputs)
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: StockbarLayout.sectionSpacing) {
                StockbarPageHeader(StockbarMainSection.calendar.title,
                                   subtitle: CalendarText.subtitle(holdings: inputs.localHoldings.count)) {
                    if hasCalendar {
                        HStack(spacing: 12) {
                            Button { model.refresh(inputs) } label: {
                                StockbarRefreshIcon(isRefreshing: model.isLoading)
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.isRefreshing)
                            .help(model.source == .folync ? "Ask Folync and Yahoo for the latest dates"
                                                          : "Ask Yahoo for the latest dates")
                            .accessibilityLabel("Refresh calendar")
                            StockbarSegmentedControl("View", selection: $model.mode,
                                                     options: CalendarMode.allCases) { $0.title }
                        }
                    }
                }
                content(rows, inputs: inputs, proxy: proxy)
            }
        }
        .stockbarPage()
        .onAppear { model.activate(inputs) }
        .onDisappear { model.deactivate() }
        .onChange(of: inputs) { old, new in model.inputsChanged(from: old, to: new) }
    }

    /// The month bar, grid and list are shown (not a loading or empty state).
    private var hasCalendar: Bool {
        switch model.source {
        case .folync:
            switch model.folync.phase {
            case .loaded, .saved: true
            default: false
            }
        case .local: model.local.phase == .loaded
        case .none: false
        }
    }

    // MARK: States

    @ViewBuilder
    private func content(_ rows: CalendarRows, inputs: StockbarCalendarInputs, proxy: ScrollViewProxy) -> some View {
        switch model.source {
        case .none:
            loading("Asking for your holdings' dates…")
        case .folync:
            switch model.folync.phase {
            case .idle, .loading:
                loading("Asking Folync for your dividends…")
            case .needsFolync:
                StockbarIncomeMessage(
                    systemImage: "calendar",
                    title: "Calendar needs a Folync portfolio",
                    message: "With Folync connected, this page shows the dividends Folync records for your holdings. "
                        + "Your Folync portfolio isn't loaded yet, so there is nothing to show here."
                )
            case .unreachable:
                StockbarIncomeMessage(
                    systemImage: "exclamationmark.triangle", tint: .orange,
                    title: "Couldn't reach Folync",
                    message: "Folync didn't answer, and nothing is saved for your dividends yet. "
                        + "This page fills in once Folync answers.",
                    action: ("Try now", { model.refresh(inputs) })
                )
            case .unavailable:
                StockbarIncomeMessage(
                    systemImage: "questionmark.circle",
                    title: "Dividends aren't available from this Folync server",
                    message: "This Folync server doesn't provide dividend records, or isn't ready to yet."
                )
            case .switchedOff:
                StockbarIncomeMessage(
                    systemImage: "pause.circle",
                    title: "Dividends are switched off",
                    message: "Folync isn't connected, or dividends are switched off for this connection. "
                        + "Check Settings → Connections → Folync."
                )
            case .loaded, .saved:
                calendar(rows, inputs: inputs, proxy: proxy)
            }
        case .local:
            switch model.local.phase {
            case .idle, .loading:
                loading("Asking Yahoo for your holdings' dates…")
            case .notAllowed:
                StockbarIncomeMessage(
                    systemImage: "pause.circle",
                    title: "Calendar needs live market data",
                    message: "For this portfolio, dividend and earnings dates come from Yahoo. "
                        + "Live market data is off, so Stockbar can't ask Yahoo."
                )
            case .noHoldings:
                StockbarIncomeMessage(
                    systemImage: "calendar",
                    title: "No holdings to show",
                    message: "Add holdings with units to see their dividend and earnings dates. Watchlist rows are left out."
                )
            case .loaded:
                calendar(rows, inputs: inputs, proxy: proxy)
            }
        }
    }

    private func loading(_ text: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(text).foregroundStyle(.secondary)
        }
        .stockbarEmptyState()
    }

    // MARK: The calendar

    private func calendar(_ rows: CalendarRows, inputs: StockbarCalendarInputs, proxy: ScrollViewProxy) -> some View {
        let today = model.today
        let shown = model.shown(rows)
        let weeks = CalendarFigures.grid(month: model.month, rows: model.gridRows(rows), today: today)
        return VStack(alignment: .leading, spacing: StockbarLayout.sectionSpacing) {
            notices
            monthBar
            StockbarCalendarGrid(weeks: weeks, month: model.month, selectedDay: model.selectedDay) { day in
                model.selectedDay = day.day
                if let first = day.rows.first(where: { row in shown.contains { $0.id == row.id } }) {
                    scroll(proxy, to: first.id)
                } else if model.mode == .upcoming,
                          let first = day.rows.first(where: { row in rows.past.contains { $0.id == row.id } }) {
                    // Upcoming's grid also shows this month's past payments;
                    // their rows are in Past's list, so go there.
                    model.mode = .past
                    DispatchQueue.main.async { scroll(proxy, to: first.id) }
                }
            }
            list(shown, today: today)
            footer(shown, inputs: inputs, today: today)
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: String) {
        if reduceMotion {
            proxy.scrollTo(id, anchor: .center)
        } else {
            withAnimation { proxy.scrollTo(id, anchor: .center) }
        }
    }

    @ViewBuilder
    private var notices: some View {
        if model.source == .folync {
            if case .saved(let savedAt) = model.folync.phase {
                StockbarNotice(message: IncomeText.savedNotice(savedAt: savedAt))
            }
            if let response = model.folync.response, let partial = IncomeText.partialNotice(response) {
                StockbarNotice(message: partial, systemImage: "info.circle.fill", tint: .secondary)
            }
            if model.earningsNotAllowed {
                StockbarNotice(message: CalendarText.earningsNotAllowedNotice, systemImage: "info.circle.fill",
                               tint: .secondary)
            }
        } else {
            StockbarNotice(message: CalendarText.estimateNotice, systemImage: "info.circle.fill", tint: .secondary)
        }
        let results = model.yahooResults
        // In Past, a rate limit met by either kind of call is one notice.
        if let until = InstrumentEventsAnswers.rateLimitedUntil(model.yahooAnswerStates) {
            StockbarNotice(message: LocalIncomeText.rateLimitNotice(until: until))
        }
        let stale = InstrumentEventsAnswers.staleCopies(results)
        if let message = LocalIncomeText.staleNotice(count: stale.count, oldest: stale.oldest) {
            StockbarNotice(message: message)
        }
        if let message = LocalIncomeText.failedNotice(count: InstrumentEventsAnswers.failedWithoutCopy(results)) {
            StockbarNotice(message: message)
        }
        if model.mode == .past {
            let history = Array(model.historyResults.values)
            let staleHistory = InstrumentEventsAnswers.staleCopies(history)
            if let message = CalendarText.pastEarningsStaleNotice(count: staleHistory.count, oldest: staleHistory.oldest) {
                StockbarNotice(message: message)
            }
            if let message = CalendarText.pastEarningsFailedNotice(
                count: InstrumentEventsAnswers.failedWithoutCopy(history)) {
                StockbarNotice(message: message)
            }
        }
    }

    private var monthBar: some View {
        let range = model.monthRange
        return HStack(spacing: 12) {
            Button(action: model.showPreviousMonth) {
                Image(systemName: "chevron.left").frame(width: 22, height: 18)
            }
            .disabled(!range.canGoBack(from: model.month))
            .help("Previous month")
            .accessibilityLabel("Previous month")
            Text(IncomeText.monthLong(model.month))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 150)
                .accessibilityAddTraits(.isHeader)
            Button(action: model.showNextMonth) {
                Image(systemName: "chevron.right").frame(width: 22, height: 18)
            }
            .disabled(!range.canGoForward(from: model.month))
            .help("Next month")
            .accessibilityLabel("Next month")
            Spacer(minLength: 12)
            StockbarSegmentedControl("Show", selection: $model.filter,
                                     options: CalendarFigures.filters(for: model.mode)) { $0.title }
        }
    }

    // MARK: The list

    private func list(_ rows: [CalendarRow], today: FolyncLedgerDay) -> some View {
        let groups = model.mode == .upcoming
            ? CalendarFigures.upcomingGroups(rows, today: today)
            : CalendarFigures.pastGroups(rows)
        return VStack(alignment: .leading, spacing: 0) {
            if groups.isEmpty {
                Text(CalendarText.emptyLine(mode: model.mode, filter: model.filter))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                Text(CalendarText.groupTitle(group.key, today: today))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, index == 0 ? 0 : 12)
                    .padding(.bottom, 4)
                ForEach(Array(group.rows.enumerated()), id: \.element.id) { rowIndex, row in
                    if rowIndex > 0 { Divider() }
                    StockbarCalendarRowView(row: row, today: today,
                                            isSelected: row.day == model.selectedDay,
                                            isHovered: hoveredRow == row.id)
                        .id(row.id)
                        .onHover { inside in hoveredRow = inside ? row.id : (hoveredRow == row.id ? nil : hoveredRow) }
                }
            }
            if model.source == .folync, model.folync.continuation != nil || model.folync.loadMoreFailed {
                HStack(spacing: 10) {
                    if model.folync.continuation != nil {
                        Text("Folync has more payments than were loaded.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Load more", action: model.folync.loadMore)
                            .disabled(model.folync.isLoadingMore || model.folync.isLoading)
                    }
                    if model.folync.isLoadingMore { ProgressView().controlSize(.small) }
                    if model.folync.loadMoreFailed {
                        Text("Couldn't load more from Folync. The dates above are unchanged.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 10)
            }
        }
        .stockbarCard(padding: 16)
    }

    // MARK: Footer

    private func footer(_ rows: [CalendarRow], inputs: StockbarCalendarInputs, today: FolyncLedgerDay) -> some View {
        let source: CalendarDividendSource = model.source == .folync ? .folync : .yahooEstimate
        let coverage = CalendarFigures.earningsCoverage(holdings: inputs.holdings, answers: model.earningsAnswers,
                                                        today: today)
        let pastCoverage = CalendarFigures.pastEarningsCoverage(holdings: inputs.holdings,
                                                                histories: model.historyAnswers, today: today)
        let earningsAsked = !(model.source == .folync && (model.earningsNotAllowed || !inputs.isFolyncPortfolio))
        let historyAsked = !model.historyNotAllowed && !(model.source == .folync && !inputs.isFolyncPortfolio)
        return HStack(alignment: .top, spacing: 16) {
            HStack(spacing: 14) {
                legend(.exDividend, "Ex-dividend")
                legend(.payment, "Payment")
                legend(.earnings, "Earnings")
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                if rows.contains(where: \.isEstimated) {
                    Text(CalendarText.estimatedDatesNote)
                }
                Text(CalendarText.sourceLine(source))
                if model.mode == .upcoming, earningsAsked, !model.isLoadingEarnings,
                   let line = CalendarText.earningsCoverageLine(coverage) {
                    Text(line)
                }
                if model.mode == .past, historyAsked, !model.isLoadingHistory,
                   let line = CalendarText.pastEarningsCoverageLine(pastCoverage) {
                    Text(line)
                }
            }
            .multilineTextAlignment(.trailing)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func legend(_ kind: CalendarEventKind, _ title: String) -> some View {
        HStack(spacing: 6) {
            StockbarCalendarMarker(kind: kind, isEstimated: false)
            Text(title)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The grid

/// The month grid: Monday first, days outside the month dimmed, today marked.
/// Each day with events is a button (reachable from the keyboard) that reads
/// as one sentence; choosing it marks its rows in the list.
struct StockbarCalendarGrid: View {
    let weeks: [[CalendarGridDay]]
    let month: IncomeMonth
    let selectedDay: FolyncLedgerDay?
    let choose: (CalendarGridDay) -> Void

    private static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(Self.weekdays, id: \.self) { name in
                    Text(name)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)
            .padding(.bottom, 2)
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 4) {
                    ForEach(week) { day in
                        cell(day)
                    }
                }
            }
        }
        .stockbarCard(padding: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(CalendarText.monthSummary(weeks, month: month))
    }

    @ViewBuilder
    private func cell(_ day: CalendarGridDay) -> some View {
        if day.rows.isEmpty {
            cellContent(day)
                .accessibilityHidden(true)
        } else {
            Button { choose(day) } label: {
                cellContent(day)
                    .stockbarSurface(day.day == selectedDay ? .rowSelected : .inset, cornerRadius: StockbarLayout.insetRadius)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(CalendarText.daySentence(day))
            .accessibilityHint("Marks this day's events in the list")
        }
    }

    private func cellContent(_ day: CalendarGridDay) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(day.day.day)")
                .font(.callout.weight(day.isToday ? .bold : .regular))
                .monospacedDigit()
                .foregroundStyle(day.isToday ? AnyShapeStyle(.white) : day.isInMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .padding(.horizontal, day.isToday ? 5 : 0)
                .background {
                    if day.isToday { Capsule().fill(Color.accentColor) }
                }
            ForEach(day.shown) { row in
                HStack(spacing: 4) {
                    StockbarCalendarMarker(kind: row.kind, isEstimated: row.isEstimated, size: 8)
                    Text(row.symbol)
                        .font(.caption.weight(.semibold))
                        .italic(row.isEstimated)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .opacity(day.isInMonth ? 1 : 0.55)
            }
            if day.overflow > 0 {
                Text("+\(day.overflow)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
    }
}

// MARK: - A row

/// One line of the list: marker, day, symbol, words, amount, pill.
struct StockbarCalendarRowView: View {
    let row: CalendarRow
    let today: FolyncLedgerDay
    var isSelected = false
    var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            StockbarCalendarMarker(kind: row.kind, isEstimated: row.isEstimated)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(CalendarText.dayLabel(row.day, today: today))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(row.symbol)
                .fontWeight(.semibold)
                .lineLimit(1)
                .frame(width: 80, alignment: .leading)
            (Text(CalendarText.title(row)) + Text(CalendarText.detail(row)).foregroundStyle(.secondary))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let amount = CalendarText.amountColumn(row) {
                Text(amount)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            if let pill = row.pill {
                StockbarCalendarPill(pill: pill)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .stockbarRow(isHovered: isHovered, isSelected: isSelected, cornerRadius: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CalendarText.accessibilitySentence(row, today: today))
    }
}

// MARK: - Next up

/// "Next up" in the popover: a heading and up to three lines. Drawn only when
/// there is something to show; the caller leaves it out otherwise.
struct StockbarNextUpList: View {
    let rows: [CalendarRow]
    let today: FolyncLedgerDay

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Next up")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    StockbarCalendarMarker(kind: row.kind, isEstimated: row.isEstimated, size: 9)
                    Text(CalendarText.dayLabel(row.day, today: today))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 74, alignment: .leading)
                    Text(CalendarText.nextUpPhrase(row))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    Spacer(minLength: 4)
                    if let pill = row.pill {
                        Text(pill.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(CalendarText.nextUpSentence(row, today: today))
            }
        }
    }
}

/// "Next up" on the Overview: one card per event, side by side.
struct StockbarNextUpCards: View {
    let rows: [CalendarRow]
    let today: FolyncLedgerDay

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        StockbarCalendarMarker(kind: row.kind, isEstimated: row.isEstimated)
                        Text(CalendarText.dayLabel(row.day, today: today))
                            .foregroundStyle(.secondary)
                    }
                    Text(CalendarText.nextUpPhrase(row))
                        .font(.headline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let pill = row.pill {
                        Text(pill.title)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .stockbarCard(padding: 14)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(CalendarText.nextUpSentence(row, today: today))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Next up")
    }
}
