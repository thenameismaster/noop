import SwiftUI

// MARK: - LedgerTrendBlock — one stacked block of the Trends board
//
// Transcribed from `data-screen-label="Trends"`. The RECOVERY block, verbatim:
//
//   <div style="margin:16px 24px 0;border-bottom:1px solid rgba(255,255,255,.06);padding-bottom:14px">
//     <div style="display:flex;justify-content:space-between;align-items:baseline">
//       <span style="font-size:10.5px;font-weight:700;letter-spacing:2.4px;color:#5C6470">RECOVERY</span>
//       <div><span style="font-family:'Space Grotesk';font-size:17px;font-weight:600">74</span>
//            <span style="font-size:12px;color:#3EE6A8;margin-left:8px">↑ trending up</span></div>
//     </div>
//     <svg width="100%" height="62" viewBox="0 0 345 62" preserveAspectRatio="none" style="margin-top:8px">
//       <rect x="0" y="20" width="345" height="22" fill="rgba(255,255,255,.045)"/>   ← baseline band
//       <path d="…" fill="rgba(62,230,168,.08)"/>                                     ← area fill @ 8%
//       <path d="…" fill="none" stroke="#3EE6A8" stroke-width="2"/>
//     </svg>
//   </div>
//
// The HRV / RESTING HR / SLEEP SCORE blocks are identical minus the area fill, and add a unit
// (`<span style="font-size:11px;color:#5C6470"> ms</span>`) between the value and the delta chip.
//
// **NO CARD.** The block draws straight on `bg/screen`; the only chrome is the `white @ 6%` rule
// beneath it. Wrapping this in a rounded fill is the exact mistake the spec forbids.
//
// EVERY BLOCK CARRIES ITS BASELINE BAND. Spec: *"a value without 'your normal' context is banned."*
// `baseline` is therefore a first-class parameter, and it is the band — not the data — that anchors
// the chart's value domain, so the line's position against "normal" is honest across blocks.
//
// WHY A `Shape`, NOT `Chart`. The spec prefers Swift Charts for charts, but §Motion mandates
// "single path draw-in 1.2 s (**trim**)" — and a `LineMark` cannot be trimmed. The motion
// requirement wins; `LedgerPolyline` + `.trim(from:0,to:progress)` is what draws in.
//
// Pure presentation: values arrive pre-formatted, points arrive as plain `[Double]`.

/// A Trends block: overline · value + delta chip · 62pt line chart with its baseline band.
///
/// ```swift
/// LedgerTrendBlock(label: "HRV", value: "62", unit: "ms",
///                  delta: "+6 / 90d", deltaTone: .good,
///                  points: hrvSeries, baseline: 52...60,
///                  accent: Ledger.accentRecovery) { route(.metric("hrv")) }
/// ```
public struct LedgerTrendBlock: View {

    // MARK: Board constants

    /// `height="62"` on the chart.
    private static let chartHeightDefault: CGFloat = 62
    /// `margin-top:8px` between the header and the chart.
    private static let chartTopGap: CGFloat = 8
    /// `padding-bottom:14px` above the rule.
    private static let bottomPadding: CGFloat = 14
    /// `stroke-width="2"` on the line.
    private static let lineWidth: CGFloat = 2
    /// `font-size:17px; font-weight:600` on the value.
    private static let valueSize: CGFloat = 17
    /// `font-size:11px` on the unit.
    private static let unitSize: CGFloat = 11
    /// `font-size:12px; margin-left:8px` on the delta chip.
    private static let deltaSize: CGFloat = 12
    private static let deltaLeadingGap: CGFloat = 8
    /// `border-bottom:1px solid rgba(255,255,255,.06)` — the block separator, one step below
    /// `Ledger.hairline`, because a stack of blocks would otherwise read as a fence.
    private static var blockRule: Color { Ledger.white(0.06) }
    /// The shift ring — 7pt across, 1.5pt stroke: visibly a ring, small enough not to read as data.
    private static let markerDiameter: CGFloat = 7
    private static let markerStroke: CGFloat = 1.5

    // MARK: Input

    private let label: String
    private let value: String?
    private let unit: String?
    private let delta: String?
    private let deltaTone: LedgerTone
    private let points: [Double]
    private let baseline: ClosedRange<Double>?
    private let marker: Int?
    private let domainOverride: ClosedRange<Double>?
    private let accent: Color
    private let showsAreaFill: Bool
    private let chartHeight: CGFloat
    private let showsDivider: Bool
    private let animates: Bool
    private let action: (() -> Void)?

