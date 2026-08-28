import SwiftUI

// MARK: - LedgerBaselineDotRow — the "WHY" row
//
// Board: `NOOP Redesign.dc.html` → `data-screen-label="Today"`, the WHY ledger.
// Transcribed from the inline CSS, verbatim:
//
//   row      display:flex; align-items:center; gap:14px; padding:12px 0;
//            border-bottom:1px solid rgba(255,255,255,.05)
//   label    width:82px; font-size:13px; color:#9BA3B0
//   track    flex:1; height:4px; border-radius:2px; background:rgba(255,255,255,.06)
//   band     position:absolute; left:32%; width:34%; height:100%;
//            border-radius:2px; background:rgba(255,255,255,.09)
//   dot      left:74%; top:50%; width:9px; height:9px; border-radius:50%;
//            background:#3EE6A8; transform:translate(-50%,-50%); box-shadow:0 0 9px #3EE6A8
//   value    width:94px; text-align:right
//            · value  Space Grotesk 16px / 600
//            · unit   11px  #5C6470   (preceded by a space)
//            · delta  11px  accent when notable · #5C6470 when "on baseline"
//
// SEMANTICS THE BOARD ENCODES:
//   • The **band** is "your normal" — the spec's non-negotiable baseline context.
//   • The **dot** is today. It is accent-coloured *and glows* only when the reading is notable
//     (HRV +9%, Sleep +4). When the reading sits on baseline the dot is `text/secondary` and has
//     NO glow (see the Resting HR and Skin temp rows), and the delta line drops to tertiary.
//
// MOTION: none. Spec §Motion — "Rows/text: no entrance animation — content is instant; only
// data-viz animates." A dot row is a row.
//
// PURE PRESENTATION. Plain value types only; no `Repository`, no view model, no derivation. The
// caller passes already-normalized 0…1 positions (or uses the `value:in:` convenience init, which
// only does the arithmetic the board's percentages already imply).

/// A Today "WHY" ledger row: a label, a baseline-band track carrying a today-dot, and a
/// value + unit + delta column.
///
/// ```swift
/// LedgerBaselineDotRow(
///     label: "HRV",
///     todayFraction: 0.74,
///     baselineFraction: 0.32...0.66,
///     value: "62", unit: "ms", delta: "+9% vs base",
///     accent: Ledger.accentRecovery, isNotable: true
/// ) { path.append(TabRoute.metric("hrv")) }
/// ```
public struct LedgerBaselineDotRow: View {

    // MARK: Board constants

    /// Track height — 4pt (`height:4px`).
    private static let trackHeight: CGFloat = 4
    /// Track corner radius — 2pt (`border-radius:2px`), i.e. a fully-rounded 4pt rail.
    private static let trackRadius: CGFloat = 2
    /// Today-dot diameter — 9pt (`width:9px;height:9px`).
    private static let dotDiameter: CGFloat = 9
    /// The dot's glow. CSS `box-shadow:0 0 9px` is a 9px *blur*; SwiftUI's shadow `radius` is
    /// roughly half a CSS blur radius, so 9 ÷ 2 = 4.5.
    private static let dotGlowRadius: CGFloat = 4.5
    /// Value column width — 94pt (`width:94px`).
    private static let valueColumnWidth: CGFloat = 94
    /// Row label — 13pt (`font-size:13px`), `text/secondary`.
    private static let labelSize: CGFloat = 13
    /// Unit + delta — 11pt (`font-size:11px`).
    private static let footnoteSize: CGFloat = 11
    /// Row value numeral — 16pt / 600 (`font-size:16px;font-weight:600`).
    private static let valueSize: CGFloat = 16
    /// Row vertical padding — 12pt (`padding:12px 0`).
    private static let rowVerticalPadding: CGFloat = 12
    /// Shown in place of a value or a delta that does not exist. An em-dash, not prose — a
    /// component that ships its own English copy is a component a screen cannot localize.
    private static let absentValue = "\u{2014}"
    /// See `absentValue`.
    private static let absentDelta = "\u{2014}"


    // MARK: Stored

    private let label: String
    private let todayFraction: Double?
    private let baselineFraction: ClosedRange<Double>?
    private let value: String?
    private let unit: String?
    private let delta: String?
    private let accent: Color
    private let isNotable: Bool
    private let showsDivider: Bool
    private let action: (() -> Void)?

