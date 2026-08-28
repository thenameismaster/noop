import SwiftUI
import Foundation
import StrandDesign

// MARK: - Aurora Design System — Tokens
//
// Aurora is the additive visual fork of NOOP: a 2026-flagship health surface whose
// reference bar is WHOOP × Apple Health × Oura × Linear. It lives entirely in
// `Strand/Aurora/**` and shares ZERO mutable state with `StrandPalette` — the legacy
// token surface keeps working untouched while Aurora screens compose their own.
//
// WHY A SEPARATE TOKEN LAYER.
// `StrandPalette` is a frozen public API whose data ramps branch on a mutable global
// (`chartStyle`) and whose neutrals were tuned for the "Titanium & Gold" theme. Aurora
// needs a deeper canvas, a stricter elevation ladder and ramps whose MEANING is fixed
// (recovery is always red→amber→green, never re-skinned). So Aurora re-declares its
// own scale and borrows only two mechanical helpers from StrandDesign:
//   • `Color(light:dark:)`  — the UIColor/NSColor dynamic provider (theme flip for free)
//   • `Color.sRGBComponents(hex:)` — hex parsing
// Both are wrapped below (`Aurora.dynamic`, `Aurora.lerpHex`) so a change in the
// upstream package is a one-line fix here, not a repo-wide edit.
//
// DESIGN PRINCIPLES, in priority order:
//   1. UX clarity      — a token never exists for decoration alone.
//   2. Visual hierarchy — three surface elevations, three text ranks. No more.
//   3. Consistency     — one spacing ramp, one radius ramp, one hairline width.
//   4. Data readability — semantic ramps carry meaning; contrast holds in both schemes.
//   5. Premium aesthetics — deep near-black canvas, soft top-lit rims, restrained glow.
//   6. Motion          — 200–320 ms, cubic-bezier(0.22, 1, 0.36, 1). Calm, never bouncy.

/// The Aurora token namespace. Everything a redesigned screen needs to look correct
/// without inventing a single literal: colour, ramps, spacing, radius, stroke, motion.
///
/// All colours are dynamic — one token resolves to its light or dark value automatically
/// at every call site when the appearance flips, so a screen never branches on
/// `@Environment(\.colorScheme)` just to pick a colour.
public enum Aurora {

    // MARK: - Dynamic colour plumbing

    /// A theme-aware colour from a light/dark hex pair (`"RRGGBB"` or `"RRGGBBAA"`).
    ///
    /// This is the single seam between Aurora and StrandDesign's colour machinery.
    /// Every Aurora colour goes through here, so swapping the backing implementation
    /// (or dropping the dependency entirely) is one function body.
    @inline(__always)
    public static func dynamic(light: String, dark: String) -> Color {
        Color(light: light, dark: dark)
    }

    /// Linear-interpolate two hex colours in sRGB and return the result as `RRGGBBAA`.
    ///
    /// Ramps interpolate on the HEX TRACKS, not on resolved `Color`s — so a sampled
    /// ramp colour is still a fully dynamic `Color(light:dark:)` and keeps flipping with
    /// the appearance. Resolving first (the classic mistake) would freeze the sample to
    /// whichever scheme happened to be active when it was computed.
    public static func lerpHex(_ a: String, _ b: String, _ t: Double) -> String {
        let ca = Color.sRGBComponents(hex: a)
        let cb = Color.sRGBComponents(hex: b)
        let tt = min(max(t, 0), 1)
        func mix(_ x: Double, _ y: Double) -> Int {
            let v = Int(((x + (y - x) * tt) * 255).rounded())
            return min(max(v, 0), 255)
        }
        return String(format: "%02X%02X%02X%02X",
                      mix(ca.r, cb.r), mix(ca.g, cb.g), mix(ca.b, cb.b), mix(ca.a, cb.a))
    }

    // MARK: - Canvas & surfaces
    //
    // The elevation ladder. Depth is expressed by FILL first, hairline second, shadow
    // last — never by shadow alone, which reads as mud on a near-black canvas.
    //
    //   canvas    the page ground. Deep near-black in dark (#0A0B0E, NOT pure black, so
    //             true-black OLED edges and shadows still have somewhere to go).
    //   surface1  a resting card sitting on the canvas.
    //   surface2  a raised card / an active row / a selected state.
    //   surface3  an overlay — sheet chrome, popover, tooltip, floating bar.
    //   inset     a recessed well: progress tracks, chart plot beds, input fields.

