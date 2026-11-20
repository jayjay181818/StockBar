import AppKit
import SwiftUI

// Shared visual language for the main window and menu-bar popovers: one set of
// motion curves, gain/loss colours, surfaces and header styles so every
// screen reads as part of the same app.
//
// A surface is anything drawn behind content to group it: a card, an inset
// panel, a metric strip, a notice bar, an empty state, a pill, a list row's
// hover or selection, a chart callout, a sheet header, the track of a range
// switch. Views take every surface from this file, through `stockbarCard()`,
// `stockbarSurface(_:)` and the components below, and never draw one from a
// raw colour or material. `Scripts/validate_invariants.sh` checks that.

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
    ///
    /// The system green and red. Used where the colour does not sit on a
    /// main-window surface: menu-bar titles (which follow the menu bar, not the
    /// app's appearance), the menu-bar popovers and chart series.
    static func signed(_ value: Double?, neutral: Color = .secondary) -> Color {
        guard let value, value.isFinite, value != 0 else { return neutral }
        return value > 0 ? .green : .red
    }

    /// Gains and losses on a main-window surface: `gain` and `loss`, so the
    /// figures stay readable on a light card. Zero and unknown stay neutral.
    static func signedOnSurface(_ value: Double?, neutral: Color = .secondary) -> Color {
        guard let value, value.isFinite, value != 0 else { return neutral }
        return value > 0 ? gain : loss
    }

    /// A deeper green and red in light mode, where the system ones are too
    /// pale on a near-white card; the system ones in dark mode.
    static let gain = adaptive(light: NSColor(srgbRed: 0.09, green: 0.55, blue: 0.24, alpha: 1), dark: .systemGreen)
    static let loss = adaptive(light: NSColor(srgbRed: 0.82, green: 0.18, blue: 0.16, alpha: 1), dark: .systemRed)

    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

enum StockbarLayout {
    static let pagePadding: CGFloat = 28
    /// The transparent title bar already leaves room above each page.
    static let pageInsets = EdgeInsets(top: 10, leading: 28, bottom: 28, trailing: 28)
    static let cardRadius: CGFloat = 13
    /// Inset panels, notices and fields inside a page.
    static let insetRadius: CGFloat = 9
    static let sectionSpacing: CGFloat = 18
}

// MARK: - Surfaces

/// Each kind of surface the app draws.
enum StockbarSurface: CaseIterable, Sendable {
    /// The Glass card: tinted fill, hairline stroke, a faint highlight along the top.
    case card
    /// A quieter panel inside a card, or a tinted block (with a tint).
    case inset
    /// A text field or search box.
    case field
    /// A small capsule: a badge, a "Paused" or "Watchlist" label, a chip.
    case pill
    /// A warning or information bar, always tinted.
    case notice
    /// A chart's hover callout or an annotation label over a plot.
    case callout
    /// The band across the top of a sheet or a toolbar strip inside a page.
    case sheetHeader
    /// The track of a range switch.
    case track
    /// The selected segment of a range switch.
    case selectedSegment
    /// A list or table row under the pointer.
    case rowHover
    /// A selected list or table row.
    case rowSelected
    /// Every other row of a striped list.
    case rowAlternate
}

/// The two accessibility settings every surface honours.
struct StockbarSurfaceAccessibility: Equatable, Sendable {
    /// Increase Contrast: a stronger stroke and a more solid fill.
    var increasedContrast = false
    /// Reduce Transparency: fully solid fills.
    var reduceTransparency = false
}

/// How one surface is drawn, for a colour scheme and the accessibility settings.
struct StockbarSurfaceStyle: Equatable {
    /// An opaque colour drawn under `fill`, so a tinted or translucent fill
    /// becomes solid under Reduce Transparency. Nil otherwise.
    var base: Color?
    var fill: Color
    var stroke: Color
    var strokeWidth: CGFloat
    /// The brighter hairline along the top of a card; nil for every other surface.
    var highlight: Color?
    /// Drop shadow under a raised element (a light card, a callout, the selected segment).
    var shadow: Color
    var shadowRadius: CGFloat = 3

    /// The fill's opacity once drawn over `base`: 1 when the surface is solid.
    var drawnOpacity: Double {
        if base != nil { return 1 }
        return Double(NSColor(fill).usingColorSpace(.sRGB)?.alphaComponent ?? 0)
    }

    /// Raised surfaces (cards, fields, callouts, the selected segment) are
    /// white with alpha in light mode; recessed ones (insets, pills, tracks,
    /// rows) are black with a little alpha. In dark mode all are white with a
    /// little alpha. The solid greys under Reduce Transparency are what the
    /// translucent fills come to over the window's background.
    static func resolve(
        _ surface: StockbarSurface,
        tint: Color? = nil,
        scheme: ColorScheme,
        accessibility: StockbarSurfaceAccessibility = .init()
    ) -> Self {
        let recipe = Recipe.of(surface, isDark: scheme == .dark)
        if let tint = tint ?? recipe.defaultTint {
            return tinted(tint, recipe: recipe, accessibility: accessibility)
        }
        return neutral(recipe, isDark: scheme == .dark, accessibility: accessibility)
    }

