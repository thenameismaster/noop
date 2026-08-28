import SwiftUI
import StrandDesign

// MARK: - Ledger Motion — one curve, three draw-ins, and a reduce-motion gate
//
// Spec §Motion, transcribed:
//
//   • **One curve everywhere**: `cubic-bezier(0.22, 1, 0.36, 1)` — the app's existing "calm easing",
//     which in SwiftUI is `.timingCurve(0.22, 1, 0.36, 1, duration:)`. There is no second easing in
//     the Ledger, and there are no springs; `NoopMotion.screen/.card/.value` belong to the Liquid
//     and Aurora layers, not here.
//   • **Score arc**: trim 0→x over **900 ms** + numeral count-up **700 ms**, ON APPEAR ONLY.
//   • **Charts**: a single path draw-in of **1.2 s** via trim. **No re-animation on data ticks.**
//   • **Tab switch**: 240 ms crossfade (unchanged from the current app).
//   • **Rows / text**: NO entrance animation. Content is instant; only data-viz animates.
//   • **Reduce Motion**: all draw-ins collapse to a **150 ms fade**.
//
// WHAT "ON APPEAR ONLY" MEANS MECHANICALLY, AND WHY IT IS ENFORCED HERE.
// A Ledger screen re-renders whenever its cached model is rebuilt. If a chart animated its trim on
// every value change, a 1 Hz live tick anywhere upstream would restart a 1.2 s draw on every frame
// of it. So `LedgerDrawIn` drives its progress from `.onAppear` and from nothing else — there is no
// `.onChange` hook on it, deliberately. A screen that wants to re-run a draw-in must change the
// view's `.id`, which is an explicit act.
//
// THE REDUCE-MOTION GATE READS TWO SIGNALS, per the spec's "system + in-app `NoopMotionState`":
//   1. `@Environment(\.accessibilityReduceMotion)` — the system setting. Only a `View` can read it.
//   2. `NoopMotionState.shared.quietMotion` — the in-app "Reduce motion in NOOP" preference
//      (`QuietMotionPrefs.enabledKey`, default OFF).
// Either one on ⇒ every draw-in becomes a 150 ms fade.

/// The Ledger motion set.
public enum LedgerMotion {

    // MARK: - The one curve

    /// `cubic-bezier(0.22, 1, 0.36, 1)` at a given duration. Every animation in the Ledger comes
    /// from here; a Ledger view that reaches for `.easeInOut` or a spring is off-spec.
    @inline(__always)
    public static func curve(_ duration: Double) -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: duration)
    }

    // MARK: - Durations (seconds)

    /// Score-arc trim draw-in — 900 ms.
    public static let arcDuration: Double = 0.9

    /// Hero numeral count-up — 700 ms.
    public static let countUpDuration: Double = 0.7

    /// Chart path draw-in — 1.2 s.
    public static let chartDuration: Double = 1.2

    /// Tab crossfade — 240 ms, unchanged from the current app.
    public static let tabCrossfadeDuration: Double = 0.24

    /// The Reduce-Motion collapse — 150 ms, fade only.
    public static let reducedFadeDuration: Double = 0.15

    // MARK: - Animations

    /// The 150 ms fade every draw-in collapses to under Reduce Motion.
    public static var reducedFade: Animation { curve(reducedFadeDuration) }

    /// The score arc's trim animation, or the 150 ms fade when motion is reduced.
    public static func arc(reduced: Bool) -> Animation {
        reduced ? reducedFade : curve(arcDuration)
    }

    /// The hero numeral's count-up, or the 150 ms fade when motion is reduced.
    public static func countUp(reduced: Bool) -> Animation {
        reduced ? reducedFade : curve(countUpDuration)
    }

    /// A chart path's single draw-in, or the 150 ms fade when motion is reduced.
    public static func chart(reduced: Bool) -> Animation {
        reduced ? reducedFade : curve(chartDuration)
    }

    /// The tab crossfade. Reduce Motion does not shorten it — it is already a fade, and the spec
    /// marks it "unchanged".
    public static var tabCrossfade: Animation { curve(tabCrossfadeDuration) }

    /// Rows and text have **no** entrance animation. Returned as `Animation?` = `nil` so a call
    /// site can pass it to `.animation(_:value:)` and document the intent in one place.
    public static let rows: Animation? = nil

    /// The draw-in duration for a given kind, honouring the reduce-motion gate. Handy for a
    /// hand-rolled `withAnimation` at a call site that is not using `LedgerDrawIn`.
    public static func duration(_ kind: DrawIn, reduced: Bool) -> Double {
        guard !reduced else { return reducedFadeDuration }
        switch kind {
        case .arc:   return arcDuration
        case .chart: return chartDuration
        }
    }

    /// The two things in the Ledger that draw themselves in.
    public enum DrawIn: Sendable {
        /// The 270° readiness arc — 900 ms trim.
        case arc
        /// Any chart path — 1.2 s trim.
        case chart

        /// The animation for this draw-in under the current gate.
        public func animation(reduced: Bool) -> Animation {
            switch self {
            case .arc:   return LedgerMotion.arc(reduced: reduced)
            case .chart: return LedgerMotion.chart(reduced: reduced)
            }
        }
    }
}

