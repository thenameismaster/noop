import SwiftUI

// MARK: - LedgerSparkRow — the Body vitals ledger row
//
// Board: `NOOP Redesign.dc.html` → `data-screen-label="Body"`, the VITALS · LAST NIGHT ledger.
// Transcribed from the inline CSS/SVG, verbatim:
//
//   row      display:flex; align-items:center; gap:14px; padding:13px 0;
//            border-bottom:1px solid rgba(255,255,255,.05)
//   label    width:100px
//            · title  font-size:13px; color:#C9CFD8       ← NOT text/secondary; the board uses
//            · sub    font-size:10.5px; color:#5C6470;      the coach step (#C9CFD8) here.
//                     margin-top:2px
//   spark    <svg width="110" height="26" preserveAspectRatio="none" style="flex:1">
//            <path stroke-width="1.7" stroke="#3EE6A8" opacity=".9">   ← above baseline
//            <path stroke-width="1.7" stroke="#9BA3B0" opacity=".8">   ← otherwise
//   value    width:88px; text-align:right
//            · value  Space Grotesk 17px / 600
//            · unit   11px  #5C6470   (preceded by a space)
//            · delta  10.5px  accent when notable · #5C6470 otherwise
//
// MOTION: the middle slot is a **chart**, so it draws in once — spec §Motion, "Charts: single path
// draw-in 1.2s (trim). No re-animation on data ticks." `LedgerDrawIn(.chart)` runs on `.onAppear`
// only and collapses to a 150 ms fade under Reduce Motion. The label and value columns do not
// animate (rows never do); pass `animatesDrawIn: false` to make the spark instant too.
//
// PURE PRESENTATION. `points` is a plain `[Double]` of already-computed readings — the row does no
// scanning, no averaging and no baseline maths.

/// A Body vitals row: label + sub-label, a 30-day sparkline, and a value + unit + delta column.
/// The whole row is tappable and pushes the metric's detail.
///
/// ```swift
/// LedgerSparkRow(
///     label: "HRV", sublabel: "rMSSD, sleep",
///     points: hrv30d, isAboveBaseline: true,
///     value: "62", unit: "ms", delta: "+9% vs base", deltaTint: Ledger.accentRecovery
/// ) { path.append(TabRoute.metricSourced(key: "hrv", source: source)) }
/// ```
public struct LedgerSparkRow: View {

    // MARK: Board constants

    /// Sparkline slot height — 26pt (`height="26"`).
    private static let sparkHeight: CGFloat = 26
    /// The board draws the spark at `width="110"` with `flex:1` — 110 is its flex *basis*, and it
    /// grows into the free space (and, like `flex-shrink:1`, gives space back on a narrow window).
    private static let sparkNaturalWidth: CGFloat = 110
    /// The mint (above-baseline) stroke's opacity — `.9`.
    private static let aboveBaselineOpacity: Double = 0.9
    /// The grey (at/below-baseline) stroke's opacity — `.8`.
    private static let neutralOpacity: Double = 0.8
    /// Value column width — 88pt (`width:88px`).
    private static let valueColumnWidth: CGFloat = 88
    /// Row title — 13pt (`font-size:13px`), `#C9CFD8`.
    private static let labelSize: CGFloat = 13
    /// Sub-label + delta — 10.5pt (`font-size:10.5px`).
    private static let subSize: CGFloat = 10.5
    /// Unit — 11pt (`font-size:11px`).
    private static let unitSize: CGFloat = 11
    /// Row value numeral — 17pt / 600 (`font-size:17px;font-weight:600`).
    private static let valueSize: CGFloat = 17
    /// Gap between the title and its sub-label — 2pt (`margin-top:2px`).
    private static let labelStackSpacing: CGFloat = 2
    /// Row vertical padding — 13pt (`padding:13px 0`).
    private static let rowVerticalPadding: CGFloat = 13
    /// Shown in place of a value or a delta that does not exist. An em-dash, not prose — a
    /// component that ships its own English copy is a component a screen cannot localize.
    private static let absentValue = "\u{2014}"


    // MARK: Stored

    private let label: String
    private let sublabel: String?
    private let points: [Double]
    private let isAboveBaseline: Bool
    private let value: String?
    private let unit: String?
    private let delta: String?
    private let deltaTint: Color
    private let showsDivider: Bool
    private let animatesDrawIn: Bool
    private let action: (() -> Void)?