    /// The numbers behind one surface in one colour scheme.
    private struct Recipe {
        /// Opacity of the fill: white when `raised` or dark, black otherwise.
        var fill: Double
        var raised = false
        /// In dark mode, a near-opaque grey instead of a white tint.
        var darkGrey: Double?
        /// The grey drawn instead under Reduce Transparency.
        var solid: Double
        /// Opacity of the hairline stroke; nil for none.
        var stroke: Double?
        var highlight: Double?
        var shadow: Double?
        /// Opacity of a tinted fill.
        var tintFill: Double = 0.14
        var tintStroke: Double?
        var defaultTint: Color?

        // swiftlint:disable:next cyclomatic_complexity function_body_length
        static func of(_ surface: StockbarSurface, isDark dark: Bool) -> Self {
            switch surface {
            case .card:
                // Until the window shell turns tinted, the light detail column
                // is plain white: a white highlight there would erase the top
                // hairline, so a light card has a firmer stroke and a soft
                // shadow instead.
                Recipe(fill: dark ? 0.055 : 0.72, raised: true, solid: dark ? 0.165 : 0.98,
                       stroke: 0.10, highlight: dark ? 0.20 : nil,
                       shadow: dark ? nil : 0.06, tintFill: dark ? 0.14 : 0.10, tintStroke: 0.22)
            case .field:
                Recipe(fill: dark ? 0.055 : 0.72, raised: true, solid: dark ? 0.165 : 0.98,
                       stroke: dark ? 0.12 : 0.10)
            case .inset:
                Recipe(fill: dark ? 0.045 : 0.035, solid: dark ? 0.20 : 0.945,
                       tintFill: dark ? 0.14 : 0.10)
            case .pill:
                Recipe(fill: dark ? 0.09 : 0.06, solid: dark ? 0.24 : 0.91,
                       tintFill: dark ? 0.16 : 0.14)
            case .notice:
                Recipe(fill: 0, solid: dark ? 0.19 : 0.95, tintFill: dark ? 0.16 : 0.12,
                       tintStroke: 0.25, defaultTint: .orange)
            case .callout:
                // Over a plot a dark callout needs body: a solid-looking grey.
                Recipe(fill: 0.96, raised: true, darkGrey: 0.20, solid: dark ? 0.22 : 0.99,
                       stroke: dark ? 0.16 : 0.10, shadow: dark ? 0.35 : 0.12)
            case .sheetHeader:
                Recipe(fill: dark ? 0.04 : 0.03, solid: dark ? 0.19 : 0.95)
            case .track:
                Recipe(fill: dark ? 0.06 : 0.045, solid: dark ? 0.20 : 0.93, stroke: dark ? 0.08 : 0.05)
            case .selectedSegment:
                Recipe(fill: dark ? 0.16 : 0.95, raised: true, solid: dark ? 0.32 : 1.0,
                       stroke: dark ? 0.12 : 0.08, shadow: dark ? 0.25 : 0.12)
            case .rowHover:
                Recipe(fill: dark ? 0.05 : 0.04, solid: dark ? 0.215 : 0.935)
            case .rowSelected:
                Recipe(fill: 0, solid: dark ? 0.19 : 0.95, tintFill: dark ? 0.22 : 0.14,
                       defaultTint: .accentColor)
            case .rowAlternate:
                Recipe(fill: dark ? 0.025 : 0.02, solid: dark ? 0.185 : 0.96)
            }
        }
    }

    private static func white(_ white: Double, _ opacity: Double = 1) -> Color {
        Color(.sRGB, white: white, opacity: opacity)
    }

    private static func neutral(_ recipe: Recipe, isDark dark: Bool, accessibility: StockbarSurfaceAccessibility) -> Self {
        // Hairlines are white on dark and black on light.
        let ink = dark ? 1.0 : 0.0
        let contrast = accessibility.increasedContrast
        let stroke: Color = contrast ? white(ink, dark ? 0.5 : 0.45) : recipe.stroke.map { white(ink, $0) } ?? .clear
        let strokeWidth: CGFloat = contrast ? 1.5 : (recipe.stroke == nil ? 0 : 1)
        let fill: Color
        if accessibility.reduceTransparency {
            fill = white(recipe.solid)
        } else if dark, let grey = recipe.darkGrey {
            fill = white(grey, contrast ? 1 : 0.94)
        } else {
            // Increase Contrast: a more solid fill.
            let opacity = contrast ? min(recipe.fill * 1.6 + 0.02, 1) : recipe.fill
            fill = white(dark || recipe.raised ? 1 : 0, opacity)
        }
        let plain = !contrast && !accessibility.reduceTransparency
        var style = Self(
            base: nil,
            fill: fill,
            stroke: stroke,
            strokeWidth: strokeWidth,
            highlight: plain ? recipe.highlight.map { white(1, $0) } : nil,
            shadow: recipe.shadow.map { accessibility.reduceTransparency ? .clear : Color.black.opacity($0) } ?? .clear
        )
        if recipe.raised && recipe.fill < 0.9 { style.shadowRadius = 6 }
        return style
    }

