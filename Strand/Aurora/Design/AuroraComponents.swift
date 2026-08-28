import SwiftUI

// MARK: - Aurora Components
//
// The surface primitives every Aurora screen composes from. Nothing here knows about
// NOOP's domain: a component takes already-formatted strings and already-resolved
// colours, so the same tile renders a heart rate, a sleep debt or a battery level.
//
// THE ONE RULE THAT MATTERS: `AuroraMetricTile` must look DESIGNED when it has no data.
// The app it replaces prints a bare hyphen where a number should be, which reads as a
// bug. A missing metric is a normal, expected state — the strap was off, the night is
// not over, the sensor has not synced yet — and the UI should say so calmly instead of
// leaving a hole. The empty state below keeps the tile's full silhouette, swaps the
// numeral for a deliberately-styled placeholder, dashes the trend baseline, and adds one
// line of copy explaining the absence. It should feel like a designed resting state.

// MARK: - Elevation

/// The four levels of the Aurora surface ladder.
///
/// Depth is communicated by FILL first (each level is a measurably lighter step off the
/// canvas), rim second, shadow last. On a near-black canvas a shadow alone reads as mud,
/// so it is only ever the finishing touch.
public enum AuroraElevation: Int, CaseIterable, Sendable {
    /// No fill — the card is a pure outline. For grouping without visual weight.
    case flat
    /// The resting card. The default for almost everything.
    case base
    /// A raised card: hovered, selected, or a hero that must sit above its siblings.
    case raised
    /// An overlay: sheet chrome, popover, tooltip, floating toolbar.
    case overlay

    /// The surface fill for this level.
    public var fill: Color {
        switch self {
        case .flat:    return .clear
        case .base:    return Aurora.surface1
        case .raised:  return Aurora.surface2
        case .overlay: return Aurora.surface3
        }
    }

    /// The border colour. Higher elevations carry a slightly stronger rim so they read
    /// as nearer even before the shadow lands.
    public var border: Color {
        switch self {
        case .flat, .base: return Aurora.hairline
        case .raised, .overlay: return Aurora.hairlineStrong
        }
    }

    var shadowRadius: CGFloat {
        switch self {
        case .flat: return 0
        case .base: return Aurora.Shadow.restingRadius
        case .raised: return Aurora.Shadow.raisedRadius
        case .overlay: return Aurora.Shadow.overlayRadius
        }
    }

    var shadowY: CGFloat {
        switch self {
        case .flat: return 0
        case .base: return Aurora.Shadow.restingY
        case .raised: return Aurora.Shadow.raisedY
        case .overlay: return Aurora.Shadow.overlayY
        }
    }

    func shadowOpacity(_ scheme: ColorScheme) -> Double {
        guard self != .flat else { return 0 }
        return Aurora.Shadow.opacity(for: scheme, raised: self != .base)
    }
}

// MARK: - AuroraSurface

/// The bare surface treatment behind every Aurora container: fill, optional accent wash,
/// a soft top rim highlight, a hairline border and an elevation shadow.
///
/// Exposed on its own so a screen can put the Aurora surface behind something that is not
/// an `AuroraCard` — a custom hero, a grid cell, a toolbar.
public struct AuroraSurface: View {

    private let elevation: AuroraElevation
    private let radius: CGFloat
    private let tint: Color?
    private let highlight: Bool

    @Environment(\.colorScheme) private var scheme

