import SwiftUI

// MARK: - LedgerScoreArc — the Today/Body hero
//
// Transcribed from the board's readiness-hero SVG (`data-screen-label="Today"`), verbatim:
//
//   <svg width="216" height="216" viewBox="0 0 216 216">
//     <circle cx="108" cy="108" r="94" fill="none" stroke="rgba(255,255,255,.06)" stroke-width="9"
//             stroke-linecap="round" stroke-dasharray="443 590" transform="rotate(125 108 108)"/>
//     <circle cx="108" cy="108" r="94" fill="none" stroke="#3EE6A8" stroke-width="9"
//             stroke-linecap="round" stroke-dasharray="328 590" transform="rotate(125 108 108)"
//             style="filter:drop-shadow(0 0 16px rgba(62,230,168,.35))"/>
//     <line x1="108" y1="10" x2="108" y2="22" stroke="rgba(255,255,255,.25)" stroke-width="1.5"/>
//   </svg>
//
// READING THE DASH ARRAY. Circumference = 2πr = 2π·94 = 590.62 — which is the SVG's second dash
// value, i.e. "one full turn of gap". The first value is the drawn run:
//   • track `443` → 443/590.62 = 0.750 of the circle = **270°**, the spec's open arc.
//   • fill  `328` → 328/443   = 0.740 of the ARC     = the score, 74/100.
// So the fill is `score/100` of a 270° sweep — NOT of the full circle. `rotate(125 …)` puts the
// arc's start at 125° clockwise from 3 o'clock, leaving the 90° opening centred on 80° (just left
// of 6 o'clock). Those are the board's numbers; they are not symmetrised here.
//
// THE MINI VARIANT IS A DIFFERENT SHAPE, not a scaled hero. From the Body board:
//   <circle r="24" stroke-width="5"/>                                    ← full-circle track, no dash
//   <circle r="24" stroke-width="5" stroke-linecap="round"
//           stroke-dasharray="112 151" transform="rotate(-90 28 28)"/>   ← 112/150.8 = 74/100
//   <text font-size="16" font-weight="700">74</text>
// 2π·24 = 150.80 = the dash gap, so the mini fill is `score/100` of a FULL 360° ring starting at
// 12 o'clock. It carries no index tick, no state word and no glow — the board's mini `<circle>` has
// no `filter`. Both facts are reproduced, not harmonised.
//
// Pure presentation: it takes a `Double?`, a colour and a word. It never computes a score, never
// touches a `Repository`, and never observes a live object.

/// The readiness/recovery arc. `.hero` is the Today 216pt open arc; `.mini` is the Body header's
/// 56pt ring.
///
/// ```swift
/// LedgerScoreArc(score: day.recovery)                                  // Today hero
/// LedgerScoreArc(score: day.recovery, style: .mini)                    // Body header
/// LedgerScoreArc(score: strain, style: .hero, scale: 0...21,           // any 0…max metric
///                accent: Ledger.accentStrain, stateWord: "OPTIMAL")
/// ```
public struct LedgerScoreArc: View {

    // MARK: Style

    /// Which of the two arcs the boards draw.
    public enum Style: String, CaseIterable, Sendable {
        /// Today's readiness hero — 216pt, 9pt stroke, a 270° open arc starting at 125°, an index
        /// tick at 12 o'clock, a 66/700 numeral and the state word beneath it.
        case hero
        /// The Body header's recovery ring — 56pt, 5pt stroke, a full 360° ring from 12 o'clock,
        /// a 16/700 numeral, no tick and no word.
        case mini

        // Board geometry. Every number below appears literally in the SVG quoted above.

        /// Outer box, points. Hero `216`, mini `56`.
        var diameter: CGFloat { self == .hero ? Ledger.arcDiameter : Ledger.miniRingDiameter }
        /// Stroke width. Hero `9`, mini `5`.
        var stroke: CGFloat { self == .hero ? Ledger.arcStrokeWidth : Ledger.miniRingStrokeWidth }
        /// `r / (diameter/2)` — hero `94/108`, mini `24/28`.
        var radiusRatio: CGFloat { self == .hero ? 94.0 / 108.0 : 24.0 / 28.0 }
        /// Sweep. Hero `270`, mini `360`.
        var sweep: Double { self == .hero ? Ledger.arcSweepDegrees : 360 }
        /// Start angle, clockwise from 3 o'clock. Hero `125`, mini `-90` (12 o'clock).
        var start: Double { self == .hero ? Ledger.arcStartDegrees : -90 }
        /// The 12-o'clock index tick — hero only.
        var showsTick: Bool { self == .hero }
        /// The accent glow — hero only (the mini `<circle>` carries no `filter`).
        var glows: Bool { self == .hero }
        /// The centre numeral's font. Hero `66/700`, mini `16/700`.
        var numeralFont: Font {
            self == .hero ? LedgerType.displayNumeral : LedgerType.numeral(16, LedgerType.bold)
        }
        /// The centre numeral's tracking. Hero `-3`; the mini board sets none.
        var numeralTracking: CGFloat { self == .hero ? LedgerType.displayTracking : 0 }
    }