// MARK: - The reduce-motion gate

private struct LedgerReduceMotionKey: EnvironmentKey {
    /// `false` by default so a preview or a detached subtree animates normally. The real value is
    /// installed by `.ledgerMotionGate()` at the screen root.
    static let defaultValue: Bool = false
}

public extension EnvironmentValues {
    /// `true` when either the system Reduce Motion setting or NOOP's own "Reduce motion in NOOP"
    /// preference is on. Read this in a leaf; install it once with `.ledgerMotionGate()`.
    var ledgerReduceMotion: Bool {
        get { self[LedgerReduceMotionKey.self] }
        set { self[LedgerReduceMotionKey.self] = newValue }
    }
}

/// Resolves both reduce-motion signals and publishes the result into the environment.
///
/// Applied ONCE at a Ledger screen's root. It observes `NoopMotionState.shared`, which publishes
/// only when the preference or the power state actually changes — not on any per-second cadence —
/// so this does not violate the "never observe a live object at screen root" rule that exists to
/// keep the 1 Hz HR tick out of a screen's render path.
private struct LedgerMotionGate: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @ObservedObject private var motion = NoopMotionState.shared

    func body(content: Content) -> some View {
        content.environment(\.ledgerReduceMotion, systemReduceMotion || motion.quietMotion)
    }
}

public extension View {
    /// Installs `\.ledgerReduceMotion` for this subtree from the system setting **and**
    /// `NoopMotionState.shared.quietMotion`. Apply once, at the screen root.
    func ledgerMotionGate() -> some View {
        modifier(LedgerMotionGate())
    }
}

/// Reads the reduce-motion gate for a leaf that is not under a `.ledgerMotionGate()` root — a
/// standalone component, a preview, a sheet presented outside the Ledger shell.
///
/// ```swift
/// LedgerMotionReader { reduced in
///     ScoreArc(progress: …).animation(LedgerMotion.arc(reduced: reduced), value: …)
/// }
/// ```
public struct LedgerMotionReader<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @ObservedObject private var motion = NoopMotionState.shared
    private let content: (Bool) -> Content

    public init(@ViewBuilder content: @escaping (Bool) -> Content) {
        self.content = content
    }

    public var body: some View {
        content(systemReduceMotion || motion.quietMotion)
    }
}

// MARK: - The draw-in container

/// Drives a 0→1 progress for a trim-based draw-in, **on appear only**.
///
/// Full motion: `progress` animates 0→1 over the kind's duration on the one curve, and the content
/// is fully opaque throughout. Reduced motion: `progress` snaps to 1 with no animation and the
/// content fades in over 150 ms — the spec's "all draw-ins collapse to a 150 ms fade".
///
/// There is intentionally NO `.onChange` here. New data re-renders the path at its final geometry
/// without restarting the draw; that is what "no re-animation on data ticks" means.
///
/// ```swift
/// LedgerDrawIn(.chart) { progress in
///     TrendPath(points: points).trim(from: 0, to: progress).stroke(Ledger.accentRecovery, lineWidth: 1.7)
/// }
/// ```
public struct LedgerDrawIn<Content: View>: View {
    @Environment(\.ledgerReduceMotion) private var reduceMotion