    /// - Parameters:
    ///   - elevation: which rung of the surface ladder. Default `.base`.
    ///   - radius: corner radius. Default `Aurora.Radius.card` (20).
    ///   - tint: an optional identity colour washed faintly across the top-leading
    ///     corner. Kept under 8% alpha on purpose — a metric's colour should tint its
    ///     card, never repaint it.
    ///   - highlight: draw the soft inner rim highlight along the card's top edge.
    ///     This single detail carries most of Aurora's perceived depth; turn it off only
    ///     for surfaces that sit flush against another surface.
    public init(
        elevation: AuroraElevation = .base,
        radius: CGFloat = Aurora.Radius.card,
        tint: Color? = nil,
        highlight: Bool = true
    ) {
        self.elevation = elevation
        self.radius = radius
        self.tint = tint
        self.highlight = highlight
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        shape
            .fill(elevation.fill)
            .overlay {
                if let tint {
                    shape.fill(
                        LinearGradient(
                            colors: [tint.opacity(0.075), tint.opacity(0.015), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
            }
            .overlay {
                if highlight {
                    // The light source sits above the page: a bright sliver across the
                    // top 45% that dissolves before the middle of the card.
                    shape.fill(
                        LinearGradient(
                            stops: [
                                .init(color: Aurora.rimHighlight.opacity(scheme == .dark ? 0.55 : 0.0), location: 0.0),
                                .init(color: .clear, location: 0.45),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .blendMode(scheme == .dark ? .plusLighter : .normal)
                    .opacity(scheme == .dark ? 1 : 0)
                }
            }
            .overlay {
                shape.strokeBorder(elevation.border, lineWidth: Aurora.Stroke.border)
            }
            .shadow(
                color: .black.opacity(elevation.shadowOpacity(scheme)),
                radius: elevation.shadowRadius,
                x: 0,
                y: elevation.shadowY
            )
    }
}

// MARK: - AuroraCard

/// The Aurora container primitive. A card is a surface plus interior padding — nothing
/// more. It never adds a title, a header or a divider, because a card that also arranges
/// its contents stops being reusable at exactly the moment a screen needs something else.
public struct AuroraCard<Content: View>: View {

    private let elevation: AuroraElevation
    private let padding: EdgeInsets
    private let radius: CGFloat
    private let tint: Color?
    private let highlight: Bool
    private let content: Content

    /// - Parameters:
    ///   - elevation: surface ladder rung. Default `.base`.
    ///   - padding: uniform interior padding. Default 16. Pass `0` for a card whose rows
    ///     draw their own insets edge-to-edge (a grouped list), then clip the rows.
    ///   - radius: corner radius. Default 20; use `Aurora.Radius.hero` (28) for heroes.
    ///   - tint: faint identity wash (see `AuroraSurface`).
    ///   - highlight: draw the top rim highlight. Default `true`.
    public init(
        elevation: AuroraElevation = .base,
        padding: CGFloat = Aurora.Space.cardPadding,
        radius: CGFloat = Aurora.Radius.card,
        tint: Color? = nil,
        highlight: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.elevation = elevation
        self.padding = EdgeInsets(top: padding, leading: padding, bottom: padding, trailing: padding)
        self.radius = radius
        self.tint = tint
        self.highlight = highlight
        self.content = content()
    }

    /// Per-edge padding variant, for a card whose header is flush but whose body is inset.
    public init(
        elevation: AuroraElevation = .base,
        insets: EdgeInsets,
        radius: CGFloat = Aurora.Radius.card,
        tint: Color? = nil,
        highlight: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.elevation = elevation
        self.padding = insets
        self.radius = radius
        self.tint = tint
        self.highlight = highlight
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AuroraSurface(elevation: elevation, radius: radius, tint: tint, highlight: highlight))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - AuroraSectionHeader

/// An uppercase, widely-tracked section rule with an optional trailing action.
///
/// The label is set at 11pt so it reads as structure rather than content, and the
/// trailing action is deliberately small and accent-coloured: a section header is a
/// signpost, and a signpost should never out-shout the thing it points at.
public struct AuroraSectionHeader: View {

    private let title: String
    private let subtitle: String?
    private let actionTitle: String?
    private let actionIcon: String?
    private let action: (() -> Void)?

    /// - Parameters:
    ///   - title: the label. Rendered uppercase — pass it in natural case.
    ///   - subtitle: an optional one-line clarifier beneath the label.
    ///   - actionTitle: text for the trailing button. `nil` hides the button.
    ///   - actionIcon: SF Symbol shown after `actionTitle`. Default `chevron.right`.
    ///   - action: tapped handler. Required for the button to appear.
    public init(
        _ title: String,
        subtitle: String? = nil,
        actionTitle: String? = nil,
        actionIcon: String? = "chevron.right",
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actionTitle = actionTitle
        self.actionIcon = actionIcon
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Aurora.Space.s) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).auroraSectionHeader()
                if let subtitle {
                    Text(subtitle).auroraCaption()
                }
            }

            Spacer(minLength: Aurora.Space.xs)

            if let actionTitle, let action {
                Button(action: action) {
                    HStack(spacing: 3) {
                        Text(actionTitle)
                            .font(AuroraType.captionStrong)
                        if let actionIcon {
                            Image(systemName: actionIcon)
                                .font(.system(size: 9, weight: .bold))
                        }
                    }
                    .foregroundStyle(Aurora.accent)
                }
                .buttonStyle(.auroraPress)
                .accessibilityLabel(Text("\(actionTitle), \(title)"))
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Tone

/// The semantic tone of a chip, pill or badge. Tone drives colour; colour never gets
/// picked by hand at a call site.
public enum AuroraTone: Sendable, CaseIterable {
    case neutral, accent, good, caution, alert

    /// The foreground (text/glyph) colour.
    public var foreground: Color {
        switch self {
        case .neutral: return Aurora.statusNeutral
        case .accent:  return Aurora.accent
        case .good:    return Aurora.statusGood
        case .caution: return Aurora.statusCaution
        case .alert:   return Aurora.statusAlert
        }
    }

    /// The tinted background fill.
    public var fill: Color {
        switch self {
        case .neutral: return Aurora.statusNeutralFill
        case .accent:  return Aurora.accentMuted
        case .good:    return Aurora.statusGoodFill
        case .caution: return Aurora.statusCautionFill
        case .alert:   return Aurora.statusAlertFill
        }
    }
}

// MARK: - AuroraStatusPill

/// A compact capsule that states a status in one or two words.
///
/// Two variants: `.tinted` (a filled capsule — the default, for a verdict the eye should
/// find) and `.outline` (a hairline capsule — for metadata that must not compete).
public struct AuroraStatusPill: View {

    /// Fill treatment for the pill.
    public enum Style: Sendable { case tinted, outline, solid }

    private let text: String
    private let tone: AuroraTone
    private let icon: String?
    private let style: Style
    private let overrideColor: Color?

    /// - Parameters:
    ///   - text: the pill's label. Kept as authored (not uppercased) so a band name like
    ///     `"PRIMED"` and a phrase like `"Synced"` can both live here.
    ///   - tone: semantic tone driving the colour. Default `.neutral`.
    ///   - icon: optional leading SF Symbol.
    ///   - style: fill treatment. Default `.tinted`.
    ///   - overrideColor: use an exact colour (e.g. a sampled ramp value) instead of the
    ///     tone's. The tone still supplies the fill's alpha behaviour.
    public init(
        _ text: String,
        tone: AuroraTone = .neutral,
        icon: String? = nil,
        style: Style = .tinted,
        overrideColor: Color? = nil
    ) {
        self.text = text
        self.tone = tone
        self.icon = icon
        self.style = style
        self.overrideColor = overrideColor
    }

    private var tint: Color { overrideColor ?? tone.foreground }

    public var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(AuroraType.captionStrong)
                .tracking(0.3)
        }
        .foregroundStyle(style == .solid ? Aurora.textOnAccent : tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background {
            switch style {
            case .tinted:
                Capsule(style: .continuous).fill(overrideColor.map { $0.opacity(0.16) } ?? tone.fill)
            case .solid:
                Capsule(style: .continuous).fill(tint)
            case .outline:
                Capsule(style: .continuous).strokeBorder(tint.opacity(0.42), lineWidth: Aurora.Stroke.border)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(text))
    }
}

// MARK: - Delta

/// A signed change with the metadata needed to colour it correctly.
///
/// `higherIsBetter` exists because direction is not valence: +6 ms of HRV is good, +6 bpm
/// of resting heart rate is not. Without this flag a delta chip would confidently paint
/// half of the app's metrics the wrong colour.
public struct AuroraDelta: Equatable, Sendable {
    public var value: Double
    public var unit: String?
    public var decimals: Int
    public var higherIsBetter: Bool
    /// Below this magnitude the change is reported as "flat" rather than up or down.
    public var flatThreshold: Double

    public init(
        _ value: Double,
        unit: String? = nil,
        decimals: Int = 0,
        higherIsBetter: Bool = true,
        flatThreshold: Double = 0.05
    ) {
        self.value = value
        self.unit = unit
        self.decimals = decimals
        self.higherIsBetter = higherIsBetter
        self.flatThreshold = flatThreshold
    }

    /// Which way the value moved.
    public enum Direction: Sendable { case up, down, flat }

    public var direction: Direction {
        if abs(value) < flatThreshold { return .flat }
        return value > 0 ? .up : .down
    }

    /// The semantic tone for this change, resolving direction against `higherIsBetter`.
    public var tone: AuroraTone {
        switch direction {
        case .flat: return .neutral
        case .up:   return higherIsBetter ? .good : .caution
        case .down: return higherIsBetter ? .caution : .good
        }
    }

    var symbol: String {
        switch direction {
        case .up:   return "arrow.up.right"
        case .down: return "arrow.down.right"
        case .flat: return "arrow.right"
        }
    }

    var text: String {
        switch direction {
        case .flat:
            return "0"
        default:
            let magnitude = abs(value)
            let formatted = decimals > 0
                ? String(format: "%.\(decimals)f", magnitude)
                : String(Int(magnitude.rounded()))
            return (value > 0 ? "+" : "−") + formatted
        }
    }
}

/// A compact up / down / flat chip with a semantic colour.
public struct AuroraDeltaChip: View {

    private let delta: AuroraDelta
    private let showsUnit: Bool

    /// - Parameters:
    ///   - delta: the change to render.
    ///   - showsUnit: append `delta.unit` after the number. Default `true`.
    public init(_ delta: AuroraDelta, showsUnit: Bool = true) {
        self.delta = delta
        self.showsUnit = showsUnit
    }

    /// Convenience: build the delta inline.
    /// - Parameters:
    ///   - value: the signed change.
    ///   - unit: trailing unit (e.g. `"ms"`, `"%"`). `nil` for unitless.
    ///   - decimals: fraction digits. Default 0.
    ///   - higherIsBetter: whether an increase is a good thing. Default `true`.
    public init(
        value: Double,
        unit: String? = nil,
        decimals: Int = 0,
        higherIsBetter: Bool = true
    ) {
        self.init(AuroraDelta(value, unit: unit, decimals: decimals, higherIsBetter: higherIsBetter))
    }

    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: delta.symbol)
                .font(.system(size: 9, weight: .heavy))
            Text(delta.text + (showsUnit ? (delta.unit.map { " \($0)" } ?? "") : ""))
                .font(AuroraType.number(11, weight: .semibold))
        }
        .foregroundStyle(delta.tone.foreground)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Capsule(style: .continuous).fill(delta.tone.fill))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        let unitText = delta.unit.map { " \($0)" } ?? ""
        switch delta.direction {
        case .flat: return "No change"
        case .up:   return "Up \(delta.text.dropFirst())\(unitText)"
        case .down: return "Down \(delta.text.dropFirst())\(unitText)"
        }
    }
}

// MARK: - AuroraPressStyle

/// The house button feel: a subtle scale-down plus a slight dim, on the Aurora curve.
///
/// The numbers are deliberately small. A 3% scale and a 14% dim register as a physical
/// acknowledgement without turning a list of taps into a bouncing toy — and both collapse
/// to a pure opacity change when Reduce Motion is on, so the feedback survives without
/// the movement.
public struct AuroraPressStyle: ButtonStyle {

    private let scaleAmount: CGFloat
    private let dim: Double

    /// - Parameters:
    ///   - scaleAmount: pressed scale. Default `0.97`.
    ///   - dim: pressed opacity. Default `0.86`.
    public init(scaleAmount: CGFloat = 0.97, dim: Double = 0.86) {
        self.scaleAmount = scaleAmount
        self.dim = dim
    }

    public func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration, scaleAmount: scaleAmount, dim: dim)
    }

    private struct PressBody: View {
        let configuration: Configuration
        let scaleAmount: CGFloat
        let dim: Double
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? scaleAmount : 1)
                .opacity(configuration.isPressed ? dim : 1)
                .animation(Aurora.Motion.fast, value: configuration.isPressed)
        }
    }
}

