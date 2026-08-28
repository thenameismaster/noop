import SwiftUI
import Foundation
import StrandDesign

#if os(iOS)
import UIKit
#endif

// MARK: - Aurora Signature Interactions
//
// The tokens, type scale, components and charts files describe how Aurora LOOKS. This
// file describes how Aurora *behaves* — the handful of structural pieces that make the
// fork a different application rather than a repaint of the incumbent one.
//
// The first redesign attempt failed because it kept every screen's information
// architecture and swapped colours. Everything here exists to change the architecture:
//
//   • `AuroraDayRail`        — the app becomes DAY-CENTRIC. A rail of coloured day pips is
//                              pinned under the nav bar of every pillar screen, so the
//                              question "which day am I looking at?" is answered at all
//                              times and moving between days is a swipe, not a menu.
//   • `AuroraBandWash`       — COLOUR IS DATA. A full-bleed wash tinted by the day's band
//                              makes the verdict readable from across a room before a
//                              single numeral has been parsed.
//   • `AuroraCollapsingHero` — PROGRESSIVE DISCLOSURE in the vertical axis. One dominant
//                              statement owns the screen at rest and demotes itself to an
//                              inline summary as the user reads downward.
//   • `AuroraZoneBar` /
//     `AuroraNeedBar`        — composition, not readout. Both answer "what is this number
//                              made of?" in a single glance-able shape.
//   • `AuroraRollingNumber`  — the hero numeral is alive: it counts in, and it rolls when
//                              the selected day changes.
//   • `AuroraPillarCard`     — the overview stops being a grid of tiles and becomes a
//                              short list of full-width pillars, each a doorway.
//   • `AuroraCoachLine`      — COACHING, NOT READOUT. Every hero carries one plain-English
//                              sentence with its key phrase burning in the band colour.
//
// PLATFORM. Everything compiles for macOS 13 and iOS 17. That rules out
// `scrollTargetBehavior`, `scrollPosition`, `Text.foregroundStyle` and the two-parameter
// `onChange` — the last of which is handled by `onChangeCompat` from StrandDesign.
// Haptics are UIKit-only and live behind `#if os(iOS)`.
//
// PRESENTATION ONLY. Nothing here computes, scores or persists anything. Every component
// takes already-derived values and renders them.

// MARK: - Formatting

/// Duration formatting shared by the composition bars, kept in one place so a zone
/// legend and a sleep-need legend can never disagree about how "1h 07m" is spelled.
public enum AuroraFormat {

    /// `"1h 12m"` / `"12m"` / `"0m"`. Negative input clamps to zero.
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((max(seconds, 0) / 60).rounded())
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }

    /// `"7:42"` — a clock-style duration for hero numerals, where the colon reads faster
    /// than an `h`/`m` pair at 80pt.
    public static func clock(_ seconds: TimeInterval) -> String {
        let minutes = Int((max(seconds, 0) / 60).rounded())
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    /// `"+1h 05m"` / `"−22m"` / `"—"` for a signed shortfall or surplus.
    public static func signedDuration(_ seconds: TimeInterval) -> String {
        if abs(seconds) < 30 { return "on target" }
        return (seconds > 0 ? "+" : "−") + duration(abs(seconds))
    }
}

// MARK: - AuroraDayPip

/// One day in the `AuroraDayRail`.
///
/// `recovery` is optional on purpose: a day with no reading is a real, common state and
/// the rail must show it as a *hole in the record* (a hollow pip) rather than as a zero,
/// which would read as "you were wrecked" instead of "we have nothing".
public struct AuroraDayPip: Identifiable, Equatable, Sendable {

    /// The canonical `YYYY-MM-DD` day key — the rail's selection currency.
    public let dayKey: String
    /// The day itself, used only for the weekday initial and the date label.
    public let date: Date
    /// Recovery percentage on 0…100, or `nil` when the day has no reading.
    public let recovery: Double?

    public var id: String { dayKey }

    /// - Parameters:
    ///   - dayKey: `YYYY-MM-DD`. Must match the key used in the rail's `selection` binding.
    ///   - date: the calendar date this pip represents.
    ///   - recovery: 0…100, or `nil` for a day with no reading.
    public init(dayKey: String, date: Date, recovery: Double?) {
        self.dayKey = dayKey
        self.date = date
        self.recovery = recovery
    }
}

// MARK: - AuroraDayRail

/// The horizontal rail of day pips pinned under the nav bar on every Aurora pillar screen.
///
/// This is the single most important structural change in the fork. The incumbent UI
/// answers "which day?" with a title that scrolls away; Aurora answers it with a
/// persistent, always-visible strip in which *colour is the data*: each pip is filled
/// with that day's recovery band, so a week of training reads as a colour sequence before
/// any number is parsed. Moving day is a swipe or a tap on the rail, never a picker.
///
/// True carousel snapping needs `scrollTargetBehavior` (iOS 17 / macOS 14) and the macOS
/// target is 13, so the rail snaps the honest way instead: any selection change scrolls
/// the chosen pip to the centre of the viewport on the house curve. The felt behaviour is
/// the same and it costs no availability fence.
public struct AuroraDayRail: View {