    /// - Parameters:
    ///   - label: the row's name, e.g. `"HRV"`. Rendered 13/400 in `text/secondary`.
    ///   - todayFraction: today's position along the track, `0…1`. `nil` draws no dot — the
    ///     designed no-reading state.
    ///   - baselineFraction: the "your normal" span along the track, `0…1`. `nil` draws no band
    ///     (there is no baseline yet).
    ///   - value: the pre-formatted reading, e.g. `"62"`. `nil` renders an em-dash in tertiary.
    ///   - unit: the unit suffix, e.g. `"ms"`. Rendered 11pt tertiary after a space.
    ///   - delta: the delta line, e.g. `"+9% vs base"` or `"on baseline"`.
    ///   - accent: the domain accent used for the dot and, when `isNotable`, the delta.
    ///   - isNotable: `true` when the reading is off baseline — dot takes the accent and glows,
    ///     delta takes the accent. `false` keeps the dot `text/secondary` with no glow and the
    ///     delta in `text/tertiary`, exactly as the board's Resting HR / Skin temp rows.
    ///   - showsDivider: draws the 1px `white @ 5%` rule beneath. `false` on a section's last row.
    ///   - action: tap destination. `nil` renders a non-interactive row.
    public init(
        label: String,
        todayFraction: Double?,
        baselineFraction: ClosedRange<Double>? = nil,
        value: String?,
        unit: String? = nil,
        delta: String? = nil,
        accent: Color = Ledger.accentRecovery,
        isNotable: Bool = false,
        showsDivider: Bool = true,
        action: (() -> Void)? = nil
    ) {
        self.label = label
        self.todayFraction = todayFraction.map { $0.clampedToUnit }
        self.baselineFraction = baselineFraction.map {
            $0.lowerBound.clampedToUnit ... Swift.max($0.lowerBound.clampedToUnit, $0.upperBound.clampedToUnit)
        }
        self.value = value
        self.unit = unit
        self.delta = delta
        self.accent = accent
        self.isNotable = isNotable
        self.showsDivider = showsDivider
        self.action = action
    }

    /// Convenience: derives the track positions from a reading, its baseline range and the axis
    /// the row is drawn against. The arithmetic is only the normalization the board's `left:%` /
    /// `width:%` already encode — no scoring, no derivation.
    ///
    /// - Parameters:
    ///   - reading: today's raw value in the metric's own units. `nil` → no dot.
    ///   - baseline: the on-device baseline range in the same units. `nil` → no band.
    ///   - scale: the axis the track spans. A degenerate scale (`lowerBound >= upperBound`)
    ///     collapses every position to the mid-point rather than dividing by zero.
    public init(
        label: String,
        reading: Double?,
        baseline: ClosedRange<Double>?,
        scale: ClosedRange<Double>,
        value: String?,
        unit: String? = nil,
        delta: String? = nil,
        accent: Color = Ledger.accentRecovery,
        isNotable: Bool = false,
        showsDivider: Bool = true,
        action: (() -> Void)? = nil
    ) {
        self.init(
            label: label,
            todayFraction: reading.map { Self.fraction($0, in: scale) },
            baselineFraction: baseline.map {
                Self.fraction($0.lowerBound, in: scale) ... Self.fraction($0.upperBound, in: scale)
            },
            value: value,
            unit: unit,
            delta: delta,
            accent: accent,
            isNotable: isNotable,
            showsDivider: showsDivider,
            action: action
        )
    }

