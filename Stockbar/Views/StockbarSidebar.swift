import AppKit
import SwiftUI

// The main window's sidebar, drawn by the app inside a floating panel.
//
// It keeps what the standard sidebar gave for free:
// - Keyboard: one stop in the Tab loop, like a native list. With focus in it,
//   Up and Down move the selection, Home and End go to the first and last
//   entry. The selected entry shows a focus ring while the sidebar has focus.
// - VoiceOver: the group headings are headings, and each entry is a button
//   that reads its title, any "New" badge or dimmed reason, its position
//   ("2 of 11") and whether it is selected. The entries are wrapped in a
//   container labelled "Sidebar"; SwiftUI draws no list role.
// - Hiding and showing, through View → Hide Sidebar (⌃⌘S) or the button by the
//   traffic lights (a toolbar item, so AppKit delivers its clicks).

/// One entry as drawn and as read aloud.
struct StockbarSidebarEntry: Identifiable, Equatable {
    let section: StockbarMainSection
    /// Why the section has nothing to show for the current portfolio; the entry
    /// is drawn dimmed but can still be chosen. Nil for a normal entry.
    var dimmedReason: String?
    /// Shows a small "New" badge.
    var isNew = false
    /// One-based position in the whole sidebar, and the number of entries.
    var position: Int
    var count: Int

    var id: StockbarMainSection { section }
    var title: String { section.title }
    var isDimmed: Bool { dimmedReason != nil }

    /// What VoiceOver reads after the title: the badge, the dimmed reason and
    /// the position, in that order. Selection is read from the selected trait.
    var accessibilityValue: String {
        var parts: [String] = []
        if isNew { parts.append("New") }
        if let dimmedReason { parts.append("Dimmed. \(dimmedReason)") }
        parts.append("\(position) of \(count)")
        return parts.joined(separator: ", ")
    }
}

/// The sidebar's groups, as drawn: the sections from
/// `StockbarMainSection.sidebarGroups` with each entry's state.
enum StockbarSidebarModel {
    struct Group: Identifiable, Equatable {
        let title: String
        let entries: [StockbarSidebarEntry]
        var id: String { title }
    }

    /// The main view passes the sections marked new and those dimmed for
    /// the current portfolio source, with their reasons.
    static func groups(dimmed: [StockbarMainSection: String] = [:],
                       new: Set<StockbarMainSection> = []) -> [Group] {
        let count = StockbarMainSection.sidebarOrder.count
        var position = 0
        return StockbarMainSection.sidebarGroups.map { group in
            Group(title: group.title, entries: group.sections.map { section in
                position += 1
                return StockbarSidebarEntry(section: section, dimmedReason: dimmed[section],
                                            isNew: new.contains(section), position: position, count: count)
            })
        }
    }

    enum Move: Equatable {
        case previous, next, first, last
    }

    /// The entry a key press selects, or nil when the selection stays where it is.
    static func target(of move: Move, from current: StockbarMainSection,
                       in order: [StockbarMainSection] = StockbarMainSection.sidebarOrder) -> StockbarMainSection? {
        guard let first = order.first, let last = order.last else { return nil }
        let target: StockbarMainSection
        switch move {
        case .first: target = first
        case .last: target = last
        case .previous, .next:
            guard let index = order.firstIndex(of: current) else { return first }
            let next = index + (move == .next ? 1 : -1)
            guard order.indices.contains(next) else { return nil }
            target = order[next]
        }
        return target == current ? nil : target
    }

    static func move(for key: KeyEquivalent) -> Move? {
        switch key {
        case .upArrow: .previous
        case .downArrow: .next
        case .home: .first
        case .end: .last
        default: nil
        }
    }
}

/// The floating sidebar panel: room for the traffic lights and the hide
/// button, the grouped entries, and the footer.
@MainActor
struct StockbarSidebar: View {
    let navigationState: StockbarMainNavigationState
    let groups: [StockbarSidebarModel.Group]
    let footer: StockbarSidebarFooterStatus.Inputs
    let isRefreshing: Bool
    let refresh: () -> Void

    var body: some View {
        StockbarSidebarContent(navigationState: navigationState, groups: groups, footer: footer,
                               isRefreshing: isRefreshing, refresh: refresh)
            .stockbarSidebarPanel()
    }
}