    /// The page ground. Every Aurora screen paints this edge-to-edge.
    public static let canvas = dynamic(light: "F5F6F8", dark: "0A0B0E")

    /// A secondary ground for grouped regions that must separate from `canvas`
    /// without becoming a card (e.g. a pinned header strip behind scrolling content).
    public static let canvasElevated = dynamic(light: "FFFFFF", dark: "0E1014")

    /// Elevation 1 — the resting card.
    public static let surface1 = dynamic(light: "FFFFFF", dark: "131519")

    /// Elevation 2 — a raised card, hovered row, or selected cell.
    public static let surface2 = dynamic(light: "FFFFFF", dark: "191C22")

    /// Elevation 3 — overlays: sheets, popovers, tooltips, floating toolbars.
    public static let surface3 = dynamic(light: "FFFFFF", dark: "21252C")

    /// A recessed well — progress tracks, chart beds, text fields. Reads BELOW the card.
    public static let surfaceInset = dynamic(light: "ECEEF2", dark: "0E1013")

    /// A quiet fill for chips/badges that must sit on top of a card without a border.
    public static let surfaceSubtle = dynamic(light: "0E11160D", dark: "FFFFFF0F")

    /// A pressed/active wash layered over any surface.
    public static let surfacePressed = dynamic(light: "0E111614", dark: "FFFFFF16")

    // MARK: - Hairlines & rims

    /// The default 1px card/divider edge. Deliberately low-contrast: it defines the
    /// card's silhouette without drawing attention to itself.
    public static let hairline = dynamic(light: "0E111614", dark: "FFFFFF16")

    /// A stronger edge for focused, selected or emphasised containers.
    public static let hairlineStrong = dynamic(light: "0E11162E", dark: "FFFFFF2E")

    /// The soft inner highlight painted across the TOP of a card, simulating a light
    /// source above the page. This one token is most of Aurora's perceived depth.
    public static let rimHighlight = dynamic(light: "FFFFFFFF", dark: "FFFFFF1A")

    /// The complementary shade along a card's bottom edge; pairs with `rimHighlight`.
    public static let rimShade = dynamic(light: "0E11160A", dark: "00000059")

    /// A plain divider between rows inside a grouped card.
    public static let divider = dynamic(light: "0E11161A", dark: "FFFFFF12")

    // MARK: - Text ranks
    //
    // Exactly three ranks plus a disabled tint. A fourth rank always turns out to be a
    // hierarchy problem, not a colour problem.

    /// Rank 1 — headlines, metric values, anything the eye must land on first.
    public static let textPrimary = dynamic(light: "0D1117", dark: "F3F5F8")

    /// Rank 2 — labels, supporting copy, axis values.
    public static let textSecondary = dynamic(light: "545C69", dark: "9BA3B0")

    /// Rank 3 — units, timestamps, footnotes, inactive glyphs.
    public static let textTertiary = dynamic(light: "858C99", dark: "666D7A")

    /// Disabled / unavailable text and glyphs.
    public static let textDisabled = dynamic(light: "AAB0BA", dark: "474D57")

    /// Text and glyphs placed ON a saturated accent fill (scheme-invariant — an accent
    /// fill stays saturated in both themes, so its label must NOT flip with the scheme).
    public static let textOnAccent = Color(hex: "FFFFFF")

    /// Text placed on a surface that is pinned dark in BOTH schemes (hero photography,
    /// a night-sky backdrop). The normal ranks flip to dark ink and vanish there.
    public static let textOnDark = Color(hex: "F3F5F8")

    /// Secondary text on a permanently-dark surface.
    public static let textOnDarkSecondary = Color(hex: "B9C0CB")

    // MARK: - Accent
    //
    // A single confident blue anchors chrome: links, selection, focus, primary actions.
    // The accent is NEVER used to encode a measurement — that is what the semantic
    // ramps below are for.

    /// The primary accent.
    public static let accent = dynamic(light: "1F6FEB", dark: "4E9BFF")

    /// Hover / pressed variant of the accent.
    public static let accentHover = dynamic(light: "1A5FCC", dark: "6DAFFF")

    /// A muted accent fill for tinted chips, selected rows and quiet emphasis.
    public static let accentMuted = dynamic(light: "1F6FEB1F", dark: "4E9BFF24")

