import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Ledger Trends — spec §"05 · Trends"
//
// Board: `NOOP Redesign.dc.html` → `data-screen-label="Trends"`. Transcribed item by item:
//
//   1. Header + range pill    `padding:22px 24px 0` · overline "LONG VIEW" 11/600/+2.6 ·
//                             title "Trends" Space Grotesk 27/700/−.5 · `align-items:flex-end` ·
//                             pill `#10131A` + `rgba(255,255,255,.07)` border, segments
//                             `padding:5px 12px`, selected inverts to `#F2F4F7` on `#0A0C11`.
//   2. Five TrendBlocks       stacked, hairline-separated, NO CARDS:
//                             RECOVERY (mint, area fill @8%) · HRV (mint) · RESTING HR (gray) ·
//                             SLEEP SCORE (indigo) · DAY STRAIN (blue, no rule beneath).
//                             First block `margin-top:16px`; the rest `margin-top:14px`.
//   3. MEANINGFUL CHANGE      `margin:16px 24px 22px; border-left:2px solid #3EE6A8`.
//
// This is an ADDITIVE, toggle-gated screen (`LedgerFlags.ledgerUIEnabledKey`, default false). It
// changes NOTHING in the data layer: every number below is a value NOOP already computes and every
// tap routes to a `TabRoute` NOOP already has.
//
// WHAT IS COPIED VERBATIM FROM `TrendsView` (the classic screen this forks):
//   • `@EnvironmentObject var repo: Repository` is the ONLY data source, and `LiveState` is
//     deliberately NOT observed — observing it forced a full re-render of this subtree on every
//     ~1 Hz live-HR tick.
//   • The six-step range enum and its `widening` auto-expand order (`TrendsView.Range` is
//     private-by-nesting, so — exactly as `AuroraTrendsRange` did — it is mirrored here).
//   • Windows cut against TODAY's local day key, not the latest recorded day (issue #23).
//   • Rest is the `sleep_performance` COMPOSITE via `repo.exploreSeries` (#732), never
//     `DailyMetric.efficiency`.
//   • The delta is mean(recent half) − mean(earlier half) over the window, guarded at ≥ 4 points —
//     `TrendsView.periodChange`, expressed through `ComparisonEngine.compare`.
//   • Effort/strain is stored 0–100 and only DISPLAYED on the selected scale (#268,
//     `UnitPrefs.effortScaleKey` — the key string is byte-identical).
//   • Tap-through routes stay `TabRoute.metric(_:)`, and macOS wraps its own `NavigationStack` +
//     `tabRouteDestinations()` because the `.trends` detail pane has none (RootView).
//
// PERF CONTRACT. Unlike the classic screen, NOTHING here scans `repo.days` inside `body`: the whole
// screen is one memoized `@State` model rebuilt in a `.task(id:)` whenever the day count, the range,
// the Effort scale or the loaded Rest series changes. `body` reads pre-formatted strings and
// pre-sliced `[Double]`s only.

// MARK: - Range

/// The Trends range control: W(7) / M(30) / 3M(90) / 6M(180) / 1Y(365) / ALL.
///
/// A verbatim mirror of `TrendsView.Range` — that enum is nested inside `TrendsView` and so is not
/// reachable from another file; mirroring it is the only way to keep the windowing byte-identical
/// without editing the original. `AuroraTrendsRange` is the same mirror for the Aurora fork.
///
/// The BOARD's pill shows `7D · 30D · 90D`, and the spec adds *"(+1Y/ALL in the control)"* — so
/// `pillOptions` is those five. `.half` (6M) stays in the enum because `widening` walks the full
/// order when a selected window is empty; it is simply never offered as a chip.
enum LedgerTrendsRange: Int, CaseIterable, Identifiable, Sendable {
    case week = 7, month = 30, quarter = 90, half = 180, year = 365, all = 0

    var id: Int { rawValue }

    /// The chips the Ledger pill offers, left to right — the board's `7D 30D 90D`, plus the spec's
    /// `1Y` and `ALL`.
    static let pillOptions: [LedgerTrendsRange] = [.week, .month, .quarter, .year, .all]

    /// The pill's segment label, verbatim from the board (`7D` / `30D` / `90D`), extended with the
    /// spec's two longer chips.
    var pillLabel: String {
        switch self {
        case .week:    return String(localized: "7D")
        case .month:   return String(localized: "30D")
        case .quarter: return String(localized: "90D")
        case .half:    return String(localized: "6M")
        case .year:    return String(localized: "1Y")
        case .all:     return String(localized: "ALL")
        }
    }

