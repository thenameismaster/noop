import SwiftUI
import StrandDesign

// MARK: - LedgerHypnogram — the Sleep board's NIGHT TIMELINE
//
// A Ledger restyle of the night timeline. Transcribed from `data-screen-label="Sleep"`, whose SVG
// is `viewBox="0 0 345 176"`:
//
//   <text x="0" y="26|64|102|140" fill="#5C6470" font-size="9">AWAKE|REM|LIGHT|DEEP</text>
//   <line x1="42" y1="22|60|98|136" x2="345" stroke="rgba(255,255,255,.045)"/>
//   <rect x=".." y="17|55|93|131" width=".." height="10" rx="5" fill="#4A5468|#A78BFA|#6D8DF7|#3B55D9"/>
//   <path d="M42,158 C…" stroke="#FF6B81" stroke-width="1.4" opacity=".8"/>
//   <text x="42|180|316" y="174" fill="#5C6470" font-size="10">23:12|03:00|07:04</text>
//
// READING THE LAYOUT.
//   • Four lanes, 38pt apart, centred on y = 22 / 60 / 98 / 136 — each `<rect>`'s `y` is its lane
//     centre minus half the 10pt bar height (17+5=22, 55+5=60, 93+5=98, 131+5=136). Lane order is
//     `SleepStage.bandRank`: awake 0 → REM 1 → light 2 → deep 3. The existing rank is reused, not
//     re-declared.
//   • The label gutter is 42pt wide; the plot runs 42 → 345.
//   • Bars are `height="10" rx="5"` — a full-round capsule, which is why a one-minute wake shows as
//     a dot rather than a hairline.
//   • The sleeping-HR overlay lives in the band the board's path actually occupies, y 144 → 162,
//     between the deep lane's bottom edge (131+10=141) and the time-axis labels.
//   • Axis labels sit at y=174: `x=42` left-anchored, `x=180` (a 5-glyph 10pt label centred on the
//     plot's midpoint 193.5) and `x=316` (right-anchored at the plot's end).
//
// This restyle differs from `StrandDesign.Hypnogram` in colour, lane metrics, bar radius, the HR
// overlay and the axis; it deliberately shares that component's INPUT type, `SleepInterval`, so a
// screen feeds both from one `SleepView.decodeSegments` call. No hover, no tooltip, no highlight —
// the Ledger's Sleep board has none, and the STAGES ledger below it carries the per-stage numbers.

/// One point of the sleeping-HR overlay: seconds from the start of the night, and bpm.
///
/// Map from the repository's existing `HRBucket` at the call site — the component stays free of any
/// store type:
/// ```swift
/// let hr = buckets.map { LedgerHRPoint(seconds: TimeInterval($0.ts - night.effectiveStartTs), bpm: $0.bpm) }
/// ```
public struct LedgerHRPoint: Sendable, Equatable {
    /// Seconds from the start of the night — the same domain `SleepInterval.start` uses.
    public var seconds: TimeInterval
    /// Beats per minute.
    public var bpm: Double

    public init(seconds: TimeInterval, bpm: Double) {
        self.seconds = seconds
        self.bpm = bpm
    }
}

/// The Ledger night timeline: four labelled stage lanes, a sleeping-HR overlay, and a time axis.
///
/// ```swift
/// LedgerHypnogram(intervals: night.intervals,
///                 heartRate: hr,
///                 nightStart: Date(timeIntervalSince1970: TimeInterval(night.effectiveStartTs)))
/// ```
public struct LedgerHypnogram: View {

    // MARK: Board constants (viewBox 0 0 345 176)

