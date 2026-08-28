import SwiftUI
import StrandDesign

// MARK: - Ledger Design Tokens — "The Athlete's Ledger"
//
// The token surface for the flat, near-black, data-first redesign. Transcribed VERBATIM from the
// handoff spec sheet (`NOOP Redesign.dc.html` → "01 · COLOR TOKENS" / "03 · LAYOUT RULES") and the
// design bible's Design Tokens table. Where the spec states a number, that number is here — not a
// rounded one, not an "improved" one.
//
// CARDINAL RULE (spec, §Design Tokens): **no cards behind data.** Data draws directly on
// `Ledger.bgScreen`; sections separate with a 1px hairline + an overline label. `Ledger.bgRaised`
// is reserved for CONTROLS (the range pill) and phone chrome — never for a metric.
// Colour = meaning only. Chrome is grayscale.
//
// DARK-ONLY BY INTENT. Unlike `Aurora` (which pairs every token light/dark via
// `Color(light:dark:)`), the Ledger is a single fixed instrument palette. Every value below is a
// literal sRGB colour that does NOT flip with `@Environment(\.colorScheme)`. That is deliberate:
// the boards are authored against `#0A0C11` and a light inversion of them does not exist.
//
// Nothing in this file touches data models, scoring, repositories or BLE. It is presentation only,
// and it is additive — see `LedgerFlags.ledgerUIEnabledKey`.

/// The Ledger token namespace: colour, layout, radii, strokes, and the recovery-band accent map.
///
/// Every screen in `Strand/Ledger/**` reads from here. A literal hex or a magic `CGFloat` inside a
/// Ledger view is a bug — add the token instead.
public enum Ledger {

    // MARK: - Colour plumbing