    private let days: [AuroraDayPip]
    @Binding private var selection: String
    private let showsDivider: Bool
    private let onSelect: ((String) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The rail's fixed height. Screens reserve this much space under the nav bar.
    public static let height: CGFloat = 82

    private static let itemWidth: CGFloat = 46
    private static let pipRow: CGFloat = 30

    /// - Parameters:
    ///   - days: the pips, oldest first. An empty array renders a quiet placeholder.
    ///   - selection: the selected `YYYY-MM-DD` day key. Two-way: tapping a pip writes it.
    ///   - showsDivider: draw the hairline along the rail's bottom edge, so it reads as
    ///     pinned chrome above scrolling content. Default `true`.
    ///   - onSelect: called after the binding is written, for the screen to reload. The
    ///     binding alone is usually enough; this exists for side effects that are not
    ///     state (analytics-free logging, scroll-to-top).
    public init(
        days: [AuroraDayPip],
        selection: Binding<String>,
        showsDivider: Bool = true,
        onSelect: ((String) -> Void)? = nil
    ) {
        self.days = days
        self._selection = selection
        self.showsDivider = showsDivider
        self.onSelect = onSelect
    }

    public var body: some View {
        Group {
            if days.isEmpty {
                Text("No days yet")
                    .auroraCaption()
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                rail
            }
        }
        .frame(height: Self.height)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle()
                    .fill(Aurora.divider)
                    .frame(height: Aurora.Stroke.hairline)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Day selector"))
    }

    // MARK: Rail

    private var rail: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(days) { pip in
                        pipButton(pip).id(pip.dayKey)
                    }
                }
                .padding(.horizontal, Aurora.Space.screenGutter)
            }
            .onAppear { center(proxy, animated: false) }
            .onChangeCompat(of: selection) { _ in center(proxy, animated: true) }
            .onChangeCompat(of: railSignature) { _ in center(proxy, animated: false) }
        }
    }

    /// Changes whenever the backing window of days is replaced, so the rail re-centres
    /// after a reload instead of sitting at whatever offset the old data left behind.
    private var railSignature: String {
        "\(days.count)|\(days.first?.dayKey ?? "")|\(days.last?.dayKey ?? "")"
    }

    private func center(_ proxy: ScrollViewProxy, animated: Bool) {
        guard days.contains(where: { $0.dayKey == selection }) else { return }
        if animated, !reduceMotion {
            withAnimation(Aurora.Motion.slow) { proxy.scrollTo(selection, anchor: .center) }
        } else {
            proxy.scrollTo(selection, anchor: .center)
        }
    }

    // MARK: Pip

    @ViewBuilder
    private func pipButton(_ pip: AuroraDayPip) -> some View {
        let isSelected = pip.dayKey == selection
        let isToday = Calendar.current.isDateInToday(pip.date)
        let tint: Color = pip.recovery.map { Aurora.recoveryColor($0) } ?? Aurora.textDisabled

        Button {
            select(pip)
        } label: {
            VStack(spacing: 5) {
                Text(Self.weekdayInitial(pip.date))
                    .font(AuroraType.number(10, weight: .semibold))
                    .foregroundStyle(isSelected ? Aurora.textPrimary : Aurora.textTertiary)

                ZStack {
                    // The selection ring. Always present, scaled and faded so the change
                    // is a movement rather than an insertion.
                    Circle()
                        .strokeBorder(tint.opacity(0.60), lineWidth: 1.5)
                        .frame(width: 30, height: 30)
                        .opacity(isSelected ? 1 : 0)
                        .scaleEffect(isSelected ? 1 : 0.68)

                    Group {
                        if pip.recovery == nil {
                            Circle().strokeBorder(Aurora.hairlineStrong, lineWidth: 1.5)
                        } else {
                            Circle().fill(tint)
                        }
                    }
                    .frame(width: isSelected ? 17 : 10, height: isSelected ? 17 : 10)
                    .shadow(color: (isSelected && pip.recovery != nil) ? tint.opacity(0.55) : .clear,
                            radius: 8)
                }
                .frame(height: Self.pipRow)

                Text(Self.footLabel(pip, isSelected: isSelected, isToday: isToday))
                    .font(AuroraType.number(9, weight: .semibold))
                    .tracking(0.3)
                    .foregroundStyle(isToday && !isSelected ? Aurora.textSecondary : Aurora.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(height: 11)
            }
            .frame(width: Self.itemWidth)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Aurora.Motion.respecting(Aurora.Motion.standard, reduced: reduceMotion),
                   value: isSelected)
        .accessibilityLabel(Text(Self.accessibilityLabel(pip)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func select(_ pip: AuroraDayPip) {
        guard pip.dayKey != selection else { return }
        withAnimation(Aurora.Motion.respecting(Aurora.Motion.standard, reduced: reduceMotion)) {
            selection = pip.dayKey
        }
        onSelect?(pip.dayKey)
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    // MARK: Labels

    /// The localized one-letter weekday symbol ("M", "T", …).
    private static func weekdayInitial(_ date: Date) -> String {
        let calendar = Calendar.current
        let index = calendar.component(.weekday, from: date) - 1
        let symbols = calendar.veryShortWeekdaySymbols
        guard index >= 0, index < symbols.count else { return "" }
        return symbols[index]
    }

    /// The foot label is reserved at a fixed height whether or not it has text, so the
    /// pips never shift vertically as the selection moves along the rail.
    private static func footLabel(_ pip: AuroraDayPip, isSelected: Bool, isToday: Bool) -> String {
        if isSelected {
            return isToday ? "TODAY" : pip.date.formatted(.dateTime.day().month(.abbreviated))
        }
        return isToday ? "·" : ""
    }

    private static func accessibilityLabel(_ pip: AuroraDayPip) -> String {
        let day = pip.date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        guard let recovery = pip.recovery else { return "\(day), no reading" }
        let band = AuroraRecoveryBand(pct: recovery)
        return "\(day), recovery \(Int(recovery.rounded())) percent, \(band.label.lowercased())"
    }
}

// MARK: - AuroraBandWash

/// The full-bleed colour wash that sits behind a hero.
///
/// This is the component that makes an Aurora screen legible from across a room. A large,
/// very soft radial bloom in the band's colour bleeds out of the hero and dissolves into
/// the canvas, and a vignette pulls the corners down so the bloom reads as light rather
/// than as a painted rectangle. Alphas are deliberately low — the wash must never fight
/// the numeral it sits behind, and at no intensity should text contrast drop below the
/// canvas baseline.
///
/// Use it as a background under `.ignoresSafeArea()`, usually via `.auroraBandWash(_:)`.
public struct AuroraBandWash: View {

    private let color: Color
    private let intensity: Double
    private let anchor: UnitPoint

    @Environment(\.colorScheme) private var scheme

    /// - Parameters:
    ///   - color: the band colour to wash with — typically `Aurora.recoveryColor(pct)` or
    ///     `AuroraRecoveryBand(pct:).color`.
    ///   - intensity: 0…1.4 multiplier on every alpha. `1` is the tuned default; drop to
    ///     ~0.5 behind dense content, raise past 1 only for a full-screen verdict.
    ///   - anchor: where the bloom originates. Default `.top` — directly behind the hero.
    public init(color: Color, intensity: Double = 1.0, anchor: UnitPoint = .top) {
        self.color = color
        self.intensity = max(intensity, 0)
        self.anchor = anchor
    }

    public var body: some View {
        GeometryReader { geo in
            let span = max(geo.size.width, geo.size.height)
            ZStack {
                // The bloom. Three stops so the falloff is perceptually smooth instead of
                // ending in the hard grey ring a two-stop radial always produces.
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: color.opacity(0.34 * intensity), location: 0.00),
                        .init(color: color.opacity(0.14 * intensity), location: 0.38),
                        .init(color: color.opacity(0.04 * intensity), location: 0.68),
                        .init(color: color.opacity(0.00), location: 1.00),
                    ]),
                    center: anchor,
                    startRadius: 0,
                    endRadius: span * 0.92
                )

                // A whisper of the band along the very top edge, so the wash still reads
                // when the hero itself is scrolled away.
                LinearGradient(
                    colors: [color.opacity(0.10 * intensity), .clear],
                    startPoint: .top,
                    endPoint: .center
                )

                // Vignette. Warm-neutral, not black, in light appearance — a black
                // vignette on a near-white canvas reads as dirt.
                RadialGradient(
                    gradient: Gradient(colors: [.clear, vignetteColor]),
                    center: .center,
                    startRadius: span * 0.30,
                    endRadius: span * 0.95
                )
            }
        }
        .allowsHitTesting(false)
        .animation(Aurora.Motion.slow, value: color)
    }

    private var vignetteColor: Color {
        scheme == .dark ? Color.black.opacity(0.38) : Color.black.opacity(0.055)
    }
}