    private static func tinted(_ tint: Color, recipe: Recipe, accessibility: StockbarSurfaceAccessibility) -> Self {
        let contrast = accessibility.increasedContrast
        let stroke: Color = contrast ? tint.opacity(0.75) : recipe.tintStroke.map { tint.opacity($0) } ?? .clear
        let strokeWidth: CGFloat = contrast ? 1.5 : (recipe.tintStroke == nil ? 0 : 1)
        return Self(
            base: accessibility.reduceTransparency ? white(recipe.solid) : nil,
            fill: tint.opacity(min(recipe.tintFill * (contrast ? 1.5 : 1), 1)),
            stroke: stroke,
            strokeWidth: strokeWidth,
            highlight: nil,
            shadow: .clear
        )
    }
}

private struct StockbarSurfaceAccessibilityOverrideKey: EnvironmentKey {
    static let defaultValue: StockbarSurfaceAccessibility? = nil
}

private struct StockbarResolvedSurfaceKey: EnvironmentKey {
    static let defaultValue: StockbarSurfaceStyle? = nil
}

extension EnvironmentValues {
    /// Replaces the system's Increase Contrast and Reduce Transparency for the
    /// surfaces below. SwiftUI does not let either be set, so tests set this.
    var stockbarSurfaceAccessibilityOverride: StockbarSurfaceAccessibility? {
        get { self[StockbarSurfaceAccessibilityOverrideKey.self] }
        set { self[StockbarSurfaceAccessibilityOverrideKey.self] = newValue }
    }

    /// The surface the content sits on, as drawn. Nil outside any surface.
    var stockbarSurface: StockbarSurfaceStyle? {
        get { self[StockbarResolvedSurfaceKey.self] }
        set { self[StockbarResolvedSurfaceKey.self] = newValue }
    }
}

private struct StockbarSurfaceModifier<S: InsettableShape>: ViewModifier {
    let surface: StockbarSurface
    let tint: Color?
    let shape: S
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.stockbarSurfaceAccessibilityOverride) private var override

    func body(content: Content) -> some View {
        let accessibility = override ?? StockbarSurfaceAccessibility(
            increasedContrast: contrast == .increased,
            reduceTransparency: reduceTransparency
        )
        let style = StockbarSurfaceStyle.resolve(surface, tint: tint, scheme: scheme, accessibility: accessibility)
        content
            .environment(\.stockbarSurface, style)
            .background {
                ZStack {
                    if let base = style.base {
                        shape.fill(base)
                    }
                    shape.fill(style.fill)
                }
                .shadow(color: style.shadow, radius: style.shadow == .clear ? 0 : style.shadowRadius,
                        y: style.shadow == .clear ? 0 : style.shadowRadius / 3)
            }
            .overlay {
                if style.strokeWidth > 0 {
                    shape.strokeBorder(style.stroke, lineWidth: style.strokeWidth)
                }
            }
            .overlay {
                // The faint top highlight: a brighter hairline that fades out by mid-card.
                if let highlight = style.highlight {
                    shape.strokeBorder(
                        LinearGradient(colors: [highlight, .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35)),
                        lineWidth: 1
                    )
                }
            }
    }
}

extension View {
    /// Draws one of the app's surfaces behind this view, in `shape`.
    func stockbarSurface<S: InsettableShape>(_ surface: StockbarSurface, tint: Color? = nil, in shape: S) -> some View {
        modifier(StockbarSurfaceModifier(surface: surface, tint: tint, shape: shape))
    }