    /// - Parameters:
    ///   - label: the overline (`"RECOVERY"`). Uppercased and tracked by `ledgerOverline()`.
    ///   - value: the pre-formatted current value. **`nil` renders the empty state** — an em-dash
    ///     and a caption where the chart would be.
    ///   - unit: the 11pt tertiary unit after the value (`"ms"`, `"bpm"`). `nil` omits it.
    ///   - delta: the pre-formatted delta chip (`"+6 / 90d"`, `"trending up"`, `"steady"`). `nil`
    ///     omits it.
    ///   - deltaTone: the chip's colour. The SCREEN decides polarity — a falling resting HR is
    ///     `.good`; see `LedgerTone`.
    ///   - points: the series, oldest first, evenly spaced edge to edge. Fewer than two points
    ///     renders the empty state.
    ///   - baseline: the "your normal" band **in value units**, drawn as `white @ 4.5%` behind the
    ///     line. `nil` omits the band — allowed only where no baseline exists yet.
    ///   - marker: an index into `points` to ring on the line — the screen's "the level shifted
    ///     here" annotation. `nil` (the default, and the board's own state) draws nothing.
    ///   - domain: overrides the plotted value range. Default `nil` ⇒ the union of the series and
    ///     the baseline band, padded 8%.
    ///   - accent: the line colour, and the area fill's tint. Default `accent/recovery`.
    ///   - showsAreaFill: the `@ 8%` area under the line — the board applies it to RECOVERY only.
    ///   - chartHeight: default `62`, the board's.
    ///   - showsDivider: the `white @ 6%` rule beneath. Default `true`; pass `false` on the last
    ///     block of the stack, as the DAY STRAIN block does.
    ///   - animates: `false` renders at final geometry. Default `true` ⇒ a 1.2 s trim draw-in on
    ///     appear, collapsing to a 150 ms fade under Reduce Motion. Never re-runs on a data tick.
    ///   - action: pushes the block's metric detail. `nil` = inert.
    public init(
        label: String,
        value: String?,
        unit: String? = nil,
        delta: String? = nil,
        deltaTone: LedgerTone = .neutral,
        points: [Double],
        baseline: ClosedRange<Double>? = nil,
        marker: Int? = nil,
        domain: ClosedRange<Double>? = nil,
        accent: Color = Ledger.accentRecovery,
        showsAreaFill: Bool = false,
        chartHeight: CGFloat = 62,
        showsDivider: Bool = true,
        animates: Bool = true,
        action: (() -> Void)? = nil
    ) {
        self.label = label
        self.value = value
        self.unit = unit
        self.delta = delta
        self.deltaTone = deltaTone
        self.points = points
        self.baseline = baseline
        self.marker = marker
        self.domainOverride = domain
        self.accent = accent
        self.showsAreaFill = showsAreaFill
        self.chartHeight = chartHeight
        self.showsDivider = showsDivider
        self.animates = animates
        self.action = action
    }

    // MARK: Derived

    private var hasSeries: Bool { points.count >= 2 }

    private var domain: ClosedRange<Double>? {
        domainOverride ?? LedgerScale.domain(values: points, including: baseline)
    }

    private var normalizedPoints: [CGPoint] {
        guard let domain else { return [] }
        return points.enumerated().map { index, value in
            CGPoint(x: LedgerScale.normalizedX(index, count: points.count),
                    y: LedgerScale.normalizedY(value, in: domain))
        }
    }

    public var body: some View {
        Group {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            chart
                .padding(.top, Self.chartTopGap)
                .padding(.bottom, Self.bottomPadding)
            if showsDivider {
                Rectangle()
                    .fill(Self.blockRule)
                    .frame(height: Ledger.hairlineWidth)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label).ledgerOverline()
            Spacer(minLength: Ledger.rowGap)
            Text(value ?? "\u{2014}")
                .ledgerRowValue(Self.valueSize)
                .foregroundStyle(value == nil ? Ledger.textTertiary : Ledger.textPrimary)
            if let unit {
                Text(verbatim: " \(unit)")
                    .font(LedgerType.caption(Self.unitSize))
                    .foregroundStyle(Ledger.textTertiary)
            }
            if let delta {
                Text(delta)
                    .font(LedgerType.label(Self.deltaSize, LedgerType.regular))
                    .foregroundStyle(deltaTone.color)
                    .padding(.leading, Self.deltaLeadingGap)
            }
        }
    }