public extension ButtonStyle where Self == AuroraPressStyle {
    /// `.buttonStyle(.auroraPress)` — the house press feedback.
    static var auroraPress: AuroraPressStyle { AuroraPressStyle() }
}

// MARK: - AuroraSkeleton

/// A shimmering placeholder for content that is loading.
///
/// A skeleton is a promise about layout: it must occupy the same footprint the real
/// content will, or the page jumps when data lands. The shimmer travels left-to-right on
/// a 1.4 s loop and is suppressed entirely under Reduce Motion, where a static tinted
/// block communicates "loading" just as well without the animation.
public struct AuroraSkeleton: View {

    private let width: CGFloat?
    private let height: CGFloat
    private let radius: CGFloat

    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - width: fixed width, or `nil` to fill the available space.
    ///   - height: bar height. Default 12 (a line of caption text).
    ///   - radius: corner radius. Default `Aurora.Radius.xs` (6).
    public init(width: CGFloat? = nil, height: CGFloat = 12, radius: CGFloat = Aurora.Radius.xs) {
        self.width = width
        self.height = height
        self.radius = radius
    }

    /// `nil` when a fixed width was supplied, `.infinity` when the bar should fill.
    private var fillWidth: CGFloat? { width == nil ? .infinity : nil }

    public var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Aurora.surfaceSubtle)
            .frame(width: width, height: height)
            .frame(maxWidth: fillWidth)
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [.clear, Aurora.rimHighlight.opacity(0.5), .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * 0.55)
                            .offset(x: phase * geo.size.width * 1.4)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1.2
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - AuroraEmptyState