    /// Draws one of the app's surfaces behind this view, in a rounded rectangle.
    func stockbarSurface(_ surface: StockbarSurface, tint: Color? = nil, cornerRadius: CGFloat = StockbarLayout.insetRadius) -> some View {
        stockbarSurface(surface, tint: tint, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// The Glass card: groups related content on a page.
    func stockbarCard(padding: CGFloat = 18, tint: Color? = nil) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .stockbarSurface(.card, tint: tint, cornerRadius: StockbarLayout.cardRadius)
    }

    /// A panel inside a card, or a tinted block, with its own padding.
    func stockbarInset(padding: CGFloat = 12, tint: Color? = nil) -> some View {
        self
            .padding(padding)
            .stockbarSurface(.inset, tint: tint)
    }

    /// A small capsule label such as "Paused" or "Watchlist".
    func stockbarPill(tint: Color? = nil) -> some View {
        self
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .stockbarSurface(.pill, tint: tint, in: Capsule())
    }

    /// The hover, selection or stripe behind one row of a list or table that
    /// draws its own rows. Nothing is drawn for a plain row.
    func stockbarRow(isHovered: Bool = false, isSelected: Bool = false, isAlternate: Bool = false,
                     cornerRadius: CGFloat = 0) -> some View {
        modifier(StockbarRowModifier(isHovered: isHovered, isSelected: isSelected, isAlternate: isAlternate,
                                     cornerRadius: cornerRadius))
    }

    /// A chart's hover callout or a label over a plot.
    func stockbarCallout(cornerRadius: CGFloat = 8) -> some View {
        stockbarSurface(.callout, cornerRadius: cornerRadius)
    }

    /// An empty, loading or error state that stands on a page by itself: a
    /// card at least `minHeight` tall. One inside a card needs no surface.
    func stockbarEmptyState(minHeight: CGFloat = 260) -> some View {
        self
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .stockbarCard()
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

private struct StockbarRowModifier: ViewModifier {
    let isHovered: Bool
    let isSelected: Bool
    let isAlternate: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let surface: StockbarSurface? = isSelected ? .rowSelected : isHovered ? .rowHover : isAlternate ? .rowAlternate : nil
        if let surface {
            content.stockbarSurface(surface, cornerRadius: cornerRadius)
        } else {
            content
        }
    }
}

// MARK: - Window shell

/// The main window's see-through backing and its floating sidebar panel.
///
/// The window is drawn by the app: macOS gives no floating sidebar in this
/// AppKit-hosted window, so the panel, its entries and their states live here.
/// Real glass is used only on macOS 26 and later, and only for the panel;
/// earlier systems get a material with a hairline stroke. Reduce Transparency
/// makes the window and the panel opaque, and Increase Contrast strokes the
/// panel and strengthens its text.
enum StockbarShell {
    /// Width of the sidebar panel. Fixed: the panel cannot be dragged wider.
    /// With its inset it takes the 220 points the standard sidebar took at
    /// its ideal width, so a page keeps the width it had.
    static let sidebarWidth: CGFloat = 213
    /// Gap between the panel and the window's edges.
    static let panelInset: CGFloat = 7
    static let panelRadius: CGFloat = 16
    static let entryRadius: CGFloat = 9
    /// Height of the window's top strip, where the traffic lights sit. The
    /// empty unified toolbar that places them makes it this tall.
    static let topStripHeight: CGFloat = 52

    /// Whether real glass can be drawn on this system.
    static var systemHasGlass: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }
}

/// How the sidebar panel is drawn.
struct StockbarShellPanelStyle: Equatable {
    enum Kind: Equatable {
        /// `glassEffect`, macOS 26 and later.
        case glass
        /// A system material, before macOS 26.
        case material
        /// An opaque grey, under Reduce Transparency.
        case solid
    }

    var kind: Kind
    /// The opaque fill for `.solid`; nil otherwise.
    var solidFill: Color?
    var stroke: Color
    var strokeWidth: CGFloat
    /// Increase Contrast: group headings and secondary footer text are drawn
    /// in the primary colour.
    var strongText: Bool

    static func resolve(scheme: ColorScheme, accessibility: StockbarSurfaceAccessibility, glassAvailable: Bool) -> Self {
        let dark = scheme == .dark
        let ink = Color(.sRGB, white: dark ? 1 : 0, opacity: 1)
        let contrast = accessibility.increasedContrast
        let stroke = contrast ? ink.opacity(dark ? 0.55 : 0.5) : ink.opacity(dark ? 0.14 : 0.08)
        let width: CGFloat = contrast ? 1.5 : 1
        if accessibility.reduceTransparency {
            return Self(kind: .solid, solidFill: Color(.sRGB, white: dark ? 0.17 : 0.965, opacity: 1),
                        stroke: stroke, strokeWidth: width, strongText: contrast)
        }
        if glassAvailable {
            // Glass draws its own edge; a stroke is added only for Increase Contrast.
            return Self(kind: .glass, solidFill: nil, stroke: contrast ? stroke : .clear,
                        strokeWidth: contrast ? width : 0, strongText: contrast)
        }
        return Self(kind: .material, solidFill: nil, stroke: stroke, strokeWidth: width, strongText: contrast)
    }
}

/// The state one sidebar entry is drawn in.
enum StockbarSidebarEntryState: Equatable, CaseIterable {
    case plain, hovered, pressed, selected
}

/// The fill and stroke behind one sidebar entry. Neutral, as in the
/// mock-ups: white on light, a light tint on dark. Selected, hovered and
/// pressed each look different.
struct StockbarSidebarEntryStyle: Equatable {
    var fill: Color
    var stroke: Color
    var strokeWidth: CGFloat
    var shadow: Color

    static func resolve(_ state: StockbarSidebarEntryState, scheme: ColorScheme,
                        accessibility: StockbarSurfaceAccessibility) -> Self {
        let dark = scheme == .dark
        let solid = accessibility.reduceTransparency
        let contrast = accessibility.increasedContrast
        func white(_ value: Double, _ opacity: Double) -> Color { Color(.sRGB, white: value, opacity: opacity) }
        let ink = dark ? 1.0 : 0.0
        let fill: Color
        switch state {
        case .plain:
            fill = .clear
        case .hovered:
            fill = solid ? white(dark ? 0.22 : 0.92, 1) : white(ink, dark ? 0.06 : 0.045)
        case .pressed:
            fill = solid ? white(dark ? 0.27 : 0.87, 1) : white(ink, dark ? 0.15 : 0.09)
        case .selected:
            fill = solid ? white(dark ? 0.30 : 1.0, 1) : (dark ? white(1, 0.11) : white(1, 0.85))
        }
        let stroked = contrast && state != .plain
        return Self(
            fill: fill,
            stroke: stroked ? white(ink, 0.5) : .clear,
            strokeWidth: stroked ? 1.5 : 0,
            shadow: state == .selected && !dark && !solid ? .black.opacity(0.08) : .clear
        )
    }
}

private struct StockbarGlassAvailableOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    /// Replaces "this system has real glass" for the shell below. Tests set it
    /// to draw the macOS 15–25 fallback on a newer system.
    var stockbarGlassAvailableOverride: Bool? {
        get { self[StockbarGlassAvailableOverrideKey.self] }
        set { self[StockbarGlassAvailableOverrideKey.self] = newValue }
    }
}

