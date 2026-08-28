import SwiftUI

// MARK: - Ledger Type — the spec's typography scale, and nothing else
//
// Transcribed from the design bible's Typography table and the board's "02 · TYPE" panel. Every
// size, weight and tracking value below is the spec's number verbatim.
//
// | Style | Spec |
// |---|---|
// | Display numeral (hero score) | Space Grotesk 66/700, −3 tracking |
// | Big numeral (detail hero)    | 58/700, −2.5 |
// | Section numeral              | 31–34/700, −1 |
// | Strip numeral                | 20/600 |
// | Row value                    | 16–17/600 |
// | Screen title                 | Space Grotesk 27/700, −0.5 |
// | Row title                    | Instrument Sans 14/600 |
// | Body                         | 13.5/400, line-height 1.55 |
// | Overline                     | 10.5/700, +2.4 tracking, UPPERCASE, text/tertiary |
// | Caption / axis               | 10–11/400, text/tertiary |
//
// TWO RULES THIS FILE ENFORCES SO SCREENS CANNOT BREAK THEM:
//
//   1. **All numerals are `.monospacedDigit()`.** Both bundled faces ship a `tnum` feature, so this
//      is a real tabular substitution, not a no-op — a counting-up score does not jitter and a
//      column of values lines up. Every numeral style below applies it; a screen cannot forget.
//   2. **No screen hardcodes a font.** There is no public accessor here that takes an arbitrary
//      family. A view says `.ledgerDisplayNumeral()`, not `.font(.custom("Space Grotesk", size: 66))`.
//
// SIZES ARE FIXED, NOT DYNAMIC-TYPE-SCALED. The boards are laid out to the pixel (a 216pt arc with a
// 66pt numeral inside it), and the spec calls the fidelity "high — colors, type sizes, spacing and
// layout are final". Accessibility is served by the ≥44pt row targets and the contrast ladder, not
// by reflowing the hero.

/// The Ledger type scale. Exposed as both `Font` values and `Text`/`View` modifiers.
public enum LedgerType {

    // MARK: - Weights (variable-font `wght` axis values)

    /// `wght 400` — body copy.
    public static let regular: Double = 400
    /// `wght 600` — strip numerals, row values, row titles.
    public static let semibold: Double = 600
    /// `wght 700` — display/section numerals, screen titles, overlines.
    public static let bold: Double = 700

    // MARK: - Fonts (Space Grotesk — numerals + screen titles)

    /// Display numeral — 66/700. The Today readiness score.
    public static var displayNumeral: Font { numeral(66, bold) }

    /// Big numeral — 58/700. The metric-detail hero value.
    public static var bigNumeral: Font { numeral(58, bold) }

    /// Section numeral — 31–34/700. Defaults to the tight end (31); the Sleep header's score and
    /// the Activity strain hero pass their own size from the boards (44 and 46 respectively).
    /// - Parameter size: 31…34 per the spec table.
    public static func sectionNumeral(_ size: CGFloat = 31) -> Font { numeral(size, bold) }

    /// Strip numeral — 20/600. Stat-strip values.
    public static var stripNumeral: Font { numeral(20, semibold) }

    /// Row value — 16–17/600. Defaults to 17 (the boards' ledger rows).
    /// - Parameter size: 16…17 per the spec table.
    public static func rowValue(_ size: CGFloat = 17) -> Font { numeral(size, semibold) }

    /// Screen title — Space Grotesk 27/700.
    public static var screenTitle: Font { numeral(27, bold) }

    // MARK: - Fonts (Instrument Sans — labels + body)

    /// Row title — Instrument Sans 14/600.
    public static var rowTitle: Font { label(14, semibold) }

    /// Body — 13.5/400. Pair with `bodyLineSpacing` for the spec's 1.55 line-height.
    public static var body: Font { label(13.5, regular) }

    /// Overline — 10.5/700. Pair with `overlineTracking` and `.textCase(.uppercase)`; prefer the
    /// `.ledgerOverline()` modifier, which applies all three plus `text/tertiary`.
    public static var overline: Font { label(10.5, bold) }

    /// Caption / axis — 10–11/400. Defaults to 10 (the boards' chart axes); stat-strip sub-labels
    /// use 10.5.
    /// - Parameter size: 10…11 per the spec table.
    public static func caption(_ size: CGFloat = 10) -> Font { label(size, regular) }

    // MARK: - Tracking (points, not em — SwiftUI's `.tracking` is absolute)

    /// −3 on the display numeral.
    public static let displayTracking: CGFloat = -3
    /// −2.5 on the big numeral.
    public static let bigTracking: CGFloat = -2.5
    /// −1 on section numerals.
    public static let sectionTracking: CGFloat = -1
    /// −0.5 on the screen title.
    public static let titleTracking: CGFloat = -0.5
    /// +2.4 on overlines.
    public static let overlineTracking: CGFloat = 2.4

    /// Extra leading that turns the 13.5pt body into the spec's 1.55 line-height.
    /// SwiftUI's `.lineSpacing` is additive on top of the font's own line height, so this is
    /// `13.5 × 0.55`.
    public static let bodyLineSpacing: CGFloat = 13.5 * 0.55

