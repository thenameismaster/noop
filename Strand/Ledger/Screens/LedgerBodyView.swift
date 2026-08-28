import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - LedgerBodyView
//
// Spec §"03 · Body (Recovery)" of the Athlete's Ledger handoff, board `data-screen-label="Body"`.
// The five numbered items, in the spec's order:
//
//   1. Header — overline "RECOVERY", title "Body", right: 56pt recovery mini-ring with score.
//   2. Verdict sentence (2 lines, secondary).
//   3. VITALS ledger (5 rows) — HRV, Resting HR, Respiratory, Skin temp, SpO₂. Each: label + sub
//      (100pt col) · 30-day sparkline (1.7pt stroke; mint when above baseline, gray otherwise) ·
//      value + delta. SpO₂ renders only when the experimental toggle is on. Each row pushes its
//      metric detail.
//   4. RECOVERY · 7 DAYS — 7 bars coloured by recovery band, past at ~45–50%, today solid + bold.
//   5. WATCHING note — caution left-rule block fed by the existing illness/early-warning state,
//      rendering nothing when quiet.
//
// PRESENTATION ONLY. Every number here is a value NOOP already computes:
//
//   · the five vitals, their formats, units, banding verdicts and provenance come out of
//     `BodyVitalSigns.readings(sourceRows:temperatureUnit:now:spo2CandidateByDay:hrvOverCountByDay:)`
//     — the same pure call `HealthView`'s vitals grid and `AuroraBodyView` make, unchanged;
//   · the personal baseline behind each delta is `Baselines.foldHistory` + `Baselines.deviation`
//     over the SAME calendar-padded history `VitalBands.band` z-tests against, with the SAME
//     per-metric configs, so a delta can never contradict the row's own in/out-of-range verdict;
//   · the 7-day strip reads `DailyMetric.recovery` off `Repository.week`;
//   · the WATCHING note reads `AppModel.illnessSignal`, which the analytics pass publishes.
//
// Nothing is re-derived, re-scored or invented. Where a value genuinely does not exist the row
// draws its designed empty state (an em-dash, a dashed spark, an empty bar slot) rather than a
// number.
//
// PERF (spec §State Management, and the conventions the source documents):
//   · The screen NEVER observes `AppModel` / `LiveState` at its root — a connected strap publishes
//     live HR at ~1 Hz and observing here would re-diff the whole vitals ledger every second. The
//     one place `AppModel` is read is the `LedgerBodyWatchingNote` leaf, exactly as
//     `HealthAlertBanner` isolates it today.
//   · Every O(days) scan — source-precedence resolution, baseline folds, the week pad — runs ONCE
//     in `load()` behind a `.task(id:)` keyed on the inputs, and the result is cached in a `@State`
//     model. `body` only reads the built model.

/// The Ledger's Body (Recovery) screen: recovery ring + verdict → vitals ledger → 7-day recovery →
/// watching note. Absorbs the old Health Monitor / Stress surfaces per spec §05.
@MainActor
struct LedgerBodyView: View {

    // MARK: Environment
    //
    // The same environment contract the classic Body surface declares: `HealthView`'s vitals section
    // binds `repo` alone, and reads the temperature preference from `@AppStorage`. `AppModel` is
    // deliberately NOT declared here — see the perf note above.

    @EnvironmentObject var repo: Repository

    /// Temperature display preference (D#103). Skin temp is stored in °C — absolute or a ±deviation
    /// — and the toggle re-labels it. Display-only: banding still runs on the stored °C value,
    /// exactly as in `HealthView`. Keys byte-identical to `UnitPrefs`.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""

    /// The re-tap-the-active-tab signal (#135/#198). The shell bumps it; the screen scrolls to top.
    @Environment(\.scrollToTopSignal) private var scrollToTopSignal

    // MARK: State

    /// Everything the screen draws, built once per input change in `load()`.
    @State private var model = LedgerBodyModel.empty

    /// #103/queue-11a — SpO₂ candidate nightly means, loaded only when the experimental toggle is on.
    /// Loaded verbatim the way `HealthView` loads it; this screen never writes.
    @State private var spo2CandidateByDay: [String: Double] = [:]
    /// #1118 — per-night HRV R-R over-count flags, so an over-counted night is captioned "unverified"
    /// rather than presented as a clean reading.
    @State private var hrvOverCountByDay: [String: Double] = [:]

    /// The CAPACITY rows — the slow-moving 90-day figures (Fitness Age, Vitality, Body Age,
    /// estimated VO₂ Max) the daily vitals ledger has no room for. Empty hides the section.
    @State private var capacity: [LedgerCapacityRow] = []

    /// Whether `loadCapacity()` has run. Gates the section so the pre-load frames show nothing at
    /// all rather than flashing the "not computed yet" copy before the rows arrive.
    @State private var capacityLoaded = false

    // MARK: Board constants
    //
    // Every number below appears literally in the `data-screen-label="Body"` board.