public extension View {
    /// Paint an `AuroraBandWash` edge-to-edge behind this view, on top of the canvas.
    ///
    /// The canonical first two lines of an Aurora pillar screen:
    /// ```swift
    /// content
    ///     .auroraCanvas()
    ///     .auroraBandWash(Aurora.recoveryColor(recovery))
    /// ```
    func auroraBandWash(_ color: Color, intensity: Double = 1.0, anchor: UnitPoint = .top) -> some View {
        background(
            AuroraBandWash(color: color, intensity: intensity, anchor: anchor)
                .ignoresSafeArea()
        )
    }
}

// MARK: - Scroll offset plumbing

/// Carries a scroll view's vertical offset out of the content and up to the screen.
public struct AuroraScrollOffsetKey: PreferenceKey {
    public static let defaultValue: CGFloat = 0
    public static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// A zero-height probe placed as the FIRST element inside a scroll view's content.
///
/// It publishes how far the content has scrolled up, in points, as a non-negative number.
/// Pair it with `.auroraScrollSpace(_:)` on the `ScrollView` and
/// `.onAuroraScrollOffset(_:)` anywhere above it.
///
/// ```swift
/// ScrollView {
///     VStack(spacing: 0) {
///         AuroraScrollOffsetProbe(space: Self.space)
///         AuroraCollapsingHero(offset: offset) { hero } compact: { bar }
///         …
///     }
/// }
/// .auroraScrollSpace(Self.space)
/// .onAuroraScrollOffset { offset = $0 }
/// ```
public struct AuroraScrollOffsetProbe: View {

    private let space: String

    /// - Parameter space: the coordinate-space name, matching `.auroraScrollSpace(_:)`.
    public init(space: String) {
        self.space = space
    }

    public var body: some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: AuroraScrollOffsetKey.self,
                value: max(0, -geo.frame(in: .named(space)).minY)
            )
        }
        .frame(height: 0)
    }
}

public extension View {
    /// Name this scroll view's coordinate space for `AuroraScrollOffsetProbe`.
    func auroraScrollSpace(_ name: String) -> some View {
        coordinateSpace(name: name)
    }

    /// Observe the offset published by an `AuroraScrollOffsetProbe` in this subtree.
    func onAuroraScrollOffset(_ action: @escaping (CGFloat) -> Void) -> some View {
        onPreferenceChange(AuroraScrollOffsetKey.self) { action($0) }
    }
}

private struct AuroraHeroHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - AuroraCollapsingHero

/// A scroll-linked header that demotes a hero into an inline summary as the page is read.
///
/// One dominant statement owns the screen at rest. The moment the user starts reading
/// downward the hero has done its job, so it shrinks from its anchor, fades out, and hands
/// the top of the screen to a one-line compact summary that stays available while the user
/// works through the detail below. No third-party dependency and no `scrollTargetBehavior`:
/// the caller measures the offset with `AuroraScrollOffsetProbe` and passes it in, which
/// also means the same offset can drive a nav-bar title or a wash intensity in step.
///
/// The container's height interpolates between the hero's measured natural height and
/// `compactHeight`, so the content below travels smoothly rather than jumping at the
/// moment of the swap.
public struct AuroraCollapsingHero<Hero: View, Compact: View>: View {

    private let offset: CGFloat
    private let collapseDistance: CGFloat
    private let compactHeight: CGFloat
    private let minScale: CGFloat
    private let hero: Hero
    private let compact: Compact

    @State private var heroHeight: CGFloat = 0

    /// - Parameters:
    ///   - offset: points the content has scrolled up, `0` at rest. Feed it from
    ///     `AuroraScrollOffsetProbe` via `.onAuroraScrollOffset(_:)`.
    ///   - collapseDistance: how far the user must scroll for the collapse to complete.
    ///     Default 140. Shorter feels twitchy; longer feels unresponsive.
    ///   - compactHeight: the height the header settles at once collapsed. Default 44.
    ///   - minScale: the hero's scale at full collapse. Default 0.84 — enough to read as
    ///     receding, not so much that it looks like it fell down a hole.
    ///   - hero: the dominant statement. Measured; may be any height.
    ///   - compact: the inline summary that replaces it. Should fit `compactHeight`.
    public init(
        offset: CGFloat,
        collapseDistance: CGFloat = 140,
        compactHeight: CGFloat = 44,
        minScale: CGFloat = 0.84,
        @ViewBuilder hero: () -> Hero,
        @ViewBuilder compact: () -> Compact
    ) {
        self.offset = offset
        self.collapseDistance = max(collapseDistance, 1)
        self.compactHeight = compactHeight
        self.minScale = minScale
        self.hero = hero()
        self.compact = compact()
    }

    /// Collapse progress, 0 (hero at rest) … 1 (fully collapsed). Exposed as a computed
    /// property so the same easing is used for the height, the scale and the fades.
    private var t: Double {
        Double(min(max(offset / collapseDistance, 0), 1))
    }