/// The accessibility settings in force for the shell, honouring the test override.
private struct StockbarShellAccessibilityReader<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.stockbarSurfaceAccessibilityOverride) private var override
    @Environment(\.stockbarGlassAvailableOverride) private var glassOverride
    @ViewBuilder let content: (ColorScheme, StockbarSurfaceAccessibility, Bool) -> Content

    var body: some View {
        let accessibility = override ?? StockbarSurfaceAccessibility(
            increasedContrast: contrast == .increased,
            reduceTransparency: reduceTransparency
        )
        content(scheme, accessibility, glassOverride ?? StockbarShell.systemHasGlass)
    }
}

/// Behind-window blending, so the desktop shows through the window.
struct StockbarWindowBacking: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The main window's background: the desktop blurred, under a wash that keeps
/// text readable over any wallpaper. Opaque under Reduce Transparency.
struct StockbarWindowBackground: View {
    var body: some View {
        StockbarShellAccessibilityReader { scheme, accessibility, _ in
            if accessibility.reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                ZStack {
                    StockbarWindowBacking()
                    Color(.sRGB, white: scheme == .dark ? 0 : 1, opacity: scheme == .dark ? 0.38 : 0.40)
                }
            }
        }
    }
}

private struct StockbarSidebarPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: StockbarShell.panelRadius, style: .continuous)
        StockbarShellAccessibilityReader { scheme, accessibility, glassAvailable in
            let style = StockbarShellPanelStyle.resolve(scheme: scheme, accessibility: accessibility,
                                                        glassAvailable: glassAvailable)
            panel(content, style: style, shape: shape, scheme: scheme)
                .environment(\.stockbarShellPanelStyle, style)
        }
    }

    @ViewBuilder
    private func panel(_ content: Content, style: StockbarShellPanelStyle,
                       shape: RoundedRectangle, scheme: ColorScheme) -> some View {
        let stroked = content.overlay {
            if style.strokeWidth > 0 {
                shape.strokeBorder(style.stroke, lineWidth: style.strokeWidth)
            }
        }
        switch style.kind {
        case .solid:
            stroked.background(style.solidFill ?? .clear, in: shape)
        case .material:
            stroked
                .background(.regularMaterial, in: shape)
                .shadow(color: .black.opacity(scheme == .dark ? 0.25 : 0.08), radius: 10, y: 3)
        case .glass:
            if #available(macOS 26, *) {
                stroked.glassEffect(.regular, in: shape)
            } else {
                stroked.background(.regularMaterial, in: shape)
            }
        }
    }
}

private struct StockbarShellPanelStyleKey: EnvironmentKey {
    static let defaultValue: StockbarShellPanelStyle? = nil
}

extension EnvironmentValues {
    /// The sidebar panel the content sits on, as drawn. Nil outside the panel.
    var stockbarShellPanelStyle: StockbarShellPanelStyle? {
        get { self[StockbarShellPanelStyleKey.self] }
        set { self[StockbarShellPanelStyleKey.self] = newValue }
    }
}

private struct StockbarSidebarEntryBackground: View {
    let state: StockbarSidebarEntryState
    let showsFocus: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: StockbarShell.entryRadius, style: .continuous)
        StockbarShellAccessibilityReader { scheme, accessibility, _ in
            let style = StockbarSidebarEntryStyle.resolve(state, scheme: scheme, accessibility: accessibility)
            shape.fill(style.fill)
                .shadow(color: style.shadow, radius: 2, y: 1)
                .overlay {
                    if style.strokeWidth > 0 {
                        shape.strokeBorder(style.stroke, lineWidth: style.strokeWidth)
                    }
                }
                .overlay {
                    // The keyboard focus ring, on the selected entry while the sidebar has focus.
                    if showsFocus {
                        shape.strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
        }
    }
}

extension View {
    /// The floating sidebar panel: glass on macOS 26 and later, a material
    /// with a hairline before, opaque under Reduce Transparency.
    func stockbarSidebarPanel() -> some View {
        modifier(StockbarSidebarPanelModifier())
    }