    // MARK: Board constants

    /// `<line x1="108" y1="10" … y2="22">` — the tick runs from `r = 98` to `r = 86` in the 216 box,
    /// i.e. 98/108 and 86/108 of the half-box, so it scales with the arc.
    private static let tickOuterRatio: CGFloat = 98.0 / 108.0
    private static let tickInnerRatio: CGFloat = 86.0 / 108.0
    /// `stroke-width="1.5"` on the tick.
    private static let tickWidth: CGFloat = 1.5

    /// The state word — `font-size:11px; font-weight:700; letter-spacing:3px`.
    private static let wordSize: CGFloat = 11
    private static let wordTracking: CGFloat = 3
    /// `margin-top:7px` between the numeral and the state word.
    private static let wordTopGap: CGFloat = 7

    /// `drop-shadow(0 0 16px …)`. A CSS drop-shadow's third length is the BLUR DIAMETER, whereas
    /// SwiftUI's `.shadow(radius:)` is the blur radius — so the board's `16px` is `radius: 8` here.
    /// The spec's number is preserved; only the unit is converted.
    private static let glowBlurCSS: CGFloat = 16
    private static var glowRadius: CGFloat { glowBlurCSS / 2 }
    /// `rgba(…,.35)` on the glow.
    private static let glowOpacity: Double = 0.35

    // MARK: Input

    private let score: Double?
    private let style: Style
    private let scale: ClosedRange<Double>
    private let accentOverride: Color?
    private let stateWordOverride: String?
    private let showsStateWord: Bool
    private let animates: Bool
    private let format: (Double) -> String

    /// - Parameters:
    ///   - score: the value to draw, in `scale`. **`nil` renders the designed empty state** — track
    ///     only, an em-dash numeral and a `NO DATA` word, all in `text/tertiary`.
    ///   - style: `.hero` (216pt open arc) or `.mini` (56pt ring). Default `.hero`.
    ///   - scale: the value range the sweep spans. Default `0...100` (recovery / sleep score).
    ///     Pass `0...21` to draw WHOOP-axis strain on the same arc.
    ///   - accent: overrides the band accent. Default `nil` ⇒ `Ledger.recoveryAccent(score)`, i.e.
    ///     mint ≥ 70 / caution 50…69 / red < 50, on the existing recovery-band cut points.
    ///   - stateWord: overrides the caption. Default `nil` ⇒ `Ledger.recoveryWord(score)`, the
    ///     existing `DEPLETED · LOW · MODERATE · PRIMED · PEAK` vocabulary.
    ///   - showsStateWord: hide the caption without hiding the numeral. `.mini` never shows it.
    ///   - animates: `false` renders at final geometry with no draw-in (previews, snapshot tests,
    ///     a row that scrolls in repeatedly). Default `true` ⇒ 900 ms trim + 700 ms count-up on
    ///     appear only, collapsing to a 150 ms fade under Reduce Motion.
    ///   - format: renders the numeral. Default rounds to a whole number.
    public init(
        score: Double?,
        style: Style = .hero,
        scale: ClosedRange<Double> = 0...100,
        accent: Color? = nil,
        stateWord: String? = nil,
        showsStateWord: Bool = true,
        animates: Bool = true,
        format: @escaping (Double) -> String = { "\(Int($0.rounded()))" }
    ) {
        self.score = score
        self.style = style
        self.scale = scale
        self.accentOverride = accent
        self.stateWordOverride = stateWord
        self.showsStateWord = showsStateWord
        self.animates = animates
        self.format = format
    }

    // MARK: Derived

    /// 0…1 of the arc's sweep. Clamped, so a value past the scale cannot wrap the arc.
    private var fraction: Double {
        guard let score else { return 0 }
        let span = scale.upperBound - scale.lowerBound
        guard span > 0 else { return 0 }
        return min(1, max(0, (score - scale.lowerBound) / span))
    }

    private var accent: Color {
        if let accentOverride { return accentOverride }
        guard let score else { return Ledger.textTertiary }
        return Ledger.recoveryAccent(score)
    }

    private var word: String? {
        guard showsStateWord, style == .hero else { return nil }
        if let stateWordOverride { return stateWordOverride }
        guard let score else { return nil }
        return Ledger.recoveryWord(score)
    }