    /// The focus ring colour (keyboard focus, active field).
    public static let accentFocus = dynamic(light: "1F6FEB80", dark: "4E9BFF80")

    /// The ambient bloom behind a hero ring or a chart's peak. Very low alpha by design:
    /// glow is atmosphere, never a shape.
    public static let glow = dynamic(light: "1F6FEB1A", dark: "4E9BFF33")

    // MARK: - Semantic data ramps
    //
    // Colour here carries MEANING and is fixed. A user re-theming chrome must never be
    // able to make "depleted" look green.

    /// Recovery / Charge — how ready the body is. Red (depleted) → amber → green (peak).
    /// The canonical readiness scale; readable by anyone who has ever seen a health app.
    public static let recoveryRamp = AuroraRamp([
        .init(location: 0.00, light: "C22B30", dark: "E5484D"),   // depleted
        .init(location: 0.30, light: "D2600E", dark: "F2761B"),   // low
        .init(location: 0.55, light: "BC8E00", dark: "F5C518"),   // moderate
        .init(location: 0.78, light: "5E9E2E", dark: "8FD14F"),   // primed
        .init(location: 1.00, light: "12915A", dark: "30D158"),   // peak
    ])

    /// Strain / Effort — cardiovascular output. Cool teal (light) → blue → indigo →
    /// violet (all-out). Deliberately disjoint from the recovery ramp so a strain
    /// number and a recovery number can never be confused at a glance.
    public static let strainRamp = AuroraRamp([
        .init(location: 0.00, light: "0E9A93", dark: "3FD0C9"),   // light
        .init(location: 0.33, light: "1F6FEB", dark: "4E9BFF"),   // moderate
        .init(location: 0.66, light: "5445D6", dark: "7A6BFF"),   // hard
        .init(location: 1.00, light: "8E3BD6", dark: "C25BFF"),   // all-out
    ])

    /// Sleep depth as a continuous ramp (surface → depth). Used for gradients and
    /// sleep-quality gauges; the discrete stage colours live on `AuroraSleepStage`.
    public static let sleepRamp = AuroraRamp([
        .init(location: 0.00, light: "7A8290", dark: "C9CFD9"),   // awake / surface
        .init(location: 0.40, light: "2A72C9", dark: "5EA9F5"),   // light
        .init(location: 0.70, light: "6D4BD6", dark: "A78BFA"),   // rem
        .init(location: 1.00, light: "1E3F9E", dark: "2F5BD1"),   // deep
    ])

    /// Stress / load — calm green → amber → hot red.
    public static let stressRamp = AuroraRamp([
        .init(location: 0.00, light: "12915A", dark: "30D158"),
        .init(location: 0.50, light: "BC8E00", dark: "F5C518"),
        .init(location: 1.00, light: "C22B30", dark: "E5484D"),
    ])

    /// A neutral single-hue ramp for series that carry no valence (steps, volume).
    public static let neutralRamp = AuroraRamp([
        .init(location: 0.00, light: "8791A0", dark: "4A525E"),
        .init(location: 1.00, light: "1F6FEB", dark: "4E9BFF"),
    ])

    // MARK: - Status colours

    /// Everything is fine / improved / within range.
    public static let statusGood = dynamic(light: "12915A", dark: "30D158")

    /// Worth attention / borderline / trending the wrong way.
    public static let statusCaution = dynamic(light: "9A6C00", dark: "F5C518")

    /// A problem / out of range / failure.
    public static let statusAlert = dynamic(light: "C22B30", dark: "E5484D")

    /// Neutral informational state (no valence).
    public static let statusNeutral = dynamic(light: "545C69", dark: "9BA3B0")

    /// Faint tinted fills for status chips, one per status colour.
    public static let statusGoodFill    = dynamic(light: "12915A1F", dark: "30D15826")
    public static let statusCautionFill = dynamic(light: "9A6C001F", dark: "F5C51826")
    public static let statusAlertFill   = dynamic(light: "C22B301F", dark: "E5484D26")
    public static let statusNeutralFill = dynamic(light: "545C6914", dark: "9BA3B01F")

    // MARK: - Ramp sampling

    /// The colour for a recovery / readiness percentage.
    /// - Parameter pct: 0…100 (clamped). Values outside the range pin to the end stops.
    public static func recoveryColor(_ pct: Double) -> Color {
        recoveryRamp.color(at: pct / 100.0)
    }

