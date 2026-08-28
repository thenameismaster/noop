import SwiftUI
import StrandDesign

// MARK: - Ledger component support — the two things every Ledger component shares
//
// Not a component. Two primitives that would otherwise be copy-pasted into four files:
//
//   1. `LedgerTone` — the semantic colour a delta / caption is painted in. The boards never derive
//      a delta's colour from its sign: the Sleep STAGES ledger paints "−9m vs typical" (Deep, short)
//      in `accent/caution` and "−8m vs typical" (Awake, short) in `accent/recovery`, because less
//      awake is GOOD and less deep is BAD. So a component takes the TONE, never the number, and the
//      screen — which knows the metric's polarity — decides. `colour = meaning only`.
//
//   2. `LedgerPolyline` — a normalized-coordinate polyline `Shape`. Every Ledger chart is an SVG
//      `<path>` of straight segments over a fixed viewBox in the boards; this is that, in a form
//      `.trim(from:to:)` can draw in.
//
// Nothing here reads a `Repository`, a model, or a live object. Pure presentation.

// MARK: - Tone

/// The semantic colour of a delta, a caption, or a bar — chosen by the SCREEN (which knows whether
/// "down" is good for this metric), never inferred from the sign by the component.
///
/// | tone | colour | board usage |
/// |---|---|---|
/// | `.good` | `accent/recovery` `#3EE6A8` | "+11m vs typical", "+9% vs base", "↑ trending up" |
/// | `.caution` | `accent/caution` `#F2C14E` | "−9m vs typical", "high 2 wks", debt |
/// | `.critical` | `accent/live-hr` `#FF6B81` | a negative correlation, a low band |
/// | `.neutral` | `text/tertiary` `#5C6470` | "on baseline", "in range", "steady", "+6m vs typical" |
/// | `.sleep` | `accent/sleep` `#8F9BFF` | "+4 vs base" on the Today WHY sleep row |
/// | `.strain` | `accent/strain` `#58B9FF` | the Activity domain's own deltas |
public enum LedgerTone: String, CaseIterable, Sendable {
    case good, caution, critical, neutral, sleep, strain

    /// The colour this tone paints in.
    public var color: Color {
        switch self {
        case .good:     return Ledger.accentRecovery
        case .caution:  return Ledger.accentCaution
        case .critical: return Ledger.accentLiveHR
        case .neutral:  return Ledger.textTertiary
        case .sleep:    return Ledger.accentSleep
        case .strain:   return Ledger.accentStrain
        }
    }
}

// MARK: - Polyline

/// A polyline in NORMALIZED coordinates — `x` 0…1 left→right, `y` 0…1 **top→bottom** (SVG's sense,
/// so a board path transcribes without flipping signs).
///
/// `closed` appends the two edges that turn the line into the boards' area fill
/// (`fill="rgba(62,230,168,.08)"` on the Trends RECOVERY block and the metric-detail hero): down to
/// the bottom edge from the last point, back along it to the first point.
///
/// Draw-in is `.trim(from:0,to:progress)` on the OPEN variant. A closed area path must not be
/// trimmed — trimming a filled region reveals a nonsense wedge — so the fill is revealed with a
/// mask instead; see `LedgerTrendBlock`.
struct LedgerPolyline: Shape {
    /// Normalized points, in draw order.
    var points: [CGPoint]
    /// Close the path down to the bottom edge, producing an area fill.
    var closed: Bool = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count >= 2 else { return path }
        let mapped = points.map {
            CGPoint(x: rect.minX + $0.x * rect.width,
                    y: rect.minY + $0.y * rect.height)
        }
        path.move(to: mapped[0])
        for point in mapped.dropFirst() { path.addLine(to: point) }
        if closed, let first = mapped.first, let last = mapped.last {
            path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
            path.addLine(to: CGPoint(x: first.x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - Normalization helpers

enum LedgerScale {
    /// Maps `values` into normalized `y` (0 = top of the plot = `domain.upperBound`).
    /// A zero-width domain pins everything to the vertical centre rather than dividing by zero.
    static func normalizedY(_ value: Double, in domain: ClosedRange<Double>) -> CGFloat {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return 0.5 }
        return CGFloat(1 - (value - domain.lowerBound) / span)
    }

    /// The value domain a chart plots over: the union of the data's own range and any baseline band,
    /// padded by `pad` of the span so a terminal point is not clipped by the stroke.
    /// Returns `nil` when there is nothing to plot.
    static func domain(
        values: [Double],
        including baseline: ClosedRange<Double>? = nil,
        pad: Double = 0.08
    ) -> ClosedRange<Double>? {
        var low = values.min()
        var high = values.max()
        if let baseline {
            low = Swift.min(low ?? baseline.lowerBound, baseline.lowerBound)
            high = Swift.max(high ?? baseline.upperBound, baseline.upperBound)
        }
        guard var lower = low, var upper = high else { return nil }
        if upper <= lower {
            // A dead-flat series still deserves a band to sit in: give it ±1 unit (or ±5% when the
            // value is large) so the line lands on the centre line instead of on an edge.
            let nudge = Swift.max(1, abs(upper) * 0.05)
            lower -= nudge
            upper += nudge
        } else {
            let padding = (upper - lower) * pad
            lower -= padding
            upper += padding
        }
        return lower...upper
    }

    /// Evenly spaced normalized `x` for `count` samples: first at 0, last at 1 (the boards' charts
    /// run edge to edge). A single sample sits at the left edge.
    static func normalizedX(_ index: Int, count: Int) -> CGFloat {
        guard count > 1 else { return 0 }
        return CGFloat(index) / CGFloat(count - 1)
    }
}

// MARK: - Sleep stage bridge

extension SleepStage {
    /// The Ledger stage token for this `StrandDesign` stage. The Ledger re-colours the stages
    /// (`#4A5468 · #A78BFA · #6D8DF7 · #3B55D9`) but does NOT re-define them — `SleepStage` and its
    /// `bandRank` (awake 0 → deep 3, exactly the boards' lane order) stay the one vocabulary.
    var ledgerStage: Ledger.Stage {
        switch self {
        case .awake: return .awake
        case .rem:   return .rem
        case .light: return .light
        case .deep:  return .deep
        }
    }

    /// The lane label the NIGHT TIMELINE board prints down the left edge — 9pt, uppercase.
    var ledgerLaneLabel: String {
        switch self {
        case .awake: return "AWAKE"
        case .rem:   return "REM"
        case .light: return "LIGHT"
        case .deep:  return "DEEP"
        }
    }
}