    /// - Parameters:
    ///   - label: the vital's name, e.g. `"HRV"`. Rendered 13/400 in `#C9CFD8`.
    ///   - sublabel: the provenance line, e.g. `"rMSSD, sleep"`. 10.5/400 tertiary.
    ///   - points: the 30-day series, oldest → newest. Fewer than two points renders the designed
    ///     "not enough history" state (a dashed hairline) instead of a path.
    ///   - isAboveBaseline: `true` strokes the spark in `accent/recovery` @ 90%; `false` strokes it
    ///     in `text/secondary` @ 80%. Exactly the board's two spark treatments.
    ///   - value: the pre-formatted latest reading, e.g. `"62"`. `nil` renders an em-dash.
    ///   - unit: the unit suffix, e.g. `"ms"`.
    ///   - delta: the delta line, e.g. `"+9% vs base"` / `"on baseline"` / `"in range"`.
    ///   - deltaTint: the delta's colour. Defaults to `text/tertiary` — the board's neutral rows.
    ///   - showsDivider: draws the 1px `white @ 5%` rule beneath. `false` on the last row.
    ///   - animatesDrawIn: runs the 1.2 s chart trim on appear. `false` renders the spark whole.
    ///   - action: tap destination. `nil` renders a non-interactive row.
    public init(
        label: String,
        sublabel: String? = nil,
        points: [Double],
        isAboveBaseline: Bool = false,
        value: String?,
        unit: String? = nil,
        delta: String? = nil,
        deltaTint: Color = Ledger.textTertiary,
        showsDivider: Bool = true,
        animatesDrawIn: Bool = true,
        action: (() -> Void)? = nil
    ) {
        self.label = label
        self.sublabel = sublabel
        self.points = points
        self.isAboveBaseline = isAboveBaseline
        self.value = value
        self.unit = unit
        self.delta = delta
        self.deltaTint = deltaTint
        self.showsDivider = showsDivider
        self.animatesDrawIn = animatesDrawIn
        self.action = action
    }

    // MARK: Body