    /// Height the container currently occupies. Falls back to `nil` (natural layout)
    /// until the hero has been measured, so the first frame is never a zero-height gap.
    private var currentHeight: CGFloat? {
        guard heroHeight > 0 else { return nil }
        return heroHeight + (compactHeight - heroHeight) * CGFloat(t)
    }

    public var body: some View {
        ZStack(alignment: .top) {
            hero
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: AuroraHeroHeightKey.self, value: geo.size.height)
                    }
                )
                // Fades out over the first 78% of the travel so the compact summary has
                // clear air to arrive into rather than cross-dissolving into a mush.
                .opacity(max(0, 1 - t / 0.78))
                .scaleEffect(1 - (1 - minScale) * CGFloat(t), anchor: .top)
                .allowsHitTesting(t < 0.4)

            compact
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: compactHeight)
                .opacity(max(0, (t - 0.55) / 0.45))
                .offset(y: 8 * (1 - CGFloat(t)))
                .allowsHitTesting(t > 0.6)
        }
        .frame(height: currentHeight, alignment: .top)
        .clipped()
        .onPreferenceChange(AuroraHeroHeightKey.self) { measured in
            if measured > 0, abs(measured - heroHeight) > 0.5 { heroHeight = measured }
        }
    }
}

public extension AuroraCollapsingHero where Compact == EmptyView {
    /// A hero that simply recedes, with nothing taking its place.
    init(
        offset: CGFloat,
        collapseDistance: CGFloat = 140,
        compactHeight: CGFloat = 0,
        minScale: CGFloat = 0.84,
        @ViewBuilder hero: () -> Hero
    ) {
        self.init(offset: offset,
                  collapseDistance: collapseDistance,
                  compactHeight: compactHeight,
                  minScale: minScale,
                  hero: hero,
                  compact: { EmptyView() })
    }
}

// MARK: - AuroraZoneSlice

/// One heart-rate zone's share of a session.
public struct AuroraZoneSlice: Identifiable, Equatable, Sendable {

    /// Zone number, 1…5. Used for identity and ordering only.
    public let zone: Int
    /// Display name — "Zone 3", "Threshold", "70–80%". The caller owns the vocabulary.
    public let label: String
    /// Time spent in this zone.
    public let seconds: TimeInterval
    /// An explicit colour, overriding the ramp sample. `nil` uses the bar's ramp.
    public let color: Color?

    public var id: Int { zone }

    /// - Parameters:
    ///   - zone: 1…5.
    ///   - label: the zone's display name.
    ///   - seconds: time in zone. Zero-length zones are kept (the legend still lists them)
    ///     but contribute no width to the bar.
    ///   - color: overrides the ramp sample for this segment.
    public init(zone: Int, label: String, seconds: TimeInterval, color: Color? = nil) {
        self.zone = zone
        self.label = label
        self.seconds = seconds
        self.color = color
    }
}

// MARK: - AuroraZoneBar

/// A stacked horizontal distribution of time-in-zone.
///
/// A zone table is a readout; this is a shape. The proportions ARE the answer — a session
/// that lived in zone 2 and one that spiked into zone 5 look nothing alike from two metres
/// away, which is the whole point of putting the strain screen's composition here instead
/// of in five rows of numbers. Rounded outer caps and a hairline between segments keep the
/// bar reading as one object rather than five bricks.
///
/// The segments sweep in left-to-right on first appear (`Aurora.Motion.drawIn`), and the
/// sweep is suppressed under Reduce Motion.
public struct AuroraZoneBar: View {

    private let zones: [AuroraZoneSlice]
    private let height: CGFloat
    private let ramp: AuroraRamp
    private let showsLegend: Bool
    private let emptyHint: String

    @State private var reveal: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - zones: the slices, lowest zone first. Empty or all-zero renders `emptyHint`.
    ///   - height: bar thickness. Default 18.
    ///   - ramp: the colour ramp sampled across the zones. Default `.strain`, which is the
    ///     ramp the rest of the effort surface uses.
    ///   - showsLegend: draw the labelled rows beneath the bar. Default `true`.
    ///   - emptyHint: the caption shown when there is nothing to distribute.
    public init(
        zones: [AuroraZoneSlice],
        height: CGFloat = 18,
        ramp: AuroraRamp = .strain,
        showsLegend: Bool = true,
        emptyHint: String = "No zone data for this session"
    ) {
        self.zones = zones
        self.height = height
        self.ramp = ramp
        self.showsLegend = showsLegend
        self.emptyHint = emptyHint
    }

    private var total: TimeInterval {
        zones.reduce(0) { $0 + max($1.seconds, 0) }
    }

    private func color(for index: Int) -> Color {
        if let explicit = zones[index].color { return explicit }
        let denominator = max(zones.count - 1, 1)
        return ramp.color(at: Double(index) / Double(denominator))
    }

    private func fraction(_ slice: AuroraZoneSlice) -> Double {
        total > 0 ? max(slice.seconds, 0) / total : 0
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.s) {
            if zones.isEmpty || total <= 0 {
                Capsule(style: .continuous)
                    .fill(Aurora.surfaceInset)
                    .frame(height: height)
                Text(emptyHint).auroraCaption()
            } else {
                bar
                if showsLegend { legend }
            }
        }
        .onAppear {
            withAnimation(Aurora.Motion.respecting(Aurora.Motion.drawIn, reduced: reduceMotion)) {
                reveal = 1
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Time in zone"))
        .accessibilityValue(Text(accessibilitySummary))
    }

    private var bar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(Aurora.surfaceInset)
                HStack(spacing: 1) {
                    ForEach(Array(zones.enumerated()), id: \.element.id) { index, slice in
                        Rectangle()
                            .fill(color(for: index))
                            .frame(width: max(0, width * CGFloat(fraction(slice) * reveal)))
                    }
                    Spacer(minLength: 0)
                }
            }
            .clipShape(Capsule(style: .continuous))
        }
        .frame(height: height)
    }

    private var legend: some View {
        VStack(spacing: Aurora.Space.xs) {
            ForEach(Array(zones.enumerated()), id: \.element.id) { index, slice in
                HStack(spacing: Aurora.Space.xs) {
                    Circle()
                        .fill(color(for: index))
                        .frame(width: 7, height: 7)
                    Text(slice.label)
                        .auroraLabel()
                    Spacer(minLength: Aurora.Space.xs)
                    Text("\(Int((fraction(slice) * 100).rounded()))%")
                        .font(AuroraType.tabularLabel)
                        .foregroundStyle(Aurora.textTertiary)
                    Text(AuroraFormat.duration(slice.seconds))
                        .font(AuroraType.number(13, weight: .semibold))
                        .foregroundStyle(Aurora.textPrimary)
                        .frame(minWidth: 56, alignment: .trailing)
                }
            }
        }
    }

    private var accessibilitySummary: String {
        zones
            .filter { $0.seconds > 0 }
            .map { "\($0.label) \(AuroraFormat.duration($0.seconds))" }
            .joined(separator: ", ")
    }
}