/// A full-panel empty state: glyph, headline, supporting copy and an optional action.
///
/// Written to be reassuring rather than apologetic. An empty screen in a health app is
/// almost always a "not yet" and almost never a failure, so the copy a screen passes in
/// should explain what will fill it, not what went wrong.
public struct AuroraEmptyState: View {

    private let icon: String
    private let headline: String
    private let message: String?
    private let actionTitle: String?
    private let action: (() -> Void)?
    private let tint: Color

    /// - Parameters:
    ///   - icon: SF Symbol shown in the glyph plate.
    ///   - headline: one short line naming what is missing.
    ///   - message: one or two sentences explaining how it gets filled.
    ///   - actionTitle: label for the primary button. `nil` hides it.
    ///   - tint: accent for the glyph plate. Default `Aurora.accent`.
    ///   - action: tapped handler. Required for the button to appear.
    public init(
        icon: String,
        headline: String,
        message: String? = nil,
        actionTitle: String? = nil,
        tint: Color = Aurora.accent,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.headline = headline
        self.message = message
        self.actionTitle = actionTitle
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        VStack(spacing: Aurora.Space.s) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.12))
                Circle()
                    .strokeBorder(tint.opacity(0.22), lineWidth: Aurora.Stroke.border)
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(tint)
            }
            .frame(width: 56, height: 56)

            Text(headline)
                .auroraHeadline()
                .multilineTextAlignment(.center)

            if let message {
                Text(message)
                    .auroraBody()
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(AuroraType.label)
                        .foregroundStyle(Aurora.textOnAccent)
                        .padding(.horizontal, Aurora.Space.m)
                        .padding(.vertical, Aurora.Space.xs + 2)
                        .background(Capsule(style: .continuous).fill(Aurora.accent))
                }
                .buttonStyle(.auroraPress)
                .padding(.top, Aurora.Space.xxs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Aurora.Space.xl)
        .padding(.horizontal, Aurora.Space.m)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - AuroraMetricTile