    /// The fill behind one sidebar entry, and the focus ring when `showsFocus`.
    func stockbarSidebarEntry(_ state: StockbarSidebarEntryState, showsFocus: Bool = false) -> some View {
        background(StockbarSidebarEntryBackground(state: state, showsFocus: showsFocus))
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

private struct StockbarInMetricStripKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var stockbarInMetricStrip: Bool {
        get { self[StockbarInMetricStripKey.self] }
        set { self[StockbarInMetricStripKey.self] = newValue }
    }
}

/// A row of metric tiles drawn as one card, the tiles divided by hairlines.
struct StockbarMetricStrip<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Group(subviews: content) { tiles in
                ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                    if index > 0 {
                        Divider()
                    }
                    tile
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .environment(\.stockbarInMetricStrip, true)
        .stockbarSurface(.card, cornerRadius: StockbarLayout.cardRadius)
    }
}

/// A labelled figure: its own card, or one cell of a `StockbarMetricStrip`.
struct StockbarMetricTile: View {
    let title: String
    let value: String
    var detail: String?
    var systemImage: String?
    var valueColor: Color = .primary
    @Environment(\.stockbarInMetricStrip) private var inStrip

    var body: some View {
        let tile = VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(.secondary)
                        .imageScale(.small)
                        .accessibilityHidden(true)
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
                .stockbarRollingDigits()
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)