    /// Normalizes `value` into `0…1` across `scale`, clamped. A zero-width scale returns `0.5`.
    public static func fraction(_ value: Double, in scale: ClosedRange<Double>) -> Double {
        let span = scale.upperBound - scale.lowerBound
        guard span > 0 else { return 0.5 }
        return ((value - scale.lowerBound) / span).clampedToUnit
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
                Text(label)
                    .font(LedgerType.label(Self.labelSize, LedgerType.regular))
                    .foregroundStyle(Ledger.textSecondary)
                    .lineLimit(1)
                    .frame(width: Ledger.labelColumnToday, alignment: .leading)

                track

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

    // MARK: Track

    private var track: some View {
        GeometryReader { geo in
            let width = geo.size.width

            ZStack(alignment: .leading) {
                // The empty rail — white @ 6%.
                RoundedRectangle(cornerRadius: Self.trackRadius, style: .continuous)
                    .fill(Ledger.track)

                // "Your normal" — white @ 9%, one step above the rail so it reads against it.
                if let band = baselineFraction {
                    let bandX = band.lowerBound * width
                    let bandWidth = Swift.max(0, (band.upperBound - band.lowerBound) * width)
                    RoundedRectangle(cornerRadius: Self.trackRadius, style: .continuous)
                        .fill(Ledger.trackBand)
                        .frame(width: bandWidth)
                        .offset(x: bandX)
                }

                // Today.
                if let today = todayFraction {
                    dot
                        .offset(x: today * width - Self.dotDiameter / 2)
                }
            }
        }
        // GeometryReader has no intrinsic size: this is what makes the rail exactly 4pt tall and
        // as wide as the row's free space. The 9pt dot deliberately overflows it (the board's
        // `transform:translate(-50%,-50%)`); nothing here clips.
        .frame(height: Self.trackHeight)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var dot: some View {
        let fill = isNotable ? accent : Ledger.textSecondary
        Circle()
            .fill(fill)
            .frame(width: Self.dotDiameter, height: Self.dotDiameter)
            // `box-shadow:0 0 9px <accent>` — only on a notable reading.
            .shadow(color: isNotable ? accent : .clear, radius: isNotable ? Self.dotGlowRadius : 0)
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
                    // Designed no-reading state — an em-dash in tertiary, never a zero.
                    Text(Self.absentValue)
                        .ledgerRowValue(Self.valueSize)
                        .foregroundStyle(Ledger.textTertiary)
                }
                if let unit, !unit.isEmpty {
                    Text(" " + unit)
                        .font(LedgerType.label(Self.footnoteSize, LedgerType.regular))
                        .foregroundStyle(Ledger.textTertiary)
                }
            }
            .lineLimit(1)

            // No delta = no baseline to compare against. The row holds its height with an em-dash
            // rather than inventing copy: the words ("on baseline", "no baseline yet") are the
            // screen's to write and to localize, not this component's.
            Text(delta ?? Self.absentDelta)
                .font(LedgerType.label(Self.footnoteSize, LedgerType.regular))
                .foregroundStyle(isNotable && delta != nil ? accent : Ledger.textTertiary)
                .lineLimit(1)
        }
        .frame(width: Self.valueColumnWidth, alignment: .trailing)
    }
}

// MARK: - Clamping

private extension Double {
    /// Clamped into `0…1`. Guards a NaN (which would otherwise poison a `frame(width:)`).
    var clampedToUnit: Double {
        guard isFinite else { return 0 }
        return Swift.min(1, Swift.max(0, self))
    }
}

// MARK: - Preview

#if DEBUG
#Preview("LedgerBaselineDotRow") {
    VStack(spacing: 0) {
        LedgerBaselineDotRow(
            label: "HRV",
            todayFraction: 0.74,
            baselineFraction: 0.32...0.66,
            value: "62", unit: "ms", delta: "+9% vs base",
            accent: Ledger.accentRecovery, isNotable: true
        ) {}

        LedgerBaselineDotRow(
            label: "Resting HR",
            todayFraction: 0.50,
            baselineFraction: 0.38...0.68,
            value: "60", unit: "bpm", delta: "on baseline",
            accent: Ledger.accentRecovery, isNotable: false
        ) {}

        LedgerBaselineDotRow(
            label: "Sleep",
            todayFraction: 0.68,
            baselineFraction: 0.30...0.66,
            value: "82", unit: "score", delta: "+4 vs base",
            accent: Ledger.accentSleep, isNotable: true
        ) {}

        LedgerBaselineDotRow(
            label: "Skin temp",
            reading: 0.2, baseline: -0.3...0.3, scale: -1.5...1.5,
            value: "+0.2", unit: "°C", delta: "in range",
            accent: Ledger.accentCaution, isNotable: false
        ) {}

        // Designed empty state — no reading, no baseline.
        LedgerBaselineDotRow(
            label: "SpO₂",
            todayFraction: nil,
            baselineFraction: nil,
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