    /// A fixed sRGB colour from a 24-bit hex value, with an optional alpha.
    ///
    /// Deliberately NOT `Color(light:dark:)`: the Ledger is dark-only, so a token must resolve to
    /// the same value in every appearance. Marked `@inline(__always)` because tokens are read in
    /// `body` at every row.
    @inline(__always)
    static func hex(_ value: UInt32, _ opacity: Double = 1) -> Color {
        Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0,
            opacity: opacity
        )
    }

    /// Pure white at a given alpha — the ONLY way chrome is drawn. Hairlines, tracks and baseline
    /// bands are white-at-percent, never a tinted grey, so they sit identically on every surface.
    @inline(__always)
    static func white(_ opacity: Double) -> Color {
        Color(.sRGB, red: 1, green: 1, blue: 1, opacity: opacity)
    }

    // MARK: - Surfaces
    //
    // Three surfaces. There is no fourth, and there is no "card".

    /// `bg/canvas` `#060709` — the app window backdrop behind the screen. Mac split-view chrome and
    /// the area outside the phone frame.
    public static let bgCanvas = hex(0x060709)

    /// `bg/screen` `#0A0C11` — EVERY screen background. All data draws directly on this.
    public static let bgScreen = hex(0x0A0C11)

    /// `bg/raised` `#10131A` — **controls only** (the range pill). Never behind a number, a chart,
    /// or a row. If you are about to put data on this fill, you are building a card; stop.
    public static let bgRaised = hex(0x10131A)

    // MARK: - Text ranks
    //
    // Three ranks. Values and titles, body and row labels, overlines and axes.

    /// `text/primary` `#F2F4F7` — values, titles.
    public static let textPrimary = hex(0xF2F4F7)

    /// `text/secondary` `#9BA3B0` — body copy, row labels.
    public static let textSecondary = hex(0x9BA3B0)

    /// `text/tertiary` `#5C6470` — overlines, captions, axes.
    public static let textTertiary = hex(0x5C6470)

    /// `#C9CFD8` — the coach/insight block's body copy, one step brighter than `textSecondary` so a
    /// left-ruled note reads as the screen's one raised voice without a fill behind it.
    /// (Boards: `CoachNote` / `WATCHING` copy.)
    public static let textCoach = hex(0xC9CFD8)

    // MARK: - Accents — colour = meaning only
    //
    // Five accents, each bound to a domain. An accent never appears for decoration, and chrome
    // never borrows one.

    /// `accent/recovery` `#3EE6A8` — recovery domain + positive deltas.
    public static let accentRecovery = hex(0x3EE6A8)

    /// `accent/sleep` `#8F9BFF` — sleep domain.
    public static let accentSleep = hex(0x8F9BFF)

    /// `accent/strain` `#58B9FF` — activity/strain domain.
    public static let accentStrain = hex(0x58B9FF)

    /// `accent/caution` `#F2C14E` — debt, drift, watch flags, negative-ish.
    public static let accentCaution = hex(0xF2C14E)

    /// `accent/live-hr` `#FF6B81` — live/sleeping HR, and "low" recovery.
    public static let accentLiveHR = hex(0xFF6B81)

    // MARK: - Sleep stages (hypnogram)

    /// `stage/awake` `#4A5468`.
    public static let stageAwake = hex(0x4A5468)

    /// `stage/rem` `#A78BFA`.
    public static let stageREM = hex(0xA78BFA)

    /// `stage/light` `#6D8DF7`.
    public static let stageLight = hex(0x6D8DF7)

    /// `stage/deep` `#3B55D9`.
    public static let stageDeep = hex(0x3B55D9)

    // MARK: - Hairlines & bands
    //
    // Spec: hairlines are `rgba(255,255,255,.05–.08)`; baseline bands are `rgba(255,255,255,.045)`.
    // The three named steps below are the three the boards actually use, so a section rule and a
    // row rule never disagree by a hand-typed percent.

    /// Section divider — `white @ 7%`. The 1px rule above every overline label. (Boards: `.07`.)
    public static let hairline = white(0.07)

    /// The strong end of the hairline range — `white @ 8%`. Screen/device chrome borders and the
    /// range pill's outline. (Boards: `.08`.)
    public static let hairlineStrong = white(0.08)

    /// Row divider — `white @ 5%`. Between ledger rows inside a section. (Boards: `.05`.)
    public static let hairlineSoft = white(0.05)

    /// Chart guide rule — `white @ 4.5%`. The hypnogram's stage guides and a chart's silent
    /// gridline. (Boards: `.045`.)
    public static let hairlineChart = white(0.045)

    /// **Baseline band** — `white @ 4.5%`. "Your normal", drawn behind every trend chart.
    /// Spec: *a value without "your normal" context is banned.*
    public static let baselineBand = white(0.045)

    /// Empty track behind a bar / dot row / progress rail — `white @ 6%`. (Boards: `.06`.)
    public static let track = white(0.06)

    /// The baseline segment drawn INSIDE a track (the "your normal" span on a `BaselineDotRow`) —
    /// `white @ 9%`. Sits one step above `track` so the band is legible against it. (Boards: `.09`.)
    public static let trackBand = white(0.09)

    /// The "typical" tick mark on a stage/duration bar — `white @ 45%`. (Boards: `.45`.)
    public static let typicalTick = white(0.45)

    /// The dashed 28-day comparison line on the training-load chart — `white @ 30%`. (Boards: `.3`.)
    public static let comparisonLine = white(0.30)

    /// The arc's unfilled track — `white @ 6%`, per the readiness hero board.
    public static let arcTrack = white(0.06)

    /// The arc's 12-o'clock index tick — `white @ 25%`. (Boards: `.25`.)
    public static let arcTick = white(0.25)

    // MARK: - Opacities
    //
    // The two the boards apply to historical data, so "past vs today" is one constant, not a guess.

    /// Past bars in a 7-day strip render at 35% — today stays solid. (Today's load strip.)
    public static let pastBarOpacity: Double = 0.35

    /// Past bars in the Body recovery strip render at 45–50%; the boards use `.45` for mint and
    /// `.5` for caution/low. `pastBarOpacity` is the Today variant; this is the Body variant.
    public static let pastRecoveryBarOpacity: Double = 0.45

    /// Area fill under a `TrendBlock` line — 8%.
    public static let trendAreaFillOpacity: Double = 0.08

    /// Area fill under the metric-detail hero chart — 7%.
    public static let detailAreaFillOpacity: Double = 0.07

    /// The optimal-strain band overlay on the Activity rail — mint @ 18%.
    public static let optimalBandOpacity: Double = 0.18

    /// The sleeping-HR overlay on the hypnogram — `accent/live-hr` @ 80%.
    public static let sleepingHROpacity: Double = 0.80

    /// The Sleep screen's top wash — `accent/sleep` @ 9%, fading to clear at 70% of its height.
    public static let sleepWashOpacity: Double = 0.09

    /// A session icon tile's fill (8%) and border (22%) in the domain accent.
    public static let iconTileFillOpacity: Double = 0.08
    /// See `iconTileFillOpacity`.
    public static let iconTileBorderOpacity: Double = 0.22

    // MARK: - Layout
    //
    // Spec §03: page margin 24pt · section gap 16–18pt · row height ≥44pt.

    /// Page margin — **24pt**, on both horizontal edges of every Ledger screen.
    public static let pageMargin: CGFloat = 24

    /// Section gap — **16pt**, the tight end of the spec's 16–18pt range. Between a section's
    /// bottom edge and the next section's hairline.
    public static let sectionGap: CGFloat = 16

    /// Section gap — **18pt**, the loose end of the spec's range. Used where a section carries a
    /// hero above it (the boards alternate 16 and 18).
    public static let sectionGapWide: CGFloat = 18

    /// Padding between a section's hairline and its overline label — 14pt, per the boards.
    public static let sectionRulePadding: CGFloat = 14

    /// Row minimum height — **44pt**. Every tappable ledger row honours this, hit-target first.
    public static let rowMinHeight: CGFloat = 44

    /// Horizontal gap between a row's label column, its track, and its value — 14pt.
    public static let rowGap: CGFloat = 14

    /// The WHY-ledger label column width — 82pt (Today).
    public static let labelColumnToday: CGFloat = 82

    /// The vitals-ledger label column width — 100pt (Body: label + sub-label).
    public static let labelColumnBody: CGFloat = 100

    // MARK: - Radii
    //
    // Spec §03: charts/bars 3–5pt; icon tiles 12pt. **No rounded metric cards.** The only large
    // radii in the boards are device chrome, which the app does not draw.

    /// Bar / chart corner radius — 5pt (the loose end of the spec's 3–5pt).
    public static let barRadius: CGFloat = 5

    /// Bar / chart corner radius — 3pt (the tight end), for thin ribbons and stage segments.
    public static let barRadiusTight: CGFloat = 3

    /// Icon tile corner radius — 12pt.
    public static let iconTileRadius: CGFloat = 12

    /// Icon tile size — 38pt (Activity session rows).
    public static let iconTileSize: CGFloat = 38

    // MARK: - Strokes

    /// A hairline is exactly 1px in the boards. Kept as a token so a Ledger view never types `1`
    /// and never reaches for `Divider()`'s platform default.
    public static let hairlineWidth: CGFloat = 1

    /// The coach/insight block's left rule — **2px** in the domain accent, no background fill.
    /// One per screen, maximum.
    public static let coachRuleWidth: CGFloat = 2

    /// A sparkline's stroke — 1.7pt (Body vitals ledger).
    public static let sparkStrokeWidth: CGFloat = 1.7

    // MARK: - The readiness arc (Today hero)
    //
    // Spec §Today.2, transcribed exactly: a 270° open arc starting at 125°, 216pt across, 9pt
    // stroke with round caps.

    /// Arc outer diameter — **216pt**.
    public static let arcDiameter: CGFloat = 216

    /// Arc stroke width — **9pt**, round caps.
    public static let arcStrokeWidth: CGFloat = 9

    /// Arc sweep — **270°** (an open arc, not a ring).
    public static let arcSweepDegrees: Double = 270

    /// Arc start angle — **125°**, measured clockwise from 3 o'clock, per the board's
    /// `transform="rotate(125 …)"`.
    public static let arcStartDegrees: Double = 125

    /// The Body header's recovery mini-ring — 56pt across, 5pt stroke.
    public static let miniRingDiameter: CGFloat = 56
    /// See `miniRingDiameter`.
    public static let miniRingStrokeWidth: CGFloat = 5

    // MARK: - Domain accent

    /// The accent for a data domain. `colour = meaning only` means a view asks for the DOMAIN, not
    /// for a colour.
    public enum Domain: String, CaseIterable, Sendable {
        case recovery, sleep, strain, caution, liveHR

        /// The accent this domain paints with.
        public var accent: Color {
            switch self {
            case .recovery: return Ledger.accentRecovery
            case .sleep:    return Ledger.accentSleep
            case .strain:   return Ledger.accentStrain
            case .caution:  return Ledger.accentCaution
            case .liveHR:   return Ledger.accentLiveHR
            }
        }
    }

    /// A sleep stage's hypnogram colour, in the spec's stage vocabulary.
    public enum Stage: String, CaseIterable, Sendable {
        case awake, rem, light, deep

        /// The stage's fill.
        public var color: Color {
            switch self {
            case .awake: return Ledger.stageAwake
            case .rem:   return Ledger.stageREM
            case .light: return Ledger.stageLight
            case .deep:  return Ledger.stageDeep
            }
        }
    }
}