    /// The board's design height. Every vertical metric below is expressed against it and scaled by
    /// `height / designHeight`, so a caller may shrink the timeline without the lanes drifting.
    private static let designHeight: CGFloat = 176
    /// `x1="42"` — the label gutter.
    private static let labelColumn: CGFloat = 42
    /// Lane centres, in `SleepStage.bandRank` order: awake, REM, light, deep.
    private static let laneCentres: [CGFloat] = [22, 60, 98, 136]
    /// `height="10"` on every stage `<rect>`.
    private static let barHeight: CGFloat = 10
    /// The segment corner radius. The board's SVG says `rx="5"` (a full capsule), but the STAGES
    /// ledger right below draws its bars at `Ledger.barRadiusTight` (3) — and the two read as one
    /// system only when their corners agree, so the tighter shared token wins over the board here.
    private static let barRadius: CGFloat = Ledger.barRadiusTight
    /// Transition risers — the quiet vertical hairlines that trace the staircase between
    /// consecutive stage levels, mirroring `StrandDesign.Hypnogram.risers` (stroke and opacity
    /// verbatim) so the two hypnogram styles describe transitions the same way.
    private static let riserWidth: CGFloat = 1.5
    private static let riserOpacity: Double = 0.35
    /// The lane labels — `font-size="9"`.
    private static let laneLabelSize: CGFloat = 9
    /// The band the sleeping-HR path occupies, top and bottom.
    private static let hrTop: CGFloat = 144
    private static let hrBottom: CGFloat = 162
    /// `stroke-width="1.4"` on the HR path.
    private static let hrStroke: CGFloat = 1.4
    /// The axis labels — `font-size="10"`, baseline `y="174"`.
    private static let axisLabelSize: CGFloat = 10
    private static let axisBaseline: CGFloat = 174

    // MARK: Input

    private let intervals: [SleepInterval]
    private let heartRate: [LedgerHRPoint]
    private let nightStart: Date?
    private let height: CGFloat
    private let showsTimeAxis: Bool
    private let animates: Bool

    /// - Parameters:
    ///   - intervals: stage segments in seconds from the start of the night — the same
    ///     `StrandDesign.SleepInterval` values `SleepView.decodeSegments` already produces. Empty
    ///     renders the designed empty state (lanes + labels + a caption), not a blank box.
    ///   - heartRate: the sleeping-HR overlay. Empty omits the line; the lanes are unchanged.
    ///   - nightStart: wall-clock start of the night. `nil` omits the time axis labels.
    ///   - height: total height. Default `176`, the board's. Other values scale every vertical
    ///     metric proportionally.
    ///   - showsTimeAxis: draw the three clock labels. Needs `nightStart`. Default `true`.
    ///   - animates: `false` renders at final geometry. Default `true` ⇒ a single 1.2 s draw-in on
    ///     appear (a left-to-right reveal of the bars, a trim of the HR line), collapsing to a
    ///     150 ms fade under Reduce Motion. Never re-runs on a data tick.
    public init(
        intervals: [SleepInterval],
        heartRate: [LedgerHRPoint] = [],
        nightStart: Date? = nil,
        height: CGFloat = 176,
        showsTimeAxis: Bool = true,
        animates: Bool = true
    ) {
        self.intervals = intervals.sorted { $0.start < $1.start }
        self.heartRate = heartRate.sorted { $0.seconds < $1.seconds }
        self.nightStart = nightStart
        self.height = height
        self.showsTimeAxis = showsTimeAxis
        self.animates = animates
    }

    // MARK: Derived

    private var scale: CGFloat { height / Self.designHeight }

    /// The night's span in seconds — 0 to the last segment's end (or the last HR sample, if the
    /// trace runs past it).
    private var span: TimeInterval {
        let stageEnd = intervals.map(\.end).max() ?? 0
        let hrEnd = heartRate.last?.seconds ?? 0
        return max(stageEnd, hrEnd)
    }

    private var isEmpty: Bool { intervals.isEmpty || span <= 0 }

    /// The HR trace's bpm domain, padded so the line is not flattened onto the band's edges.
    private var hrDomain: ClosedRange<Double>? {
        LedgerScale.domain(values: heartRate.map(\.bpm), pad: 0.12)
    }