// MARK: - AuroraNeedBar

/// The composition of a night's sleep NEED, with the sleep ACHIEVED overlaid on it.
///
/// "You needed 8h 10m" is an assertion; this is the evidence. The bar stacks the three
/// things need is made of — the physiological baseline, accumulated debt, and the extra
/// the day's strain bought — and then fills only as far as the user actually slept. The
/// unfilled remainder is the shortfall, rendered as a ghost of the same stack so it is
/// obvious *which part* of the need went unmet, and an overshoot past the need is drawn
/// as a green tail. One shape answers "how much, made of what, and did I get there".
///
/// All inputs are seconds and are supplied already computed — this view does no sleep
/// maths whatsoever.
public struct AuroraNeedBar: View {

    private let baseline: TimeInterval
    private let debt: TimeInterval
    private let strain: TimeInterval
    private let achieved: TimeInterval?
    private let height: CGFloat
    private let showsLegend: Bool
    private let showsSummary: Bool

    @State private var reveal: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The baseline segment's colour — the sleep ramp's mid depth.
    public static let baselineTint: Color = Aurora.sleepColor(62)
    /// The debt segment's colour — caution, because debt is a thing to clear.
    public static let debtTint: Color = Aurora.statusCaution
    /// The strain-contribution segment's colour, borrowed from the effort ramp so the
    /// sleep screen and the strain screen agree about what "strain" is coloured.
    public static let strainTint: Color = Aurora.strainColor(13)

    /// - Parameters:
    ///   - baseline: the baseline sleep need, in seconds.
    ///   - debt: the accumulated sleep-debt contribution, in seconds. Pass `0` if none.
    ///   - strain: the strain-driven contribution, in seconds. Pass `0` if none.
    ///   - achieved: sleep actually attained, in seconds, or `nil` when the night has no
    ///     reading — the bar then shows the need composition alone, with no marker.
    ///   - height: bar thickness. Default 26 — thicker than a zone bar because three
    ///     segments plus a marker need the room.
    ///   - showsLegend: draw the labelled component rows. Default `true`.
    ///   - showsSummary: draw the "6h 12m of 7h 40m" line above the bar. Default `true`.
    public init(
        baseline: TimeInterval,
        debt: TimeInterval,
        strain: TimeInterval,
        achieved: TimeInterval?,
        height: CGFloat = 26,
        showsLegend: Bool = true,
        showsSummary: Bool = true
    ) {
        self.baseline = max(baseline, 0)
        self.debt = max(debt, 0)
        self.strain = max(strain, 0)
        self.achieved = achieved.map { max($0, 0) }
        self.height = height
        self.showsLegend = showsLegend
        self.showsSummary = showsSummary
    }

    private var need: TimeInterval { baseline + debt + strain }

    /// The bar's full-width value. Headroom is granted only when the user overshot, so a
    /// met need still fills the bar completely.
    private var scaleMax: TimeInterval {
        max(need, achieved ?? 0, 1) * 1.02
    }

    private var shortfall: TimeInterval? {
        guard let achieved else { return nil }
        return achieved - need
    }