    /// The window suffix inside a numeric delta chip — the board's `"+6 / 90d"`.
    var deltaSuffix: String {
        switch self {
        case .week:    return String(localized: "7d")
        case .month:   return String(localized: "30d")
        case .quarter: return String(localized: "90d")
        case .half:    return String(localized: "6m")
        case .year:    return String(localized: "1y")
        case .all:     return String(localized: "all")
        }
    }

    /// The spelled-out name used in the MEANINGFUL CHANGE copy ("over 90 days").
    var longName: String {
        switch self {
        case .week:    return String(localized: "7 days")
        case .month:   return String(localized: "30 days")
        case .quarter: return String(localized: "90 days")
        case .half:    return String(localized: "6 months")
        case .year:    return String(localized: "a year")
        case .all:     return String(localized: "all history")
        }
    }

    /// Trailing-day window, or nil for "all history".
    var days: Int? { self == .all ? nil : rawValue }

    /// This range plus every LARGER range, ascending — the auto-expand search order when the
    /// selected window holds zero points. Byte-identical to `TrendsView.Range.widening`.
    var widening: [LedgerTrendsRange] {
        let order: [LedgerTrendsRange] = [.week, .month, .quarter, .half, .year, .all]
        guard let i = order.firstIndex(of: self) else { return [.all] }
        return Array(order[i...])
    }
}

// MARK: - Memoized model

/// One resolved TrendBlock, fully formatted. Built off the render path; `body` only reads it.
private struct LedgerTrendsBlock: Identifiable {
    /// The `MetricCatalog` key — also the `TabRoute.metric(_:)` this block pushes.
    let key: String
    /// The block's overline ("RECOVERY"), uppercased by `ledgerOverline()`.
    let label: String
    let value: String?
    let unit: String?
    let delta: String?
    let tone: LedgerTone
    /// The resolved window's series, oldest first.
    let points: [Double]
    /// "Your normal", in value units. `nil` only where the app genuinely holds no baseline yet.
    let baseline: ClosedRange<Double>?
    /// The level-shift point to ring on the chart (`LedgerTrendsView.shift`). `nil` = no shift found.
    let marker: Int?
    let accent: Color
    /// The board applies the `@8%` area fill to RECOVERY only.
    let showsAreaFill: Bool

    var id: String { key }
}

/// The THIS WEEK digest strip: trailing 7 days vs the 7 before, pre-formatted.
private struct LedgerTrendsWeek {
    var items: [LedgerStatStrip.Item]
}

/// The whole screen, resolved once per (days · range · Effort scale · Rest series) change.
private struct LedgerTrendsModel {
    var blocks: [LedgerTrendsBlock] = []
    /// The MEANINGFUL CHANGE copy. Empty renders nothing — `LedgerCoachNote` self-hides.
    var note: String = ""
    /// THIS WEEK vs last. nil (no scored day in the trailing 7) renders nothing.
    var week: LedgerTrendsWeek?

    static let empty = LedgerTrendsModel()
}

// MARK: - Screen

/// The Ledger Trends screen: one range control, five stacked TrendBlocks drawn straight on
/// `bg/screen`, and a single MEANINGFUL CHANGE note.
@MainActor
struct LedgerTrendsView: View {

    // MARK: Board constants

    /// `margin-top:16px` above the FIRST trend block.
    private static let firstBlockGap: CGFloat = 16
    /// `margin-top:14px` above every subsequent block.
    private static let blockGap: CGFloat = 14
    /// The board puts `padding-bottom:2px` under the last (DAY STRAIN) chart and `margin-top:16px`
    /// above the note — an 18pt gap. `LedgerTrendBlock` always contributes its own 14pt bottom
    /// padding, so the remaining 4pt is added here and the total is the board's 18.
    private static let noteGap: CGFloat = 18 - 14
    /// `margin:… 22px` beneath the note — the board's bottom gutter.
    private static let pageBottomPadding: CGFloat = 22
    /// The board's Trends pill uses `padding:5px 12px` on each segment.
    private static let pillSegmentPadding: CGFloat = 12

    // MARK: Data sources (identical to `TrendsView`)

    @EnvironmentObject var repo: Repository
    // NOTE: deliberately does NOT observe LiveState — Trends shows historical data only, and
    // observing it forced a full re-render of this subtree on every ~1 Hz live-HR tick.

    /// Effort display scale (#268). Display-only: Effort is always stored and plotted 0–100. The
    /// key string is byte-identical to every other surface that reads it.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue

    @State private var range: LedgerTrendsRange = .quarter
    /// Rest's per-day series, keyed by "yyyy-MM-dd" — the `sleep_performance` COMPOSITE (#732).
    @State private var sleepPerfByDay: [String: Double] = [:]
    /// The memoized screen. Rebuilt in `.task(id:)`, never in `body`.
    @State private var model: LedgerTrendsModel = .empty

