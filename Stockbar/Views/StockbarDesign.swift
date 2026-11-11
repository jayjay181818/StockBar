import SwiftUI

// Shared visual language for the main window and menu-bar popovers: one set of
// motion curves, gain/loss colours, card surfaces and header styles so every
// screen reads as part of the same app.

enum StockbarMotion {
    /// Page, card and state changes.
    static let standard: Animation = .smooth(duration: 0.3)
    /// Small controls such as segmented pills and hover feedback.
    static let quick: Animation = .snappy(duration: 0.22)
    /// Charts drawing in after data loads.
    static let reveal: Animation = .easeOut(duration: 0.55)

    /// Returns nil when Reduce Motion is on so changes apply without movement.
    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

enum StockbarPalette {
    /// Gains green, losses red; zero and unknown values stay neutral so an
    /// unchanged or missing figure never reads as a gain.
    static func signed(_ value: Double?, neutral: Color = .secondary) -> Color {
        guard let value, value.isFinite, value != 0 else { return neutral }
        return value > 0 ? .green : .red
    }

    /// The fill of the older analytics panels and sheet headers. Named here so
    /// those views stop spelling out system colours one by one.
    static let panelFill = Color(NSColor.controlBackgroundColor)
    static let sheetHeaderFill = Color(NSColor.controlBackgroundColor).opacity(0.5)
    /// A quiet grey behind small tiles and inactive chips.
    static let subtleFill = Color.gray.opacity(0.1)
    static let faintFill = Color.gray.opacity(0.05)

    static let cardFill = Color.primary.opacity(0.035)
    static let cardStroke = Color.primary.opacity(0.08)
    static let hoverFill = Color.primary.opacity(0.06)
}

enum StockbarLayout {
    static let pagePadding: CGFloat = 28
    /// The transparent title bar already leaves room above each page.
    static let pageInsets = EdgeInsets(top: 10, leading: 28, bottom: 28, trailing: 28)
    static let cardRadius: CGFloat = 12
    static let sectionSpacing: CGFloat = 22
}

private struct StockbarCardModifier: ViewModifier {
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StockbarPalette.cardFill, in: RoundedRectangle(cornerRadius: StockbarLayout.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: StockbarLayout.cardRadius, style: .continuous)
                    .strokeBorder(StockbarPalette.cardStroke, lineWidth: 1)
            )
    }
}

extension View {
    /// A quiet rounded surface that groups related content.
    func stockbarCard(padding: CGFloat = 18) -> some View {
        modifier(StockbarCardModifier(padding: padding))
    }

    /// Standard scrollable page layout used by every main-window section.
    func stockbarPage() -> some View {
        ScrollView {
            self
                .padding(StockbarLayout.pageInsets)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// Title, subtitle and trailing actions at the top of each main-window section.
struct StockbarPageHeader<Accessory: View>: View {
    let title: String
    let subtitle: String?
    private let accessory: Accessory

    init(_ title: String, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.largeTitle.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            accessory
        }
    }
}

extension StockbarPageHeader where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

/// Section title inside a page, above a card.
struct StockbarSectionTitle: View {
    let title: String
    var systemImage: String?

    var body: some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A labelled figure in a card, optionally tinted and with an icon.
struct StockbarMetricTile: View {
    let title: String
    let value: String
    var detail: String?
    var systemImage: String?
    var valueColor: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(.secondary)
                        .imageScale(.small)
                }
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .stockbarCard(padding: 16)
        .accessibilityElement(children: .combine)
    }
}

/// Up/down percentage pill. Unknown and unchanged values are neutral.
struct StockbarChangeBadge: View {
    let percent: Double?
    var size: ControlSize = .regular

    private var value: Double? { percent.flatMap { $0.isFinite ? $0 : nil } }

    var body: some View {
        let tint = StockbarPalette.signed(value)
        let symbol = value.map { $0 > 0 ? "arrow.up.right" : ($0 < 0 ? "arrow.down.right" : "minus") } ?? "minus"
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: size == .small ? 8 : 9, weight: .bold))
            Text(value.map { String(format: "%.2f%%", abs($0)) } ?? "—")
                .font(.system(size: size == .small ? 10 : 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(tint)
        .background(tint.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value.map {
            $0 == 0 ? "Unchanged" : String(format: "%@ %.2f percent", $0 > 0 ? "Up" : "Down", abs($0))
        } ?? "Change unavailable")
    }
}

/// A label/value row with a hairline divider, used in summary cards.
struct StockbarDetailRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary
    var showsDivider = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
                    .multilineTextAlignment(.trailing)
                    .contentTransition(.numericText())
            }
            .padding(.vertical, 9)
            if showsDivider {
                Divider()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Inline warning/notice banner.
struct StockbarNotice: View {
    let message: String
    var systemImage = "exclamationmark.triangle.fill"
    var tint: Color = .orange

    var body: some View {
        Label {
            Text(message).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .font(.callout)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Refresh glyph that spins while work is in flight.
struct StockbarRefreshIcon: View {
    let isRefreshing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "arrow.clockwise")
            .symbolEffect(.rotate, options: .repeat(.continuous), isActive: isRefreshing && !reduceMotion)
    }
}

/// Reveals its content from leading to trailing whenever `trigger` changes,
/// so charts appear to draw in. Disabled under Reduce Motion.
private struct ChartRevealModifier<Trigger: Equatable>: ViewModifier {
    let trigger: Trigger
    @State private var progress: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .mask(alignment: .leading) {
                GeometryReader { proxy in
                    Rectangle().frame(width: max(proxy.size.width * progress, 0))
                }
            }
            .onAppear { replay() }
            .onChange(of: trigger) { _, _ in replay() }
    }

    private func replay() {
        guard !reduceMotion else {
            progress = 1
            return
        }
        progress = 0
        withAnimation(StockbarMotion.reveal) { progress = 1 }
    }
}

extension View {
    func chartReveal<Trigger: Equatable>(trigger: Trigger) -> some View {
        modifier(ChartRevealModifier(trigger: trigger))
    }
}

enum StockbarAppearance {
    /// NSAppearance matching Settings → Appearance → Theme; nil follows the system.
    static func popoverAppearance(defaults: UserDefaults = StockbarRuntimeStorage.userDefaults) -> NSAppearance? {
        switch defaults.string(forKey: "appearanceMode") {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
    }
}

enum StockbarRelativeTime {
    /// Most recent positive Unix timestamp, as a date.
    static func latest(_ timestamps: [Int?]) -> Date? {
        timestamps.compactMap { $0 }.filter { $0 > 0 }.max()
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// The oldest positive Unix timestamp and how many entries have none. A single stale
    /// position must not be hidden by fresher ones, and a position that never updated counts
    /// as missing rather than being skipped.
    static func oldest(_ timestamps: [Int?]) -> (date: Date?, missingCount: Int) {
        let valid = timestamps.compactMap { $0 }.filter { $0 > 0 }
        let oldest = valid.min().map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return (oldest, timestamps.count - valid.count)
    }

    /// "Updated just now", "Updated 5 min. ago" or "Not updated yet".
    static func updatedText(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Not updated yet" }
        if now.timeIntervalSince(date) < 60 { return "Updated just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        return "Updated \(formatter.localizedString(for: date, relativeTo: now))"
    }
}

/// Search box styled to match Stockbar cards.
struct StockbarSearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(StockbarPalette.cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(StockbarPalette.cardStroke, lineWidth: 1)
        )
    }
}

/// Page change transition for the main window's detail column.
extension AnyTransition {
    static func stockbarPage(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8))
    }
}