/// The workhorse: an icon, a name, a large tabular value, an optional unit, an optional
/// sparkline and an optional delta chip — in one fixed-height tile that grids cleanly.
///
/// **Empty state.** When `value` is `nil` the tile keeps its full silhouette and swaps in
/// a designed placeholder: a muted en-dash at the same optical weight as a real number, a
/// dashed baseline where the sparkline would sit, and one line of copy naming the reason.
/// Nothing collapses, so a grid of tiles does not reflow as data arrives one metric at a
/// time — and nothing reads as broken.
public struct AuroraMetricTile: View {

    private let label: String
    private let value: String?
    private let unit: String?
    private let icon: String?
    private let accent: Color
    private let sparkline: [Double]?
    private let delta: AuroraDelta?
    private let caption: String?
    private let emptyHint: String
    private let elevation: AuroraElevation
    private let height: CGFloat?
    private let action: (() -> Void)?

    /// - Parameters:
    ///   - label: the metric's name (e.g. `"Resting HR"`).
    ///   - value: the already-formatted value, or `nil` to render the empty state.
    ///   - unit: trailing unit (e.g. `"bpm"`).
    ///   - icon: optional leading SF Symbol shown in a tinted plate.
    ///   - accent: the metric's identity colour — plate tint, sparkline stroke, and a
    ///     faint card wash. Default `Aurora.accent`.
    ///   - sparkline: a short recent series. `nil` (or fewer than two points) hides it.
    ///   - delta: change vs. the comparison period, shown as a chip beside the value.
    ///   - caption: one quiet line beneath the value (e.g. `"vs 30-day average"`).
    ///   - emptyHint: the line shown in place of `caption` when `value` is `nil`.
    ///     Default `"Not measured yet"`.
    ///   - elevation: surface rung. Default `.base`.
    ///   - height: fixed tile height, or `nil` to size to content. Default
    ///     `Aurora.Layout.metricTileHeight` (128) so a grid stays even.
    ///   - action: makes the whole tile tappable with the house press feedback.
    public init(
        label: String,
        value: String?,
        unit: String? = nil,
        icon: String? = nil,
        accent: Color = Aurora.accent,
        sparkline: [Double]? = nil,
        delta: AuroraDelta? = nil,
        caption: String? = nil,
        emptyHint: String = "Not measured yet",
        elevation: AuroraElevation = .base,
        height: CGFloat? = Aurora.Layout.metricTileHeight,
        action: (() -> Void)? = nil
    ) {
        self.label = label
        self.value = value
        self.unit = unit
        self.icon = icon
        self.accent = accent
        self.sparkline = sparkline
        self.delta = delta
        self.caption = caption
        self.emptyHint = emptyHint
        self.elevation = elevation
        self.height = height
        self.action = action
    }