    /// `margin:14px 24px 0` on the verdict sentence.
    private static let verdictTopGap: CGFloat = 14
    /// `margin:18px 24px 0` above the vitals ledger's top hairline.
    private static let vitalsTopGap: CGFloat = 18
    /// `padding:14px 0 2px` on the vitals section's overline row.
    private static let sectionOverlineTop: CGFloat = 14
    private static let sectionOverlineBottom: CGFloat = 2
    /// `font-size:11.5px` on the "30-day spark" trailing caption.
    private static let sparkCaptionSize: CGFloat = 11.5
    /// `margin:16px 24px 0` above the recovery-week and the watching blocks.
    private static let blockTopGap: CGFloat = 16
    /// `padding-top:14px` under the recovery-week hairline.
    private static let weekRuleGap: CGFloat = 14
    /// `margin-top:12px` between the overline and the bars.
    private static let weekBarsTop: CGFloat = 12
    /// `gap:8px` between the seven bar columns.
    private static let weekBarGap: CGFloat = 8
    /// `height:60px` — the bar column the fill grows inside.
    private static let weekBarColumnHeight: CGFloat = 60
    /// `margin-top:6px` between a bar and its weekday label.
    private static let weekLabelGap: CGFloat = 6
    /// `font-size:10px` on the weekday labels.
    private static let weekLabelSize: CGFloat = 10
    /// `margin:16px 24px 22px` — the watching block's bottom gutter.
    private static let pageBottomGap: CGFloat = 22
    /// The board's `opacity:.5` on a past caution/low bar (`opacity:.45` on a past mint one lives in
    /// `Ledger.pastRecoveryBarOpacity`).
    private static let pastNonMintBarOpacity: Double = 0.5

    /// The sparkline window, in days. Spec §03 item 3: "30-day sparkline".
    private static let sparkDays = 30
    /// The recovery strip's width, in days. Spec §03 item 4: "RECOVERY · 7 DAYS".
    private static let weekDays = 7

    /// Scroll-to-top anchor id.
    private static let topAnchor = "ledger.body.top"

    // MARK: Section copy
    //
    // The overlines are `String(localized:)` VALUES rather than bare `Text("…")` literals — the same
    // shape `LedgerHeader(overline:)` and `LedgerCoachNote(title:)` already take, so every piece of
    // Ledger section copy is one kind of thing and the extraction path is identical for all of it.

    /// The vitals ledger's overline. Board: `VITALS · LAST NIGHT` (uppercased by `ledgerOverline()`).
    private static var vitalsOverline: String { String(localized: "Vitals \u{00B7} Last night") }
    /// The vitals ledger's trailing caption. Board: `30-day spark`, `font-size:11.5px`.
    private static var sparkCaption: String { String(localized: "30-day spark") }
    /// The recovery strip's overline. Board: `RECOVERY \u{00B7} 7 DAYS`.
    private static var weekOverline: String { String(localized: "Recovery \u{00B7} 7 days") }

    // MARK: Derived

    private var temperatureUnit: TemperatureUnit {
        let system = UnitSystem(rawValue: unitSystemRaw) ?? .metric
        return UnitPrefs.resolveTemperature(system: system, override: temperatureRaw)
    }

    /// The `.task(id:)` key. Every component is O(1) to read, so this costs nothing in `body` — it
    /// exists purely so a refresh, an import, a unit flip or the SpO₂ toggle rebuilds the model.
    private var inputs: LedgerBodyInputs {
        LedgerBodyInputs(
            dayCount: repo.days.count,
            lastDay: repo.days.last?.day,
            vitalRowCount: repo.vitalRows.count,
            spo2Toggle: PuffinExperiment.spo2CandidateDisplayEnabled,
            unitSystemRaw: unitSystemRaw,
            temperatureRaw: temperatureRaw
        )
    }

    // MARK: - Body

    var body: some View {
        #if os(iOS)
        content.refreshable { await repo.refresh() }
        #else
        content
        #endif
    }

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    Color.clear
                        .frame(height: 0)
                        .id(Self.topAnchor)

                    header                       // 1
                    verdict                      // 2
                    vitalsLedger                 // 3
                    recoveryWeek                 // 4
                    capacitySection              // 4b — hidden until any 90-day figure exists