    private let kind: LedgerMotion.DrawIn
    private let content: (Double) -> Content

    @State private var progress: Double = 0
    @State private var opacity: Double = 1
    @State private var hasAppeared = false

    /// - Parameters:
    ///   - kind: `.arc` (900 ms) or `.chart` (1.2 s).
    ///   - content: builds the view from a 0…1 trim progress.
    public init(_ kind: LedgerMotion.DrawIn, @ViewBuilder content: @escaping (Double) -> Content) {
        self.kind = kind
        self.content = content
    }

    public var body: some View {
        content(progress)
            .opacity(opacity)
            .onAppear(perform: start)
    }

    private func start() {
        guard !hasAppeared else { return }   // "on appear only" — never twice.
        hasAppeared = true

        if reduceMotion {
            progress = 1                      // final geometry, immediately.
            opacity = 0
            withAnimation(LedgerMotion.reducedFade) { opacity = 1 }
        } else {
            withAnimation(kind.animation(reduced: false)) { progress = 1 }
            // Belt: snap to final geometry once the draw should have finished. `onAppear` can fire
            // while the view is not actually being rendered (a `TabView` pre-building a background
            // tab), and an animation transaction begun there can be dropped — observed as a chart
            // whose guides and axis drew but whose data never did, because `progress` stayed at 0.
            // Writing `1` again is a no-op after a completed draw and a plain snap after a dropped
            // one, so the chart is ALWAYS complete one duration after first appear.
            let duration = LedgerMotion.duration(kind, reduced: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) {
                progress = 1
            }
        }
    }
}

// MARK: - Numeral count-up

/// Counts a numeral up to its value over 700 ms on appear, then tracks later changes instantly.
///
/// A thin, Ledger-typed wrapper around the same idea as `StrandDesign.CountUpText`, kept local
/// because the Ledger needs the count to run on the ONE curve and to obey the two-signal gate — and
/// because the hero numeral's font comes from `LedgerType`, not from a passed-in `Font`.
///
/// Under Reduce Motion the final value is shown instantly, with no tick.
public struct LedgerCountUpNumeral: View, Animatable {
    @Environment(\.ledgerReduceMotion) private var reduceMotion

    private let target: Double
    private let format: (Double) -> String
    private let font: Font
    private let tracking: CGFloat

    @State private var displayed: Double = 0
    @State private var hasAppeared = false

    /// - Parameters:
    ///   - value: the final value. `Repository`-computed; this view never derives a number.
    ///   - font: a `LedgerType` numeral font (already `.monospacedDigit()`).
    ///   - tracking: the matching `LedgerType` tracking value.
    ///   - format: renders the intermediate value — e.g. `{ "\(Int($0.rounded()))" }`.
    public init(
        value: Double,
        font: Font = LedgerType.displayNumeral,
        tracking: CGFloat = LedgerType.displayTracking,
        format: @escaping (Double) -> String = { "\(Int($0.rounded()))" }
    ) {
        self.target = value
        self.font = font
        self.tracking = tracking
        self.format = format
    }

    public var animatableData: Double {
        get { displayed }
        set { displayed = newValue }
    }

    public var body: some View {
        Text(format(displayed))
            .font(font)
            .tracking(tracking)
            .onAppear {
                guard !hasAppeared else { return }
                hasAppeared = true
                if reduceMotion {
                    displayed = target
                } else {
                    withAnimation(LedgerMotion.countUp(reduced: false)) { displayed = target }
                }
            }
            .onChangeCompatLedger(target) { new in
                displayed = new              // later ticks land instantly — no re-run of the count.
            }
    }
}

private extension View {
    /// `onChange` with a single-parameter closure across the macOS 13 / iOS 17 floor. Named
    /// distinctly so it cannot collide with the app target's own `onChangeCompat`.
    @ViewBuilder
    func onChangeCompatLedger<V: Equatable>(_ value: V, perform: @escaping (V) -> Void) -> some View {
        if #available(macOS 14.0, iOS 17.0, *) {
            self.onChange(of: value) { _, newValue in perform(newValue) }
        } else {
            self.onChange(of: value) { newValue in perform(newValue) }
        }
    }
}