        Group {
            if inStrip {
                tile
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                tile.stockbarCard(padding: 16)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Up/down percentage pill. Unknown and unchanged values are neutral.
struct StockbarChangeBadge: View {
    let percent: Double?
    var size: ControlSize = .regular
    /// True on a main-window surface: the pill is a surface from this file and
    /// takes `gain`/`loss`. The menu-bar popovers leave it false and keep
    /// today's system colours until their own redesign.
    var onSurface = false

    private var value: Double? { percent.flatMap { $0.isFinite ? $0 : nil } }

    var body: some View {
        let tint = onSurface ? StockbarPalette.signedOnSurface(value) : StockbarPalette.signed(value)
        let symbol = value.map { $0 > 0 ? "arrow.up.right" : ($0 < 0 ? "arrow.down.right" : "minus") } ?? "minus"
        let badge = HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: size == .small ? 8 : 9, weight: .bold))
            Text(value.map { String(format: "%.2f%%", abs($0)) } ?? "—")
                .font(.system(size: size == .small ? 10 : 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .stockbarRollingDigits()
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(tint)

        Group {
            if onSurface {
                badge.stockbarSurface(.pill, tint: tint, in: Capsule())
            } else {
                badge.background(tint.opacity(0.14), in: Capsule())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value.map {
            $0 == 0 ? "Unchanged" : String(format: "%@ %.2f percent", $0 > 0 ? "Up" : "Down", abs($0))
        } ?? "Change unavailable")
    }
}

// MARK: - Overview: hero figure and composition bar

/// One large figure with the decimals smaller and quieter: "£84,310" and ".47".
struct StockbarHeroFigure: View {
    let text: String
    var size: CGFloat = 50

    /// Splits a formatted figure into its whole part and the rest, from the
    /// decimal separator on: "£84,310" and ".47"; "1,234" and ".50 CHF". Figures
    /// from `HoldingsCurrencyFormatter` always use a point, whatever the user's
    /// locale, so that is the default. Not split unless the separator is
    /// followed by digits and then nothing but a currency suffix.
    static func split(_ text: String, decimalSeparator: String = ".") -> (whole: String, fraction: String) {
        guard !decimalSeparator.isEmpty,
              let range = text.range(of: decimalSeparator, options: .backwards) else { return (text, "") }
        let rest = text[range.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        let suffix = rest.dropFirst(digits.count)
        guard !digits.isEmpty, suffix.allSatisfy({ !$0.isNumber && $0 != "," && $0 != "." }) else { return (text, "") }
        return (String(text[..<range.lowerBound]), String(text[range.lowerBound...]))
    }

    var body: some View {
        let parts = Self.split(text)
        let whole = Text(verbatim: parts.whole).font(.system(size: size, weight: .bold))
        let fraction = Text(verbatim: parts.fraction)
            .font(.system(size: size * 0.56, weight: .semibold))
            .foregroundStyle(.secondary)
        Text("\(whole)\(fraction)")
            .monospacedDigit()
            .tracking(-0.6)
            .lineLimit(1)
    }
}

extension StockbarPalette {
    /// The composition bar's segments: net deposits grey, unrealised gains the
    /// gain green, realised gains a quieter green, the remainder amber.
    static func compositionFill(_ kind: PortfolioTotalComposition.Kind) -> Color {
        switch kind {
        case .netDeposits: depositsFill
        case .unrealisedGains: gain
        case .realisedGains: realisedFill
        case .incomeInterestAndFees: incomeFill
        }
    }

    static let depositsFill = adaptive(light: NSColor(white: 0.62, alpha: 1), dark: NSColor(white: 0.45, alpha: 1))
    static let realisedFill = adaptive(
        light: NSColor(srgbRed: 0.36, green: 0.62, blue: 0.45, alpha: 1),
        dark: NSColor(srgbRed: 0.25, green: 0.56, blue: 0.36, alpha: 1)
    )
    static let incomeFill = adaptive(
        light: NSColor(srgbRed: 0.80, green: 0.55, blue: 0.05, alpha: 1),
        dark: NSColor(srgbRed: 0.99, green: 0.78, blue: 0.20, alpha: 1)
    )
}

/// The single bar of a `PortfolioTotalComposition`: one segment per positive part,
/// in proportion. Decorative: the legend beside it carries the figures.
struct StockbarCompositionBar: View {
    let composition: PortfolioTotalComposition
    var height: CGFloat = 14

    var body: some View {
        let fractions = composition.barFractions
        GeometryReader { proxy in
            let shown = fractions.indices.filter { fractions[$0] > 0 }
            let spacing: CGFloat = 3
            let usable = max(proxy.size.width - spacing * CGFloat(max(shown.count - 1, 0)), 0)
            HStack(spacing: spacing) {
                ForEach(shown, id: \.self) { index in
                    Rectangle()
                        .fill(StockbarPalette.compositionFill(composition.parts[index].kind))
                        .frame(width: usable * fractions[index])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: height)
        .stockbarSurface(.track, in: Capsule())
        .clipShape(Capsule())
        .accessibilityHidden(true)
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
                    .stockbarRollingDigits()
            }
            .padding(.vertical, 9)
            if showsDivider {
                Divider()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Inline warning/notice bar.
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
        .stockbarSurface(.notice, tint: tint, cornerRadius: 10)
    }
}

// MARK: - Range switch

/// The capsule switch for choosing a range, period or mode inside a page.
/// Pickers in Settings forms stay native.
///
/// For assistive technology it is one group named by `label`, and each
/// segment is a button that reports whether it is selected. With Full
/// Keyboard Access each segment can be focused and pressed, and the left and
/// right arrows move the selection while any segment has focus.
struct StockbarSegmentedControl<Value: Hashable>: View {
    let label: String
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    /// Equal-width segments that fill the width the control is given.
    var expands = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var pill

    init(_ label: String, selection: Binding<Value>, options: [Value], expands: Bool = false,
         title: @escaping (Value) -> String) {
        self.label = label
        self._selection = selection
        self.options = options
        self.expands = expands
        self.title = title
    }

    /// One segment as assistive technology reads it.
    struct Segment: Equatable {
        let option: Value
        let label: String
        let isSelected: Bool
    }

    /// What the control exposes: one group named `label`, and a button per
    /// option that reports whether it is selected. The body draws from this.
    static func accessibility(label: String, options: [Value], selection: Value,
                              title: (Value) -> String) -> (label: String, segments: [Segment]) {
        (label, options.map { Segment(option: $0, label: title($0), isSelected: $0 == selection) })
    }

    /// The option `offset` places away from `current`, stopping at either end.
    static func step(from current: Value, by offset: Int, in options: [Value]) -> Value? {
        guard let index = options.firstIndex(of: current) else { return options.first }
        let target = min(max(index + offset, 0), options.count - 1)
        return target == index ? nil : options[target]
    }

    var body: some View {
        let exposure = Self.accessibility(label: label, options: options, selection: selection, title: title)
        HStack(spacing: 2) {
            ForEach(exposure.segments, id: \.option) { segment in
                self.segment(segment)
            }
        }
        // One group around exactly the segment buttons.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(exposure.label)
        .padding(2)
        .stockbarSurface(.track, in: Capsule())
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            let offset = press.key == .leftArrow ? -1 : 1
            guard let next = Self.step(from: selection, by: offset, in: options) else { return .handled }
            select(next)
            return .handled
        }
    }

    private func segment(_ segment: Segment) -> some View {
        let isSelected = segment.isSelected
        return Button {
            select(segment.option)
        } label: {
            Text(segment.label)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .frame(maxWidth: expands ? .infinity : nil)
                .background {
                    if isSelected {
                        Color.clear
                            .stockbarSurface(.selectedSegment, in: Capsule())
                            .matchedGeometryEffect(id: "selected", in: pill)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(segment.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func select(_ option: Value) {
        guard option != selection else { return }
        withAnimation(StockbarMotion.animation(StockbarMotion.quick, reduceMotion: reduceMotion)) {
            selection = option
        }
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

// MARK: - Portfolio popover

// The popover keeps the system's own popover background, which covers the
// arrow as well as the body. How it reads under Reduce Transparency and
// Increase Contrast, and as glass on macOS 26, is left to the system; nothing
// here paints over it. Increase Contrast also strengthens the popover's text.

extension StockbarPalette {
    /// Gains and losses in the portfolio popover: the deeper green and red in
    /// light mode, the system ones in dark, resolved against the popover's own
    /// appearance. Zero and unknown stay neutral.
    static func signedOnPopover(_ value: Double?, neutral: Color = .secondary) -> Color {
        signedOnSurface(value, neutral: neutral)
    }
}

/// How text in the portfolio popover is drawn for the accessibility settings.
struct StockbarPopoverText: Equatable {
    /// Labels and secondary figures. Under Increase Contrast they take the
    /// primary colour instead of the faded secondary one.
    var secondaryIsPrimary: Bool

    static func resolve(accessibility: StockbarSurfaceAccessibility) -> Self {
        Self(secondaryIsPrimary: accessibility.increasedContrast)
    }

    var secondary: HierarchicalShapeStyle { secondaryIsPrimary ? .primary : .secondary }
    var tertiary: HierarchicalShapeStyle { secondaryIsPrimary ? .secondary : .tertiary }
}

extension View {
    /// Hands the popover's text style to the views below, from the system's
    /// Increase Contrast or a test's `stockbarSurfaceAccessibilityOverride`.
    func stockbarPopoverText() -> some View {
        modifier(StockbarPopoverTextModifier())
    }
}

private struct StockbarPopoverTextKey: EnvironmentKey {
    static let defaultValue = StockbarPopoverText(secondaryIsPrimary: false)
}

extension EnvironmentValues {
    var stockbarPopoverText: StockbarPopoverText {
        get { self[StockbarPopoverTextKey.self] }
        set { self[StockbarPopoverTextKey.self] = newValue }
    }
}

private struct StockbarPopoverTextModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.stockbarSurfaceAccessibilityOverride) private var override

    func body(content: Content) -> some View {
        let accessibility = override ?? StockbarSurfaceAccessibility(
            increasedContrast: contrast == .increased,
            reduceTransparency: reduceTransparency
        )
        content.environment(\.stockbarPopoverText, .resolve(accessibility: accessibility))
    }
}

/// A large money figure with its decimals smaller and quieter: "£84,310" ".47".
struct StockbarSplitFigure: View {
    let text: String
    var size: CGFloat = 36
    @Environment(\.stockbarPopoverText) private var textStyle

    /// The whole part and the fraction with its separator. A figure with no
    /// fraction, or text that is not a figure ("-"), stays whole. The app's
    /// money figures (`HoldingsCurrencyFormatter`) always use a full stop.
    static func split(_ text: String, separator: String = ".") -> (whole: String, fraction: String) {
        guard let range = text.range(of: separator, options: .backwards) else { return (text, "") }
        let digits = text[range.upperBound...]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return (text, "") }
        return (String(text[..<range.lowerBound]), String(text[range.lowerBound...]))
    }

    var body: some View {
        let parts = Self.split(text)
        let whole = Text(parts.whole).font(.system(size: size, weight: .bold, design: .rounded))
        let fraction = Text(parts.fraction).font(.system(size: size * 0.56, weight: .semibold, design: .rounded))
            .foregroundStyle(textStyle.secondary)
        Text("\(whole)\(fraction)")
            .monospacedDigit()
            .lineLimit(1)
            .accessibilityLabel(text)
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
        .stockbarSurface(.field, cornerRadius: 8)
    }
}

/// Page change transition for the main window's detail column.
extension AnyTransition {
    static func stockbarPage(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8))
    }
}

// MARK: - Rolling digits

/// Whether figures roll to a new value or change without rolling.
///
/// CoreGraphics keeps the glyph bitmaps drawn while a figure rolls: 6 to
/// 10 MB when measured after the main window's figures had rolled in at
/// launch. Settings → Advanced → Memory → Roll Digits When Figures Change
/// turns the rolling off. On unless turned off.
///
/// A figure asks for the rolling with `stockbarRollingDigits()`, never with
/// the transition itself, and every SwiftUI root that AppKit hosts ends its
/// body with `stockbarRollingDigitsSetting()`. A figure under a root
/// without it rolls whatever the setting says.
enum StockbarRollingDigits {
    static let key = "figures.rollingDigits"
    static let defaultValue = true
}

private struct StockbarRollingDigitsKey: EnvironmentKey {
    static let defaultValue = StockbarRollingDigits.defaultValue
}

extension EnvironmentValues {
    /// Set for a whole window or popover by `stockbarRollingDigitsSetting()`.
    var stockbarRollingDigits: Bool {
        get { self[StockbarRollingDigitsKey.self] }
        set { self[StockbarRollingDigitsKey.self] = newValue }
    }
}

extension View {
    /// For a figure: its digits roll to a new value unless the setting is off.
    func stockbarRollingDigits() -> some View {
        modifier(StockbarRollingDigitsTransition())
    }

    /// For the root view of a window or popover: hands the setting to every
    /// figure inside, so there is one defaults observer per window and not
    /// one per figure.
    func stockbarRollingDigitsSetting() -> some View {
        modifier(StockbarRollingDigitsSetting())
    }
}

private struct StockbarRollingDigitsTransition: ViewModifier {
    @Environment(\.stockbarRollingDigits) private var rolls

    func body(content: Content) -> some View {
        // Off leaves the transition out altogether: that is the form whose
        // glyph cache was measured.
        if rolls {
            content.contentTransition(.numericText())
        } else {
            content
        }
    }
}

private struct StockbarRollingDigitsSetting: ViewModifier {
    @AppStorage(StockbarRollingDigits.key, store: StockbarRuntimeStorage.userDefaults)
    private var rolls = StockbarRollingDigits.defaultValue

    func body(content: Content) -> some View {
        content.environment(\.stockbarRollingDigits, rolls)
    }
}