    /// The colour for a strain / effort value.
    /// - Parameters:
    ///   - v: the raw strain value.
    ///   - scale: the top of the strain scale this value is expressed on. Defaults to
    ///     `21` (the WHOOP-style 0…21 scale). Pass `100` for a percentage scale.
    public static func strainColor(_ v: Double, scale: Double = 21) -> Color {
        strainRamp.color(at: scale > 0 ? v / scale : 0)
    }

    /// The colour for a stress score on 0…100.
    public static func stressColor(_ pct: Double) -> Color {
        stressRamp.color(at: pct / 100.0)
    }

    /// The colour for a sleep-quality score on 0…100.
    public static func sleepColor(_ pct: Double) -> Color {
        sleepRamp.color(at: pct / 100.0)
    }

    // MARK: - Spacing
    //
    // One 4-point ramp. If a gap is not on this ramp it is a mistake, not a nuance.

    public enum Space {
        /// 4 — hairline separation between a glyph and its label.
        public static let xxs: CGFloat = 4
        /// 8 — tight pairing (value + unit, icon + text).
        public static let xs: CGFloat = 8
        /// 12 — rows inside a card.
        public static let s: CGFloat = 12
        /// 16 — the default card interior padding.
        public static let m: CGFloat = 16
        /// 20 — the screen's horizontal gutter.
        public static let l: CGFloat = 20
        /// 24 — between stacked cards.
        public static let xl: CGFloat = 24
        /// 32 — between a section header and the section above it.
        public static let xxl: CGFloat = 32
        /// 40 — between major page sections.
        public static let xxxl: CGFloat = 40
        /// 56 — around a hero element; the largest gap Aurora ever uses.
        public static let hero: CGFloat = 56

        // Named aliases — reach for these in layout code so intent survives a refactor.

        /// The left/right page gutter. (20)
        public static let screenGutter: CGFloat = 20
        /// Interior padding of a standard card. (16)
        public static let cardPadding: CGFloat = 16
        /// Interior padding of a hero card. (24)
        public static let heroPadding: CGFloat = 24
        /// Vertical gap between stacked cards. (12)
        public static let cardGap: CGFloat = 12
        /// Vertical gap between top-level page sections. (32)
        public static let sectionGap: CGFloat = 32
        /// Vertical gap between rows inside a card. (12)
        public static let rowGap: CGFloat = 12
        /// Extra bottom scroll room so the last card clears a floating tab bar (iOS).
        public static let tabBarClearance: CGFloat = 84
    }

    // MARK: - Radius

    public enum Radius {
        /// 6 — skeleton bars, tiny swatches.
        public static let xs: CGFloat = 6
        /// 10 — chips, delta pills, compact glyph plates.
        public static let s: CGFloat = 10
        /// 14 — inner elements nested inside a card.
        public static let m: CGFloat = 14
        /// 20 — the standard card.
        public static let l: CGFloat = 20
        /// 28 — hero cards and sheets.
        public static let xl: CGFloat = 28
        /// Fully rounded — capsules and pills.
        public static let pill: CGFloat = 999

        /// The canonical card radius. (20)
        public static let card: CGFloat = 20
        /// The canonical hero-card radius. (28)
        public static let hero: CGFloat = 28
        /// The canonical tile radius. (14)
        public static let tile: CGFloat = 14
    }

    // MARK: - Stroke widths

    public enum Stroke {
        /// 0.5 — a true hairline divider on a Retina display.
        public static let hairline: CGFloat = 0.5
        /// 1 — the standard card border.
        public static let border: CGFloat = 1
        /// 1.5 — an emphasised / focused border.
        public static let emphasis: CGFloat = 1.5
        /// 2 — sparkline and trend-line stroke.
        public static let line: CGFloat = 2
        /// 3 — a chart's hero series.
        public static let lineHeavy: CGFloat = 3
        /// 10 — a compact ring's arc.
        public static let ringCompact: CGFloat = 10
        /// 16 — the hero ring's arc.
        public static let ring: CGFloat = 16
    }

    // MARK: - Elevation shadows
    //
    // Shadow is the LAST depth cue, applied sparingly. On the dark canvas a shadow is
    // nearly invisible by design; the fill step and the rim do the real work.

    public enum Shadow {
        public static let restingRadius: CGFloat = 10
        public static let restingY: CGFloat = 4
        public static let raisedRadius: CGFloat = 20
        public static let raisedY: CGFloat = 10
        public static let overlayRadius: CGFloat = 34
        public static let overlayY: CGFloat = 18