    /// Convenience for a numeric value: formats to `decimals` places, or renders the
    /// empty state when `value` is `nil`.
    public init(
        label: String,
        value: Double?,
        decimals: Int = 0,
        unit: String? = nil,
        icon: String? = nil,
        accent: Color = Aurora.accent,
        sparkline: [Double]? = nil,
        delta: AuroraDelta? = nil,
        caption: String? = nil,
        emptyHint: String = "Not measured yet",
        elevation: AuroraElevation = .base,
        height: CGFloat? = Aurora.Layout.metricTileHeight,
        action: (() -> Void)? = nil
    ) {
        let text: String? = value.map { v in
            decimals > 0 ? String(format: "%.\(decimals)f", v) : String(Int(v.rounded()))
        }
        self.init(
            label: label, value: text, unit: unit, icon: icon, accent: accent,
            sparkline: sparkline, delta: delta, caption: caption, emptyHint: emptyHint,
            elevation: elevation, height: height, action: action
        )
    }

    private var isEmpty: Bool { value == nil }

    public var body: some View {
        Group {
            if let action {
                Button(action: action) { tile }
                    .buttonStyle(.auroraPress)
            } else {
                tile
            }
        }
    }

    private var tile: some View {
        AuroraCard(
            elevation: elevation,
            padding: Aurora.Space.s + 2,
            radius: Aurora.Radius.tile,
            // A metric's identity tints its tile only when the metric actually has a
            // reading. An empty tile stays neutral so a grid reads at a glance as
            // "these three have data, these two don't".
            tint: isEmpty ? nil : accent
        ) {
            VStack(alignment: .leading, spacing: Aurora.Space.xs) {
                header
                Spacer(minLength: Aurora.Space.xxs)
                valueRow
                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height, alignment: .top)
        }
        .opacity(isEmpty ? 0.92 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    // MARK: Header — glyph plate + name

    private var header: some View {
        HStack(spacing: Aurora.Space.xs) {
            if let icon {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isEmpty ? Aurora.surfaceSubtle : accent.opacity(0.16))
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isEmpty ? Aurora.textTertiary : accent)
                }
                .frame(width: Aurora.Layout.glyphPlate, height: Aurora.Layout.glyphPlate)
            }

            Text(label)
                .auroraLabel()
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 0)
        }
    }

    // MARK: Value row — the hero of the tile

    @ViewBuilder
    private var valueRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Aurora.Space.xs) {
            if let value {
                AuroraValueUnit(value: value, unit: unit, role: .metricMedium)
            } else {
                emptyValue
            }

            Spacer(minLength: Aurora.Space.xxs)

            if let delta, !isEmpty {
                AuroraDeltaChip(delta)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
            }
        }
    }

    /// The designed placeholder. An en-dash set at the SAME size and weight as a real
    /// value keeps the tile's optical rhythm, and the short dashed rule beneath it says
    /// "a number belongs here" rather than "something failed".
    private var emptyValue: some View {
        HStack(alignment: .firstTextBaseline, spacing: Aurora.Space.xs) {
            Text("–")
                .font(AuroraType.metricMedium)
                .foregroundStyle(Aurora.textDisabled)
                .overlay(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Aurora.textDisabled.opacity(0.35))
                        .frame(height: 2)
                        .offset(y: 4)
                }
            if let unit {
                Text(unit)
                    .auroraUnit()
                    .foregroundStyle(Aurora.textDisabled)
            }
        }
    }

    // MARK: Footer — sparkline or caption

    @ViewBuilder
    private var footer: some View {
        if isEmpty {
            // A dashed baseline occupies the sparkline's footprint, so a tile that gains
            // data later does not change height and the grid never reflows.
            DashedBaseline()
                .frame(maxWidth: .infinity)
                .frame(height: 14)
            Text(emptyHint)
                .auroraFootnote()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        } else if let sparkline, sparkline.count > 1 {
            AuroraSparkline(values: sparkline, tint: accent, showsArea: true)
                .frame(height: 22)
            if let caption {
                Text(caption).auroraFootnote().lineLimit(1)
            }
        } else if let caption {
            Text(caption)
                .auroraFootnote()
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accessibilityText: String {
        guard let value else { return "\(label), \(emptyHint)" }
        let unitText = unit.map { " \($0)" } ?? ""
        return "\(label), \(value)\(unitText)"
    }
}

/// A hairline dashed rule — the empty state's stand-in for a trend line.
struct DashedBaseline: View {
    var color: Color = Aurora.textDisabled.opacity(0.4)

    var body: some View {
        GeometryReader { geo in
            Path { p in
                p.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 5]))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Divider

/// The Aurora row divider — a true hairline in the divider token, inset to match a card's
/// interior padding so it never runs edge-to-edge under a rounded corner.
public struct AuroraDivider: View {
    private let inset: CGFloat

    /// - Parameter inset: leading/trailing inset. Default 0 (a card with zero padding
    ///   should pass its row padding here).
    public init(inset: CGFloat = 0) { self.inset = inset }

    public var body: some View {
        Rectangle()
            .fill(Aurora.divider)
            .frame(height: Aurora.Stroke.hairline)
            .padding(.horizontal, inset)
            .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Aurora Components") {
    ScrollView {
        VStack(alignment: .leading, spacing: Aurora.Space.l) {

            AuroraSectionHeader("Today", subtitle: "Wednesday, 27 August",
                                actionTitle: "History", action: {})

            LazyVGrid(columns: [GridItem(.flexible(), spacing: Aurora.Space.s),
                                GridItem(.flexible(), spacing: Aurora.Space.s)],
                      spacing: Aurora.Space.s) {
                AuroraMetricTile(
                    label: "Resting HR", value: 52.0, unit: "bpm",
                    icon: "heart.fill", accent: Aurora.recoveryColor(72),
                    sparkline: [54, 53, 55, 52, 51, 52, 50],
                    delta: AuroraDelta(-2, unit: "bpm", higherIsBetter: false),
                    caption: "vs 30-day average"
                )
                AuroraMetricTile(
                    label: "HRV", value: 62.0, unit: "ms",
                    icon: "waveform.path.ecg", accent: Aurora.accent,
                    sparkline: [48, 51, 58, 55, 60, 63, 62],
                    delta: AuroraDelta(6, unit: "ms")
                )
                AuroraMetricTile(
                    label: "SpO₂", value: nil, unit: "%",
                    icon: "lungs.fill", accent: Aurora.statusGood,
                    emptyHint: "Wear the strap overnight"
                )
                AuroraMetricTile(
                    label: "Skin temp", value: nil, unit: "°C",
                    icon: "thermometer.medium", accent: Aurora.statusCaution,
                    emptyHint: "Needs 3 more nights"
                )
            }

            HStack(spacing: Aurora.Space.xs) {
                AuroraStatusPill("PRIMED", tone: .good)
                AuroraStatusPill("Syncing", tone: .accent, icon: "arrow.triangle.2.circlepath")
                AuroraStatusPill("Strap off", tone: .caution, style: .outline)
                AuroraDeltaChip(value: 6, unit: "ms")
                AuroraDeltaChip(value: -3, unit: "bpm", higherIsBetter: false)
                AuroraDeltaChip(value: 0)
            }

            AuroraCard(elevation: .raised) {
                VStack(alignment: .leading, spacing: Aurora.Space.s) {
                    AuroraSkeleton(width: 120, height: 14)
                    AuroraSkeleton(height: 10)
                    AuroraSkeleton(width: 180, height: 10)
                }
            }

            AuroraCard {
                AuroraEmptyState(
                    icon: "bed.double.fill",
                    headline: "No sleep recorded",
                    message: "Wear your strap through the night and Aurora will chart every stage by morning.",
                    actionTitle: "Set a reminder",
                    action: {}
                )
            }
        }
        .padding(Aurora.Space.l)
    }
    .background(Aurora.canvas)
}
#endif