    // MARK: Chart

    private var chart: some View {
        ZStack {
            baselineBand
            if hasSeries {
                if animates {
                    LedgerDrawIn(.chart) { progress in line(progress: progress) }
                } else {
                    line(progress: 1)
                }
            } else {
                Text("Not enough history yet")
                    .ledgerCaptionStyle(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Inset by half the stroke so a terminal extreme is not clipped by its own line width. It
        // wraps BOTH the band and the line, so the two share one value-space geometry — a value
        // sitting exactly on a baseline edge lands exactly on that edge.
        .padding(.vertical, Self.lineWidth / 2)
        .frame(height: chartHeight)
    }

    /// `<rect fill="rgba(255,255,255,.045)">` — "your normal", positioned in VALUE space so the
    /// line's relationship to the band is real, not decorative.
    @ViewBuilder
    private var baselineBand: some View {
        if let baseline, let domain {
            GeometryReader { geo in
                let top = LedgerScale.normalizedY(baseline.upperBound, in: domain) * geo.size.height
                let bottom = LedgerScale.normalizedY(baseline.lowerBound, in: domain) * geo.size.height
                Rectangle()
                    .fill(Ledger.baselineBand)
                    .frame(width: geo.size.width, height: max(0, bottom - top))
                    .offset(y: top)
            }
        }
    }

    @ViewBuilder
    private func line(progress: Double) -> some View {
        ZStack {
            if showsAreaFill {
                // A closed area path must not be trimmed — trimming a filled region reveals a
                // wedge, not a chart — so the fill is revealed by the same progress as a mask.
                LedgerPolyline(points: normalizedPoints, closed: true)
                    .fill(accent.opacity(Ledger.trendAreaFillOpacity))
                    .mask(alignment: .leading) {
                        GeometryReader { geo in
                            Rectangle().frame(width: geo.size.width * CGFloat(progress))
                        }
                    }
            }
            LedgerPolyline(points: normalizedPoints)
                .trim(from: 0, to: progress)
                .stroke(accent, style: StrokeStyle(lineWidth: Self.lineWidth,
                                                   lineCap: .round,
                                                   lineJoin: .round))

            // The shift ring — a hollow caution ring on the marked point, matching the note's
            // "stepped up around <date>" sentence. Caution because a level shift is the same
            // "drift" family the token table assigns that colour to; hollow so the line's own
            // colour still reads through it. Held until the draw-in has passed the point, so the
            // ring never floats ahead of a line that has not reached it yet.
            if let marker, normalizedPoints.indices.contains(marker),
               progress >= LedgerScale.normalizedX(marker, count: normalizedPoints.count) {
                let point = normalizedPoints[marker]
                GeometryReader { geo in
                    Circle()
                        .stroke(Ledger.accentCaution, lineWidth: Self.markerStroke)
                        .frame(width: Self.markerDiameter, height: Self.markerDiameter)
                        .position(x: point.x * geo.size.width,
                                  y: point.y * geo.size.height)
                }
            }
        }
    }
}

#if DEBUG
#Preview("LedgerTrendBlock") {
    let recovery: [Double] = [58, 62, 51, 66, 71, 60, 55, 64, 78, 82, 70, 74]
    let hrv: [Double] = [50, 53, 48, 56, 54, 59, 56, 63, 61, 66, 64, 62]
    return ScrollView {
        VStack(spacing: 0) {
            LedgerTrendBlock(label: "Recovery", value: "74", delta: "\u{2191} trending up",
                             deltaTone: .good, points: recovery, baseline: 58...70,
                             accent: Ledger.accentRecovery, showsAreaFill: true) {}
            LedgerTrendBlock(label: "HRV", value: "62", unit: "ms", delta: "+6 / 90d",
                             deltaTone: .good, points: hrv, baseline: 52...60,
                             accent: Ledger.accentRecovery)
            LedgerTrendBlock(label: "Resting HR", value: "60", unit: "bpm", delta: "\u{2212}2 / 90d",
                             deltaTone: .good, points: hrv.reversed().map { 110 - $0 },
                             baseline: 58...64, accent: Ledger.textSecondary)
            LedgerTrendBlock(label: "Sleep score", value: nil, points: [],
                             accent: Ledger.accentSleep, showsDivider: false)
        }
        .padding(Ledger.pageMargin)
    }
    .frame(width: 393)
    .background(Ledger.bgScreen)
    .preferredColorScheme(.dark)
}
#endif