    private var markerTint: Color {
        guard let shortfall else { return Aurora.textTertiary }
        return shortfall >= -15 * 60 ? Aurora.statusGood : Aurora.statusAlert
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.s) {
            if showsSummary { summary }
            bar
            if showsLegend { legend }
        }
        .onAppear {
            withAnimation(Aurora.Motion.respecting(Aurora.Motion.drawIn, reduced: reduceMotion)) {
                reveal = 1
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Sleep need"))
        .accessibilityValue(Text(accessibilitySummary))
    }

    // MARK: Summary

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: Aurora.Space.xs) {
            if let achieved {
                Text(AuroraFormat.clock(achieved))
                    .font(AuroraType.number(20, weight: .bold))
                    .foregroundStyle(Aurora.textPrimary)
                Text("of \(AuroraFormat.clock(need))")
                    .auroraCaption()
            } else {
                Text(AuroraFormat.clock(need))
                    .font(AuroraType.number(20, weight: .bold))
                    .foregroundStyle(Aurora.textPrimary)
                Text("needed").auroraCaption()
            }
            Spacer(minLength: Aurora.Space.xs)
            if let shortfall {
                AuroraStatusPill(
                    shortfall >= -15 * 60 ? "Met" : "\(AuroraFormat.duration(-shortfall)) short",
                    style: .tinted,
                    overrideColor: markerTint
                )
            }
        }
    }

    // MARK: Bar

    private var bar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let achievedX = min(width, width * CGFloat((achieved ?? need) / scaleMax) * CGFloat(reveal))

            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(Aurora.surfaceInset)

                // Overshoot tail, drawn under the stack so the stack's cap stays crisp.
                if let shortfall, shortfall > 0 {
                    Rectangle()
                        .fill(Aurora.statusGood.opacity(0.30))
                        .frame(width: achievedX)
                }

                // The ghost: the whole need, faint. This is the shortfall made visible.
                stack(width: width).opacity(achieved == nil ? 1 : 0.26)

                // The filled portion: the same stack, masked to what was actually slept.
                if achieved != nil {
                    stack(width: width)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: achievedX)
                        }
                }
            }
            .clipShape(Capsule(style: .continuous))
            .overlay(alignment: .leading) {
                if achieved != nil {
                    // The marker deliberately overhangs the bar top and bottom so it reads
                    // as a measurement against the bar, not as another segment of it.
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(markerTint)
                        .frame(width: 3, height: height + 12)
                        .shadow(color: markerTint.opacity(0.5), radius: 5)
                        .offset(x: max(0, achievedX - 1.5))
                }
            }
        }
        .frame(height: height)
    }

    private func stack(width: CGFloat) -> some View {
        HStack(spacing: 1) {
            segment(baseline, width: width, tint: Self.baselineTint)
            segment(debt, width: width, tint: Self.debtTint)
            segment(strain, width: width, tint: Self.strainTint)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func segment(_ seconds: TimeInterval, width: CGFloat, tint: Color) -> some View {
        if seconds > 0 {
            Rectangle()
                .fill(tint)
                .frame(width: max(0, width * CGFloat(seconds / scaleMax) * CGFloat(reveal)))
        }
    }

    // MARK: Legend

    private var legend: some View {
        VStack(spacing: Aurora.Space.xs) {
            legendRow("Baseline", seconds: baseline, tint: Self.baselineTint)
            if debt > 0 { legendRow("Sleep debt", seconds: debt, tint: Self.debtTint) }
            if strain > 0 { legendRow("Strain", seconds: strain, tint: Self.strainTint) }
        }
    }

    private func legendRow(_ label: String, seconds: TimeInterval, tint: Color) -> some View {
        HStack(spacing: Aurora.Space.xs) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(label).auroraLabel()
            Spacer(minLength: Aurora.Space.xs)
            Text(AuroraFormat.duration(seconds))
                .font(AuroraType.number(13, weight: .semibold))
                .foregroundStyle(Aurora.textPrimary)
        }
    }

    private var accessibilitySummary: String {
        var parts = ["needed \(AuroraFormat.duration(need))"]
        if let achieved { parts.append("slept \(AuroraFormat.duration(achieved))") }
        if let shortfall, shortfall < -15 * 60 {
            parts.append("\(AuroraFormat.duration(-shortfall)) short")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - AuroraRollingNumber

/// The hero numeral, alive.
///
/// It counts up from zero on first appear and rolls to the new value whenever the
/// selected day changes, which is what makes the day rail feel connected to the number it
/// governs rather than merely adjacent to it. Digits are monospaced and tabular so a roll
/// through 9 → 10 → 100 never reflows the layout or jitters the surrounding chrome.
///
/// The interpolation runs through `AuroraAnimatedValue`, so SwiftUI produces a real
/// per-frame sweep instead of a single jump; Reduce Motion collapses it to a plain set.
public struct AuroraRollingNumber: View {

    private let value: Double?
    private let unit: String?
    private let size: CGFloat
    private let decimals: Int
    private let weight: Font.Weight
    private let color: Color?
    private let placeholder: String

    @State private var shown: Double = 0
    @State private var hasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - value: the number, or `nil` for "no reading" (renders `placeholder`).
    ///   - unit: an optional trailing unit, set one rank quieter on the numeral's baseline.
    ///   - size: point size. Default 84 — the Aurora hero size. Anything under ~40 should
    ///     use `AuroraValueUnit` instead; a rolling small number is noise.
    ///   - decimals: fraction digits. Default 0.
    ///   - weight: numeral weight. Default `.heavy`.
    ///   - color: the numeral's colour. `nil` uses `Aurora.textPrimary`; pass a sampled
    ///     ramp colour to make the number itself carry the band.
    ///   - placeholder: shown when `value` is `nil`. Default an em dash.
    public init(
        value: Double?,
        unit: String? = nil,
        size: CGFloat = 84,
        decimals: Int = 0,
        weight: Font.Weight = .heavy,
        color: Color? = nil,
        placeholder: String = "—"
    ) {
        self.value = value
        self.unit = unit
        self.size = size
        self.decimals = max(decimals, 0)
        self.weight = weight
        self.color = color
        self.placeholder = placeholder
    }

    private var numeralFont: Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Aurora.Space.xxs) {
            if value == nil {
                Text(placeholder)
                    .font(numeralFont)
                    .tracking(-size * 0.04)
                    .foregroundStyle(Aurora.textTertiary)
            } else {
                AuroraAnimatedValue(shown) { interpolated in
                    Text(interpolated, format: .number.precision(.fractionLength(decimals)))
                        .font(numeralFont)
                        .tracking(-size * 0.04)
                        .foregroundStyle(color ?? Aurora.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                if let unit, !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: max(size * 0.22, 12), weight: .semibold, design: .rounded))
                        .foregroundStyle(Aurora.textTertiary)
                }
            }
        }
        .onAppear(perform: countIn)
        .onChangeCompat(of: value) { _ in roll() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    private func countIn() {
        guard !hasAppeared else { return }
        hasAppeared = true
        guard let value else { shown = 0; return }
        if reduceMotion {
            shown = value
        } else {
            shown = 0
            withAnimation(Aurora.Motion.drawIn) { shown = value }
        }
    }

    private func roll() {
        guard let value else { return }
        withAnimation(Aurora.Motion.respecting(Aurora.Motion.standard, reduced: reduceMotion)) {
            shown = value
        }
    }

    private var accessibilityText: String {
        guard let value else { return placeholder }
        let formatted = value.formatted(.number.precision(.fractionLength(decimals)))
        guard let unit, !unit.isEmpty else { return formatted }
        return "\(formatted) \(unit)"
    }
}

// MARK: - AuroraCoachLine

/// The interpretive one-liner that follows every hero.
///
/// Aurora's rule is that a screen never leaves the user to interpret a number. The line is
/// plain English and short, and its key phrase burns in the band colour so the verdict is
/// legible even when the sentence is not read — "**Primed.** Push today." carries at
/// arm's length; "Recovery 82%" does not.
///
/// Colour is applied per-run via `Text` concatenation rather than `AttributedString`,
/// because `Text.foregroundStyle` is iOS 17 / macOS 14 and the macOS target is 13.
public struct AuroraCoachLine: View {

    private let text: String
    private let emphasis: String?
    private let tint: Color
    private let icon: String?
    private let size: CGFloat

    /// - Parameters:
    ///   - text: the whole sentence, including the emphasised phrase.
    ///   - emphasis: the substring to burn in `tint`. Matched case-sensitively on first
    ///     occurrence; a phrase that is not found simply leaves the line unemphasised, so
    ///     a copy change can never crash or blank the line.
    ///   - tint: the band colour for the emphasised phrase. Default `Aurora.textPrimary`.
    ///   - icon: an optional leading SF Symbol, drawn in `tint`.
    ///   - size: point size for the sentence. Default 15.
    public init(
        _ text: String,
        emphasis: String? = nil,
        tint: Color = Aurora.textPrimary,
        icon: String? = nil,
        size: CGFloat = 15
    ) {
        self.text = text
        self.emphasis = emphasis
        self.tint = tint
        self.icon = icon
        self.size = size
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Aurora.Space.xs) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: size * 0.8, weight: .semibold))
                    .foregroundStyle(tint)
            }
            composed
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(text))
    }

    private var regularFont: Font { .system(size: size, weight: .regular, design: .rounded) }
    private var strongFont: Font { .system(size: size, weight: .semibold, design: .rounded) }

    private var composed: Text {
        guard let emphasis, !emphasis.isEmpty, let range = text.range(of: emphasis) else {
            return Text(text).font(regularFont).foregroundColor(Aurora.textSecondary)
        }
        let head = String(text[text.startIndex..<range.lowerBound])
        let key = String(text[range])
        let tail = String(text[range.upperBound...])
        return Text(head).font(regularFont).foregroundColor(Aurora.textSecondary)
            + Text(key).font(strongFont).foregroundColor(tint)
            + Text(tail).font(regularFont).foregroundColor(Aurora.textSecondary)
    }
}

