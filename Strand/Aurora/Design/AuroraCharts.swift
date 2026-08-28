import SwiftUI
import Charts
import StrandDesign

// MARK: - Aurora Charts
//
// The data-visualisation kit. Native Swift Charts where an axis and a scale earn their
// keep; `Canvas` where Aurora needs a shape Swift Charts cannot draw on macOS 13 (rounded
// bar caps, a stepped hypnogram, a hairline sparkline with a glowing head).
//
// FOUR RULES EVERY CHART HERE OBEYS.
//
// 1. COLOUR MEANS SOMETHING. A series is tinted by a ramp sampled at its own value, so a
//    depleted recovery arc is red and a peak one is green without a call site deciding.
//
// 2. EVERY CHART ANIMATES IN. A number that simply appears reads as static; a number that
//    arrives reads as measured. The sweep runs once on the house curve and is suppressed
//    entirely under Reduce Motion — where the final frame is shown instantly, never a
//    half-drawn arc.
//
// 3. EVERY CHART HANDLES EMPTY. No series is ever guaranteed: the strap was charging, the
//    night is not over, the import has not run. Empty renders a designed resting state
//    that keeps the chart's footprint, so a screen does not reflow as data lands.
//
// 4. macOS 13 IS A REAL TARGET. `Strand/**` compiles into both the macOS 13 app and the
//    iOS 17 app, so nothing here uses `chartXSelection`, `chartScrollPosition` or the
//    iOS-17 `onChange`. Scrubbing is a `DragGesture` over `chartOverlay`, hover is
//    `onContinuousHover` behind a platform guard, and the plot rect comes from
//    StrandDesign's `plotRectCompat(in:)` shim.

// MARK: - Animation driver

/// Drives a renderer that SwiftUI cannot animate on its own — a `Canvas` closure, a bit
/// of `Path` maths — with a smoothly interpolated value.
///
/// `Canvas` re-renders when its captured state changes, but SwiftUI only *interpolates*
/// values exposed through `Animatable`. Wrapping the canvas in this view makes the
/// progress an animatable attribute, so `withAnimation` produces a real per-frame sweep
/// instead of a single jump to the final value.
public struct AuroraAnimatedValue<Content: View>: View, Animatable {

    public var value: Double
    private let content: (Double) -> Content

    public var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    /// - Parameters:
    ///   - value: the value to interpolate (typically a 0…1 reveal fraction).
    ///   - content: builds the view for an interpolated value.
    public init(_ value: Double, @ViewBuilder content: @escaping (Double) -> Content) {
        self.value = value
        self.content = content
    }

    public var body: some View { content(value) }
}

/// Reports pointer position on macOS and does nothing on iOS, so a chart's scrub code can
/// be written once. Kept as a modifier because `#if` inside a modifier chain is fragile.
struct AuroraHoverReporter: ViewModifier {
    let onMove: (CGPoint?) -> Void

    func body(content: Content) -> some View {
        #if os(macOS)
        content.onContinuousHover { phase in
            switch phase {
            case .active(let point): onMove(point)
            case .ended: onMove(nil)
            }
        }
        #else
        content
        #endif
    }
}

// MARK: - AuroraRing
//
// THE hero component. It is the first thing a user sees each morning, and it has to carry
// the whole product's confidence in one shape.
//
// Anatomy, outermost in:
//   • an ambient bloom — a blurred copy of the arc, 45% opacity, sized to the stroke.
//     Atmosphere, not a shape: it should read only when you look away.
//   • a recessed track in `surfaceInset`, so the unfilled remainder is a groove the arc
//     sits in rather than a competing ring.
//   • the arc itself: an angular gradient of the full ramp across a full turn, so the
//     colour at the arc's TIP is exactly `ramp.color(at: progress)` — the value's own
//     colour, arrived at by travelling through every value below it.
//   • a rounded cap plus a bright tip bead, which is what makes the arc look like it was
//     drawn rather than clipped.
//   • the value, set enormous, tabular and tightly tracked, with the band name above it.

/// An animated radial progress ring with a gradient arc, soft glow and a large centred
/// value. Aurora's signature component — Charge, Effort and Rest all render as one.
public struct AuroraRing: View {

    private let progress: Double?
    private let value: String?
    private let unit: String?
    private let label: String?
    private let caption: String?
    private let ramp: AuroraRamp
    private let lineWidth: CGFloat
    private let size: CGFloat?
    private let showsGlow: Bool
    private let showsTip: Bool
    private let emptyHint: String