        /// Shadow opacity for a scheme. Dark canvases need a deeper, softer shadow;
        /// light canvases need a shallower one or the card looks like it is floating away.
        public static func opacity(for scheme: ColorScheme, raised: Bool) -> Double {
            switch scheme {
            case .dark: return raised ? 0.44 : 0.28
            default:    return raised ? 0.10 : 0.06
            }
        }
    }

    // MARK: - Motion
    //
    // Fast, intentional, calm. The house curve is cubic-bezier(0.22, 1, 0.36, 1) — a
    // decisive start that settles without overshoot. Durations sit in 200–320 ms except
    // for a deliberate hero draw-in.

    public enum Motion {
        /// 0.20 s — chips, presses, hover states.
        public static let durationFast: Double = 0.20
        /// 0.26 s — the default: card appear, cross-fades, value changes.
        public static let durationStandard: Double = 0.26
        /// 0.32 s — layout changes, sheet content, expanding sections.
        public static let durationSlow: Double = 0.32
        /// 0.90 s — the hero ring's first sweep. Deliberately outside the standard band:
        /// it happens once, and it is the app's opening statement.
        public static let durationDrawIn: Double = 0.90

        /// The house easing curve, cubic-bezier(0.22, 1, 0.36, 1), at any duration.
        public static func curve(_ duration: Double) -> Animation {
            .timingCurve(0.22, 1, 0.36, 1, duration: duration)
        }

        /// Immediate feedback — a press, a hover, a chip flip.
        public static let fast = curve(durationFast)
        /// The default transition.
        public static let standard = curve(durationStandard)
        /// Layout and container changes.
        public static let slow = curve(durationSlow)
        /// The hero ring / gauge sweep on first appear.
        public static let drawIn = curve(durationDrawIn)
        /// A gentle spring for direct manipulation (scrub handles, drag).
        public static let interactive = Animation.spring(response: 0.28, dampingFraction: 0.86)
        /// A slower spring for a hero element materialising.
        public static let hero = Animation.spring(response: 0.62, dampingFraction: 0.88)

        /// A looping ambient breath for glow / shimmer.
        public static var breathe: Animation {
            .easeInOut(duration: 3.2).repeatForever(autoreverses: true)
        }

        /// Any Aurora animation, suppressed when Reduce Motion is on.
        ///
        /// Returns `nil` so `withAnimation(Aurora.Motion.respecting(.drawIn, reduced))`
        /// snaps straight to the final frame instead of sweeping — Apple's Reduce Motion
        /// HIG, honoured once here instead of at every call site.
        public static func respecting(_ animation: Animation, reduced: Bool) -> Animation? {
            reduced ? nil : animation
        }
    }

    // MARK: - Layout constants

    public enum Layout {
        /// Height of a standard metric tile in a grid.
        public static let metricTileHeight: CGFloat = 128
        /// Height of a compact metric row.
        public static let rowHeight: CGFloat = 56
        /// Height of a standard inline chart.
        public static let chartHeight: CGFloat = 200
        /// Height of a compact sparkline inside a tile.
        public static let sparklineHeight: CGFloat = 32
        /// Height of a hypnogram.
        public static let hypnogramHeight: CGFloat = 140
        /// Diameter of the hero ring on a phone.
        public static let heroRingSize: CGFloat = 220
        /// Diameter of a secondary ring.
        public static let compactRingSize: CGFloat = 92
        /// Standard interactive control height.
        public static let controlHeight: CGFloat = 48
        /// Minimum tap target (Apple HIG).
        public static let minTapTarget: CGFloat = 44
        /// Diameter of a tile's leading glyph plate.
        public static let glyphPlate: CGFloat = 28
        /// Track thickness for linear progress / range bars.
        public static let trackHeight: CGFloat = 8
    }
}

// MARK: - AuroraRamp

/// An ordered set of colour stops with a light and a dark track, sampled by fraction.
///
/// Ramps interpolate on the hex tracks rather than on resolved `Color` values, so a
/// sampled colour stays a dynamic `Color(light:dark:)` and keeps flipping with the
/// system appearance. That is the whole reason this type exists instead of a bare
/// `Gradient` — a `Gradient` cannot be sampled, and resolving to sample would freeze
/// the result to one scheme.
public struct AuroraRamp: Sendable {