    public var body: some View {
        GeometryReader { geo in
            let plotWidth = max(0, geo.size.width - Self.labelColumn * scale)
            ZStack(alignment: .topLeading) {
                guides(plotWidth: plotWidth)
                laneLabels
                if isEmpty {
                    emptyCaption(plotWidth: plotWidth)
                } else if animates {
                    LedgerDrawIn(.chart) { progress in
                        plot(plotWidth: plotWidth, progress: progress)
                    }
                } else {
                    plot(plotWidth: plotWidth, progress: 1)
                }
                if showsTimeAxis, nightStart != nil, !isEmpty {
                    axis(plotWidth: plotWidth)
                }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Sleep stage timeline"))
    }

    // MARK: Layers

    /// The four `rgba(255,255,255,.045)` lane guides.
    @ViewBuilder
    private func guides(plotWidth: CGFloat) -> some View {
        ForEach(Array(Self.laneCentres.enumerated()), id: \.offset) { _, centre in
            Rectangle()
                .fill(Ledger.hairlineChart)
                .frame(width: plotWidth, height: Ledger.hairlineWidth)
                .offset(x: Self.labelColumn * scale,
                        y: centre * scale - Ledger.hairlineWidth / 2)
        }
    }

    /// `AWAKE · REM · LIGHT · DEEP`, 9pt, `text/tertiary`, centred on their lanes.
    @ViewBuilder
    private var laneLabels: some View {
        ForEach(SleepStage.allCases.sorted { $0.bandRank < $1.bandRank }, id: \.self) { stage in
            Text(verbatim: stage.ledgerLaneLabel)
                .font(LedgerType.label(Self.laneLabelSize * scale, LedgerType.regular))
                .foregroundStyle(Ledger.textTertiary)
                .frame(width: Self.labelColumn * scale,
                       height: Self.barHeight * scale,
                       alignment: .leading)
                .offset(y: Self.laneCentres[stage.bandRank] * scale - Self.barHeight * scale / 2)
        }
    }

    /// The stage capsules plus the sleeping-HR overlay, revealed by `progress`.
    @ViewBuilder
    private func plot(plotWidth: CGFloat, progress: Double) -> some View {
        ZStack(alignment: .topLeading) {
            // Drawn FIRST so every segment sits on top of its risers — the staircase is traced, the
            // segments own the ink.
            risers(plotWidth: plotWidth)

            ForEach(intervals) { interval in
                let x = CGFloat(interval.start / span) * plotWidth
                // A segment is never narrower than its corner diameter, so a one-minute wake still
                // reads as a rounded chip rather than a sliver.
                let w = max(Self.barRadius * scale * 2,
                            CGFloat(interval.duration / span) * plotWidth)
                RoundedRectangle(cornerRadius: Self.barRadius * scale, style: .continuous)
                    .fill(interval.stage.ledgerStage.color)
                    .frame(width: w, height: Self.barHeight * scale)
                    .offset(x: Self.labelColumn * scale + x,
                            y: Self.laneCentres[interval.stage.bandRank] * scale
                                - Self.barHeight * scale / 2)
            }

            if let hrDomain, heartRate.count >= 2 {
                LedgerPolyline(points: heartRate.map { point in
                    CGPoint(x: CGFloat(point.seconds / span),
                            y: LedgerScale.normalizedY(point.bpm, in: hrDomain))
                })
                .trim(from: 0, to: progress)
                .stroke(Ledger.accentLiveHR.opacity(Ledger.sleepingHROpacity),
                        style: StrokeStyle(lineWidth: Self.hrStroke,
                                           lineCap: .round,
                                           lineJoin: .round))
                .frame(width: plotWidth,
                       height: (Self.hrBottom - Self.hrTop) * scale)
                .offset(x: Self.labelColumn * scale, y: Self.hrTop * scale)
            }
        }
        // The lanes are positioned with `.offset`, which paints outside the ZStack's LAYOUT bounds
        // (offsets never grow them) — so the stack must be framed to the full plot area BEFORE the
        // mask, or the mask (sized to those bounds) would clip every lane below the first.
        .frame(width: Self.labelColumn * scale + plotWidth, height: height, alignment: .topLeading)
        // The bars have no trim of their own, so the draw-in is a left-to-right reveal — the same
        // gesture, applied to a stepped shape.
        .mask(alignment: .topLeading) {
            Rectangle()
                .frame(width: Self.labelColumn * scale + plotWidth * CGFloat(progress))
        }
    }

    /// WHOOP-style transition risers: a thin vertical hairline at each stage boundary, from the
    /// outgoing lane's centre to the incoming one's — the staircase between levels. Stroke, width
    /// and opacity mirror `StrandDesign.Hypnogram.risers` so both hypnogram styles trace
    /// transitions identically. Consecutive intervals only: a data gap draws no riser, because a
    /// line across a gap would claim a transition nobody measured.
    private func risers(plotWidth: CGFloat) -> some View {
        Path { p in
            guard intervals.count >= 2 else { return }
            for i in 0..<(intervals.count - 1) {
                let a = intervals[i]
                let b = intervals[i + 1]
                guard a.stage.bandRank != b.stage.bandRank else { continue }
                let x = Self.labelColumn * scale + CGFloat(b.start / span) * plotWidth
                p.move(to: CGPoint(x: x, y: Self.laneCentres[a.stage.bandRank] * scale))
                p.addLine(to: CGPoint(x: x, y: Self.laneCentres[b.stage.bandRank] * scale))
            }
        }
        .stroke(Ledger.textTertiary.opacity(Self.riserOpacity),
                style: StrokeStyle(lineWidth: Self.riserWidth,
                                   lineCap: .round, lineJoin: .round))
    }

    /// The three clock labels: onset (left), midpoint (centred), wake (right).
    @ViewBuilder
    private func axis(plotWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: clock(0))
            Spacer(minLength: 0)
            Text(verbatim: clock(span / 2))
            Spacer(minLength: 0)
            Text(verbatim: clock(span))
        }
        .font(LedgerType.caption(Self.axisLabelSize * scale))
        .foregroundStyle(Ledger.textTertiary)
        .frame(width: plotWidth, alignment: .leading)
        .offset(x: Self.labelColumn * scale,
                y: (Self.axisBaseline - Self.axisLabelSize) * scale)
    }