    @State private var sweep: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - progress: fill fraction 0…1, or `nil` for the empty state (a dashed track and
    ///     a placeholder value — the ring keeps its exact footprint).
    ///   - value: the already-formatted centre numeral (e.g. `"88"`, `"14.2"`).
    ///   - unit: an optional unit set beside the numeral (e.g. `"%"`).
    ///   - label: an uppercase overline above the value (e.g. `"RECOVERY"`).
    ///   - caption: one quiet line beneath the value (e.g. `"PRIMED"`, `"vs 7-day avg"`).
    ///   - ramp: the semantic ramp painted along the arc. Default recovery.
    ///   - lineWidth: arc thickness. Default `Aurora.Stroke.ring` (16).
    ///   - size: fixed diameter, or `nil` to fill the space offered by the parent.
    ///   - showsGlow: draw the ambient bloom behind the arc. Default `true`.
    ///   - showsTip: draw the bright bead at the arc's leading end. Default `true`.
    ///   - emptyHint: the caption shown when `progress` is `nil`.
    public init(
        progress: Double?,
        value: String? = nil,
        unit: String? = nil,
        label: String? = nil,
        caption: String? = nil,
        ramp: AuroraRamp = .recovery,
        lineWidth: CGFloat = Aurora.Stroke.ring,
        size: CGFloat? = nil,
        showsGlow: Bool = true,
        showsTip: Bool = true,
        emptyHint: String = "No reading yet"
    ) {
        self.progress = progress
        self.value = value
        self.unit = unit
        self.label = label
        self.caption = caption
        self.ramp = ramp
        self.lineWidth = lineWidth
        self.size = size
        self.showsGlow = showsGlow
        self.showsTip = showsTip
        self.emptyHint = emptyHint
    }

    private var target: Double { min(max(progress ?? 0, 0), 1) }
    private var isEmpty: Bool { progress == nil }
    private var tipColor: Color { ramp.color(at: sweep) }

    public var body: some View {
        Group {
            if let size {
                ring(diameter: size).frame(width: size, height: size)
            } else {
                GeometryReader { geo in
                    let d = min(geo.size.width, geo.size.height)
                    ring(diameter: d)
                        .frame(width: d, height: d)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .aspectRatio(1, contentMode: .fit)
            }
        }
        .onAppear { animate(to: target) }
        .onChangeCompat(of: target) { newValue in animate(to: newValue) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    private func animate(to newValue: Double) {
        withAnimation(Aurora.Motion.respecting(Aurora.Motion.drawIn, reduced: reduceMotion)) {
            sweep = newValue
        }
    }

    // MARK: Ring body

    @ViewBuilder
    private func ring(diameter: CGFloat) -> some View {
        let radius = (diameter - lineWidth) / 2

        ZStack {
            // 1 — ambient bloom.
            if showsGlow && !isEmpty {
                Circle()
                    .trim(from: 0, to: sweep)
                    .stroke(arcGradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(lineWidth / 2)
                    .blur(radius: lineWidth * 0.85)
                    .opacity(0.45)
                    .allowsHitTesting(false)
            }

            // 2 — the recessed track.
            Circle()
                .stroke(
                    Aurora.surfaceInset,
                    style: StrokeStyle(
                        lineWidth: lineWidth,
                        lineCap: .round,
                        dash: isEmpty ? [2, lineWidth * 0.75] : []
                    )
                )
                .padding(lineWidth / 2)

            // 3 — the arc.
            if !isEmpty {
                Circle()
                    .trim(from: 0, to: sweep)
                    .stroke(arcGradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(lineWidth / 2)
            }

            // 4 — the tip bead. Offset then rotated: `offset` does not change the layout
            // frame, so `rotationEffect` still pivots about the ring's centre and the bead
            // orbits the arc exactly.
            if showsTip && !isEmpty && sweep > 0.005 {
                Circle()
                    .fill(Aurora.textOnAccent)
                    .frame(width: lineWidth * 0.34, height: lineWidth * 0.34)
                    .shadow(color: tipColor.opacity(0.9), radius: lineWidth * 0.4)
                    .offset(y: -radius)
                    .rotationEffect(.degrees(360 * sweep))
                    .allowsHitTesting(false)
            }

            // 5 — the centre stack.
            center(diameter: diameter)
                .padding(lineWidth * 1.6)
        }
    }

    private var arcGradient: AngularGradient {
        // A full turn of the ramp, so the arc's tip colour equals the value's colour.
        AngularGradient(
            gradient: ramp.gradient,
            center: .center,
            startAngle: .degrees(0),
            endAngle: .degrees(360)
        )
    }

    @ViewBuilder
    private func center(diameter: CGFloat) -> some View {
        let valueSize = min(max(diameter * 0.30, 26), 76)

        VStack(spacing: Aurora.Space.xxs) {
            if let label {
                Text(label)
                    .auroraSectionHeader()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value ?? "–")
                    .font(AuroraType.display(valueSize))
                    .tracking(AuroraType.displayTracking(valueSize))
                    .foregroundStyle(isEmpty ? Aurora.textDisabled : Aurora.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let unit, !isEmpty {
                    Text(unit)
                        .font(AuroraType.number(valueSize * 0.30, weight: .semibold))
                        .foregroundStyle(Aurora.textTertiary)
                }
            }

            if isEmpty {
                Text(emptyHint)
                    .auroraFootnote()
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            } else if let caption {
                Text(caption)
                    .auroraCaptionStrong()
                    .foregroundStyle(tipColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .multilineTextAlignment(.center)
    }

    private var accessibilityText: String {
        guard let progress else { return "\(label ?? "Ring"), \(emptyHint)" }
        let pct = Int((min(max(progress, 0), 1) * 100).rounded())
        let head = label.map { "\($0), " } ?? ""
        let val = value.map { "\($0)\(unit ?? "")" } ?? "\(pct) percent"
        let tail = caption.map { ", \($0)" } ?? ""
        return head + val + tail
    }
}

// MARK: - AuroraArcGauge

/// A 240° arc gauge — the ring's shallower sibling.
///
/// The open bottom is the point: an arc that does not close reads as a *scale with a
/// position on it*, where a full ring reads as a *proportion of a whole*. Use this for
/// values that live on a range (strain on 0…21, a temperature deviation) and the ring for
/// values that are genuinely a percentage of something.
public struct AuroraArcGauge: View {

    private let progress: Double?
    private let value: String?
    private let unit: String?
    private let label: String?
    private let caption: String?
    private let ramp: AuroraRamp
    private let lineWidth: CGFloat
    private let sweepDegrees: Double
    private let showsTicks: Bool
    private let emptyHint: String

    @State private var sweep: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - progress: fill fraction 0…1, or `nil` for the empty state.
    ///   - value: the already-formatted centre numeral.
    ///   - unit: optional trailing unit.
    ///   - label: uppercase overline above the value.
    ///   - caption: quiet line beneath the value.
    ///   - ramp: the semantic ramp painted along the arc. Default strain.
    ///   - lineWidth: arc thickness. Default `Aurora.Stroke.ringCompact` (10).
    ///   - sweepDegrees: total arc sweep, centred on the top. Default `240`.
    ///   - showsTicks: draw the start / mid / end scale ticks. Default `true`.
    ///   - emptyHint: caption shown when `progress` is `nil`.
    public init(
        progress: Double?,
        value: String? = nil,
        unit: String? = nil,
        label: String? = nil,
        caption: String? = nil,
        ramp: AuroraRamp = .strain,
        lineWidth: CGFloat = Aurora.Stroke.ringCompact,
        sweepDegrees: Double = 240,
        showsTicks: Bool = true,
        emptyHint: String = "No reading yet"
    ) {
        self.progress = progress
        self.value = value
        self.unit = unit
        self.label = label
        self.caption = caption
        self.ramp = ramp
        self.lineWidth = lineWidth
        self.sweepDegrees = sweepDegrees
        self.showsTicks = showsTicks
        self.emptyHint = emptyHint
    }

    private var target: Double { min(max(progress ?? 0, 0), 1) }
    private var isEmpty: Bool { progress == nil }
    /// Start angle in SwiftUI's 0°-at-3-o'clock, clockwise coordinate system, so the arc
    /// is centred on 12 o'clock whatever the sweep.
    private var startAngle: Double { 90 + (360 - sweepDegrees) / 2 }

    public var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                AuroraArcShape(startDegrees: startAngle, sweepDegrees: sweepDegrees, progress: 1)
                    .stroke(
                        Aurora.surfaceInset,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round,
                                           dash: isEmpty ? [2, lineWidth * 0.75] : [])
                    )
                    .padding(lineWidth / 2)

                if showsTicks {
                    ticks(diameter: d)
                }

                if !isEmpty {
                    AuroraArcShape(startDegrees: startAngle, sweepDegrees: sweepDegrees, progress: sweep)
                        .stroke(
                            AngularGradient(gradient: ramp.gradient, center: .center,
                                            startAngle: .degrees(startAngle),
                                            endAngle: .degrees(startAngle + sweepDegrees)),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                        )
                        .padding(lineWidth / 2)
                        .shadow(color: ramp.color(at: sweep).opacity(0.5), radius: lineWidth * 0.6)
                }

                center(diameter: d)
                    .padding(.horizontal, lineWidth * 2)
            }
            .frame(width: d, height: d)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear { animate(to: target) }
        .onChangeCompat(of: target) { newValue in animate(to: newValue) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label ?? "Gauge"))
        .accessibilityValue(Text(value ?? emptyHint))
    }

    private func animate(to newValue: Double) {
        withAnimation(Aurora.Motion.respecting(Aurora.Motion.drawIn, reduced: reduceMotion)) {
            sweep = newValue
        }
    }

    @ViewBuilder
    private func ticks(diameter: CGFloat) -> some View {
        let radius = (diameter - lineWidth) / 2
        ForEach([0.0, 0.5, 1.0], id: \.self) { t in
            Capsule()
                .fill(Aurora.hairlineStrong)
                .frame(width: 1.5, height: 5)
                .offset(y: -(radius + lineWidth * 0.75))
                .rotationEffect(.degrees(startAngle + sweepDegrees * t - 270))
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func center(diameter: CGFloat) -> some View {
        let valueSize = min(max(diameter * 0.26, 22), 60)

        VStack(spacing: 2) {
            if let label {
                Text(label).auroraSectionHeader().lineLimit(1).minimumScaleFactor(0.7)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value ?? "–")
                    .font(AuroraType.display(valueSize))
                    .tracking(AuroraType.displayTracking(valueSize))
                    .foregroundStyle(isEmpty ? Aurora.textDisabled : Aurora.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let unit, !isEmpty {
                    Text(unit)
                        .font(AuroraType.number(valueSize * 0.32, weight: .semibold))
                        .foregroundStyle(Aurora.textTertiary)
                }
            }
            if isEmpty {
                Text(emptyHint).auroraFootnote().lineLimit(2).multilineTextAlignment(.center)
            } else if let caption {
                Text(caption)
                    .auroraCaptionStrong()
                    .foregroundStyle(ramp.color(at: sweep))
                    .lineLimit(1)
            }
        }
    }
}

/// An arc from `startDegrees`, sweeping `sweepDegrees × progress` clockwise.
/// `progress` is the animatable attribute, so the sweep interpolates natively.
public struct AuroraArcShape: Shape {

    public var startDegrees: Double
    public var sweepDegrees: Double
    public var progress: Double

    public var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    public init(startDegrees: Double, sweepDegrees: Double, progress: Double) {
        self.startDegrees = startDegrees
        self.sweepDegrees = sweepDegrees
        self.progress = progress
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width, rect.height) / 2
        guard radius > 0 else { return path }
        let clamped = min(max(progress, 0), 1)
        guard clamped > 0 else { return path }
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: radius,
            startAngle: .degrees(startDegrees),
            endAngle: .degrees(startDegrees + sweepDegrees * clamped),
            clockwise: false
        )
        return path
    }
}

// MARK: - AuroraSparkline

/// A compact trend line for a tile or a dense row. Canvas-drawn: no axes, no labels, no
/// hit testing — just the shape of the last few readings.
///
/// Drawn rather than charted because at 22 points tall a Swift Charts plot spends most of
/// its height on insets, and because the left-to-right reveal below needs a clip the
/// framework does not expose.
public struct AuroraSparkline: View {

    private let values: [Double]
    private let tint: Color
    private let ramp: AuroraRamp?
    private let range: ClosedRange<Double>?
    private let lineWidth: CGFloat
    private let showsArea: Bool
    private let showsHead: Bool

    @State private var reveal: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - values: the series, oldest first. Fewer than two points renders the empty state.
    ///   - tint: the stroke colour. Ignored when `ramp` is supplied.
    ///   - ramp: paint the stroke with a ramp gradient instead of a flat tint, so the line
    ///     itself encodes magnitude. `nil` (default) uses `tint`.
    ///   - range: an explicit y-range. `nil` auto-fits with 8% headroom, which is what you
    ///     want for a shape read, not a value read.
    ///   - lineWidth: stroke width. Default 2.
    ///   - showsArea: fill beneath the line with a dissolving gradient. Default `true`.
    ///   - showsHead: draw a bright dot at the latest sample. Default `true`.
    public init(
        values: [Double],
        tint: Color = Aurora.accent,
        ramp: AuroraRamp? = nil,
        range: ClosedRange<Double>? = nil,
        lineWidth: CGFloat = Aurora.Stroke.line,
        showsArea: Bool = true,
        showsHead: Bool = true
    ) {
        self.values = values
        self.tint = tint
        self.ramp = ramp
        self.range = range
        self.lineWidth = lineWidth
        self.showsArea = showsArea
        self.showsHead = showsHead
    }

    public var body: some View {
        Group {
            if values.count > 1 {
                AuroraAnimatedValue(reveal) { t in
                    Canvas(rendersAsynchronously: false) { ctx, size in
                        draw(in: &ctx, size: size, reveal: t)
                    }
                }
            } else {
                DashedBaseline()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            withAnimation(Aurora.Motion.respecting(Aurora.Motion.drawIn, reduced: reduceMotion)) {
                reveal = 1
            }
        }
        .accessibilityHidden(true)
    }

    private var bounds: (lo: Double, hi: Double) {
        if let range { return (range.lowerBound, range.upperBound) }
        let lo = values.min() ?? 0
        let hi = values.max() ?? 1
        if hi - lo < .ulpOfOne { return (lo - 1, hi + 1) }
        let pad = (hi - lo) * 0.08
        return (lo - pad, hi + pad)
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let (lo, hi) = bounds
        let span = max(hi - lo, .ulpOfOne)
        let inset = lineWidth / 2 + (showsHead ? lineWidth : 0)
        let usableH = max(size.height - inset * 2, 1)
        let stepX = values.count > 1 ? size.width / CGFloat(values.count - 1) : 0
        return values.enumerated().map { i, v in
            let norm = (v - lo) / span
            return CGPoint(x: CGFloat(i) * stepX,
                           y: inset + usableH * (1 - CGFloat(norm)))
        }
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize, reveal t: Double) {
        let pts = points(in: size)
        guard pts.count > 1 else { return }

        // The reveal is a clip, not a re-sample: the curve's shape is final from frame
        // one and simply becomes visible left to right, so it never appears to wriggle.
        let clamped = min(max(t, 0), 1)
        ctx.clip(to: Path(CGRect(x: 0, y: 0, width: size.width * clamped, height: size.height)))

        var line = Path()
        line.addLines(pts)

        if showsArea {
            var area = line
            area.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: size.height))
            area.addLine(to: CGPoint(x: pts[0].x, y: size.height))
            area.closeSubpath()
            let top = ramp?.end ?? tint
            ctx.fill(
                area,
                with: .linearGradient(
                    Gradient(colors: [top.opacity(0.30), top.opacity(0.0)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
        }

        if let ramp {
            ctx.stroke(
                line,
                with: .linearGradient(ramp.gradient,
                                      startPoint: CGPoint(x: 0, y: size.height),
                                      endPoint: CGPoint(x: 0, y: 0)),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
        } else {
            ctx.stroke(
                line,
                with: .color(tint),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
        }

        if showsHead, let head = pts.last, clamped > 0.98 {
            let r = lineWidth * 1.1
            let dot = Path(ellipseIn: CGRect(x: head.x - r, y: head.y - r, width: r * 2, height: r * 2))
            ctx.fill(dot, with: .color(ramp?.end ?? tint))
        }
    }
}

// MARK: - AuroraTrendChart

/// One point in a time series.
public struct AuroraPoint: Identifiable, Equatable, Sendable {
    public var date: Date
    public var value: Double
    /// Identity is the timestamp — stable across re-renders, unlike a generated UUID,
    /// so Swift Charts can animate a series update instead of rebuilding it.
    public var id: Date { date }

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

/// A full-width line/area chart with a gradient fill, quiet axes and an interactive
/// scrub read-out.
///
/// **The read-out lives in the header, not in a floating tooltip.** A tooltip that
/// follows the finger is covered by the finger on a phone and clips at the plot edges on
/// both platforms; a header that updates as you scrub is always readable, never occludes
/// the data, and gives the chart a useful resting state (the latest value) when nobody is
/// touching it. Apple Health and Linear both land here for the same reasons.
public struct AuroraTrendChart: View {

    private let points: [AuroraPoint]
    private let title: String?
    private let tint: Color
    private let ramp: AuroraRamp?
    private let unit: String?
    private let decimals: Int
    private let showsArea: Bool
    private let lineWidth: CGFloat
    private let height: CGFloat
    private let yDomain: ClosedRange<Double>?
    private let emptyHeadline: String
    private let emptyMessage: String?
    private let dateStyle: Date.FormatStyle

    @State private var selectedIndex: Int?
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - points: the series, any order (sorted internally by date).
    ///   - title: an optional overline above the read-out.
    ///   - tint: the line colour. Ignored when `ramp` is supplied.
    ///   - ramp: paint the line and fill with a ramp gradient instead of a flat tint.
    ///   - unit: unit appended to the read-out value.
    ///   - decimals: fraction digits in the read-out. Default 0.
    ///   - showsArea: draw the dissolving area fill under the line. Default `true`.
    ///   - lineWidth: stroke width. Default 2.5.
    ///   - height: plot height. Default `Aurora.Layout.chartHeight` (200).
    ///   - yDomain: an explicit y-range; `nil` auto-fits with 10% headroom.
    ///   - emptyHeadline: headline for the empty state.
    ///   - emptyMessage: supporting copy for the empty state.
    ///   - dateStyle: how the scrubbed date is formatted. Default abbreviated day + month.
    public init(
        points: [AuroraPoint],
        title: String? = nil,
        tint: Color = Aurora.accent,
        ramp: AuroraRamp? = nil,
        unit: String? = nil,
        decimals: Int = 0,
        showsArea: Bool = true,
        lineWidth: CGFloat = 2.5,
        height: CGFloat = Aurora.Layout.chartHeight,
        yDomain: ClosedRange<Double>? = nil,
        emptyHeadline: String = "Not enough history",
        emptyMessage: String? = "Two days of readings and this chart fills in.",
        dateStyle: Date.FormatStyle = .dateTime.day().month(.abbreviated)
    ) {
        self.points = points.sorted { $0.date < $1.date }
        self.title = title
        self.tint = tint
        self.ramp = ramp
        self.unit = unit
        self.decimals = decimals
        self.showsArea = showsArea
        self.lineWidth = lineWidth
        self.height = height
        self.yDomain = yDomain
        self.emptyHeadline = emptyHeadline
        self.emptyMessage = emptyMessage
        self.dateStyle = dateStyle
    }

    private var strokeStyle: AnyShapeStyle {
        if let ramp {
            return AnyShapeStyle(
                LinearGradient(gradient: ramp.gradient, startPoint: .bottom, endPoint: .top)
            )
        }
        return AnyShapeStyle(tint)
    }

    private var areaStyle: AnyShapeStyle {
        let top = ramp?.end ?? tint
        return AnyShapeStyle(
            LinearGradient(colors: [top.opacity(0.34), top.opacity(0.02)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private var resolvedDomain: ClosedRange<Double> {
        if let yDomain { return yDomain }
        let vs = points.map(\.value)
        guard let lo = vs.min(), let hi = vs.max() else { return 0...1 }
        if hi - lo < .ulpOfOne { return (lo - 1)...(hi + 1) }
        let pad = (hi - lo) * 0.10
        return (lo - pad)...(hi + pad)
    }

    private var readoutPoint: AuroraPoint? {
        if let selectedIndex, points.indices.contains(selectedIndex) { return points[selectedIndex] }
        return points.last
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.s) {
            readout
            if points.count > 1 {
                chart
            } else {
                AuroraEmptyState(
                    icon: "chart.line.uptrend.xyaxis",
                    headline: emptyHeadline,
                    message: emptyMessage,
                    tint: ramp?.end ?? tint
                )
                .frame(height: height)
            }
        }
    }

    // MARK: Header read-out

    @ViewBuilder
    private var readout: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title {
                Text(title).auroraSectionHeader()
            }
            HStack(alignment: .firstTextBaseline, spacing: Aurora.Space.xs) {
                if let p = readoutPoint {
                    AuroraValueUnit(
                        value: decimals > 0 ? String(format: "%.\(decimals)f", p.value)
                                            : String(Int(p.value.rounded())),
                        unit: unit,
                        role: .metricLarge,
                        valueColor: ramp.map { $0.color(at: fraction(of: p.value)) }
                    )
                    Text(p.date.formatted(dateStyle))
                        .auroraCaption()
                } else {
                    AuroraValueUnit(value: "–", unit: unit, role: .metricLarge,
                                    valueColor: Aurora.textDisabled)
                }
                Spacer(minLength: 0)
            }
        }
        // The read-out swaps values continuously while scrubbing, so it must not animate
        // — an easing curve here turns a precise instrument into a lagging one.
        .animation(nil, value: selectedIndex)
    }

    private func fraction(of value: Double) -> Double {
        let d = resolvedDomain
        let span = d.upperBound - d.lowerBound
        guard span > .ulpOfOne else { return 0.5 }
        return min(max((value - d.lowerBound) / span, 0), 1)
    }

    // MARK: Plot

    private var chart: some View {
        Chart {
            if showsArea {
                ForEach(points) { p in
                    AreaMark(
                        x: .value("Date", p.date),
                        yStart: .value("Min", resolvedDomain.lowerBound),
                        yEnd: .value("Value", p.value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(areaStyle)
                }
            }

            ForEach(points) { p in
                LineMark(
                    x: .value("Date", p.date),
                    y: .value("Value", p.value)
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .foregroundStyle(strokeStyle)
            }

            if let selectedIndex, points.indices.contains(selectedIndex) {
                let p = points[selectedIndex]
                RuleMark(x: .value("Date", p.date))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Aurora.hairlineStrong)
                PointMark(x: .value("Date", p.date), y: .value("Value", p.value))
                    .symbolSize(70)
                    .foregroundStyle(ramp?.color(at: fraction(of: p.value)) ?? tint)
            }
        }
        .chartYScale(domain: resolvedDomain)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Aurora.divider)
                AxisValueLabel()
                    .font(AuroraType.footnote)
                    .foregroundStyle(Aurora.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Aurora.divider)
                AxisValueLabel()
                    .font(AuroraType.footnote)
                    .foregroundStyle(Aurora.textTertiary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in select(at: v.location, proxy: proxy, geo: geo) }
                            .onEnded { _ in selectedIndex = nil }
                    )
                    .modifier(AuroraHoverReporter { point in
                        if let point {
                            select(at: point, proxy: proxy, geo: geo)
                        } else {
                            selectedIndex = nil
                        }
                    })
            }
        }
        .frame(height: height)
        // Charts cannot be masked without wiping their axes too, so the entrance is a
        // fade and a short rise from the baseline — calm, and it never leaves the plot
        // looking half-rendered if the animation is interrupted.
        .opacity(appeared ? 1 : 0)
        .scaleEffect(x: 1, y: appeared ? 1 : 0.92, anchor: .bottom)
        .onAppear {
            guard !appeared else { return }
            withAnimation(Aurora.Motion.respecting(Aurora.Motion.drawIn, reduced: reduceMotion)) {
                appeared = true
            }
        }
    }

    private func select(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        let plot = proxy.plotRectCompat(in: geo)
        guard plot.width > 0 else { return }
        let x = location.x - plot.minX
        guard let date: Date = proxy.value(atX: x) else { return }
        var best = 0
        var bestDelta = Double.greatestFiniteMagnitude
        for (i, p) in points.enumerated() {
            let d = abs(p.date.timeIntervalSince(date))
            if d < bestDelta { bestDelta = d; best = i }
        }
        selectedIndex = best
    }
}

// MARK: - AuroraBarSeries

/// One bar in a comparison series.
public struct AuroraBar: Equatable, Sendable {
    public var label: String
    /// `nil` renders a ghost bar — a day with no reading, which is different from a day
    /// with a reading of zero, and must not look the same.
    public var value: Double?
    /// Optional 0…1 position used to sample the series ramp for this bar's colour.
    /// `nil` samples the ramp at the bar's own height instead.
    public var colorFraction: Double?

    public init(label: String, value: Double?, colorFraction: Double? = nil) {
        self.label = label
        self.value = value
        self.colorFraction = colorFraction
    }
}

/// A weekly / monthly comparison bar chart with rounded caps.
///
/// Hand-drawn rather than `BarMark`, because per-mark corner radius is not available in
/// Swift Charts on macOS 13 and a squared-off bar is exactly the detail that makes a chart
/// look unfinished. Bars grow from the baseline on the house curve, staggered by ~18 ms so
/// the series arrives as a wave rather than a block.
public struct AuroraBarSeries: View {

    private let bars: [AuroraBar]
    private let tint: Color
    private let ramp: AuroraRamp?
    private let maxValue: Double?
    private let height: CGFloat
    private let highlightIndex: Int?
    private let showsLabels: Bool
    private let showsValues: Bool
    private let decimals: Int
    private let emptyHeadline: String

    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - bars: the series, left to right.
    ///   - tint: flat bar colour. Ignored when `ramp` is supplied.
    ///   - ramp: sample each bar's colour from a ramp, so magnitude is encoded twice
    ///     (height and hue) — the fastest possible read on a small chart.
    ///   - maxValue: the top of the scale. `nil` uses the tallest bar.
    ///   - height: total chart height, labels included. Default 160.
    ///   - highlightIndex: the bar to emphasise (today, the selected week). Others dim
    ///     to 55%, which reads as focus rather than as missing data.
    ///   - showsLabels: draw the x labels beneath the bars. Default `true`.
    ///   - showsValues: draw each bar's value above it. Default `false`.
    ///   - decimals: fraction digits for the value labels. Default 0.
    ///   - emptyHeadline: headline when every bar is `nil`.
    public init(
        bars: [AuroraBar],
        tint: Color = Aurora.accent,
        ramp: AuroraRamp? = nil,
        maxValue: Double? = nil,
        height: CGFloat = 160,
        highlightIndex: Int? = nil,
        showsLabels: Bool = true,
        showsValues: Bool = false,
        decimals: Int = 0,
        emptyHeadline: String = "Nothing logged yet"
    ) {
        self.bars = bars
        self.tint = tint
        self.ramp = ramp
        self.maxValue = maxValue
        self.height = height
        self.highlightIndex = highlightIndex
        self.showsLabels = showsLabels
        self.showsValues = showsValues
        self.decimals = decimals
        self.emptyHeadline = emptyHeadline
    }

    private var scaleTop: Double {
        if let maxValue, maxValue > 0 { return maxValue }
        let top = bars.compactMap(\.value).max() ?? 0
        return top > 0 ? top : 1
    }

    private var hasAnyValue: Bool { bars.contains { $0.value != nil } }

    public var body: some View {
        Group {
            if bars.isEmpty || !hasAnyValue {
                AuroraEmptyState(
                    icon: "chart.bar.fill",
                    headline: emptyHeadline,
                    message: "Bars appear here as soon as there is something to compare.",
                    tint: ramp?.end ?? tint
                )
                .frame(height: height)
            } else {
                series
            }
        }
        .onAppear {
            guard !grown else { return }
            withAnimation(Aurora.Motion.respecting(Aurora.Motion.drawIn, reduced: reduceMotion)) {
                grown = true
            }
        }
    }

    private var series: some View {
        GeometryReader { geo in
            let labelH: CGFloat = showsLabels ? 16 : 0
            let valueH: CGFloat = showsValues ? 14 : 0
            let plotH = max(geo.size.height - labelH - valueH - 8, 8)
            let count = max(bars.count, 1)
            let gap: CGFloat = count > 14 ? 3 : 6
            let barW = max((geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count), 2)

            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, bar in
                    VStack(spacing: 4) {
                        if showsValues {
                            Text(bar.value.map { valueText($0) } ?? "–")
                                .font(AuroraType.number(10, weight: .semibold))
                                .foregroundStyle(bar.value == nil ? Aurora.textDisabled : Aurora.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .frame(height: valueH)
                        }

                        ZStack(alignment: .bottom) {
                            // The full-height track keeps every column the same optical
                            // weight, so a short bar reads as "low", not as "missing".
                            RoundedRectangle(cornerRadius: barW / 2, style: .continuous)
                                .fill(Aurora.surfaceInset)
                                .frame(width: barW, height: plotH)

                            if let v = bar.value {
                                let fraction = min(max(v / scaleTop, 0), 1)
                                RoundedRectangle(cornerRadius: barW / 2, style: .continuous)
                                    .fill(color(for: bar, fraction: fraction))
                                    .frame(
                                        width: barW,
                                        height: max(barW, plotH * CGFloat(grown ? fraction : 0))
                                    )
                                    .opacity(opacity(for: index))
                                    .animation(
                                        Aurora.Motion.respecting(
                                            Aurora.Motion.drawIn.delay(Double(index) * 0.018),
                                            reduced: reduceMotion
                                        ),
                                        value: grown
                                    )
                            } else {
                                // A ghost bar: a dashed stub that says "no reading",
                                // clearly distinct from a real bar of height zero.
                                RoundedRectangle(cornerRadius: barW / 2, style: .continuous)
                                    .strokeBorder(
                                        Aurora.textDisabled.opacity(0.5),
                                        style: StrokeStyle(lineWidth: 1, dash: [2, 3])
                                    )
                                    .frame(width: barW, height: max(barW, 10))
                            }
                        }
                        .frame(height: plotH, alignment: .bottom)

                        if showsLabels {
                            Text(bar.label)
                                .font(AuroraType.footnote)
                                .foregroundStyle(index == highlightIndex ? Aurora.textPrimary : Aurora.textTertiary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .frame(height: labelH)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(bar.label))
                    .accessibilityValue(Text(bar.value.map { valueText($0) } ?? "No data"))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
        .frame(height: height)
    }

    private func valueText(_ v: Double) -> String {
        decimals > 0 ? String(format: "%.\(decimals)f", v) : String(Int(v.rounded()))
    }

    private func color(for bar: AuroraBar, fraction: Double) -> Color {
        guard let ramp else { return tint }
        return ramp.color(at: bar.colorFraction ?? fraction)
    }

    private func opacity(for index: Int) -> Double {
        guard let highlightIndex else { return 1 }
        return index == highlightIndex ? 1 : 0.55
    }
}

// MARK: - AuroraHypnogram

/// One contiguous stretch of a single sleep stage.
public struct AuroraSleepSegment: Equatable, Sendable {
    public var stage: AuroraSleepStage
    public var start: Date
    public var end: Date

    public init(stage: AuroraSleepStage, start: Date, end: Date) {
        self.stage = stage
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { max(end.timeIntervalSince(start), 0) }
}

/// A stepped sleep-stage chart with four stage-coloured bands.
///
/// Canvas-drawn, because a night is hundreds of segments — many of them under a minute —
/// and each needs a minimum drawn thickness or it disappears entirely. A chart framework
/// will happily render a two-minute REM block as a sub-pixel sliver; here every segment is
/// clamped to a readable width so short stages stay countable.
///
/// Two styles: `.stepped` draws each stage as a band at its own depth with vertical risers
/// at transitions (the clinical read — transitions are the information); `.filled` fills
/// from each stage's depth to the floor (the ambient read — total time at depth is the
/// information).
public struct AuroraHypnogram: View {

    /// How the stages are drawn.
    public enum Style: Sendable {
        /// Bands at stage depth, connected by vertical risers. Clinical.
        case stepped
        /// Filled from stage depth down to the floor. Ambient.
        case filled
    }

    private let segments: [AuroraSleepSegment]
    private let style: Style
    private let height: CGFloat
    private let showsStageLabels: Bool
    private let showsLegend: Bool
    private let emptyHeadline: String
    private let emptyMessage: String?

    @State private var reveal: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - segments: the night, any order (sorted internally by start).
    ///   - style: `.stepped` (default) or `.filled`.
    ///   - height: plot height, excluding the legend. Default 140.
    ///   - showsStageLabels: draw the stage names down the leading edge. Default `true`.
    ///   - showsLegend: draw the stage swatch legend beneath. Default `true`.
    ///   - emptyHeadline: headline when there are no segments.
    ///   - emptyMessage: supporting copy for the empty state.
    public init(
        segments: [AuroraSleepSegment],
        style: Style = .stepped,
        height: CGFloat = Aurora.Layout.hypnogramHeight,
        showsStageLabels: Bool = true,
        showsLegend: Bool = true,
        emptyHeadline: String = "No sleep recorded",
        emptyMessage: String? = "Wear your strap overnight and every stage is charted by morning."
    ) {
        self.segments = segments.sorted { $0.start < $1.start }
        self.style = style
        self.height = height
        self.showsStageLabels = showsStageLabels
        self.showsLegend = showsLegend
        self.emptyHeadline = emptyHeadline
        self.emptyMessage = emptyMessage
    }

    private var span: (start: Date, end: Date)? {
        guard let first = segments.first, let last = segments.max(by: { $0.end < $1.end }) else { return nil }
        guard last.end > first.start else { return nil }
        return (first.start, last.end)
    }

    public var body: some View {
        Group {
            if segments.isEmpty || span == nil {
                AuroraEmptyState(
                    icon: "bed.double.fill",
                    headline: emptyHeadline,
                    message: emptyMessage,
                    tint: AuroraSleepStage.light.color
                )
                .frame(height: height)
            } else {
                VStack(alignment: .leading, spacing: Aurora.Space.s) {
                    HStack(alignment: .top, spacing: Aurora.Space.xs) {
                        if showsStageLabels { stageLabels }
                        plot
                    }
                    if showsLegend { legend }
                }
            }
        }
        .onAppear {
            withAnimation(Aurora.Motion.respecting(Aurora.Motion.drawIn, reduced: reduceMotion)) {
                reveal = 1
            }
        }
    }

    private var stageLabels: some View {
        VStack(spacing: 0) {
            ForEach(AuroraSleepStage.allCases.sorted { $0.bandRank < $1.bandRank }, id: \.self) { stage in
                Text(stage.label)
                    .font(AuroraType.footnote)
                    .foregroundStyle(Aurora.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .frame(width: 38, height: height)
        .accessibilityHidden(true)
    }

    private var plot: some View {
        AuroraAnimatedValue(reveal) { t in
            Canvas(rendersAsynchronously: false) { ctx, size in
                draw(in: &ctx, size: size, reveal: t)
            }
        }
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: Aurora.Radius.m, style: .continuous)
                .fill(Aurora.surfaceInset)
        )
        .clipShape(RoundedRectangle(cornerRadius: Aurora.Radius.m, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Sleep stages"))
        .accessibilityValue(Text(accessibilitySummary))
    }

    private var legend: some View {
        HStack(spacing: Aurora.Space.s) {
            ForEach(AuroraSleepStage.allCases.sorted { $0.bandRank < $1.bandRank }, id: \.self) { stage in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(stage.color)
                        .frame(width: 10, height: 10)
                    Text(stage.label)
                        .font(AuroraType.footnote)
                        .foregroundStyle(Aurora.textSecondary)
                    Text(durationText(for: stage))
                        .font(AuroraType.number(11, weight: .semibold))
                        .foregroundStyle(Aurora.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }

    private func durationText(for stage: AuroraSleepStage) -> String {
        let total = segments.filter { $0.stage == stage }.reduce(0.0) { $0 + $1.duration }
        let minutes = Int((total / 60).rounded())
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    private var accessibilitySummary: String {
        AuroraSleepStage.allCases
            .sorted { $0.bandRank < $1.bandRank }
            .map { "\($0.label) \(durationText(for: $0))" }
            .joined(separator: ", ")
    }

    // MARK: Canvas

    private func draw(in ctx: inout GraphicsContext, size: CGSize, reveal t: Double) {
        guard let span, size.width > 0, size.height > 0 else { return }
        let total = span.end.timeIntervalSince(span.start)
        guard total > 0 else { return }

        let clamped = min(max(t, 0), 1)
        ctx.clip(to: Path(CGRect(x: 0, y: 0, width: size.width * clamped, height: size.height)))

        let bandCount = CGFloat(AuroraSleepStage.allCases.count)
        let bandH = size.height / bandCount
        // A drawn band is 52% of its lane so the lanes read as separate depths; the rest
        // is breathing room, which is what stops a busy night looking like a barcode.
        let drawnH = max(bandH * 0.52, 6)

        func x(for date: Date) -> CGFloat {
            CGFloat(date.timeIntervalSince(span.start) / total) * size.width
        }
        func bandCentreY(_ stage: AuroraSleepStage) -> CGFloat {
            (CGFloat(stage.bandRank) + 0.5) * bandH
        }

        // Lane guides.
        for stage in AuroraSleepStage.allCases {
            let y = bandCentreY(stage)
            var guideLine = Path()
            guideLine.move(to: CGPoint(x: 0, y: y))
            guideLine.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(guideLine, with: .color(Aurora.divider),
                       style: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
        }

        // Risers first, so the stage blocks sit on top of them.
        if style == .stepped, segments.count > 1 {
            var risers = Path()
            for i in 0..<(segments.count - 1) {
                let a = segments[i]
                let b = segments[i + 1]
                guard a.stage != b.stage else { continue }
                let rx = x(for: b.start)
                risers.move(to: CGPoint(x: rx, y: bandCentreY(a.stage)))
                risers.addLine(to: CGPoint(x: rx, y: bandCentreY(b.stage)))
            }
            ctx.stroke(risers, with: .color(Aurora.hairlineStrong),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }

        // Stage blocks. Every block gets a minimum drawn width so a two-minute REM burst
        // is still countable at phone width.
        for segment in segments {
            let x0 = x(for: segment.start)
            let x1 = x(for: segment.end)
            let w = max(x1 - x0, 2)
            let centre = bandCentreY(segment.stage)
            let color = segment.stage.color

            switch style {
            case .stepped:
                let rect = CGRect(x: x0, y: centre - drawnH / 2, width: w, height: drawnH)
                let path = Path(roundedRect: rect, cornerRadius: min(drawnH / 2, w / 2), style: .continuous)
                ctx.fill(path, with: .color(color))

            case .filled:
                let top = centre - drawnH / 2
                let rect = CGRect(x: x0, y: top, width: w, height: size.height - top)
                let path = Path(roundedRect: rect, cornerRadius: min(3, w / 2), style: .continuous)
                ctx.fill(
                    path,
                    with: .linearGradient(
                        Gradient(colors: [color.opacity(0.95), color.opacity(0.35)]),
                        startPoint: CGPoint(x: 0, y: top),
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                )
            }
        }
    }
}

// MARK: - AuroraRangeBar

/// A value plotted against its typical range.
///
/// A number alone is not information — 62 ms of HRV means nothing until you know your own
/// 55–70 is normal. This bar is Aurora's answer: the typical band is drawn as a lit
/// segment of a recessed track, and the reading sits on it as a marker. The judgement
/// ("in range", "below range") is then something the user makes by looking, not something
/// the app has to spell out.
public struct AuroraRangeBar: View {

    private let value: Double?
    private let bounds: ClosedRange<Double>
    private let typical: ClosedRange<Double>
    private let tint: Color
    private let ramp: AuroraRamp?
    private let unit: String?
    private let decimals: Int
    private let showsScale: Bool
    private let typicalLabel: String
    private let emptyHint: String

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - value: the reading, or `nil` for the empty state.
    ///   - bounds: the full track range (the axis).
    ///   - typical: the "normal for you" band highlighted inside the track.
    ///   - tint: marker colour. Ignored when `ramp` is supplied.
    ///   - ramp: sample the marker colour from a ramp at the value's position.
    ///   - unit: unit appended to the scale end labels.
    ///   - decimals: fraction digits for the scale labels. Default 0.
    ///   - showsScale: draw the lower / typical / upper labels. Default `true`.
    ///   - typicalLabel: what to call the highlighted band. Default `"Typical"`.
    ///   - emptyHint: caption shown when `value` is `nil`.
    public init(
        value: Double?,
        bounds: ClosedRange<Double>,
        typical: ClosedRange<Double>,
        tint: Color = Aurora.accent,
        ramp: AuroraRamp? = nil,
        unit: String? = nil,
        decimals: Int = 0,
        showsScale: Bool = true,
        typicalLabel: String = "Typical",
        emptyHint: String = "No reading yet"
    ) {
        self.value = value
        self.bounds = bounds
        self.typical = typical
        self.tint = tint
        self.ramp = ramp
        self.unit = unit
        self.decimals = decimals
        self.showsScale = showsScale
        self.typicalLabel = typicalLabel
        self.emptyHint = emptyHint
    }

    private var span: Double { max(bounds.upperBound - bounds.lowerBound, .ulpOfOne) }

    private func fraction(_ v: Double) -> Double {
        min(max((v - bounds.lowerBound) / span, 0), 1)
    }

    private var markerColor: Color {
        guard let value else { return Aurora.textDisabled }
        return ramp?.color(at: fraction(value)) ?? tint
    }

    /// Whether the reading sits inside the typical band — the one judgement this
    /// component makes, exposed so a caller can echo it in a status pill.
    public var isWithinTypicalRange: Bool? {
        value.map { typical.contains($0) }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.xs) {
            GeometryReader { geo in
                let w = geo.size.width
                let h = Aurora.Layout.trackHeight
                let lo = CGFloat(fraction(typical.lowerBound)) * w
                let hi = CGFloat(fraction(typical.upperBound)) * w

                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Aurora.surfaceInset)
                        .frame(height: h)

                    Capsule(style: .continuous)
                        .fill(markerColor.opacity(0.28))
                        .frame(width: max(hi - lo, 2), height: h)
                        .offset(x: lo)

                    if let value {
                        Capsule(style: .continuous)
                            .fill(markerColor)
                            .frame(width: 4, height: h + 10)
                            .shadow(color: markerColor.opacity(0.55), radius: 5)
                            .offset(x: max(CGFloat(fraction(value)) * w - 2, 0))
                            .opacity(appeared ? 1 : 0)
                            .scaleEffect(y: appeared ? 1 : 0.4)
                    } else {
                        Capsule(style: .continuous)
                            .strokeBorder(Aurora.textDisabled.opacity(0.5),
                                          style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                            .frame(width: 4, height: h + 10)
                            .offset(x: max(CGFloat(fraction((bounds.lowerBound + bounds.upperBound) / 2)) * w - 2, 0))
                    }
                }
                .frame(height: h + 10)
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: Aurora.Layout.trackHeight + 12)

            if showsScale {
                HStack(spacing: 0) {
                    Text(scaleText(bounds.lowerBound)).auroraFootnote()
                    Spacer(minLength: Aurora.Space.xxs)
                    Text(value == nil
                         ? emptyHint
                         : "\(typicalLabel) \(scaleText(typical.lowerBound))–\(scaleText(typical.upperBound))")
                        .auroraFootnote()
                        .foregroundStyle(value == nil ? Aurora.textDisabled : Aurora.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: Aurora.Space.xxs)
                    Text(scaleText(bounds.upperBound)).auroraFootnote()
                }
            }
        }
        .onAppear {
            guard !appeared else { return }
            withAnimation(Aurora.Motion.respecting(Aurora.Motion.hero, reduced: reduceMotion)) {
                appeared = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(typicalLabel))
        .accessibilityValue(Text(accessibilityText))
    }

    private func scaleText(_ v: Double) -> String {
        let n = decimals > 0 ? String(format: "%.\(decimals)f", v) : String(Int(v.rounded()))
        return unit.map { "\(n) \($0)" } ?? n
    }

    private var accessibilityText: String {
        guard let value else { return emptyHint }
        let inRange = typical.contains(value) ? "within" : "outside"
        return "\(scaleText(value)), \(inRange) the typical range \(scaleText(typical.lowerBound)) to \(scaleText(typical.upperBound))"
    }
}

#if DEBUG
private func auroraPreviewSeries(_ values: [Double]) -> [AuroraPoint] {
    let day: TimeInterval = 86_400
    let start = Date().addingTimeInterval(-day * Double(values.count - 1))
    return values.enumerated().map { AuroraPoint(date: start.addingTimeInterval(day * Double($0.offset)),
                                                 value: $0.element) }
}

private func auroraPreviewNight() -> [AuroraSleepSegment] {
    let base = Date().addingTimeInterval(-8 * 3600)
    let plan: [(AuroraSleepStage, Double)] = [
        (.awake, 6), (.light, 22), (.deep, 44), (.light, 18), (.rem, 24),
        (.light, 30), (.deep, 32), (.light, 16), (.rem, 28), (.awake, 4),
        (.light, 26), (.rem, 34), (.light, 20), (.awake, 8),
    ]
    var t = base
    return plan.map { stage, minutes in
        let end = t.addingTimeInterval(minutes * 60)
        defer { t = end }
        return AuroraSleepSegment(stage: stage, start: t, end: end)
    }
}

#Preview("Aurora Charts") {
    ScrollView {
        VStack(spacing: Aurora.Space.l) {

            AuroraCard(padding: Aurora.Space.heroPadding, radius: Aurora.Radius.hero, tint: Aurora.recoveryColor(82)) {
                AuroraRing(
                    progress: 0.82, value: "82", unit: "%",
                    label: "Recovery", caption: AuroraRecoveryBand(pct: 82).label,
                    ramp: .recovery, size: 210
                )
                .frame(maxWidth: .infinity)
            }

            HStack(spacing: Aurora.Space.s) {
                AuroraCard {
                    AuroraArcGauge(progress: 0.62, value: "13.1", label: "Strain",
                                   caption: "Moderate", ramp: .strain)
                        .frame(height: 150)
                }
                AuroraCard {
                    AuroraRing(progress: nil, label: "Sleep", ramp: .sleep,
                               lineWidth: Aurora.Stroke.ringCompact,
                               emptyHint: "Strap was charging")
                        .frame(height: 150)
                }
            }

            AuroraCard {
                AuroraTrendChart(
                    points: auroraPreviewSeries([48, 52, 51, 58, 55, 61, 63, 60, 66, 62, 68, 71, 67, 72]),
                    title: "HRV · 14 days",
                    ramp: .recovery, unit: "ms"
                )
            }

            AuroraCard {
                VStack(alignment: .leading, spacing: Aurora.Space.s) {
                    AuroraSectionHeader("Weekly strain")
                    AuroraBarSeries(
                        bars: [
                            AuroraBar(label: "M", value: 11.2), AuroraBar(label: "T", value: 15.8),
                            AuroraBar(label: "W", value: 8.4), AuroraBar(label: "T", value: nil),
                            AuroraBar(label: "F", value: 17.9), AuroraBar(label: "S", value: 6.1),
                            AuroraBar(label: "S", value: 13.4),
                        ],
                        ramp: .strain, maxValue: 21, highlightIndex: 6, showsValues: true, decimals: 1
                    )
                }
            }

            AuroraCard {
                VStack(alignment: .leading, spacing: Aurora.Space.s) {
                    AuroraSectionHeader("Last night")
                    AuroraHypnogram(segments: auroraPreviewNight())
                }
            }

            AuroraCard {
                VStack(alignment: .leading, spacing: Aurora.Space.s) {
                    AuroraSectionHeader("Resting heart rate")
                    AuroraRangeBar(value: 52, bounds: 40...80, typical: 48...58,
                                   ramp: .recovery, unit: "bpm")
                    AuroraRangeBar(value: nil, bounds: 40...80, typical: 48...58, unit: "bpm")
                }
            }
        }
        .padding(Aurora.Space.l)
    }
    .background(Aurora.canvas)
}
#endif