// MARK: - Recovery bands

/// A recovery score's band, in **NOOP's existing recovery-band vocabulary** —
/// `DEPLETED · LOW · MODERATE · PRIMED · PEAK`, with the same cut points
/// `StrandPalette.recoveryState(_:)` has always used (25 / 50 / 70 / 88).
///
/// The Ledger does NOT re-cut the bands and does NOT re-word them; the state word comes straight
/// from `StrandPalette.recoveryState(_:)` so the arc's caption, the sidebar and Android all say the
/// same thing. What the Ledger DOES supply is the flat three-colour accent map the boards use —
/// mint / caution / red — in place of the classic five-stop gradient ramp:
///
/// | band | score | accent |
/// |---|---|---|
/// | depleted | `< 25` | `accent/live-hr` `#FF6B81` |
/// | low | `25 ..< 50` | `accent/live-hr` `#FF6B81` |
/// | moderate | `50 ..< 70` | `accent/caution` `#F2C14E` |
/// | primed | `70 ..< 88` | `accent/recovery` `#3EE6A8` |
/// | peak | `>= 88` | `accent/recovery` `#3EE6A8` |
///
/// Mint therefore begins at **70** — the spec's "mint ≥ ~67" landing on the nearest existing band
/// edge rather than inventing a sixth cut point.
public enum LedgerRecoveryBand: String, CaseIterable, Sendable {
    case depleted, low, moderate, primed, peak