    @ViewBuilder
    private func emptyCaption(plotWidth: CGFloat) -> some View {
        Text("No stage data for this night")
            .ledgerCaptionStyle(11)
            .frame(width: plotWidth, height: height, alignment: .center)
            .offset(x: Self.labelColumn * scale)
    }

    // MARK: Formatting

    private func clock(_ offset: TimeInterval) -> String {
        guard let nightStart else { return "" }
        return Self.clockFormatter.string(from: nightStart.addingTimeInterval(offset))
    }

    /// `HH:mm` in the user's locale/calendar — the boards print `23:12 · 03:00 · 07:04`.
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("Hm")
        return formatter
    }()
}

#if DEBUG
private func ledgerSampleNight() -> [SleepInterval] {
    var out: [SleepInterval] = []
    var t: TimeInterval = 0
    func add(_ stage: SleepStage, _ minutes: Double) {
        out.append(SleepInterval(stage: stage, start: t, end: t + minutes * 60))
        t += minutes * 60
    }
    add(.awake, 6); add(.light, 42); add(.deep, 36); add(.light, 26); add(.rem, 24)
    add(.light, 30); add(.deep, 24); add(.light, 20); add(.rem, 32); add(.light, 26)
    add(.awake, 8)
    return out
}

#Preview("LedgerHypnogram") {
    let start = Calendar.current.date(bySettingHour: 23, minute: 12, second: 0, of: Date())
    let night = ledgerSampleNight()
    let hr: [LedgerHRPoint] = stride(from: 0.0, through: night.last!.end, by: 600).map {
        LedgerHRPoint(seconds: $0, bpm: 56 + 6 * sin($0 / 3600) + Double.random(in: -1.5...1.5))
    }
    return VStack(alignment: .leading, spacing: 12) {
        Text("Night timeline").ledgerOverline()
        LedgerHypnogram(intervals: night, heartRate: hr, nightStart: start)
        Text("Empty").ledgerOverline()
        LedgerHypnogram(intervals: [], nightStart: start)
    }
    .padding(Ledger.pageMargin)
    .frame(width: 393)
    .background(Ledger.bgScreen)
    .preferredColorScheme(.dark)
}
#endif