    // MARK: - Primitives

    /// Space Grotesk at an exact size and `wght`, with tabular figures. Falls back to SF Pro.
    public static func numeral(_ size: CGFloat, _ weight: Double) -> Font {
        LedgerFonts.resolved(.numeral, size: size, weight: weight).monospacedDigit()
    }

    /// Instrument Sans at an exact size and `wght`. Falls back to SF Pro (SF Pro Text's role).
    public static func label(_ size: CGFloat, _ weight: Double) -> Font {
        LedgerFonts.resolved(.label, size: size, weight: weight)
    }
}

// MARK: - Text modifiers
//
// `Text` variants return `Text`, so they compose with `+` and with a following `.foregroundStyle`
// without collapsing into an opaque `some View`. Every numeral style carries `.monospacedDigit()`
// (baked into `LedgerType.numeral`) and its tracking.

public extension Text {

    /// Display numeral — Space Grotesk 66/700, −3 tracking, tabular. The Today readiness score.
    func ledgerDisplayNumeral() -> Text {
        font(LedgerType.displayNumeral).tracking(LedgerType.displayTracking)
    }

    /// Big numeral — 58/700, −2.5 tracking, tabular. The metric-detail hero.
    func ledgerBigNumeral() -> Text {
        font(LedgerType.bigNumeral).tracking(LedgerType.bigTracking)
    }

    /// Section numeral — 31–34/700, −1 tracking, tabular.
    /// - Parameter size: 31…34 per the spec table (default 31).
    func ledgerSectionNumeral(_ size: CGFloat = 31) -> Text {
        font(LedgerType.sectionNumeral(size)).tracking(LedgerType.sectionTracking)
    }

    /// Strip numeral — 20/600, tabular. Stat-strip values.
    func ledgerStripNumeral() -> Text {
        font(LedgerType.stripNumeral)
    }

    /// Row value — 16–17/600, tabular.
    /// - Parameter size: 16…17 per the spec table (default 17).
    func ledgerRowValue(_ size: CGFloat = 17) -> Text {
        font(LedgerType.rowValue(size))
    }

    /// Screen title — Space Grotesk 27/700, −0.5 tracking.
    func ledgerScreenTitle() -> Text {
        font(LedgerType.screenTitle).tracking(LedgerType.titleTracking)
    }

    /// Row title — Instrument Sans 14/600.
    func ledgerRowTitle() -> Text {
        font(LedgerType.rowTitle)
    }

    /// Body — 13.5/400. Apply `.lineSpacing(LedgerType.bodyLineSpacing)` on the enclosing view for
    /// the spec's 1.55 line-height (`.ledgerBody()` on a `View` does it for you).
    func ledgerBodyText() -> Text {
        font(LedgerType.body)
    }

    /// Caption / axis — 10–11/400.
    /// - Parameter size: 10…11 per the spec table (default 10).
    func ledgerCaption(_ size: CGFloat = 10) -> Text {
        font(LedgerType.caption(size))
    }
}

// MARK: - View modifiers
//
// The styles that carry a colour, a case transform or leading — i.e. the ones that are a *complete*
// treatment, not just a font — live here so a screen applies one modifier and is done.

public extension View {

    /// Section **overline** — Instrument Sans 10.5/700, +2.4 tracking, UPPERCASE, `text/tertiary`.
    /// The label that names every section beneath its hairline.
    func ledgerOverline() -> some View {
        self.font(LedgerType.overline)
            .tracking(LedgerType.overlineTracking)
            .textCase(.uppercase)
            .foregroundStyle(Ledger.textTertiary)
    }

    /// An overline in a domain accent — the coach/insight block's heading (`COACH`, `WATCHING`,
    /// `MEANINGFUL CHANGE`), which is the one overline that is not `text/tertiary`.
    func ledgerOverline(_ tint: Color) -> some View {
        self.font(LedgerType.overline)
            .tracking(LedgerType.overlineTracking)
            .textCase(.uppercase)
            .foregroundStyle(tint)
    }

    /// Body copy — 13.5/400, line-height 1.55, `text/secondary`.
    func ledgerBody() -> some View {
        self.font(LedgerType.body)
            .lineSpacing(LedgerType.bodyLineSpacing)
            .foregroundStyle(Ledger.textSecondary)
    }

    /// Coach/insight copy — body metrics, `#C9CFD8`. One step brighter than `ledgerBody()` because
    /// the left-ruled note is the screen's single raised voice.
    func ledgerCoachBody() -> some View {
        self.font(LedgerType.body)
            .lineSpacing(LedgerType.bodyLineSpacing)
            .foregroundStyle(Ledger.textCoach)
    }

    /// Caption / axis text — 10–11/400, `text/tertiary`.
    /// - Parameter size: 10…11 per the spec table (default 10).
    func ledgerCaptionStyle(_ size: CGFloat = 10) -> some View {
        self.font(LedgerType.caption(size))
            .foregroundStyle(Ledger.textTertiary)
    }

    /// Row title — Instrument Sans 14/600, `text/primary`.
    func ledgerRowTitleStyle() -> some View {
        self.font(LedgerType.rowTitle)
            .foregroundStyle(Ledger.textPrimary)
    }
}