    public var body: some View {
        ZStack {
            if animates {
                LedgerDrawIn(.arc) { progress in ring(progress: progress) }
            } else {
                ring(progress: 1)
            }
            centre
        }
        .frame(width: style.diameter, height: style.diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: Ring

    @ViewBuilder
    private func ring(progress: Double) -> some View {
        ZStack {
            // Track — the full sweep at white @ 6%.
            LedgerArcShape(startDegrees: style.start,
                           sweepDegrees: style.sweep,
                           radiusRatio: style.radiusRatio)
                .stroke(Ledger.arcTrack,
                        style: StrokeStyle(lineWidth: style.stroke, lineCap: .round))

            // Fill — `score/scale` of the sweep, in the band accent, with the board's glow.
            LedgerArcShape(startDegrees: style.start,
                           sweepDegrees: style.sweep,
                           radiusRatio: style.radiusRatio)
                .trim(from: 0, to: fraction * progress)
                .stroke(accent, style: StrokeStyle(lineWidth: style.stroke, lineCap: .round))
                .shadow(color: style.glows ? accent.opacity(Self.glowOpacity) : .clear,
                        radius: style.glows ? Self.glowRadius : 0)

            // Index tick at 12 o'clock — drawn last, so it sits on top of the stroke exactly as the
            // board's `<line>` does.
            if style.showsTick {
                LedgerArcTick(outerRatio: Self.tickOuterRatio, innerRatio: Self.tickInnerRatio)
                    .stroke(Ledger.arcTick, lineWidth: Self.tickWidth)
            }
        }
    }

    // MARK: Centre

    @ViewBuilder
    private var centre: some View {
        VStack(spacing: 0) {
            numeral
            if let word {
                Text(word)
                    .font(LedgerType.label(Self.wordSize, LedgerType.bold))
                    .tracking(Self.wordTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(accent)
                    .padding(.top, Self.wordTopGap)
            }
        }
    }

    @ViewBuilder
    private var numeral: some View {
        if let score {
            if animates {
                LedgerCountUpNumeral(value: score,
                                     font: style.numeralFont,
                                     tracking: style.numeralTracking,
                                     format: format)
                    .foregroundStyle(Ledger.textPrimary)
            } else {
                Text(format(score))
                    .font(style.numeralFont)
                    .tracking(style.numeralTracking)
                    .foregroundStyle(Ledger.textPrimary)
            }
        } else {
            // Designed empty state: the arc still occupies its 216pt (nothing reflows when the day
            // finishes loading), the track stays, and the hole reads as "not measured", not "zero".
            Text(verbatim: "\u{2014}")
                .font(style.numeralFont)
                .tracking(style.numeralTracking)
                .foregroundStyle(Ledger.textTertiary)
            if style == .hero && showsStateWord {
                Text("NO DATA")
                    .font(LedgerType.label(Self.wordSize, LedgerType.bold))
                    .tracking(Self.wordTracking)
                    .foregroundStyle(Ledger.textTertiary)
                    .padding(.top, Self.wordTopGap)
            }
        }
    }

    private var accessibilityText: String {
        guard let score else { return String(localized: "No score") }
        if let word { return "\(format(score)) \(word)" }
        return format(score)
    }
}

// MARK: - Shapes

/// One open arc, centred in its rect. Angles are degrees clockwise from 3 o'clock — SVG's
/// convention, so a `transform="rotate(125 …)"` transcribes as `startDegrees: 125`.
struct LedgerArcShape: Shape {
    var startDegrees: Double
    var sweepDegrees: Double
    /// `r` as a fraction of the rect's half-extent, so the stroke's centreline lands where the
    /// board's `r` puts it rather than on the frame edge.
    var radiusRatio: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 * radiusRatio
        guard radius > 0 else { return path }
        path.addArc(center: centre,
                    radius: radius,
                    startAngle: .degrees(startDegrees),
                    endAngle: .degrees(startDegrees + sweepDegrees),
                    clockwise: false)
        return path
    }
}

/// The 12-o'clock index tick — a radial line from `outerRatio` to `innerRatio` of the half-extent.
struct LedgerArcTick: Shape {
    var outerRatio: CGFloat
    var innerRatio: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let half = min(rect.width, rect.height) / 2
        path.move(to: CGPoint(x: centre.x, y: centre.y - half * outerRatio))
        path.addLine(to: CGPoint(x: centre.x, y: centre.y - half * innerRatio))
        return path
    }
}

#if DEBUG
#Preview("LedgerScoreArc") {
    ScrollView {
        VStack(spacing: 28) {
            LedgerScoreArc(score: 74)
            HStack(spacing: 24) {
                LedgerScoreArc(score: 91, style: .mini)
                LedgerScoreArc(score: 58, style: .mini)
                LedgerScoreArc(score: 31, style: .mini)
                LedgerScoreArc(score: nil, style: .mini)
            }
            LedgerScoreArc(score: 42)
            LedgerScoreArc(score: nil)
        }
        .padding(Ledger.pageMargin)
        .frame(maxWidth: .infinity)
    }
    .background(Ledger.bgScreen)
    .preferredColorScheme(.dark)
}
#endif