    /// The band a 0…100 recovery score falls in. Cut points are byte-identical to
    /// `StrandPalette.recoveryState(_:)`.
    public static func band(for score: Double) -> LedgerRecoveryBand {
        switch score {
        case ..<25:  return .depleted
        case ..<50:  return .low
        case ..<70:  return .moderate
        case ..<88:  return .primed
        default:     return .peak
        }
    }

    /// The Ledger accent for this band — mint at `primed`/`peak`, caution at `moderate`, live-hr
    /// red below.
    public var accent: Color {
        switch self {
        case .depleted, .low: return Ledger.accentLiveHR
        case .moderate:       return Ledger.accentCaution
        case .primed, .peak:  return Ledger.accentRecovery
        }
    }

    /// The state word — `DEPLETED · LOW · MODERATE · PRIMED · PEAK` — sourced from
    /// `StrandPalette.recoveryState(_:)` so the Ledger never forks the localized vocabulary.
    public var word: String {
        switch self {
        case .depleted: return StrandPalette.recoveryState(0)
        case .low:      return StrandPalette.recoveryState(37)
        case .moderate: return StrandPalette.recoveryState(60)
        case .primed:   return StrandPalette.recoveryState(79)
        case .peak:     return StrandPalette.recoveryState(94)
        }
    }
}

public extension Ledger {
    /// The accent for a recovery score, via `LedgerRecoveryBand`.
    /// Convenience for the arc, the 7-day strip and the Body mini-ring.
    static func recoveryAccent(_ score: Double) -> Color {
        LedgerRecoveryBand.band(for: score).accent
    }

    /// The state word for a recovery score — `StrandPalette.recoveryState(_:)`, unchanged.
    static func recoveryWord(_ score: Double) -> String {
        StrandPalette.recoveryState(score)
    }
}

// MARK: - Feature flag

/// The `@AppStorage` key that gates the entire Ledger UI. **Default `false`** — the classic views
/// and the `Strand/Aurora/**` fork keep compiling and keep shipping untouched.
///
/// Declared here (not in a view) so the shell wiring and the settings toggle read one constant and
/// can never drift on a typo. Mirrors how `noop.auroraUIEnabled` is used in `RootView.swift`.
///
/// ```swift
/// @AppStorage(LedgerFlags.ledgerUIEnabledKey) private var ledgerUIEnabled = false
/// ```
public enum LedgerFlags {
    /// `"noop.ledgerUIEnabled"` — the cross-platform key string. Byte-identical everywhere.
    public static let ledgerUIEnabledKey = "noop.ledgerUIEnabled"
}