public extension AuroraCoachLine {

    /// The house coaching line for a recovery percentage.
    ///
    /// Copy lives here rather than in each screen so the same score never gets two
    /// different verdicts in two places. This is presentation only — the band comes
    /// straight from `AuroraRecoveryBand(pct:)` and no score is computed or altered.
    static func forRecovery(_ pct: Double?) -> AuroraCoachLine {
        guard let pct else {
            return AuroraCoachLine("No reading yet. Wear the strap overnight to see a recovery.",
                                   emphasis: "No reading yet.",
                                   tint: Aurora.textTertiary)
        }
        let band = AuroraRecoveryBand(pct: pct)
        let tint = Aurora.recoveryColor(pct)
        switch band {
        case .peak:
            return AuroraCoachLine("Peak. Your body is ready for the hardest session of the week.",
                                   emphasis: "Peak.", tint: tint)
        case .primed:
            return AuroraCoachLine("Primed. Push today — you have room for real intensity.",
                                   emphasis: "Primed.", tint: tint)
        case .moderate:
            return AuroraCoachLine("Moderate. Train, but keep something in reserve.",
                                   emphasis: "Moderate.", tint: tint)
        case .low:
            return AuroraCoachLine("Low. Take it easy — steady aerobic work only.",
                                   emphasis: "Low.", tint: tint)
        case .depleted:
            return AuroraCoachLine("Depleted. Rest today. Sleep is the session.",
                                   emphasis: "Depleted.", tint: tint)
        }
    }

    /// The house coaching line for a strain value on a 0…21 scale.
    static func forStrain(_ value: Double?, scale: Double = 21) -> AuroraCoachLine {
        guard let value else {
            return AuroraCoachLine("Nothing logged yet today.",
                                   emphasis: "Nothing logged",
                                   tint: Aurora.textTertiary)
        }
        let tint = Aurora.strainColor(value, scale: scale)
        let fraction = scale > 0 ? value / scale : 0
        switch fraction {
        case ..<0.25:
            return AuroraCoachLine("Light day. Plenty of headroom left before you dip into recovery.",
                                   emphasis: "Light day.", tint: tint)
        case ..<0.50:
            return AuroraCoachLine("Moderate load. A solid, repeatable day.",
                                   emphasis: "Moderate load.", tint: tint)
        case ..<0.75:
            return AuroraCoachLine("Hard day. Expect tomorrow's recovery to reflect it.",
                                   emphasis: "Hard day.", tint: tint)
        default:
            return AuroraCoachLine("All out. Protect tonight's sleep or you will pay for this.",
                                   emphasis: "All out.", tint: tint)
        }
    }

    /// The house coaching line for a sleep-performance percentage (slept ÷ needed).
    static func forSleepPerformance(_ pct: Double?) -> AuroraCoachLine {
        guard let pct else {
            return AuroraCoachLine("No sleep recorded for this night.",
                                   emphasis: "No sleep recorded",
                                   tint: Aurora.textTertiary)
        }
        let tint = Aurora.sleepColor(pct)
        switch pct {
        case 95...:
            return AuroraCoachLine("Fully rested. You met your need in full.",
                                   emphasis: "Fully rested.", tint: Aurora.statusGood)
        case 85..<95:
            return AuroraCoachLine("Close to need. A short lie-in would close the gap.",
                                   emphasis: "Close to need.", tint: tint)
        case 70..<85:
            return AuroraCoachLine("Under-slept. The debt is starting to accumulate.",
                                   emphasis: "Under-slept.", tint: Aurora.statusCaution)
        default:
            return AuroraCoachLine("Badly short. Make tonight an early one.",
                                   emphasis: "Badly short.", tint: Aurora.statusAlert)
        }
    }
}

// MARK: - AuroraPillarCard

/// A full-width doorway to a pillar screen.
///
/// The overview stops being a grid of equal tiles — a grid says "these are all the same
/// and none of them matters most" — and becomes a short vertical stack of pillars, each
/// one a large value, its verdict, a compact shape and a chevron. Tapping pushes the
/// pillar's own screen, which is where the depth lives. That is the progressive-disclosure
/// contract: the overview summarises and never explains.
///
/// The leading colour spine is the card's most important detail. It is the pillar's band
/// colour, full height, and it is what lets the eye triage three pillars in one pass.
public struct AuroraPillarCard<Accessory: View>: View {

    private let title: String
    private let value: String
    private let unit: String?
    private let band: String?
    private let tint: Color
    private let coach: String?
    private let emphasis: String?
    private let icon: String?
    private let action: (() -> Void)?
    private let accessory: Accessory

