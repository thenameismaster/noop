import SwiftUI

// MARK: - LedgerStageBar — one row of the Sleep board's STAGES ledger
//
// Transcribed from `data-screen-label="Sleep"` → the `STAGES` section, whose rows are:
//
//   <div style="display:flex;align-items:center;gap:14px;padding:11px 0;
//               border-bottom:1px solid rgba(255,255,255,.05)">
//     <div style="width:52px;font-size:13px;color:#9BA3B0">Deep</div>
//     <div style="flex:1;position:relative;height:6px;border-radius:3px;background:rgba(255,255,255,.06)">
//       <div style="width:52%;height:100%;border-radius:3px;background:#3B55D9"></div>
//       <div style="position:absolute;left:60%;top:-4px;width:1.5px;height:14px;
//                   background:rgba(255,255,255,.45)"></div>
//     </div>
//     <div style="width:86px;text-align:right">
//       <span style="font-family:'Space Grotesk';font-size:15px;font-weight:600">1:05</span>
//       <div style="font-size:10.5px;color:#F2C14E">−9m vs typical</div>
//     </div>
//   </div>
//
// THE TICK. `top:-4px; height:14px` over a 6px track means the "your typical" mark overhangs the
// bar by exactly 4pt above and 4pt below (4+6+4 = 14). It is `white @ 45%` — chrome, not an accent,
// because "typical" is a reference, not a domain.
//
// THE DELTA'S COLOUR IS NOT DERIVED FROM ITS SIGN. The board paints Deep "−9m vs typical" in
// `accent/caution` and Awake "−8m vs typical" in `accent/recovery`: less deep is bad, less awake is
// good. The component therefore takes a `LedgerTone` and never inspects the number — see
// `LedgerComponentSupport.swift`.
//
// Pure presentation. Fractions arrive pre-computed; this view divides nothing.

/// One stage row: a duration bar in the stage colour, a "typical" tick, a value and a delta.
///
/// ```swift
/// LedgerStageBar(label: "Deep", stage: .deep,
///                fraction: deepMin / longestStageMin,
///                typicalFraction: typicalDeepMin / longestStageMin,
///                value: "1:05", delta: "-9m vs typical", deltaTone: .caution)
/// ```
public struct LedgerStageBar: View {

    // MARK: Board constants

    // `width:52px` on the label column and `width:86px` on the value column are the boards'
    // numbers; they appear as the `labelWidth` / `valueWidth` default arguments below (Swift forbids
    // a public default argument that references a private constant).
    /// `padding:11px 0`.
    private static let verticalPadding: CGFloat = 11
    /// `height:6px; border-radius:3px` on the track.
    private static let trackHeight: CGFloat = 6
    private static let trackRadius: CGFloat = Ledger.barRadiusTight
    /// `width:1.5px; height:14px; top:-4px` on the typical tick.
    private static let tickWidth: CGFloat = 1.5
    private static let tickHeight: CGFloat = 14
    /// `font-size:13px` on the label.
    private static let labelSize: CGFloat = 13
    /// `font-size:15px; font-weight:600` on the value — the STAGES board's own size, at the tight
    /// end of the spec table's 16–17 row-value range because this row carries a two-line right
    /// column inside a 44pt target.
    private static let valueSize: CGFloat = 15
    /// `font-size:10.5px` on the delta.
    private static let deltaSize: CGFloat = 10.5

    // MARK: Input

    private let label: String
    private let stage: Ledger.Stage
    private let fraction: Double?
    private let typicalFraction: Double?
    private let value: String
    private let delta: String?
    private let deltaTone: LedgerTone
    private let labelWidth: CGFloat
    private let valueWidth: CGFloat
    private let showsDivider: Bool
    private let animates: Bool
    private let action: (() -> Void)?