    init() {}

    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    // MARK: Body

    var body: some View {
        // The blocks tap through to their MetricDetailView. On iOS each tab already supplies a
        // NavigationStack; on macOS the `.trends` detail pane has NONE (RootView), so — exactly as
        // TrendsView and AuroraTrendsView do — wrap the scaffold in one here. Registering the value
        // routes twice in one stack double-pushes (#38), so the Ledger shell must NOT also register
        // `tabRouteDestinations()` around this screen on macOS.
        #if os(macOS)
        NavigationStack { scaffold.tabRouteDestinations() }
        #else
        scaffold
        #endif
    }

    private var scaffold: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Ledger.pageMargin)
            .padding(.bottom, Self.pageBottomPadding)
        }
        .background(Ledger.bgScreen.ignoresSafeArea())
        .ledgerMotionGate()
        // Keep pull-to-refresh (spec §Interactions).
        .refreshable { await repo.refresh() }
        // #732 — load the resolved sleep_performance series so SLEEP SCORE plots the SAME composite
        // the Today Rest score uses (not raw efficiency). Keyed on the day count so a newly-scored
        // night refreshes it, mirroring TrendsView.
        .task(id: repo.days.count) {
            let s = await repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
            sleepPerfByDay = Dictionary(s.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        }
        // PERF: the ONE place `repo.days` is scanned. Everything `body` reads is pre-resolved here.
        .task(id: rebuildKey) {
            model = makeModel()
        }
    }

    /// Every input the model depends on. A change in any of them rebuilds it — off the render path.
    private var rebuildKey: LedgerTrendsRebuildKey {
        LedgerTrendsRebuildKey(dayCount: repo.days.count,
                               range: range,
                               effortScaleRaw: effortScaleRaw,
                               sleepPerfCount: sleepPerfByDay.count)
    }

    // MARK: 1 · Header + range pill

    /// Spec §05.1 — *"Header + range pill: 7D/30D/90D (+1Y/ALL in the control); selected segment
    /// inverts to paper-on-ink."* The inversion lives in `LedgerRangePill`; this supplies the chips.
    private var header: some View {
        LedgerHeader(overline: String(localized: "LONG VIEW"),
                     title: String(localized: "Trends"),
                     // The board's `align-items:flex-end`.
                     alignment: .bottom) {
            LedgerRangePill(
                options: LedgerTrendsRange.pillOptions,
                selection: $range,
                label: { $0.pillLabel },
                horizontalPadding: Self.pillSegmentPadding
            )
            .accessibilityLabel(Text(String(localized: "Time range")))
        }
    }

    // MARK: 2 + 3 · Blocks and note

    @ViewBuilder
    private var content: some View {
        if repo.days.isEmpty {
            // Honest empty state, drawn on the canvas — no card.
            Text(repo.loaded
                 ? String(localized: "Trends need history to draw. Import your WHOOP export in Data Sources to see weeks, months and years instantly.")
                 : String(localized: "Loading your history…"))
                .ledgerBody()
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Self.firstBlockGap)
        } else {
            ForEach(Array(model.blocks.enumerated()), id: \.element.id) { index, block in
                blockLink(block, isLast: index == model.blocks.count - 1)
                    .padding(.top, index == 0 ? Self.firstBlockGap : Self.blockGap)
            }
            if let week = model.week {
                weekSection(week)
                    .padding(.top, Self.noteGap)
            }
            if !model.note.isEmpty {
                // Spec §05.3 — mint left-rule, one per screen, copy from the window deltas.
                LedgerCoachNote(title: String(localized: "Meaningful change"),
                                message: model.note,
                                accent: Ledger.accentRecovery)
                    .padding(.top, Self.noteGap)
            }
        }
    }

    // MARK: 2b · THIS WEEK
    //
    // The digest read: the trailing 7 days against the 7 before them, as a stat strip — the week's
    // narrative anchor under the long-view charts. Every figure is a plain mean/sum over
    // `repo.days` (and the loaded Rest series), computed off-body in `makeModel` like everything
    // else here; deltas colour by the metric's own polarity.

    private func weekSection(_ week: LedgerTrendsWeek) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Ledger.hairline)
                .frame(height: Ledger.hairlineWidth)

            Text(String(localized: "This week \u{00B7} vs last")).ledgerOverline()                .padding(.top, Self.weekOverlineTop)

            // The strip's own top rule is off — this section's rule + overline already frame it.
            LedgerStatStrip(week.items, showsTopRule: false, showsBottomRule: false)
        }
    }

    /// `padding-top:14px` under the section rule — the shared section-header rhythm.
    private static let weekOverlineTop: CGFloat = 14

    /// One TrendBlock wrapped in its value-based push. Spec §Tap Map — *"Trends · any TrendBlock →
    /// `TabRoute.metric(key)`"*. A VALUE push (not a closure link) is what lets a tab re-tap pop
    /// back to the root (#135/#198).
    private func blockLink(_ block: LedgerTrendsBlock, isLast: Bool) -> some View {
        NavigationLink(value: TabRoute.metric(block.key)) {
            LedgerTrendBlock(
                label: block.label,
                value: block.value,
                unit: block.unit,
                delta: block.delta,
                deltaTone: block.tone,
                points: block.points,
                baseline: block.baseline,
                marker: block.marker,
                accent: block.accent,
                showsAreaFill: block.showsAreaFill,
                // The board's DAY STRAIN block carries no rule beneath it.
                showsDivider: !isLast
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Rebuild key

/// The memoization key for `makeModel()`.
private struct LedgerTrendsRebuildKey: Equatable {
    let dayCount: Int
    let range: LedgerTrendsRange
    let effortScaleRaw: String
    let sleepPerfCount: Int
}

// MARK: - Model construction
//
// Everything below runs in `.task`, never in `body`.

private extension LedgerTrendsView {

    /// One metric's resolved window: the values that actually plotted and the range that held them.
    struct Resolved {
        var values: [Double]
        /// The `yyyy-MM-dd` key each value came from, index-aligned with `values` — what lets a
        /// chart annotation name its date.
        var dayKeys: [String]
        var effective: LedgerTrendsRange
    }

    // MARK: Windowing (verbatim from `TrendsView`)

    /// Days for a given range, taken RELATIVE TO TODAY (the phone's local date) — not the latest
    /// recorded day, which on a stale import anchored 7D/30D/90D to months-old data so it looked
    /// current (issue #23). ISO `yyyy-MM-dd` compares chronologically.
    func days(for r: LedgerTrendsRange) -> [DailyMetric] {
        guard let n = r.days else { return repo.days }
        let base = Calendar.current.date(byAdding: .day, value: -(n - 1), to: Date()) ?? Date()
        let cutoffKey = Repository.localDayKey(base)
        return repo.days.filter { $0.day >= cutoffKey }
    }

    /// Walk the widening order ONCE and keep the first window that holds at least one reading.
    /// Identical to `TrendsView.resolve(_:)` minus the caption, which the board does not show.
    func resolve(_ value: (DailyMetric) -> Double?) -> Resolved {
        for r in range.widening {
            let pairs = days(for: r).compactMap { d in value(d).map { (d.day, $0) } }
            if !pairs.isEmpty {
                return Resolved(values: pairs.map(\.1), dayKeys: pairs.map(\.0), effective: r)
            }
        }
        let pairs = repo.days.compactMap { d in value(d).map { (d.day, $0) } }
        return Resolved(values: pairs.map(\.1), dayKeys: pairs.map(\.0), effective: .all)
    }

    // MARK: Statistics (existing primitives only)

    /// The window's change as mean(recent half) − mean(earlier half), guarded at ≥ 4 readings.
    /// Byte-identical to `TrendsView.periodChange`, routed through the shipped `ComparisonEngine`.
    func periodDelta(_ values: [Double]) -> Double? {
        guard values.count >= 4 else { return nil }
        let mid = values.count / 2
        return ComparisonEngine.compare(current: Array(values.suffix(values.count - mid)),
                                        previous: Array(values.prefix(mid))).delta
    }

    /// The point in a window where the metric's LEVEL stepped — the marker the chart rings and the
    /// note dates ("Resting HR stepped up around Aug 12").
    ///
    /// PRESENTATION-ONLY, deliberately: it compares the 7-day mean after each candidate point with
    /// the 7-day mean before it and keeps the largest step, only when that step clears 0.8 σ of the
    /// window (σ via the shipped `ComparisonEngine.stat`, no new statistics). Nothing here is stored,
    /// scored, or fed downstream — it annotates a chart in the iOS-only Ledger preview, which is why
    /// it lives in this screen and carries no Android twin (the parity contract binds analytics and
    /// stored values, not a preview shell's chart furniture).
    struct Shift {
        /// Index into the window's values — the first day of the AFTER regime.
        var index: Int
        /// after-mean − before-mean, in value units. Sign = direction of the step.
        var delta: Double
    }

    func shift(_ values: [Double]) -> Shift? {
        let w = 7
        guard values.count >= w * 3 else { return nil }
        let stat = ComparisonEngine.stat(values)
        guard stat.stdev > 0 else { return nil }

        var best: Shift?
        for i in w...(values.count - w) {
            let after = values[i..<(i + w)].reduce(0, +) / Double(w)
            let before = values[(i - w)..<i].reduce(0, +) / Double(w)
            let step = after - before
            if abs(step) > abs(best?.delta ?? 0) { best = Shift(index: i, delta: step) }
        }
        guard let best, abs(best.delta) >= stat.stdev * 0.8 else { return nil }
        return best
    }

    /// "Aug 12" for the day key at a shift's index, or `nil` when the key cannot parse. Locale-aware
    /// via the `MMMd` template.
    func shiftDateText(_ shift: Shift?, dayKeys: [String]) -> String? {
        guard let shift, dayKeys.indices.contains(shift.index),
              let date = Self.dayKeyParser.date(from: dayKeys[shift.index]) else { return nil }
        return Self.shiftDateFormatter.string(from: date)
    }

    static let dayKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let shiftDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    /// The delta's colour. The SCREEN decides polarity — a falling resting HR is `.good`.
    /// `higherIsBetter == nil` (Effort) has no valence, so it stays neutral here and is coloured by
    /// its baseline instead (see `strainAboveNormal`).
    func tone(_ delta: Double?, higherIsBetter: Bool?) -> LedgerTone {
        guard let d = delta, abs(d) > 0.0001, let better = higherIsBetter else { return .neutral }
        return (d > 0) == better ? .good : .caution
    }

    /// The board's word-style chip — `"↑ trending up"` / `"steady"`. Used by RECOVERY and
    /// SLEEP SCORE, which the board shows without a number.
    func directionChip(_ delta: Double?) -> String? {
        guard let d = delta else { return nil }
        if abs(d) <= 0.0001 { return String(localized: "steady") }
        return d > 0 ? String(localized: "↑ trending up") : String(localized: "↓ trending down")
    }

    /// The board's numeric chip — `"+6 / 90d"`. `−` is U+2212, matching every other NOOP delta.
    func numericChip(_ delta: Double?, effective: LedgerTrendsRange,
                     format: (Double) -> String) -> String? {
        guard let d = delta else { return nil }
        if abs(d) <= 0.0001 { return String(localized: "steady") }
        let sign = d > 0 ? "+" : "\u{2212}"
        return "\(sign)\(format(abs(d))) / \(effective.deltaSuffix)"
    }

    // MARK: Baseline bands
    //
    // Spec §Layout: *"Every trend chart carries its baseline band — a value without 'your normal'
    // context is banned."* Two honest sources, in this order:
    //
    //   1. The PERSONAL baseline, where NOOP has a `MetricCfg` for the metric (hrv / resting_hr /
    //      strain): `VitalBands.calendarSeries` → `Baselines.foldHistory` → `baseline ± sigmaK·σ`,
    //      the exact composition the shipped Body/Health verdicts use, so the Ledger band and those
    //      verdicts can never disagree. Not yet trusted (< 14 valid nights, or stale) falls back to
    //      the population range those same call sites hardcode.
    //   2. `ComparisonEngine.stat` mean ± 1 SD over all history, for RECOVERY and SLEEP SCORE —
    //      the two blocks NOOP has NO `MetricCfg` for. This invents no data: it is the app's own
    //      statistics primitive over the user's own series.
    //
    // DAY STRAIN has a `MetricCfg` but no population range anywhere in the app, so an untrusted
    // strain baseline draws NO band — which is also exactly what the board shows for that block.

    /// The personal band for a metric NOOP holds a `MetricCfg` for.
    func personalBand(_ value: (DailyMetric) -> Double?,
                      cfg: MetricCfg,
                      population: ClosedRange<Double>?) -> ClosedRange<Double>? {
        personalBand(state: baselineState(value, cfg: cfg), population: population)
    }

    /// The personal band for an ALREADY-folded baseline, so a caller that needs the state as well
    /// (Effort, which colours its chip from it) folds the history once instead of twice.
    func personalBand(state: BaselineState,
                      population: ClosedRange<Double>?) -> ClosedRange<Double>? {
        guard state.trusted else { return population }
        let s = Baselines.sigma(state)
        return (state.baseline - VitalBands.sigmaK * s)...(state.baseline + VitalBands.sigmaK * s)
    }

    /// The folded personal baseline over ALL history, calendar-padded so wear gaps age it correctly.
    func baselineState(_ value: (DailyMetric) -> Double?, cfg: MetricCfg) -> BaselineState {
        let rows: [(day: String, value: Double?)] = repo.days.map { (day: $0.day, value: value($0)) }
        return Baselines.foldHistory(VitalBands.calendarSeries(rows), cfg: cfg)
    }

    /// "Your normal" for a metric with no `MetricCfg`: mean ± 1 SD of the full history.
    func statBand(_ value: (DailyMetric) -> Double?) -> ClosedRange<Double>? {
        let vals = repo.days.compactMap(value)
        guard vals.count >= 2 else { return nil }
        let stat = ComparisonEngine.stat(vals)
        guard stat.stdev > 0 else { return nil }
        return (stat.mean - stat.stdev)...(stat.mean + stat.stdev)
    }

    // MARK: Assembly

    func makeModel() -> LedgerTrendsModel {
        guard !repo.days.isEmpty else { return .empty }

        let scale = effortScale
        let intFormat: (Double) -> String = { "\(Int($0.rounded()))" }
        let strainFormat: (Double) -> String = { UnitFormatter.effortDisplay($0, scale: scale) }

        // Resolve each metric's window ONCE.
        let recovery = resolve { $0.recovery }
        let hrv = resolve { $0.avgHrv }
        let rhr = resolve { $0.restingHr.map(Double.init) }
        let sleep = resolve { sleepPerfByDay[$0.day] }
        let strain = resolve { $0.strain }

        let recoveryDelta = periodDelta(recovery.values)
        let hrvDelta = periodDelta(hrv.values)
        let rhrDelta = periodDelta(rhr.values)
        let sleepDelta = periodDelta(sleep.values)
        let strainDelta = periodDelta(strain.values)

        // Effort has no valence, so its chip is coloured by where the window sits against the
        // personal Effort baseline: `Baselines.deviation`'s own `inNormalRange` (|z| ≤ 1) test, no
        // new threshold. Above normal → the board's caution chip.
        let strainState = baselineState({ $0.strain }, cfg: Baselines.strainCfg)
        let strainElevated = strainAboveNormal(strain.values, state: strainState)

        // Level-shift markers (presentation-only — see `shift`'s comment). Each block rings its own
        // shift point; HRV and resting HR additionally date theirs in the note, because those two
        // are the recovery-driving pair the note already narrates.
        let recoveryShift = shift(recovery.values)
        let hrvShift = shift(hrv.values)
        let rhrShift = shift(rhr.values)
        let sleepShift = shift(sleep.values)
        let strainShift = shift(strain.values)

        let blocks: [LedgerTrendsBlock] = [
            LedgerTrendsBlock(
                key: "recovery",
                label: String(localized: "Recovery"),
                value: recovery.values.last.map(intFormat),
                unit: nil,
                delta: directionChip(recoveryDelta),
                tone: tone(recoveryDelta, higherIsBetter: true),
                points: recovery.values,
                baseline: statBand { $0.recovery },
                marker: recoveryShift?.index,
                accent: Ledger.accentRecovery,
                showsAreaFill: true),

            LedgerTrendsBlock(
                key: "hrv",
                label: String(localized: "HRV"),
                value: hrv.values.last.map(intFormat),
                unit: String(localized: "ms"),
                delta: numericChip(hrvDelta, effective: hrv.effective, format: intFormat),
                tone: tone(hrvDelta, higherIsBetter: true),
                points: hrv.values,
                baseline: personalBand({ $0.avgHrv }, cfg: Baselines.hrvCfg, population: 40...120),
                marker: hrvShift?.index,
                accent: Ledger.accentRecovery,
                showsAreaFill: false),

            LedgerTrendsBlock(
                key: "rhr",
                label: String(localized: "Resting HR"),
                value: rhr.values.last.map(intFormat),
                unit: String(localized: "bpm"),
                delta: numericChip(rhrDelta, effective: rhr.effective, format: intFormat),
                tone: tone(rhrDelta, higherIsBetter: false),
                points: rhr.values,
                baseline: personalBand({ $0.restingHr.map(Double.init) },
                                       cfg: Baselines.restingHRCfg, population: 40...60),
                marker: rhrShift?.index,
                // The board draws this line in `#9BA3B0` — chrome grey, because resting HR has no
                // domain accent of its own.
                accent: Ledger.textSecondary,
                showsAreaFill: false),

            LedgerTrendsBlock(
                key: "sleep_performance",
                label: String(localized: "Sleep score"),
                value: sleep.values.last.map(intFormat),
                unit: nil,
                delta: directionChip(sleepDelta),
                tone: tone(sleepDelta, higherIsBetter: true),
                points: sleep.values,
                baseline: statBand { sleepPerfByDay[$0.day] },
                marker: sleepShift?.index,
                accent: Ledger.accentSleep,
                showsAreaFill: false),

            LedgerTrendsBlock(
                key: "strain",
                label: String(localized: "Day strain"),
                value: strain.values.last.map(strainFormat),
                // The board prints DAY STRAIN with no unit — it assumes the WHOOP 0–21 axis. The
                // denominator is added ONLY on the 0–100 scale, where a bare number would otherwise
                // be misread as a WHOOP strain.
                unit: scale == .whoop ? nil : "/ \(UnitFormatter.effortScaleMax(scale))",
                delta: numericChip(strainDelta, effective: strain.effective, format: strainFormat),
                tone: strainElevated ? .caution : .neutral,
                points: strain.values,
                // No population Effort range exists anywhere in NOOP, so an untrusted strain
                // baseline draws no band — which is what the board shows for this block too.
                baseline: personalBand(state: strainState, population: nil),
                marker: strainShift?.index,
                accent: Ledger.accentStrain,
                showsAreaFill: false),
        ]

        return LedgerTrendsModel(
            blocks: blocks,
            note: meaningfulChange(hrv: hrv, hrvDelta: hrvDelta,
                                   hrvShift: hrvShift,
                                   hrvShiftDate: shiftDateText(hrvShift, dayKeys: hrv.dayKeys),
                                   rhr: rhr, rhrDelta: rhrDelta,
                                   rhrShift: rhrShift,
                                   rhrShiftDate: shiftDateText(rhrShift, dayKeys: rhr.dayKeys),
                                   strainElevated: strainElevated),
            week: weekDigest())
    }

    /// Is the resolved Effort window running above the personal Effort baseline? Uses
    /// `Baselines.deviation`'s own in-normal-range test (|z| ≤ 1) — no new threshold.
    func strainAboveNormal(_ values: [Double], state: BaselineState) -> Bool {
        guard state.trusted, !values.isEmpty else { return false }
        let m = values.reduce(0, +) / Double(values.count)
        let dev = Baselines.deviation(m, state: state)
        return !dev.inNormalRange && dev.z > 0
    }

    // MARK: 3 · MEANINGFUL CHANGE
    //
    // Spec §05.3 — *"copy from existing baseline-shift detection (deltas over window)."* Every
    // clause below is a sentence about a number this screen already plots; there are no pattern
    // claims ("your strongest rise on record" and the like are deliberately NOT reproduced — spec
    // §01.6 bans fabricated pattern claims). When no delta resolves, the note is empty and
    // `LedgerCoachNote` renders nothing at all.

    // MARK: THIS WEEK digest

    /// The trailing 7 local days vs the 7 before them: recovery mean, sleep-score mean, total
    /// Effort. Plain means/sums over the SAME rows the blocks plot; a metric with no reading in
    /// the trailing week shows an em-dash rather than a guess, and a whole week with no scored
    /// day returns nil so the section hides.
    func weekDigest() -> LedgerTrendsWeek? {
        let cal = Calendar.current
        guard let weekAgo = cal.date(byAdding: .day, value: -6, to: Date()),
              let twoWeeksAgo = cal.date(byAdding: .day, value: -13, to: Date()) else { return nil }
        let thisKey = Repository.localDayKey(weekAgo)
        let priorKey = Repository.localDayKey(twoWeeksAgo)

        let thisWeek = repo.days.filter { $0.day >= thisKey }
        let lastWeek = repo.days.filter { $0.day >= priorKey && $0.day < thisKey }
        guard !thisWeek.isEmpty else { return nil }

        func mean(_ rows: [DailyMetric], _ value: (DailyMetric) -> Double?) -> Double? {
            let vals = rows.compactMap(value)
            guard !vals.isEmpty else { return nil }
            return vals.reduce(0, +) / Double(vals.count)
        }

        /// A cell: this week's value, delta vs last as the tinted suffix line's replacement —
        /// `LedgerStatStrip.Item` has one value + label, so the delta rides the value's tint.
        func item(_ current: Double?, _ prior: Double?, label: String,
                  format: (Double) -> String, higherIsBetter: Bool?) -> LedgerStatStrip.Item {
            guard let current else {
                return .init(value: "\u{2014}", label: label, tint: Ledger.textTertiary)
            }
            var tint = Ledger.textPrimary
            if let prior, let better = higherIsBetter, abs(current - prior) > 0.05 {
                tint = ((current > prior) == better) ? Ledger.accentRecovery : Ledger.accentCaution
            }
            return .init(value: format(current), label: label, tint: tint)
        }

        let recovery = item(mean(thisWeek, { $0.recovery }), mean(lastWeek, { $0.recovery }),
                            label: String(localized: "avg charge"),
                            format: { "\(Int($0.rounded()))" }, higherIsBetter: true)
        let sleep = item(mean(thisWeek, { sleepPerfByDay[$0.day] }),
                         mean(lastWeek, { sleepPerfByDay[$0.day] }),
                         label: String(localized: "avg sleep"),
                         format: { "\(Int($0.rounded()))" }, higherIsBetter: true)
        // Total Effort has no valence week-over-week (a rest week is not "worse") — neutral tint.
        // Summed on the DISPLAY scale per day, because the stored→display mapping is not linear:
        // converting a sum of stored values would print a number that is no day's arithmetic.
        let strains = thisWeek.compactMap { $0.strain }
        let strainSum = strains.map { UnitFormatter.effortValue($0, scale: effortScale) }.reduce(0, +)
        let strain = LedgerStatStrip.Item(
            value: strains.isEmpty ? "\u{2014}" : String(format: "%.1f", strainSum),
            label: String(localized: "total effort"),
            tint: strains.isEmpty ? Ledger.textTertiary : Ledger.textPrimary)

        return LedgerTrendsWeek(items: [recovery, sleep, strain])
    }

    func meaningfulChange(hrv: Resolved, hrvDelta: Double?,
                          hrvShift: Shift?, hrvShiftDate: String?,
                          rhr: Resolved, rhrDelta: Double?,
                          rhrShift: Shift?, rhrShiftDate: String?,
                          strainElevated: Bool) -> String {
        var parts: [String] = []

        if let d = hrvDelta, abs(d) > 0.0001 {
            let magnitude = Int(abs(d).rounded())
            if magnitude > 0 {
                parts.append(d > 0
                    ? String(localized: "HRV is up \(magnitude) ms over \(hrv.effective.longName).")
                    : String(localized: "HRV is down \(magnitude) ms over \(hrv.effective.longName)."))
                // Date the level shift the chart rings, when one was found (see `shift`).
                if let shift = hrvShift, let date = hrvShiftDate {
                    parts.append(shift.delta > 0
                        ? String(localized: "Most of that stepped up around \(date) — the ringed point.")
                        : String(localized: "Most of that stepped down around \(date) — the ringed point."))
                }
            }
        }

        if let d = rhrDelta, abs(d) > 0.0001 {
            let magnitude = Int(abs(d).rounded())
            if magnitude > 0 {
                parts.append(d < 0
                    ? String(localized: "Resting HR fell \(magnitude) bpm over the same window.")
                    : String(localized: "Resting HR rose \(magnitude) bpm over the same window."))
                if let shift = rhrShift, let date = rhrShiftDate {
                    parts.append(shift.delta > 0
                        ? String(localized: "Its level stepped up around \(date).")
                        : String(localized: "Its level stepped down around \(date)."))
                }
            }
        }

        if strainElevated {
            parts.append(String(localized: "Day strain is running above your normal for this window."))
        }

        return parts.joined(separator: " ")
    }
}

// MARK: - Preview

#if DEBUG
@MainActor
private func ledgerTrendsPreviewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    let cal = Calendar(identifier: .gregorian)
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(identifier: "UTC")
    fmt.dateFormat = "yyyy-MM-dd"
    let today = Date()
    var seeded: [DailyMetric] = []
    let span = 365
    for i in stride(from: span - 1, through: 0, by: -1) {
        guard let d = cal.date(byAdding: .day, value: -i, to: today) else { continue }
        let phase = Double(span - 1 - i)
        let rec = 55 + 28 * sin(phase / 11.0) + Double((Int(phase) * 31) % 17) - 8
        let hrv = 58 + 16 * sin(phase / 9.0) + Double((Int(phase) * 13) % 11) - 5
        let rhr = 52 + 4 * sin(phase / 7.0) + Double((Int(phase) * 7) % 5) - 2
        let strain = 45 + 26 * sin(phase / 5.0 + 1.2) + Double((Int(phase) * 5) % 9) - 4
        let gap = Int(phase) % 23 == 0
        seeded.append(DailyMetric(
            day: fmt.string(from: d),
            totalSleepMin: 420, efficiency: 0.9, deepMin: 90, remMin: 110, lightMin: 200,
            disturbances: 6, restingHr: gap ? nil : Int(rhr.rounded()),
            avgHrv: gap ? nil : max(15, hrv), recovery: gap ? nil : max(2, min(99, rec)),
            strain: gap ? nil : max(0, min(100, strain)), exerciseCount: 1
        ))
    }
    repo.days = seeded
    repo.loaded = true
    return repo
}

#Preview("Ledger Trends") {
    LedgerTrendsView()
        .environmentObject(ledgerTrendsPreviewRepo())
        .frame(width: 393, height: 852)
        .preferredColorScheme(.dark)
}
#endif