    /// - Parameters:
    ///   - title: the pillar's name — "RECOVERY", "SLEEP", "STRAIN". Set as a section rule
    ///     in `tint`, so it is a colour-coded overline rather than a heading.
    ///   - value: the already-formatted headline value ("82", "7:12", "14.6").
    ///   - unit: the trailing unit ("%", "h"), or `nil`.
    ///   - band: an optional verdict pill on the trailing edge ("PRIMED", "MET").
    ///   - tint: the pillar's band colour. Drives the spine, the overline, the pill and
    ///     the coach line's emphasis.
    ///   - coach: the one-line interpretation. `nil` omits the line entirely.
    ///   - emphasis: the phrase inside `coach` to burn in `tint`.
    ///   - icon: an optional SF Symbol beside the title.
    ///   - action: the push. `nil` renders a non-interactive card with no chevron.
    ///   - accessory: a compact shape — an `AuroraSparkline`, an `AuroraArcGauge`, a ring.
    ///     Give it an explicit frame; the card does not size it for you.
    public init(
        title: String,
        value: String,
        unit: String? = nil,
        band: String? = nil,
        tint: Color,
        coach: String? = nil,
        emphasis: String? = nil,
        icon: String? = nil,
        action: (() -> Void)? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.value = value
        self.unit = unit
        self.band = band
        self.tint = tint
        self.coach = coach
        self.emphasis = emphasis
        self.icon = icon
        self.action = action
        self.accessory = accessory()
    }

    public var body: some View {
        Group {
            if let action {
                Button(action: action) { card }
                    .buttonStyle(.auroraPress)
            } else {
                card
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(action == nil ? [] : .isButton)
    }

    private var card: some View {
        AuroraCard(elevation: .base, padding: 0, radius: Aurora.Radius.card, tint: tint) {
            HStack(spacing: 0) {
                // The spine. Full height, band-coloured, fading downward so it reads as
                // lit rather than as a printed stripe.
                Rectangle()
                    .fill(LinearGradient(colors: [tint, tint.opacity(0.30)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 4)

                VStack(alignment: .leading, spacing: Aurora.Space.xs) {
                    HStack(spacing: Aurora.Space.xs) {
                        if let icon {
                            Image(systemName: icon)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(tint)
                        }
                        Text(title)
                            .auroraSectionHeader()
                            .foregroundStyle(tint)
                        Spacer(minLength: Aurora.Space.xs)
                        if let band {
                            AuroraStatusPill(band, style: .tinted, overrideColor: tint)
                        }
                    }

                    HStack(alignment: .center, spacing: Aurora.Space.m) {
                        AuroraValueUnit(value: value, unit: unit, role: .metricLarge)
                        Spacer(minLength: Aurora.Space.xs)
                        accessory
                        if action != nil {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Aurora.textTertiary)
                        }
                    }

                    if let coach, !coach.isEmpty {
                        AuroraCoachLine(coach, emphasis: emphasis, tint: tint, size: 14)
                    }
                }
                .padding(Aurora.Space.cardPadding)
            }
            .clipShape(RoundedRectangle(cornerRadius: Aurora.Radius.card, style: .continuous))
        }
    }

    private var accessibilityLabel: String {
        var parts = [title, value]
        if let unit { parts.append(unit) }
        if let band { parts.append(band) }
        if let coach { parts.append(coach) }
        return parts.joined(separator: ", ")
    }
}

public extension AuroraPillarCard where Accessory == EmptyView {
    /// A pillar card with no compact shape — value, verdict and coaching only.
    init(
        title: String,
        value: String,
        unit: String? = nil,
        band: String? = nil,
        tint: Color,
        coach: String? = nil,
        emphasis: String? = nil,
        icon: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.init(title: title,
                  value: value,
                  unit: unit,
                  band: band,
                  tint: tint,
                  coach: coach,
                  emphasis: emphasis,
                  icon: icon,
                  action: action,
                  accessory: { EmptyView() })
    }
}

#if DEBUG

private struct AuroraSignaturePreviewHost: View {
    @State private var selection = "2026-08-27"
    @State private var offset: CGFloat = 0

    private static let space = "aurora.signature.preview"

    private var days: [AuroraDayPip] {
        let calendar = Calendar.current
        let recoveries: [Double?] = [41, 58, nil, 72, 88, 34, 66, 91, 55]
        return recoveries.enumerated().compactMap { index, recovery in
            guard let date = calendar.date(byAdding: .day, value: index - 8, to: Date()) else { return nil }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            let key = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            return AuroraDayPip(dayKey: key, date: date, recovery: recovery)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            AuroraDayRail(days: days, selection: $selection)

            ScrollView {
                VStack(spacing: 0) {
                    AuroraScrollOffsetProbe(space: Self.space)

                    AuroraCollapsingHero(offset: offset) {
                        VStack(spacing: Aurora.Space.xs) {
                            AuroraRollingNumber(value: 82, unit: "%", color: Aurora.recoveryColor(82))
                            AuroraCoachLine.forRecovery(82)
                        }
                        .padding(.vertical, Aurora.Space.xl)
                        .auroraGutter()
                    } compact: {
                        HStack {
                            Text("Recovery").auroraHeadline()
                            Spacer()
                            Text("82%").auroraMetricSmall()
                        }
                        .auroraGutter()
                    }

                    VStack(spacing: Aurora.Space.cardGap) {
                        AuroraPillarCard(
                            title: "Sleep",
                            value: "6:41",
                            unit: "h",
                            band: "SHORT",
                            tint: Aurora.sleepColor(72),
                            coach: "Under-slept. The debt is starting to accumulate.",
                            emphasis: "Under-slept.",
                            icon: "moon.fill",
                            action: {}
                        )

                        AuroraCard {
                            AuroraNeedBar(baseline: 6.5 * 3600, debt: 40 * 60,
                                          strain: 25 * 60, achieved: 6 * 3600 + 41 * 60)
                        }

                        AuroraCard {
                            AuroraZoneBar(zones: [
                                .init(zone: 1, label: "Zone 1", seconds: 22 * 60),
                                .init(zone: 2, label: "Zone 2", seconds: 31 * 60),
                                .init(zone: 3, label: "Zone 3", seconds: 14 * 60),
                                .init(zone: 4, label: "Zone 4", seconds: 6 * 60),
                                .init(zone: 5, label: "Zone 5", seconds: 90),
                            ])
                        }
                    }
                    .auroraGutter()
                    .padding(.bottom, Aurora.Space.xxxl)
                }
            }
            .auroraScrollSpace(Self.space)
            .onAuroraScrollOffset { offset = $0 }
        }
        .auroraCanvas()
        .auroraBandWash(Aurora.recoveryColor(82))
    }
}

#Preview("Aurora Signature") {
    AuroraSignaturePreviewHost()
}

#endif