    /// - Parameters:
    ///   - label: the stage's name, as the screen words it (`Deep · REM · Light · Awake`).
    ///   - stage: the stage token that colours the bar.
    ///   - fraction: the bar's fill, 0…1, already normalized by the screen (the boards normalize
    ///     against the night's longest stage, not against the total). **`nil` renders the empty
    ///     state** — an untouched track and an em-dash value.
    ///   - typicalFraction: where the white @ 45% "your typical" tick sits, 0…1. `nil` omits it,
    ///     which is the correct state before enough nights exist to have a typical.
    ///   - value: the pre-formatted duration (`"1:05"`). The component formats nothing.
    ///   - delta: the pre-formatted comparison (`"-9m vs typical"`). `nil` omits the line.
    ///   - deltaTone: the delta's colour. The SCREEN decides polarity; see the note above.
    ///   - labelWidth: label column. Default `52`, the board's `width:52px`.
    ///   - valueWidth: value column. Default `86`, the board's `width:86px`.
    ///   - showsDivider: the `white @ 5%` rule beneath. Default `true`; pass `false` on the last
    ///     row of a section, exactly as the board's fourth row does.
    ///   - animates: `false` renders at final width. Default `true` ⇒ the bar grows in over 1.2 s
    ///     on appear, collapsing to a 150 ms fade under Reduce Motion.
    ///   - action: makes the row tappable (the board's stage-highlight behaviour). `nil` = inert.
    public init(
        label: String,
        stage: Ledger.Stage,
        fraction: Double?,
        typicalFraction: Double? = nil,
        value: String,
        delta: String? = nil,
        deltaTone: LedgerTone = .neutral,
        labelWidth: CGFloat = 52,
        valueWidth: CGFloat = 86,
        showsDivider: Bool = true,
        animates: Bool = true,
        action: (() -> Void)? = nil
    ) {
        self.label = label
        self.stage = stage
        self.fraction = fraction.map { min(1, max(0, $0)) }
        self.typicalFraction = typicalFraction.map { min(1, max(0, $0)) }
        self.value = value
        self.delta = delta
        self.deltaTone = deltaTone
        self.labelWidth = labelWidth
        self.valueWidth = valueWidth
        self.showsDivider = showsDivider
        self.animates = animates
        self.action = action
    }

    public var body: some View {
        Group {
            if let action {
                Button(action: action) { row }
                    .buttonStyle(.plain)
            } else {
                row
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var row: some View {
        VStack(spacing: 0) {
            HStack(spacing: Ledger.rowGap) {
                Text(label)
                    .font(LedgerType.label(Self.labelSize, LedgerType.regular))
                    .foregroundStyle(Ledger.textSecondary)
                    .frame(width: labelWidth, alignment: .leading)

                track

                VStack(alignment: .trailing, spacing: 2) {
                    Text(value)
                        .ledgerRowValue(Self.valueSize)
                        .foregroundStyle(fraction == nil ? Ledger.textTertiary : Ledger.textPrimary)
                    if let delta {
                        Text(delta)
                            .font(LedgerType.caption(Self.deltaSize))
                            .foregroundStyle(deltaTone.color)
                    }
                }
                .frame(width: valueWidth, alignment: .trailing)
            }
            .padding(.vertical, Self.verticalPadding)
            .frame(minHeight: Ledger.rowMinHeight)

            if showsDivider {
                Rectangle()
                    .fill(Ledger.hairlineSoft)
                    .frame(height: Ledger.hairlineWidth)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: Track

    private var track: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Ledger.track)

                if let fraction {
                    if animates {
                        LedgerDrawIn(.chart) { progress in
                            fill(width: geo.size.width * CGFloat(fraction * progress))
                        }
                    } else {
                        fill(width: geo.size.width * CGFloat(fraction))
                    }
                }

                if let typicalFraction {
                    Rectangle()
                        .fill(Ledger.typicalTick)
                        .frame(width: Self.tickWidth, height: Self.tickHeight)
                        // `left:X%` positions the tick's LEADING edge in CSS; centre it on that x so
                        // a tick at 100% is not half-clipped by the track's end.
                        .offset(x: max(0, min(geo.size.width - Self.tickWidth,
                                              geo.size.width * CGFloat(typicalFraction)
                                                - Self.tickWidth / 2)))
                }
            }
            .frame(height: Self.trackHeight, alignment: .leading)
            .frame(maxHeight: .infinity)
        }
        .frame(height: Self.tickHeight)   // the row's track band is as tall as the tallest thing in it
    }

    private func fill(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Self.trackRadius, style: .continuous)
            .fill(stage.color)
            .frame(width: max(0, width))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
#Preview("LedgerStageBar") {
    VStack(spacing: 0) {
        Text("Stages").ledgerOverline()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 6)
        LedgerStageBar(label: "Deep", stage: .deep, fraction: 0.52, typicalFraction: 0.60,
                       value: "1:05", delta: "-9m vs typical", deltaTone: .caution)
        LedgerStageBar(label: "REM", stage: .rem, fraction: 0.66, typicalFraction: 0.58,
                       value: "1:22", delta: "+11m vs typical", deltaTone: .good)
        LedgerStageBar(label: "Light", stage: .light, fraction: 0.82, typicalFraction: 0.79,
                       value: "4:12", delta: "+6m vs typical", deltaTone: .neutral)
        LedgerStageBar(label: "Awake", stage: .awake, fraction: 0.16, typicalFraction: 0.22,
                       value: "0:30", delta: "-8m vs typical", deltaTone: .good,
                       showsDivider: false)
        LedgerStageBar(label: "Deep", stage: .deep, fraction: nil,
                       value: "\u{2014}", showsDivider: false)
    }
    .padding(Ledger.pageMargin)
    .frame(width: 393)
    .background(Ledger.bgScreen)
    .preferredColorScheme(.dark)
}
#endif