                    // 5 — renders NOTHING when the illness watch is quiet, and takes no space with
                    // it: the block's own 16pt top gap lives inside the note, so a quiet screen ends
                    // on the recovery strip rather than on 16pt of dead air.
                    LedgerBodyWatchingNote(topGap: Self.blockTopGap)
                }
                .padding(.bottom, Self.pageBottomGap)
                .padding(.horizontal, Ledger.pageMargin)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChangeCompat(of: scrollToTopSignal) { _ in
                // #135/#198: re-tapping the active tab scrolls this root to the top. The pop-to-root
                // half is the shell's `NavigationPath`; this is the scroll half.
                withAnimation(LedgerMotion.tabCrossfade) { proxy.scrollTo(Self.topAnchor, anchor: .top) }
            }
        }
        .background(Ledger.bgScreen.ignoresSafeArea())
        .task(id: inputs) { await load() }
    }

    // MARK: - 1. Header
    //
    // Board: `padding:22px 24px 0`, `align-items:flex-end`; overline "RECOVERY" 11/600/+2.6,
    // title "Body" Space Grotesk 27/700/−0.5, and a 56pt `<svg>` ring (r=24, stroke-width=5,
    // dasharray "112 151", rotate(-90)) with a 16/700 numeral at its centre.
    //
    // Tap map: "Body · recovery ring + 7-day bars → TabRoute.metric(\"recovery\")".

    private var header: some View {
        LedgerHeader(overline: String(localized: "Recovery"),
                     title: String(localized: "Body"),
                     alignment: .bottom) {
            NavigationLink(value: TabRoute.metric("recovery")) {
                LedgerScoreArc(score: model.recovery, style: .mini)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 2. Verdict sentence
    //
    // Board: `margin:14px 24px 0; font-size:13.5px; line-height:1.55; color:#9BA3B0`.
    //
    // Deterministic, from the banding verdicts the pipeline already returned for the rows this
    // screen is showing — a count, never a claimed pattern.

    @ViewBuilder
    private var verdict: some View {
        if !model.verdict.isEmpty {
            Text(model.verdict)
                .ledgerBody()
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Self.verdictTopGap)
        }
    }

    // MARK: - 3. VITALS ledger
    //
    // Board: `margin:18px 24px 0; border-top:1px solid rgba(255,255,255,.07)`, then a
    // `padding:14px 0 2px` row carrying the "VITALS · LAST NIGHT" overline and a `font-size:11.5px`
    // "30-day spark" caption, then five `LedgerSparkRow`s (the last without its divider).
    //
    // Tap map: "Body · vitals ledger rows → TabRoute.metricSourced(key:source:)".

    private var vitalsLedger: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Ledger.hairline)
                .frame(height: Ledger.hairlineWidth)

            HStack {
                Text(Self.vitalsOverline).ledgerOverline()
                Spacer(minLength: Ledger.rowGap)
                Text(Self.sparkCaption)
                    .font(LedgerType.label(Self.sparkCaptionSize, LedgerType.regular))
                    .foregroundStyle(Ledger.textTertiary)
            }
            .padding(.top, Self.sectionOverlineTop)
            .padding(.bottom, Self.sectionOverlineBottom)

            ForEach(model.vitals) { row in
                NavigationLink(value: TabRoute.metricSourced(key: row.key, source: row.source)) {
                    LedgerSparkRow(
                        label: row.label,
                        sublabel: row.sublabel,
                        points: row.points,
                        isAboveBaseline: row.isAboveBaseline,
                        value: row.value,
                        unit: row.unit,
                        delta: row.delta,
                        deltaTint: row.deltaTint,
                        showsDivider: row.id != model.vitals.last?.id
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, Self.vitalsTopGap)
    }

    // MARK: - 4. RECOVERY · 7 DAYS
    //
    // Board: `margin:16px 24px 0; border-top:1px solid rgba(255,255,255,.07); padding-top:14px`,
    // the "RECOVERY · 7 DAYS" overline, then `display:flex; gap:8px; margin-top:12px` of seven
    // `flex:1` columns. Each column: a `height:60px` bottom-aligned box holding a `border-radius:5px`
    // fill whose height IS the recovery score as a percentage, then a `margin-top:6px`,
    // `font-size:10px` weekday label — tertiary on past days, `#F2F4F7` 700 on today.
    //
    // Tap map: "Body · recovery ring + 7-day bars → TabRoute.metric(\"recovery\")".

    private var recoveryWeek: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Ledger.hairline)
                .frame(height: Ledger.hairlineWidth)

            NavigationLink(value: TabRoute.metric("recovery")) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Self.weekOverline).ledgerOverline()
                        .padding(.top, Self.weekRuleGap)

                    LedgerDrawIn(.chart) { progress in
                        HStack(alignment: .bottom, spacing: Self.weekBarGap) {
                            ForEach(model.week) { bar in
                                recoveryBarColumn(bar, progress: progress)
                            }
                        }
                    }
                    .padding(.top, Self.weekBarsTop)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, Self.blockTopGap)
    }

    @ViewBuilder
    private func recoveryBarColumn(_ bar: LedgerRecoveryBar, progress: Double) -> some View {
        VStack(spacing: 0) {
            // The 60pt column. A day with no score leaves it empty — the strip never invents a bar.
            ZStack(alignment: .bottom) {
                Color.clear
                if let score = bar.score {
                    RoundedRectangle(cornerRadius: Ledger.barRadius, style: .continuous)
                        .fill(Ledger.recoveryAccent(score).opacity(bar.isToday ? 1 : pastOpacity(score)))
                        .frame(height: Self.weekBarColumnHeight
                               * CGFloat(min(1, max(0, score / 100)))
                               * CGFloat(progress))
                }
            }
            .frame(height: Self.weekBarColumnHeight)

            Text(bar.label)
                .font(LedgerType.label(Self.weekLabelSize,
                                       bar.isToday ? LedgerType.bold : LedgerType.regular))
                .foregroundStyle(bar.isToday ? Ledger.textPrimary : Ledger.textTertiary)
                .lineLimit(1)
                .padding(.top, Self.weekLabelGap)
        }
        .frame(maxWidth: .infinity)
    }

    /// A past bar's opacity. The board draws `.45` behind a mint bar and `.5` behind a caution/low
    /// one — the spec's "past at ~45–50% opacity" written out per band.
    private func pastOpacity(_ score: Double) -> Double {
        switch LedgerRecoveryBand.band(for: score) {
        case .primed, .peak: return Ledger.pastRecoveryBarOpacity
        case .depleted, .low, .moderate: return Self.pastNonMintBarOpacity
        }
    }

    // MARK: - 4b. CAPACITY · 90 DAYS
    //
    // The long-horizon complement to the nightly vitals: the modelled figures that move over weeks,
    // not nights, in the vitals ledger's own row idiom (LedgerSparkRow + metricSourced push). Renders
    // nothing while no capacity metric holds data, so the screen is unchanged for a fresh install.

    /// The section's overline.
    private static var capacityOverline: String { String(localized: "Capacity \u{00B7} 90 days") }
    /// The trailing caption, mirroring the vitals ledger's "30-day spark".
    private static var capacitySparkCaption: String { String(localized: "90-day spark") }
    /// The capacity sparkline window, in days.
    private static let capacityDays = 90

    @ViewBuilder
    private var capacitySection: some View {
        // Rendered even with nothing to show, unlike the WATCHING note above: a quiet illness watch
        // MEANS "nothing is wrong", but an absent capacity figure means "not computed yet", and
        // silently omitting the section left no way to tell that from a missing feature. The empty
        // state states the two real gates (see `loadCapacity`).
        if capacityLoaded {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle()
                    .fill(Ledger.hairline)
                    .frame(height: Ledger.hairlineWidth)

                HStack {
                    Text(Self.capacityOverline).ledgerOverline()
                    Spacer(minLength: Ledger.rowGap)
                    if !capacity.isEmpty {
                        Text(Self.capacitySparkCaption)
                            .font(LedgerType.label(Self.sparkCaptionSize, LedgerType.regular))
                            .foregroundStyle(Ledger.textTertiary)
                    }
                }
                .padding(.top, Self.sectionOverlineTop)
                .padding(.bottom, Self.sectionOverlineBottom)

                if capacity.isEmpty {
                    // The two conditions the weekly pass actually gates on — stated, not guessed.
                    Text(String(localized: "These are scored once a week, so the first figures land after a full week of wear. Fitness Age also needs your age, sex, height and weight in Profile."))
                        .ledgerCaptionStyle(11)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ForEach(capacity) { row in
                    NavigationLink(value: TabRoute.metricSourced(key: row.key, source: row.source)) {
                        LedgerSparkRow(
                            label: row.label,
                            sublabel: row.sublabel,
                            points: row.points,
                            isAboveBaseline: row.isImproving,
                            value: row.value,
                            unit: row.unit,
                            delta: row.delta,
                            deltaTint: row.deltaTint,
                            showsDivider: row.id != capacity.last?.id
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, Self.blockTopGap)
        }
    }

    /// Loads the capacity rows. Each metric is fetched through the SAME `exploreSeries` path its
    /// detail screen reads, over the section's 90-day window; a metric with no stored points (a
    /// fresh install, or an experimental figure that is off) contributes no row.
    private func loadCapacity() async {
        var out: [LedgerCapacityRow] = []
        for spec in LedgerCapacityRow.catalog {
            let pts = await repo.exploreSeries(key: spec.key,
                                               source: Repository.whoopSource,
                                               days: Self.capacityDays)
            guard let row = LedgerCapacityRow.build(spec: spec,
                                                    points: pts.map(\.value)) else { continue }
            out.append(row)
        }
        capacity = out
        capacityLoaded = true
    }

    // MARK: - Load
    //
    // Every scan lives here, never in `body`.

    private func load() async {
        // #1118 — always loaded (no toggle): the per-night HRV R-R over-count flags.
        // #103/queue-11a — the SpO₂ candidate nightly means, only when the toggle is ON.
        // Loaded exactly the way `HealthView`'s vitals section loads them.
        let ocPts = await repo.exploreSeries(key: "hrv_rr_overcount",
                                            source: Repository.whoopSource,
                                            days: Self.sparkDays)
        hrvOverCountByDay = Dictionary(ocPts.map { ($0.day, $0.value) }, uniquingKeysWith: { a, _ in a })

        if PuffinExperiment.spo2CandidateDisplayEnabled {
            let pts = await repo.exploreSeries(key: "spo2_candidate",
                                               source: Repository.whoopSource,
                                               days: Self.sparkDays)
            spo2CandidateByDay = Dictionary(pts.map { ($0.day, $0.value) }, uniquingKeysWith: { a, _ in a })
        } else {
            spo2CandidateByDay = [:]
        }

        model = LedgerBodyModel.build(
            rows: repo.vitalMetricRows,
            week: repo.week,
            todayRecovery: repo.today?.recovery,
            temperatureUnit: temperatureUnit,
            spo2CandidateByDay: spo2CandidateByDay,
            hrvOverCountByDay: hrvOverCountByDay
        )

        await loadCapacity()
    }
}

// MARK: - Task key

/// The cheap, O(1) fingerprint of everything `load()` reads. A change here — a refresh, an import,
/// a unit flip, the SpO₂ toggle — rebuilds the model; nothing else does.
private struct LedgerBodyInputs: Equatable {
    let dayCount: Int
    let lastDay: String?
    let vitalRowCount: Int
    let spo2Toggle: Bool
    let unitSystemRaw: String
    let temperatureRaw: String
}

// MARK: - Model

/// One vitals-ledger row, fully resolved and pre-formatted. Presentation only.
private struct LedgerVitalRow: Identifiable {
    /// The `MetricCatalog` key the row taps through to.
    let key: String
    /// The catalog source, pinned so `MetricCatalog.metric(key:source:)` resolves exactly one entry
    /// (a bare key can exist under several sources — see `TabRoute.metricSourced`).
    let source: String
    let label: String
    let sublabel: String
    /// Oldest → newest, the 30-day window.
    let points: [Double]
    /// Spec §03 item 3, verbatim: "mint when above baseline, gray otherwise".
    let isAboveBaseline: Bool
    let value: String?
    let unit: String
    let delta: String?
    let deltaTint: Color
    /// The pipeline's own verdict, kept so the verdict sentence counts the same rows the screen shows.
    let band: VitalBands.Band

    var id: String { key }
}

/// One CAPACITY row, fully resolved and pre-formatted. Presentation only — every number is a stored
/// `exploreSeries` value; the only arithmetic is last-minus-first over the shown window.
private struct LedgerCapacityRow: Identifiable {
    /// What a capacity metric IS, declared once: key, copy, formatting, and which direction is good.
    struct Spec {
        let key: String
        let label: String
        let sublabel: String
        let unit: String?
        let decimals: Int
        let higherIsBetter: Bool
        /// Below this, a window delta reads as flat and tints tertiary (half a display step).
        var flatEpsilon: Double { decimals == 0 ? 0.5 : 0.05 }
    }

    /// The four long-horizon figures, in the order shown. Copy states WHAT each number is; the
    /// catalog's own titles, no new claims.
    static let catalog: [Spec] = [
        Spec(key: "fitness_age", label: String(localized: "Fitness Age"),
             sublabel: String(localized: "modelled, years"), unit: String(localized: "yrs"),
             decimals: 0, higherIsBetter: false),
        Spec(key: "vitality", label: String(localized: "Vitality"),
             sublabel: String(localized: "0\u{2013}100 composite"), unit: nil,
             decimals: 0, higherIsBetter: true),
        Spec(key: "body_age", label: String(localized: "Body Age"),
             sublabel: String(localized: "modelled, years"), unit: String(localized: "yrs"),
             decimals: 0, higherIsBetter: false),
        Spec(key: "vo2max_est", label: String(localized: "VO\u{2082} Max"),
             sublabel: String(localized: "estimated"), unit: nil,
             decimals: 1, higherIsBetter: true),
    ]

    let key: String
    let source: String
    let label: String
    let sublabel: String
    /// Oldest → newest, the 90-day window.
    let points: [Double]
    /// Colours the sparkline mint — here, "moving in the good direction over the window".
    let isImproving: Bool
    let value: String?
    let unit: String?
    let delta: String?
    let deltaTint: Color

    var id: String { key }

    /// `nil` only when the window holds NO reading at all.
    ///
    /// A SINGLE reading still earns a row. These four are written once a week (on the week's
    /// Saturday key, by the weekly `IntelligenceEngine` pass), and each recompute writes only the
    /// current week's point — so a recent install legitimately holds exactly one. Requiring two
    /// hid every row, and with it the whole section, for precisely the people who had just started
    /// building this history. With one point there is no spark and no window delta, so the row says
    /// "first reading" rather than inventing a trend.
    @MainActor
    static func build(spec: Spec, points: [Double]) -> LedgerCapacityRow? {
        guard let last = points.last, let first = points.first else { return nil }

        let format: (Double) -> String = spec.decimals == 0
            ? { "\(Int($0.rounded()))" }
            : { String(format: "%.1f", $0) }

        guard points.count >= 2 else {
            return LedgerCapacityRow(
                key: spec.key, source: Repository.whoopSource,
                label: spec.label, sublabel: spec.sublabel,
                points: points, isImproving: false,
                value: format(last), unit: spec.unit,
                delta: String(localized: "first reading"), deltaTint: Ledger.textTertiary)
        }

        let change = last - first
        let isFlat = abs(change) < spec.flatEpsilon
        let improving = !isFlat && ((change > 0) == spec.higherIsBetter)

        let magnitude = String(format: "%.\(spec.decimals)f", abs(change))
        let signed = change < 0 ? "\u{2212}\(magnitude)" : "+\(magnitude)"
        let deltaText = isFlat
            ? String(localized: "steady / 90d")
            : String(localized: "\(signed) / 90d")

        return LedgerCapacityRow(
            key: spec.key,
            source: Repository.whoopSource,
            label: spec.label,
            sublabel: spec.sublabel,
            points: points,
            isImproving: improving,
            value: format(last),
            unit: spec.unit,
            delta: deltaText,
            deltaTint: isFlat ? Ledger.textTertiary
                              : (improving ? Ledger.accentRecovery : Ledger.accentCaution)
        )
    }
}

/// One column of the 7-day recovery strip.
private struct LedgerRecoveryBar: Identifiable {
    /// `yyyy-MM-dd`.
    let id: String
    /// The two-letter weekday, locale-aware.
    let label: String
    /// `DailyMetric.recovery`, 0–100. `nil` leaves the column empty.
    let score: Double?
    let isToday: Bool
}

/// Everything `LedgerBodyView` draws. Built once per input change, off `body`.
///
/// `@MainActor` because the build reads main-actor-isolated statics (`Repository.whoopSource`,
/// `Repository.logicalDayKey`, `PuffinExperiment.spo2CandidateDisplayEnabled`) — and because the
/// only caller is `load()`, which is already on the main actor. Nothing here escapes it.
@MainActor
private struct LedgerBodyModel {
    var recovery: Double?
    var verdict: String
    var vitals: [LedgerVitalRow]
    var week: [LedgerRecoveryBar]

    /// The pre-`load()` state. The verdict is deliberately BLANK rather than the "nothing measured"
    /// sentence: for the frame or two before `load()` returns, the screen knows nothing about the
    /// night, and asserting that nothing was measured would be a claim it has not earned.
    static let empty = LedgerBodyModel(recovery: nil, verdict: "", vitals: [], week: [])

    // MARK: Build

    static func build(rows: [SourcedDailyMetric],
                      week: [DailyMetric],
                      todayRecovery: Double?,
                      temperatureUnit: TemperatureUnit,
                      spo2CandidateByDay: [String: Double],
                      hrvOverCountByDay: [String: Double]) -> LedgerBodyModel {

        // The authoritative readings — the same pure call `HealthView` makes.
        let readings = BodyVitalSigns.readings(
            sourceRows: rows,
            temperatureUnit: temperatureUnit,
            spo2CandidateByDay: spo2CandidateByDay,
            hrvOverCountByDay: hrvOverCountByDay
        )
        var byKey: [String: BodyVitalReading] = [:]
        for r in readings { byKey[r.key] = r }

        var out: [LedgerVitalRow] = []

        // --- HRV --------------------------------------------------------------------
        if let r = byKey["hrv"] {
            let pts = series(rows, key: "hrv") { $0.avgHrv }
            out.append(row(
                reading: r,
                catalogKey: "hrv",
                label: String(localized: "HRV"),
                // #1118: when the night's in-sleep R-R was over-counted the row says so, using the
                // pipeline's own caveat string rather than presenting a clean-looking number.
                sublabel: r.caveat ?? String(localized: "rMSSD, sleep"),
                points: pts,
                cfg: Baselines.hrvCfg,
                higherIsBetter: true
            ))
        }

        // --- Resting HR -------------------------------------------------------------
        if let r = byKey["rhr"] {
            let pts = series(rows, key: "rhr") { $0.restingHr.map(Double.init) }
            out.append(row(
                reading: r,
                catalogKey: "rhr",
                label: String(localized: "Resting HR"),
                sublabel: String(localized: "lowest 5-min"),
                points: pts,
                cfg: Baselines.restingHRCfg,
                higherIsBetter: false
            ))
        }

        // --- Respiratory ------------------------------------------------------------
        if let r = byKey["resp"] {
            let pts = series(rows, key: "resp") { $0.respRateBpm }
            out.append(row(
                reading: r,
                catalogKey: "resp_rate",
                label: String(localized: "Respiratory"),
                sublabel: String(localized: "breaths / min"),
                points: pts,
                cfg: Baselines.respCfg,
                higherIsBetter: false
            ))
        }

        // --- Skin temp --------------------------------------------------------------
        if let r = byKey["skin"] {
            // The stored column is bimodal — imports write an absolute wrist °C, the on-device
            // pipeline a ±°C deviation — so the series is partitioned to the KIND the row is showing
            // before anything is folded or drawn (#1636 / #622).
            let absolute = r.value.map(VitalBands.isAbsoluteSkinTemp) ?? true
            let raw = series(rows, key: "skin") { $0.skinTempC ?? $0.skinTempDevC }
            let pts = raw.filter { VitalBands.isAbsoluteSkinTemp($0.value) == absolute }
            out.append(row(
                reading: r,
                catalogKey: "skin_temp",
                label: String(localized: "Skin temp"),
                sublabel: absolute ? String(localized: "absolute") : String(localized: "deviation"),
                points: pts,
                cfg: absolute ? Baselines.metricCfg["skin_temp"]! : VitalBands.skinTempDeviationCfg,
                higherIsBetter: false,
                // A ±deviation IS already "vs baseline" — a "+9% vs base" beside it would just repeat
                // the number back at the reader, and a ratio against a near-zero baseline is noise.
                suppressPercentDelta: !absolute
            ))
        }

        // --- SpO₂ -------------------------------------------------------------------
        // Spec §03 item 3, verbatim: "SpO₂ row renders only when the experimental toggle is on."
        if PuffinExperiment.spo2CandidateDisplayEnabled, let r = byKey["spo2"] {
            let calibrated = series(rows, key: "spo2") { $0.spo2Pct }
            let candidate: [LedgerBodyPoint] = spo2CandidateByDay
                .map { LedgerBodyPoint(day: $0.key, value: $0.value) }
                .sorted { $0.day < $1.day }
            // The reading falls back to the (unverified) candidate mean when no calibrated percentage
            // exists; the trail must follow the value it is drawn under. Same test `AuroraBodyView`
            // uses, which mirrors `BodyVitalSigns`' own `spo2IsCandidate`.
            let usingCandidate = calibrated.last(where: { $0.day == r.day }) == nil && r.value != nil
            out.append(row(
                reading: r,
                catalogKey: "spo2",
                label: String(localized: "SpO₂"),
                sublabel: usingCandidate
                    ? String(localized: "strap estimate (unverified)")
                    : String(localized: "overnight mean"),
                points: usingCandidate ? candidate : calibrated,
                // Population-only by design — there is no SpO₂ `MetricCfg`, and an absolute floor is
                // meaningful regardless of personal history.
                cfg: nil,
                higherIsBetter: true
            ))
        }

        return LedgerBodyModel(
            recovery: todayRecovery,
            verdict: verdictText(measured: out.filter { $0.band != .noData }.count,
                                 offRange: out.filter { $0.band == .outOfRange }.count),
            vitals: out,
            week: weekBars(week)
        )
    }

    // MARK: One row

    private static func row(reading: BodyVitalReading,
                            catalogKey: String,
                            label: String,
                            sublabel: String,
                            points: [LedgerBodyPoint],
                            cfg: MetricCfg?,
                            higherIsBetter: Bool,
                            suppressPercentDelta: Bool = false) -> LedgerVitalRow {
        // History EXCLUDING the displayed night, calendar-padded so wear gaps are visible to the
        // staleness logic — the identical construction `BodyVitalSigns` hands to `VitalBands.band`,
        // so the baseline read here is the baseline the verdict was made against.
        let readingDay = reading.day
        let prior: [(day: String, value: Double?)] = points
            .filter { p in
                guard let readingDay else { return true }
                return p.day < readingDay
            }
            .map { ($0.day, Optional($0.value)) }
        let history = VitalBands.calendarSeries(prior)
        let state: BaselineState? = cfg.map { Baselines.foldHistory(history, cfg: $0) }

        // The delta line. Three honest forms, and they are exactly the board's three:
        //   · a usable personal baseline and a notable deviation → "+9% vs base", tinted by whether
        //     the move is in the metric's good direction (`accent/recovery` = "positive deltas",
        //     `accent/caution` = "negative-ish", per the token table);
        //   · a usable personal baseline and |z| ≤ 1              → "on baseline", tertiary;
        //   · no usable personal baseline                          → the pipeline's own verdict,
        //     "in range" / "outside range", which is what the population fallback actually judged.
        var delta: String?
        var deltaTint = Ledger.textTertiary
        if !suppressPercentDelta, let value = reading.value, let state, state.usable {
            let dev = Baselines.deviation(value, state: state)
            if dev.inNormalRange {
                delta = String(localized: "on baseline")
            } else {
                let percent = dev.ratio * 100
                let sign = percent >= 0 ? "+" : "\u{2212}"
                let magnitude = String(format: "%@%.0f%%", sign, abs(percent))
                delta = String(localized: "\(magnitude) vs base")
                let good = higherIsBetter ? percent > 0 : percent < 0
                deltaTint = good ? Ledger.accentRecovery : Ledger.accentCaution
            }
        } else {
            switch reading.banding.band {
            case .inRange:
                delta = String(localized: "in range")
            case .outOfRange:
                delta = String(localized: "outside range")
                deltaTint = Ledger.accentCaution
            case .noData:
                delta = nil
            }
        }

        // Spec §03 item 3, verbatim: "mint when above baseline, gray otherwise". A literal reading —
        // the rule is stated as a visual one, with no polarity qualifier. Semantics live in the delta.
        let aboveBaseline: Bool = {
            guard let value = reading.value, let state, state.usable else { return false }
            return value > state.baseline
        }()

        return LedgerVitalRow(
            key: catalogKey,
            source: Repository.whoopSource,
            label: label,
            sublabel: sublabel,
            points: points.suffix(LedgerBodyModel.sparkWindow).map(\.value),
            isAboveBaseline: aboveBaseline,
            value: reading.value.map(reading.format),
            unit: reading.unit,
            delta: delta,
            deltaTint: deltaTint,
            band: reading.banding.band
        )
    }

    /// Spec §03 item 3: "30-day sparkline".
    private static let sparkWindow = 30

    // MARK: The verdict sentence

    /// Two lines of deterministic copy, from the banding verdicts alone. It states a COUNT and what
    /// that count means; it never claims a pattern, a cause or a trend the engines did not produce.
    static func verdictText(measured: Int, offRange: Int) -> String {
        if measured == 0 {
            return String(localized: "Nothing measured for last night. These vitals are read from an overnight wear, so a night off the strap leaves this screen blank.")
        }
        if offRange == 0 {
            return String(localized: "Every vital NOOP could read came back inside the band it is judged against. Nothing in the overnight picture argues against load today.")
        }
        if offRange == 1 {
            return String(localized: "One vital sits outside its usual band. That is common after load, a short night or a warm room — read the trend, not the night.")
        }
        return String(localized: "\(offRange) vitals sit outside their usual bands. That is common after load, a short night or a warm room — read the trend, not the night.")
    }

    // MARK: The 7-day strip

    /// Seven columns ending on the logical day, padded by day key so a missed night leaves a gap
    /// rather than silently shifting the week. `Repository.week` carries only the days that exist.
    private static func weekBars(_ week: [DailyMetric]) -> [LedgerRecoveryBar] {
        var byDay: [String: Double] = [:]
        for row in week {
            if let recovery = row.recovery { byDay[row.day] = recovery }
        }
        let todayKey = Repository.logicalDayKey(Date())
        let calendar = Calendar.current
        let now = Date()
        return (0..<7).reversed().compactMap { back -> LedgerRecoveryBar? in
            guard let date = calendar.date(byAdding: .day, value: -back, to: now) else { return nil }
            let key = Repository.localDayKey(date)
            return LedgerRecoveryBar(id: key,
                                     label: weekdayFormatter.string(from: date),
                                     score: byDay[key],
                                     isToday: key == todayKey)
        }
    }

    /// Two-letter weekday ("Sa", "Su"), locale-aware — the board's `font-size:10px` label.
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.setLocalizedDateFormatFromTemplate("EEEEEE")
        return f
    }()

    // MARK: Series

    /// One vital's per-day series across the source precedence, highest-priority source first per
    /// day — the same resolution `BodyVitalSigns` performs internally, mirrored here only so the
    /// sparkline and the baseline read the same rows the value came from.
    private static func series(_ rows: [SourcedDailyMetric],
                               key: String,
                               _ value: (DailyMetric) -> Double?) -> [LedgerBodyPoint] {
        // `BodyVitalSigns`' own `vitalPrecedence` is file-private, so the table is mirrored — NOT
        // forked — here: skin temp deliberately omits Apple Health (no 1:1 equivalent for the strap's
        // ±deviation), localCache is always last.
        let precedence: [DailyMetricSource] = key == "skin"
            ? [.whoopImport, .noopComputed, .localCache]
            : [.whoopImport, .noopComputed, .appleHealth, .localCache]
        var byDay: [String: Double] = [:]
        for source in precedence {
            for row in rows where row.source == source {
                guard let v = value(row.metric), byDay[row.metric.day] == nil else { continue }
                byDay[row.metric.day] = v
            }
        }
        return byDay.map { LedgerBodyPoint(day: $0.key, value: $0.value) }.sorted { $0.day < $1.day }
    }
}

/// One day's value for one vital, after source precedence.
private struct LedgerBodyPoint: Equatable {
    let day: String
    let value: Double
}

// MARK: - 5. WATCHING
//
// Board: `margin:16px 24px 22px; border-left:2px solid #F2C14E; padding:2px 0 2px 14px` — i.e. the
// `LedgerCoachNote` in `accent/caution`.
//
// Spec §03 item 5: "caution left-rule block fed by the existing illness/early-warning state (renders
// nothing when quiet)". This is the ONE place the screen touches `AppModel`, and it is a leaf on
// purpose: `AppModel` republishes on the ~1 Hz live-HR path, so observing it at the screen root would
// re-diff the whole vitals ledger every second. Exactly the isolation `HealthAlertBanner` uses.
//
// "Quiet" has three distinct shapes upstream, and all three render nothing here:
//   1. `illnessSignal == nil` — the illness watch is off (`behavior.illnessWatch`, default false) or
//      there are fewer than 14 days of history;
//   2. `.level == .quiet` — the baseline is untrusted or the score is below the mild threshold;
//   3. a blank message — `LedgerCoachNote` itself renders `EmptyView` for empty copy.
private struct LedgerBodyWatchingNote: View {
    @EnvironmentObject var model: AppModel

    /// The board's `margin-top:16px`, applied only when the note actually draws.
    let topGap: CGFloat

    var body: some View {
        if let illness = model.illnessSignal, illness.level != .quiet {
            LedgerCoachNote(title: String(localized: "Watching"),
                            message: ledgerIllnessCopy(illness),
                            accent: Ledger.accentCaution)
                .padding(.top, topGap)
        }
    }
}

/// Localized rendering of the semantic illness result.
///
/// `HealthView`'s own renderer (`localizedIllnessCopy` in `SkinTempCardsView.swift`) is `private` to
/// that file, so this is a mirror, not a fork: the same `Message` switch, the same seven sentences,
/// the same confounder vocabulary. The engine's English `Result.copy` is deliberately never shown —
/// the UI localizes the enum, exactly as the analytics layer documents.
private func ledgerIllnessCopy(_ result: IllnessSignalEngine.Result) -> String {
    let signals = ledgerLocalizedList(result.firedSignals)
    let reasons = ledgerLocalizedList(result.suppressionReasons.map(ledgerConfounder))
    switch result.message ?? ledgerFallbackMessage(result.level) {
    case .raised:
        return String(localized: "Your body looks strained. Signals up: \(signals). No alcohol or travel was logged, so consider taking it easy. On-device estimate, not a diagnosis.")
    case .alreadyUnwellAgree:
        return String(localized: "You logged feeling unwell, and your signals agree. Take it easy today. On-device estimate, not a diagnosis.")
    case .alreadyUnwell:
        return String(localized: "You logged feeling unwell. Take it easy today. On-device estimate, not a diagnosis.")
    case .suppressed:
        return String(localized: "Some signals are up, but you logged \(reasons). That is the more likely explanation. On-device estimate, not a diagnosis.")
    case .mild:
        return String(localized: "A few signals are mildly up: \(signals). Nothing alarming, but a calmer day may help. On-device estimate, not a diagnosis.")
    case .learningBaseline:
        return String(localized: "Still learning your baseline and keeping an eye on your signals.")
    case .normal:
        return String(localized: "Nothing notable. Your signals look like their normal range.")
    }
}

private func ledgerFallbackMessage(_ level: IllnessSignalEngine.Level) -> IllnessSignalEngine.Message {
    switch level {
    case .raised:        return .raised
    case .alreadyUnwell: return .alreadyUnwell
    case .suppressed:    return .suppressed
    case .mild:          return .mild
    case .quiet:         return .normal
    }
}

private func ledgerConfounder(_ reason: IllnessSignalEngine.SuppressionReason) -> String {
    switch reason {
    case .alcohol:           return String(localized: "Alcohol").lowercased(with: AppLanguage.activeLocale)
    case .stress:            return String(localized: "Stress").lowercased(with: AppLanguage.activeLocale)
    case .sauna:             return String(localized: "Sauna")
    case .hardOrLateWorkout: return String(localized: "Hard or late workout")
    case .travel:            return String(localized: "Travel")
    }
}

private func ledgerLocalizedList(_ values: [String]) -> String {
    let formatter = ListFormatter()
    formatter.locale = AppLanguage.activeLocale
    return formatter.string(from: values) ?? values.joined(separator: ", ")
}