    /// One stop: a normalised position plus its light and dark hex values.
    public struct Stop: Sendable {
        /// Position on the ramp, 0…1.
        public let location: Double
        /// Hex (`RRGGBB` or `RRGGBBAA`) used in light appearance.
        public let light: String
        /// Hex (`RRGGBB` or `RRGGBBAA`) used in dark appearance.
        public let dark: String

        public init(location: Double, light: String, dark: String) {
            self.location = location
            self.light = light
            self.dark = dark
        }
    }

    public let stops: [Stop]

    public init(_ stops: [Stop]) {
        self.stops = stops.sorted { $0.location < $1.location }
    }

    /// The ramp as dynamic `Color`s in stop order — for `AngularGradient`, legends, keys.
    public var colors: [Color] {
        stops.map { Aurora.dynamic(light: $0.light, dark: $0.dark) }
    }

    /// The ramp as a SwiftUI `Gradient`, preserving stop locations.
    public var gradient: Gradient {
        Gradient(stops: stops.map {
            Gradient.Stop(color: Aurora.dynamic(light: $0.light, dark: $0.dark), location: $0.location)
        })
    }

    /// The ramp's first colour (the "floor" — depleted, calm, awake).
    public var start: Color { colors.first ?? .clear }

    /// The ramp's last colour (the "peak" — primed, all-out, deep).
    public var end: Color { colors.last ?? .clear }

    /// Sample the ramp at a normalised position. Out-of-range values clamp to the ends.
    public func color(at fraction: Double) -> Color {
        guard let first = stops.first else { return .clear }
        guard stops.count > 1 else { return Aurora.dynamic(light: first.light, dark: first.dark) }

        let t = min(max(fraction, 0), 1)
        var lower = stops[0]
        var upper = stops[stops.count - 1]
        for i in 0..<(stops.count - 1) where t >= stops[i].location && t <= stops[i + 1].location {
            lower = stops[i]
            upper = stops[i + 1]
            break
        }
        let span = upper.location - lower.location
        let local = span > 0 ? (t - lower.location) / span : 0
        return Aurora.dynamic(light: Aurora.lerpHex(lower.light, upper.light, local),
                              dark: Aurora.lerpHex(lower.dark, upper.dark, local))
    }