@MainActor
private struct StockbarSidebarContent: View {
    let navigationState: StockbarMainNavigationState
    let groups: [StockbarSidebarModel.Group]
    let footer: StockbarSidebarFooterStatus.Inputs
    let isRefreshing: Bool
    let refresh: () -> Void
    @Environment(\.stockbarShellPanelStyle) private var panelStyle
    @FocusState private var isFocused: Bool
    @State private var hovered: StockbarMainSection?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The traffic lights and the sidebar button (a toolbar item) sit in this room.
            Color.clear
                .frame(height: StockbarShell.topStripHeight - StockbarShell.panelInset * 2 + 2)
            entryList
            StockbarSidebarFooter(inputs: footer, isRefreshing: isRefreshing, refresh: refresh)
        }
    }

    private var entryList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(groups) { group in
                        Text(group.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(panelStyle?.strongText == true ? .primary : .secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.entries) { entry in
                            row(entry)
                                .id(entry.section)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Sidebar")
            }
            .scrollIndicators(.never)
            .onChange(of: navigationState.selectedSection) { _, section in
                proxy.scrollTo(section)
            }
        }
        // One stop in the Tab loop, like a native list, whether or not
        // keyboard navigation is switched on.
        .focusable(interactions: .edit)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .home, .end]) { press in
            guard let move = StockbarSidebarModel.move(for: press.key) else { return .ignored }
            apply(move)
            return .handled
        }
        // AppKit turns Home and End into these commands before a key press
        // reaches the handler above.
        .onCommand(#selector(NSResponder.scrollToBeginningOfDocument(_:))) { apply(.first) }
        .onCommand(#selector(NSResponder.scrollToEndOfDocument(_:))) { apply(.last) }
    }

    private func apply(_ move: StockbarSidebarModel.Move) {
        if let target = StockbarSidebarModel.target(of: move, from: navigationState.selectedSection) {
            navigationState.selectedSection = target
        }
    }

    private func row(_ entry: StockbarSidebarEntry) -> some View {
        let isSelected = navigationState.selectedSection == entry.section
        return Button {
            navigationState.selectedSection = entry.section
            isFocused = true
        } label: {
            StockbarSidebarRowLabel(entry: entry, isSelected: isSelected)
        }
        .buttonStyle(StockbarSidebarEntryButtonStyle(
            isSelected: isSelected,
            isHovered: hovered == entry.section,
            showsFocus: isSelected && isFocused
        ))
        // The list is the keyboard stop; its entries are reached with the arrows.
        .focusable(false)
        .onHover { inside in
            if inside {
                hovered = entry.section
            } else if hovered == entry.section {
                hovered = nil
            }
        }
        .help(entry.dimmedReason ?? "")
        .accessibilityLabel(entry.title)
        .accessibilityValue(entry.accessibilityValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct StockbarSidebarRowLabel: View {
    let entry: StockbarSidebarEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.section.systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(entry.isDimmed ? .tertiary : isSelected ? .primary : .secondary)
                .frame(width: 20)
            Text(entry.title)
                .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(entry.isDimmed ? .tertiary : .primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if entry.isNew {
                Text("New")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .stockbarPill(tint: .accentColor)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

/// Selected, hovered and pressed entries each look different.
private struct StockbarSidebarEntryButtonStyle: ButtonStyle {
    let isSelected: Bool
    let isHovered: Bool
    let showsFocus: Bool

    func makeBody(configuration: Configuration) -> some View {
        let state: StockbarSidebarEntryState = configuration.isPressed ? .pressed
            : isSelected ? .selected : isHovered ? .hovered : .plain
        configuration.label
            .stockbarSidebarEntry(state, showsFocus: showsFocus)
    }
}

// MARK: - Footer

/// What the sidebar footer says: the portfolio source and how fresh it is, or
/// an amber warning when Folync is not answering and saved figures are shown.
struct StockbarSidebarFooterStatus: Equatable {
    /// The status the app already has. Building the footer makes no request.
    struct Inputs: Equatable {
        var sourceTitle: String
        var sourceIcon: String
        var sourceHelp: String
        var isFolyncActive: Bool
        var connection: FolyncConnectionState
        /// `FolyncRefreshSchedule.failureCategory` of the last failed poll.
        var failureCategory: String?
        /// When the saved Folync figures were made.
        var savedAt: Date?
        /// The latest price update.
        var lastUpdate: Date?
    }

    var title: String
    var detail: String
    var isWarning: Bool

    /// VoiceOver reads the footer as one status.
    var accessibilityLabel: String { "\(title). \(detail)" }

    static func make(_ inputs: Inputs, now: Date = Date(),
                     timeZone: TimeZone = .current, locale: Locale = .current) -> Self {
        if inputs.isFolyncActive, case .offlineCached = inputs.connection {
            let reason = switch inputs.failureCategory {
            case "unauthorized": "Folync rejected the token"
            case "rate-limited": "Folync is limiting requests"
            default: "Couldn't reach Folync"
            }
            let figures = inputs.savedAt.map { "figures from \(savedTime($0, now: now, timeZone: timeZone, locale: locale))" }
                ?? "showing saved figures"
            return Self(title: inputs.sourceTitle, detail: "\(reason) · \(figures)", isWarning: true)
        }
        return Self(title: inputs.sourceTitle,
                    detail: StockbarRelativeTime.updatedText(inputs.lastUpdate, now: now),
                    isWarning: false)
    }

    /// "14:05" today, "12 Nov, 14:05" on another day.
    static func savedTime(_ date: Date, now: Date, timeZone: TimeZone, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar)
        time.timeZone = timeZone
        guard !calendar.isDate(date, inSameDayAs: now) else { return date.formatted(time) }
        var day = Date.FormatStyle(locale: locale, calendar: calendar).day().month(.abbreviated)
        day.timeZone = timeZone
        return "\(date.formatted(day)), \(date.formatted(time))"
    }

    /// What to announce when the footer changes, so VoiceOver hears it turn
    /// to the warning (and back). Nil when nothing worth saying changed.
    static func announcement(from old: Self, to new: Self) -> String? {
        guard old.isWarning != new.isWarning else { return nil }
        return new.accessibilityLabel
    }
}

@MainActor
private struct StockbarSidebarFooter: View {
    let inputs: StockbarSidebarFooterStatus.Inputs
    let isRefreshing: Bool
    let refresh: () -> Void
    @Environment(\.stockbarShellPanelStyle) private var panelStyle

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(StockbarSidebarFooterStatus.make(inputs, now: context.date))
        }
    }

    private func content(_ status: StockbarSidebarFooterStatus) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if status.isWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
            } else {
                refreshButton
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(status.detail)
                    .font(.caption2)
                    .foregroundStyle(panelStyle?.strongText == true || status.isWarning ? .primary : .secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .help(inputs.sourceHelp)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.accessibilityLabel)
            .accessibilityAddTraits(.updatesFrequently)
            Spacer(minLength: 0)
            if status.isWarning {
                refreshButton
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background {
            if status.isWarning {
                Color.clear.stockbarSurface(.notice, tint: .orange, cornerRadius: StockbarShell.entryRadius)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .overlay(alignment: .top) {
            Divider().padding(.horizontal, 12).offset(y: -4)
        }
        .onChange(of: status) { old, new in
            if let message = StockbarSidebarFooterStatus.announcement(from: old, to: new) {
                NSAccessibility.post(
                    element: NSApplication.shared,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: message,
                        .priority: NSAccessibilityPriorityLevel.high.rawValue
                    ]
                )
            }
        }
    }

    private var refreshButton: some View {
        Button(action: refresh) {
            StockbarRefreshIcon(isRefreshing: isRefreshing)
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(isRefreshing)
        .help("Refresh prices now (⌘R). Prices fetched very recently may be reused.")
        .accessibilityLabel(isRefreshing ? "Refreshing prices" : "Refresh prices")
    }
}

// MARK: - View menu

/// The View menu, built from the same groups as the sidebar so the two
/// cannot drift apart: one item per entry in sidebar order, ⌘1 to ⌘9 on the
/// first nine, a separator between groups, then Hide Sidebar / Show Sidebar.
@MainActor
enum StockbarSidebarMenu {
    static func title(sidebarHidden: Bool) -> String {
        sidebarHidden ? "Show Sidebar" : "Hide Sidebar"
    }

    /// `sectionAction` is sent to `sectionTarget` with the section's raw value
    /// as the item's represented object. The sidebar item goes through the
    /// responder chain to the main window, so it is disabled while no main
    /// window is key; its first title comes from the remembered choice.
    static func makeViewMenu(sectionTarget: AnyObject?, sectionAction: Selector,
                             defaults: UserDefaults = StockbarRuntimeStorage.userDefaults) -> NSMenu {
        let menu = NSMenu(title: "View")
        for (index, group) in StockbarMainSection.sidebarGroups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for section in group.sections {
                let item = NSMenuItem(
                    title: section.title,
                    action: sectionAction,
                    keyEquivalent: section.shortcutNumber.map(String.init) ?? ""
                )
                item.target = sectionTarget
                item.representedObject = section.rawValue
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let sidebar = NSMenuItem(
            title: title(sidebarHidden: StockbarMainNavigationState.storedSidebarHidden(in: defaults)),
            action: #selector(StockbarMainWindowController.toggleStockbarSidebar(_:)),
            keyEquivalent: "s"
        )
        sidebar.keyEquivalentModifierMask = [.control, .command]
        menu.addItem(sidebar)
        return menu
    }
}