    public var body: some View {
        if let action {
            Button(action: action) { rowContent }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: Ledger.rowGap) {
                labelColumn
                spark
                valueColumn
            }
            .padding(.vertical, Self.rowVerticalPadding)
            .frame(minHeight: Ledger.rowMinHeight)

            if showsDivider {
                Rectangle()
                    .fill(Ledger.hairlineSoft)
                    .frame(height: Ledger.hairlineWidth)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Label column

    private var labelColumn: some View {
        VStack(alignment: .leading, spacing: Self.labelStackSpacing) {
            Text(label)
                .font(LedgerType.label(Self.labelSize, LedgerType.regular))
                .foregroundStyle(Ledger.textCoach)
                .lineLimit(1)
            if let sublabel, !sublabel.isEmpty {
                Text(sublabel)
                    .font(LedgerType.label(Self.subSize, LedgerType.regular))
                    .foregroundStyle(Ledger.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(width: Ledger.labelColumnBody, alignment: .leading)
    }

    // MARK: Sparkline

    private var strokeColor: Color {
        isAboveBaseline
            ? Ledger.accentRecovery.opacity(Self.aboveBaselineOpacity)
            : Ledger.textSecondary.opacity(Self.neutralOpacity)
    }

    @ViewBuilder
    private var spark: some View {
        if points.count >= 2 {
            Group {
                if animatesDrawIn {
                    LedgerDrawIn(.chart) { progress in
                        sparkPath(trimmedTo: progress)
                    }
                } else {
                    sparkPath(trimmedTo: 1)
                }
            }
            .frame(height: Self.sparkHeight)
            .frame(idealWidth: Self.sparkNaturalWidth, maxWidth: .infinity)
        } else {
            // Designed "not enough history" state: a dashed rule at mid-height, never a flat line
            // that could be mistaken for real, unchanging data.
            emptySpark
                .frame(height: Self.sparkHeight)
                .frame(idealWidth: Self.sparkNaturalWidth, maxWidth: .infinity)
        }
    }

    private func sparkPath(trimmedTo progress: Double) -> some View {
        LedgerSparkline(points: points)
            .trim(from: 0, to: progress)
            .stroke(
                strokeColor,
                style: StrokeStyle(lineWidth: Ledger.sparkStrokeWidth, lineCap: .round, lineJoin: .round)
            )
    }

    private var emptySpark: some View {
        GeometryReader { geo in
            Path { path in
                let y = geo.size.height / 2
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: geo.size.width, y: y))
            }
            .stroke(
                Ledger.textTertiary.opacity(Self.neutralOpacity),
                style: StrokeStyle(lineWidth: Ledger.hairlineWidth, dash: [2, 4])
            )
        }
    }

    // MARK: Value column

    private var valueColumn: some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if let value {
                    Text(value)
                        .ledgerRowValue(Self.valueSize)
                        .foregroundStyle(Ledger.textPrimary)
                } else {
                    Text(Self.absentValue)
                        .ledgerRowValue(Self.valueSize)
                        .foregroundStyle(Ledger.textTertiary)
                }
                if let unit, !unit.isEmpty {
                    Text(" " + unit)
                        .font(LedgerType.label(Self.unitSize, LedgerType.regular))
                        .foregroundStyle(Ledger.textTertiary)
                }
            }
            .lineLimit(1)

            if let delta, !delta.isEmpty {
                Text(delta)
                    .font(LedgerType.label(Self.subSize, LedgerType.regular))
                    .foregroundStyle(deltaTint)
                    .lineLimit(1)
            } else {
                // No delta = no baseline to compare against. The row holds its height with an
                // em-dash rather than inventing copy: the words are the screen's to write.
                Text(Self.absentValue)
                    .font(LedgerType.label(Self.subSize, LedgerType.regular))
                    .foregroundStyle(Ledger.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(width: Self.valueColumnWidth, alignment: .trailing)
    }
}

// MARK: - The sparkline shape

/// A min→max normalized polyline across its rect, oldest point at the leading edge.
///
/// The board's spark is `preserveAspectRatio="none"`: the series stretches to fill the slot in both
/// axes, so the shape reads as *movement*, not as an absolute level. The stroke is inset by half
/// its width top and bottom so a peak is never clipped.
///
/// A flat series (every value equal) draws a horizontal line at mid-height rather than dividing by
/// a zero range.
struct LedgerSparkline: Shape {
    let points: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count >= 2 else { return path }

        let inset = Ledger.sparkStrokeWidth / 2
        let usableHeight = max(0, rect.height - Ledger.sparkStrokeWidth)
        let lowest = points.min() ?? 0
        let highest = points.max() ?? 0
        let span = highest - lowest

        let stepX = points.count > 1 ? rect.width / CGFloat(points.count - 1) : 0

        for (index, value) in points.enumerated() {
            let x = rect.minX + CGFloat(index) * stepX
            let normalized: Double = span > 0 ? (value - lowest) / span : 0.5
            // SVG y grows downward: a high value sits near the top.
            let y = rect.minY + inset + usableHeight * (1 - CGFloat(normalized))
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}

// MARK: - Preview

#if DEBUG
#Preview("LedgerSparkRow") {
    VStack(spacing: 0) {
        LedgerSparkRow(
            label: "HRV", sublabel: "rMSSD, sleep",
            points: [18, 15, 19, 13, 16, 10, 13, 8, 6].map { 26 - $0 },
            isAboveBaseline: true,
            value: "62", unit: "ms", delta: "+9% vs base",
            deltaTint: Ledger.accentRecovery
        ) {}

        LedgerSparkRow(
            label: "Resting HR", sublabel: "lowest 5-min",
            points: [8, 10, 7, 12, 10, 14, 12, 13, 12].map { 26 - $0 },
            value: "60", unit: "bpm", delta: "on baseline"
        ) {}

        LedgerSparkRow(
            label: "Respiratory", sublabel: "breaths / min",
            points: [13, 12, 14, 12, 13, 11, 13, 12, 13].map { 26 - $0 },
            value: "14.8", unit: "rpm", delta: "in range"
        ) {}

        // Designed empty state — no history, no reading.
        LedgerSparkRow(
            label: "SpO₂", sublabel: "overnight mean",
            points: [],
            value: nil, unit: "%", delta: nil,
            showsDivider: false
        )
    }
    .padding(.horizontal, Ledger.pageMargin)
    .frame(width: 393)
    .background(Ledger.bgScreen)
    .preferredColorScheme(.dark)
}
#endif