    /// A linear gradient built from this ramp, for area fills under a chart.
    /// - Parameters:
    ///   - topOpacity: alpha at the top of the fill.
    ///   - bottomOpacity: alpha at the bottom (usually 0, so the fill dissolves).
    public func areaFill(topOpacity: Double = 0.34, bottomOpacity: Double = 0.0) -> LinearGradient {
        LinearGradient(
            colors: [end.opacity(topOpacity), end.opacity(bottomOpacity)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // Convenience references so screens read as prose: `AuroraRamp.recovery`.
    public static var recovery: AuroraRamp { Aurora.recoveryRamp }
    public static var strain: AuroraRamp { Aurora.strainRamp }
    public static var sleep: AuroraRamp { Aurora.sleepRamp }
    public static var stress: AuroraRamp { Aurora.stressRamp }
    public static var neutral: AuroraRamp { Aurora.neutralRamp }
}

// MARK: - Semantic bands

/// The five readiness bands. A band gives a metric a WORD, which is what a user
/// actually remembers — the number is the evidence, the band is the verdict.
public enum AuroraRecoveryBand: String, CaseIterable, Sendable {
    case depleted, low, moderate, primed, peak

    /// The band for a recovery percentage on 0…100.
    public init(pct: Double) {
        switch pct {
        case ..<25:  self = .depleted
        case ..<50:  self = .low
        case ..<70:  self = .moderate
        case ..<88:  self = .primed
        default:     self = .peak
        }
    }

    /// Uppercase display label for a status pill or an overline.
    public var label: String {
        switch self {
        case .depleted: return "DEPLETED"
        case .low:      return "LOW"
        case .moderate: return "MODERATE"
        case .primed:   return "PRIMED"
        case .peak:     return "PEAK"
        }
    }

    /// A representative colour sampled from the recovery ramp at the band's midpoint.
    public var color: Color {
        switch self {
        case .depleted: return Aurora.recoveryColor(12)
        case .low:      return Aurora.recoveryColor(37)
        case .moderate: return Aurora.recoveryColor(60)
        case .primed:   return Aurora.recoveryColor(79)
        case .peak:     return Aurora.recoveryColor(94)
        }
    }
}

/// Discrete sleep stages with their own fixed colours.
///
/// Separate from `Aurora.sleepRamp` on purpose: a hypnogram needs four *distinct,
/// nameable* hues that survive being drawn as 2-point-tall slivers, while the ramp
/// needs a smooth continuum. Solving both with one construct produced the unreadable
/// near-identical blues Aurora is replacing.
public enum AuroraSleepStage: String, CaseIterable, Sendable {
    case awake, rem, light, deep

    /// Display label.
    public var label: String {
        switch self {
        case .awake: return "Awake"
        case .rem:   return "REM"
        case .light: return "Light"
        case .deep:  return "Deep"
        }
    }

    /// Vertical band order in a hypnogram: 0 = top (awake) … 3 = bottom (deep).
    public var bandRank: Int {
        switch self {
        case .awake: return 0
        case .rem:   return 1
        case .light: return 2
        case .deep:  return 3
        }
    }

    /// The stage's colour. Four clearly separated hues; the light-appearance values are
    /// darkened by a uniform lightness scale so the ramp ORDER survives on a white card.
    public var color: Color {
        switch self {
        case .awake: return Aurora.dynamic(light: "7A8290", dark: "C9CFD9")
        case .rem:   return Aurora.dynamic(light: "6D4BD6", dark: "A78BFA")
        case .light: return Aurora.dynamic(light: "2A72C9", dark: "5EA9F5")
        case .deep:  return Aurora.dynamic(light: "1E3F9E", dark: "2F5BD1")
        }
    }
}

// MARK: - Surface helpers

public extension View {
    /// Paint the Aurora canvas edge-to-edge behind this view. The first line of every
    /// Aurora screen.
    func auroraCanvas() -> some View {
        self.background(Aurora.canvas.ignoresSafeArea())
    }

    /// Apply the canonical horizontal page gutter (20pt).
    func auroraGutter() -> some View {
        self.padding(.horizontal, Aurora.Space.screenGutter)
    }
}

#if DEBUG
#Preview("Aurora Tokens") {
    ScrollView {
        VStack(alignment: .leading, spacing: Aurora.Space.xl) {

            VStack(alignment: .leading, spacing: Aurora.Space.xs) {
                Text("SURFACES").font(.caption2.weight(.semibold)).tracking(1.2)
                    .foregroundStyle(Aurora.textTertiary)
                HStack(spacing: Aurora.Space.xs) {
                    ForEach(Array([Aurora.canvas, Aurora.surface1, Aurora.surface2,
                                   Aurora.surface3, Aurora.surfaceInset].enumerated()), id: \.offset) { _, c in
                        RoundedRectangle(cornerRadius: Aurora.Radius.m, style: .continuous)
                            .fill(c)
                            .frame(height: 56)
                            .overlay(RoundedRectangle(cornerRadius: Aurora.Radius.m, style: .continuous)
                                .strokeBorder(Aurora.hairline, lineWidth: Aurora.Stroke.border))
                    }
                }
            }

            ForEach(Array([("RECOVERY", Aurora.recoveryRamp), ("STRAIN", Aurora.strainRamp),
                           ("SLEEP", Aurora.sleepRamp), ("STRESS", Aurora.stressRamp)].enumerated()),
                    id: \.offset) { _, pair in
                VStack(alignment: .leading, spacing: Aurora.Space.xs) {
                    Text(pair.0).font(.caption2.weight(.semibold)).tracking(1.2)
                        .foregroundStyle(Aurora.textTertiary)
                    RoundedRectangle(cornerRadius: Aurora.Radius.s, style: .continuous)
                        .fill(LinearGradient(gradient: pair.1.gradient,
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(height: 28)
                }
            }

            VStack(alignment: .leading, spacing: Aurora.Space.xs) {
                Text("BANDS").font(.caption2.weight(.semibold)).tracking(1.2)
                    .foregroundStyle(Aurora.textTertiary)
                HStack(spacing: Aurora.Space.xxs) {
                    ForEach(AuroraRecoveryBand.allCases, id: \.self) { band in
                        Text(band.label)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(band.color)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(band.color.opacity(0.16), in: Capsule())
                    }
                }
            }
        }
        .padding(Aurora.Space.l)
    }
    .background(Aurora.canvas)
}
#endif
