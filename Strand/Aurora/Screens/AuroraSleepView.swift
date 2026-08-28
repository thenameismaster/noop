import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore
#if canImport(UIKit)
import UIKit
#endif

// MARK: - AuroraSleepView
//
// The Aurora fork of the Sleep tab. ADDITIVE: `SleepView` is untouched and keeps working.
// PRESENTATION ONLY — every number drawn here comes from the SAME pure pipeline the original
// reads (`SleepModel.build(_:)` over `SleepModelInputs`), the same memoization contract
// (`dataKey` fingerprint → rebuild only on real data change), the same `.task(id:)` loads, and
// the same per-night derivations. No scoring, no business logic, no persistence is re-derived.
//
// INFORMATION ARCHITECTURE (this is the rewrite — not a restyle of the old one):
//
//   0. A persistent DAY RAIL replaces the ◀/▶ pill. The screen is day-centric: the selected
//      night is a `YYYY-MM-DD` key that lives above the scroll view and never scrolls away,
//      and colour (that day's recovery band) is the data on the rail itself.
//   1. HERO — ONE dominant statement: hours asleep, 78pt, tabular, rolling. Sleep performance
//      rides beside it as a ring, the whole page carries a band wash tinted by performance,
//      and a plain-English coach line makes the judgement so the reader does not have to.
//      The hero collapses into a one-line inline summary as the page is read.
//   2. SLEEP NEED — the need is decomposed on an `AuroraNeedBar`: baseline + carried debt,
//      with the night's achieved sleep as an overlaid marker, plus the real 14-night
//      `SleepDebtLedger` underneath it.
//   3. STAGES — the hypnogram is the centrepiece: full width, animated, scrubbable, with the
//      stage rows (duration / share / proportional bar) reading beneath it.
//   4. OVERNIGHT VITALS — a single reading list, each row carrying a delta chip against the
//      user's own personal baseline (`Baselines.foldHistory` → `Baselines.deviation`).
//   5. 30-NIGHT TREND — duration bars with the per-night need line drawn over them.
//
// LIVE STATE: like `SleepView`, this screen deliberately does NOT observe `LiveState`. A strap
// publishes at ~1 Hz and would re-evaluate this whole body on every tick.

/// The redesigned Sleep screen. Same data sources as `SleepView`, Aurora presentation.
@MainActor
struct AuroraSleepView: View {

    // MARK: Data sources (verbatim from SleepView)

    @EnvironmentObject var repo: Repository
    /// Held to match `SleepView`'s environment contract. This screen is READ-ONLY, so it never
    /// calls `analyzeRecent()` — mutations (edit / delete / add nap) stay on the original screen.
    @EnvironmentObject var intelligence: IntelligenceEngine

    /// Coordinate space name for the collapsing hero's scroll probe.
    private static let scrollSpace = "aurora.sleep.scroll"

    // MARK: Memoized state

    /// Memoized snapshot of every expensive derivation. Rebuilt only when `dataKey` changes.
    @State private var model: SleepModel?
    /// The repo signature `model` was built from.
    @State private var modelKey: AuroraSleepInputKey?

    /// The selected night, addressed by its LOCAL WAKE-DAY key (`YYYY-MM-DD`) — the rail's currency.
    @State private var selectedDayKey: String = ""
    /// The rail's pips, oldest first: one per RECORDED night, filled with that day's recovery band.
    @State private var pips: [AuroraDayPip] = []
    /// Wake-day key → index into `navDays`, so the screen never re-groups the session list in `body`.
    @State private var offsetByDay: [String: Int] = [:]
    /// Memoized decode of the NAVIGATED night (nil at offset 0 — the hero reads `model.night`).
    @State private var navNight: Night?

    /// Every sleep BLOCK across both sources, un-deduplicated, oldest→newest.
    @State private var allSessions: [CachedSleepSession] = []
    /// The LEARNED habitual midsleep the engine threaded into the daily totals (nil = cold start).
    @State private var habitualMidsleepSec: Int? = nil
    /// Per-epoch motion keyed by each session's detected `startTs`.
    @State private var motionByStart: [Int: [Double]] = [:]

    /// Sleeping heart rate for the displayed night, in 1-minute buckets.
    @State private var nightHR: [HRBucket] = []

    /// The overnight vitals list, folded against personal baselines once per night change rather
    /// than on every body pass (each row folds a calendar-padded history).
    @State private var vitals: [AuroraVitalReadout] = []

    /// How far the page has been scrolled, in points — drives the hero's collapse.
    @State private var heroOffset: CGFloat = 0

    /// Settings → Appearance → Sleep chart. Display-only: it picks the stage-chart shape.
    @AppStorage(SleepChartStyle.storageKey) private var sleepChartStyleRaw = SleepChartStyle.classic.rawValue
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: unitSystem, override: temperatureRaw)
    }
    private var showsFahrenheit: Bool { temperatureUnit == .fahrenheit }

    // MARK: - Body

    var body: some View {
        // Same memoization contract as SleepView: `dataKey` is O(1)-ish, so comparing it every
        // render is cheap; a match reuses the cached model untouched.
        let key = dataKey
        let resolved: SleepModel? = (key == modelKey) ? model : buildModel()
        let night = resolved.flatMap(displayedNight)
        let performance = night.flatMap(performanceScore)
        let tint = performance.map { Aurora.sleepColor($0) } ?? Aurora.textDisabled

        return VStack(spacing: 0) {
            titleBar(night)
            AuroraDayRail(days: pips, selection: $selectedDayKey)
            scroller(resolved, night, performance: performance, tint: tint)
        }
        // Wash FIRST, canvas SECOND: `.background` stacks backwards, so this puts the opaque
        // canvas behind the translucent band wash rather than on top of it.
        .auroraBandWash(tint, intensity: night == nil ? 0.35 : 1.0)
        .auroraCanvas()
        // Persisting the freshly-built model after layout (writing State during body is illegal).
        // `resolved` already drives THIS frame, so there is no flash and no extra rebuild.
        .onChangeCompat(of: key) { newKey in
            modelKey = newKey
            model = buildModel()
            rebuildRail(resetSelection: true)
            navNight = nil
            rebuildVitals()
        }
        // The navigated night is decoded once per rail tap, never per body pass.
        .onChangeCompat(of: selectedDayKey) { _ in
            navNight = nightOffset == 0 ? nil : decodedNight(at: nightOffset)
            rebuildVitals()
        }
        .onAppear {
            if modelKey != key {
                modelKey = key
                model = resolved
                navNight = nil
            }
            rebuildRail(resetSelection: selectedDayKey.isEmpty)
            rebuildVitals()
        }
        // Load EVERY sleep block across BOTH sources (un-deduplicated) so the rail can browse the
        // split-sleep days the dashboard collapses. Re-runs whenever a sync/import bumps refreshSeq.
        .task(id: repo.refreshSeq) {
            allSessions = await repo.allSleepSessions()
            habitualMidsleepSec = await repo.habitualMidsleepSec()
            motionByStart = await repo.sessionMotions(starts: allSessions.map { $0.startTs })
            navNight = nil
            modelKey = dataKey
            model = buildModel()
            rebuildRail(resetSelection: true)
            rebuildVitals()
        }
        // The displayed night's sleeping HR, reloaded whenever the shown night changes.
        .task(id: night?.session.startTs ?? 0) {
            guard let night, night.session.endTs > night.session.effectiveStartTs else {
                nightHR = []
                return
            }
            nightHR = await repo.hrBuckets(from: night.session.effectiveStartTs,
                                           to: night.session.endTs,
                                           bucketSeconds: 60)
        }
    }

    // MARK: - Chrome

    /// A slim, permanent statement of WHICH night is on screen. Day-centric by construction:
    /// the label sits above the rail and never scrolls out of view.
    private func titleBar(_ night: Night?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Aurora.Space.xs) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SLEEP").auroraSectionHeader()
                Text(nightRelativeLabel)
                    .auroraTitle()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
            }

            Spacer(minLength: Aurora.Space.xs)

            if let night {
                VStack(alignment: .trailing, spacing: 4) {
                    AuroraStatusPill(nightSource(night), tone: .neutral, style: .outline)
                    Text(night.spanLabel)
                        .auroraFootnote()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .auroraGutter()
        .padding(.top, Aurora.Space.xs)
        .padding(.bottom, Aurora.Space.s)
    }

    @ViewBuilder
    private func scroller(_ resolved: SleepModel?, _ night: Night?,
                          performance: Double?, tint: Color) -> some View {
        let scroll = ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                AuroraScrollOffsetProbe(space: Self.scrollSpace)

                if let resolved, let night {
                    AuroraCollapsingHero(offset: heroOffset,
                                         collapseDistance: 200,
                                         compactHeight: 46) {
                        hero(night, performance: performance, tint: tint)
                    } compact: {
                        compactSummary(night, performance: performance, tint: tint)
                    }
                    .auroraGutter()

                    needSection(resolved, night)
                    stagesSection(resolved, night)
                    vitalsSection(night, tint: tint)
                    trendSection(night)
                } else {
                    emptyState
                        .auroraGutter()
                        .padding(.top, Aurora.Space.xl)
                }
            }
            .padding(.bottom, Aurora.Space.tabBarClearance)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .auroraScrollSpace(Self.scrollSpace)
        .onAuroraScrollOffset { heroOffset = $0 }

        #if os(iOS)
        scroll.refreshable { await repo.refresh() }
        #else
        scroll
        #endif
    }

    // MARK: - 1. Hero

    /// ONE dominant statement. The hours are the screen; everything else defers to them.
    @ViewBuilder
    private func hero(_ night: Night, performance: Double?, tint: Color) -> some View {
        let asleep = night.stages.asleep
        let need = sleepNeedMin(for: night)
        let ratio: Double? = {
            guard let need, need > 0, asleep > 0 else { return nil }
            return asleep / need
        }()

        VStack(alignment: .leading, spacing: Aurora.Space.m) {
            Text("ASLEEP").auroraSectionHeader()

            heroNumerals(asleep: asleep, tint: tint)

            HStack(alignment: .center, spacing: Aurora.Space.m) {
                AuroraRing(
                    progress: performance.map { min(max($0 / 100, 0), 1) },
                    value: performance.map { "\(Int($0.rounded()))" },
                    unit: performance != nil ? "%" : nil,
                    caption: String(localized: "PERFORMANCE"),
                    ramp: .sleep,
                    lineWidth: 9,
                    size: 96,
                    emptyHint: String(localized: "No score")
                )

                VStack(alignment: .leading, spacing: Aurora.Space.xs) {
                    AuroraCoachLine.forSleepPerformance(performance)

                    Text(heroSubline(asleep: asleep, need: need, ratio: ratio))
                        .auroraCaption()
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: Aurora.Space.xs) {
                        heroClock(icon: "moon.stars.fill", value: night.onsetText,
                                  tint: AuroraSleepStage.deep.color)
                        heroClock(icon: "sun.horizon.fill", value: night.wakeText,
                                  tint: AuroraSleepStage.awake.color)
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .padding(.top, Aurora.Space.m)
        .padding(.bottom, Aurora.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "7h 12m" at hero scale, counting up on appear and rolling when the rail moves.
    @ViewBuilder
    private func heroNumerals(asleep: Double, tint: Color) -> some View {
        if asleep > 0 {
            let total = Swift.max(0, Int(asleep.rounded()))
            HStack(alignment: .firstTextBaseline, spacing: Aurora.Space.xs) {
                AuroraRollingNumber(value: Double(total / 60), unit: "h", size: 78, color: tint)
                AuroraRollingNumber(value: Double(total % 60), unit: "m", size: 78, color: tint)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(auroraDurationText(asleep)) asleep"))
        } else {
            Text("—")
                .font(AuroraType.display(78))
                .tracking(AuroraType.displayTracking(78))
                .foregroundStyle(Aurora.textDisabled)
                .accessibilityLabel(Text("No sleep recorded"))
        }
    }

    private func heroClock(icon: String, value: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .auroraCaptionStrong()
                .monospacedDigit()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Capsule(style: .continuous).fill(Aurora.surfaceSubtle))
        .accessibilityElement(children: .combine)
    }

    private func heroSubline(asleep: Double, need: Double?, ratio: Double?) -> String {
        guard let need, need > 0 else {
            return String(localized: "Your sleep need needs a few more nights of history.")
        }
        guard asleep > 0 else {
            return String(localized: "Need \(auroraDurationText(need)) — nothing recorded for this night.")
        }
        let gap = need - asleep
        if gap > 5 {
            return String(localized: "\(auroraDurationText(gap)) short of your \(auroraDurationText(need)) need.")
        }
        if gap < -5 {
            return String(localized: "\(auroraDurationText(-gap)) over your \(auroraDurationText(need)) need.")
        }
        return String(localized: "Right on your \(auroraDurationText(need)) need.")
    }

    /// What the hero becomes once the reader starts working through the detail.
    private func compactSummary(_ night: Night, performance: Double?, tint: Color) -> some View {
        HStack(spacing: Aurora.Space.xs) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(night.stages.asleep > 0 ? auroraDurationText(night.stages.asleep) : "—")
                .auroraBodyStrong()
                .monospacedDigit()
            Text(nightRelativeLabel.lowercased())
                .auroraCaption()
                .lineLimit(1)
            Spacer(minLength: Aurora.Space.xs)
            if let performance {
                AuroraStatusPill("\(Int(performance.rounded()))%",
                                 style: .tinted,
                                 overrideColor: tint)
            }
        }
        .auroraGutter()
        .accessibilityElement(children: .combine)
    }

    // MARK: - 2. Sleep need

    /// The need, decomposed. `AuroraNeedBar` draws baseline + carried debt as a ghost stack and
    /// masks it to what was actually slept, with an overhanging marker at the achieved total.
    ///
    /// HONEST DECOMPOSITION. The TOTAL is the same need the hero measured against — this only
    /// splits it. The debt segment is the export's own per-day `sleep_debt_min`; when the night
    /// was computed on device there is no stored decomposition, so the bar is baseline-only and
    /// says so rather than inventing a split. There is no strain-contribution column anywhere in
    /// the data model, so that segment is always omitted (see the note under the bar).
    @ViewBuilder
    private func needSection(_ model: SleepModel, _ night: Night) -> some View {
        let comp = needComposition(for: night)
        let asleep = night.stages.asleep
        let ledger = model.sleepDebtLedger

        section(String(localized: "Sleep need"),
                subtitle: comp.isDecomposed
                    ? String(localized: "Baseline plus the debt carried into this night")
                    : String(localized: "Your personal need for this night")) {
            AuroraCard(elevation: .base, padding: Aurora.Space.cardPadding) {
                VStack(alignment: .leading, spacing: Aurora.Space.m) {
                    if comp.needMin > 0 {
                        AuroraNeedBar(baseline: comp.baselineSeconds,
                                      debt: comp.debtSeconds,
                                      strain: 0,
                                      achieved: asleep > 0 ? asleep * 60 : nil)

                        Text(comp.note)
                            .auroraFootnote()
                            .fixedSize(horizontal: false, vertical: true)

                        AuroraDivider()

                        AuroraSleepDebtStrip(ledger: ledger)
                    } else {
                        AuroraEmptyState(
                            icon: "scalemass",
                            headline: String(localized: "No sleep need yet"),
                            message: String(localized: "A few nights of recorded sleep and NOOP can state what you need — or import a WHOOP export, which carries its own per-night need and debt."),
                            tint: AuroraNeedBar.baselineTint
                        )
                        .frame(minHeight: 170)
                    }
                }
            }
        }
    }

    /// The need split. `baseline + debt` always equals the night's need exactly, so this screen
    /// can never disagree with the hero ring about how much sleep was needed.
    private struct NeedComposition {
        let needMin: Double
        let debtMin: Double
        let isDecomposed: Bool
        let note: String

        var baselineSeconds: TimeInterval { Swift.max(needMin - debtMin, 0) * 60 }
        var debtSeconds: TimeInterval { Swift.max(debtMin, 0) * 60 }
    }

    private func needComposition(for night: Night) -> NeedComposition {
        let wakeDay = wakeDayKey(night)
        if let figures = repo.importedSleep[wakeDay], let need = figures.needMin, need > 0 {
            let debt = Swift.min(Swift.max(figures.debtMin ?? 0, 0), need)
            if debt > 0 {
                return NeedComposition(
                    needMin: need,
                    debtMin: debt,
                    isDecomposed: true,
                    note: String(localized: "\(auroraDurationText(debt)) of this night's need was debt carried in from earlier nights. Your export does not break out a strain contribution, so none is drawn."))
            }
            return NeedComposition(
                needMin: need,
                debtMin: 0,
                isDecomposed: false,
                note: String(localized: "Your export carried no debt for this night, so the whole need is baseline."))
        }
        guard !repo.days.isEmpty else {
            return NeedComposition(needMin: 0, debtMin: 0, isDecomposed: false, note: "")
        }
        let need = SleepModel.sleepNeedMin(days: repo.days)
        return NeedComposition(
            needMin: need,
            debtMin: 0,
            isDecomposed: false,
            note: String(localized: "This night was computed on device, which stores a single need rather than a baseline / debt / strain split — so the bar shows baseline only. The rolling ledger below is the real debt picture."))
    }

    // MARK: - 3. Stages

    @ViewBuilder
    private func stagesSection(_ model: SleepModel, _ night: Night) -> some View {
        let style = SleepChartStyle.resolve(sleepChartStyleRaw)
        let raw = displayedIntervals(model, night)
        let usable = raw.count >= 2
        let smoothed = usable
            ? Hypnogram.displaySmoothed(raw.sorted { $0.start < $1.start },
                                        minDuration: style == .classic ? 90 : 300)
            : []
        let segments = auroraSegments(smoothed, onset: night.onsetDate)
        let persisted = isPersistedHypnogram(model, night)
        let s = night.stages
        // Whole percentages that sum to exactly 100, in [awake, light, deep, rem] order —
        // the SAME shared helper the original screen uses.
        let shares = StagePercentages.wholePercentages([s.awake, s.light, s.deep, s.rem])
        let rows: [(AuroraSleepStage, Double, Int, Double?)] = [
            (.rem,   s.rem,   shares?[3] ?? 0, model.typicalRemMin),
            (.deep,  s.deep,  shares?[2] ?? 0, model.typicalDeepMin),
            (.light, s.light, shares?[1] ?? 0, model.typicalLightMin),
            (.awake, s.awake, shares?[0] ?? 0, nil)
        ]

        section(String(localized: "Stages"),
                subtitle: usable ? "\(night.onsetText) → \(night.wakeText)" : nil) {
            AuroraCard(elevation: .base, padding: Aurora.Space.cardPadding) {
                VStack(alignment: .leading, spacing: Aurora.Space.l) {
                    if usable {
                        AuroraScrubbableHypnogram(segments: segments,
                                                  style: style.isFilled ? .filled : .stepped,
                                                  height: 172)
                    } else {
                        AuroraEmptyState(
                            icon: "moon.zzz.fill",
                            headline: String(localized: "No stage timeline for this night"),
                            message: String(localized: "The night is stored, but no stage timeline came with it. Wear the strap to bed and every stage is charted by morning."),
                            tint: AuroraSleepStage.light.color
                        )
                        .frame(height: 172)
                    }

                    if s.total > 0 {
                        VStack(alignment: .leading, spacing: Aurora.Space.m) {
                            ForEach(Array(rows.enumerated()), id: \.element.0) { idx, row in
                                AuroraStageRow(stage: row.0,
                                               minutes: row.1,
                                               percent: row.2,
                                               total: s.total,
                                               typicalMinutes: row.3,
                                               index: idx)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            if model.typicalTotalMin != nil {
                                Text("The hairline on each bar marks your typical minutes for that stage.")
                                    .auroraFootnote()
                            }
                            if usable && !persisted {
                                Text("This night's export carried stage totals only — the timeline above is an estimate. The durations are exact.")
                                    .auroraFootnote()
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 4. Overnight vitals

    @ViewBuilder
    private func vitalsSection(_ night: Night, tint: Color) -> some View {
        section(String(localized: "Overnight vitals"),
                subtitle: String(localized: "Measured while you slept, against your own baseline")) {
            VStack(alignment: .leading, spacing: Aurora.Space.cardGap) {
                AuroraCard(elevation: .base, padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(vitals.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { AuroraDivider(inset: Aurora.Space.cardPadding) }
                            AuroraVitalRow(readout: row)
                        }
                        if vitals.isEmpty {
                            AuroraEmptyState(
                                icon: "waveform.path.ecg",
                                headline: String(localized: "No vitals for this night"),
                                message: String(localized: "Resting heart rate, variability, respiration, blood oxygen and skin temperature all come from a worn strap or an import."),
                                tint: AuroraSleepStage.light.color
                            )
                            .padding(Aurora.Space.cardPadding)
                        }
                    }
                }

                nightHeartRateCard(tint: tint)
            }
        }
    }

    /// The night's own heart-rate trace, from the 1-minute buckets loaded for the shown night.
    @ViewBuilder
    private func nightHeartRateCard(tint: Color) -> some View {
        let bpm = nightHR.map(\.bpm).filter { $0.isFinite && $0 > 0 }

        AuroraCard(elevation: .base, padding: Aurora.Space.cardPadding) {
            VStack(alignment: .leading, spacing: Aurora.Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: Aurora.Space.xs) {
                    Text("HEART RATE THROUGH THE NIGHT").auroraSectionHeader()
                    Spacer(minLength: Aurora.Space.xs)
                    if let lo = bpm.min(), let hi = bpm.max() {
                        Text("\(Int(lo.rounded()))–\(Int(hi.rounded())) bpm")
                            .auroraCaptionStrong()
                            .monospacedDigit()
                    }
                }

                if bpm.count > 1 {
                    AuroraSparkline(values: bpm,
                                    tint: tint,
                                    lineWidth: Aurora.Stroke.line,
                                    showsArea: true,
                                    showsHead: false)
                        .frame(height: 60)
                } else {
                    Text("No heart-rate samples were stored for this night.")
                        .auroraFootnote()
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                }
            }
        }
    }

    // MARK: - 5. Thirty-night trend

    @ViewBuilder
    private func trendSection(_ night: Night) -> some View {
        let points = trendPoints()
        let selectedDay = wakeDayKey(night)

        section(String(localized: "30-night trend"),
                subtitle: String(localized: "Duration against the need for each night")) {
            AuroraCard(elevation: .base, padding: Aurora.Space.cardPadding) {
                if points.count >= 2 {
                    AuroraSleepTrendChart(points: points, selectedDay: selectedDay, height: 168)
                } else {
                    AuroraEmptyState(
                        icon: "chart.bar.fill",
                        headline: String(localized: "Not enough nights yet"),
                        message: String(localized: "Two recorded nights and this chart fills in."),
                        tint: AuroraSleepStage.light.color
                    )
                    .frame(height: 168)
                }
            }
        }
    }

    /// The trailing 30 stored days as (day, hours slept, hours needed). Both series are the SAME
    /// ones the shipping code uses: `totalSleepMin` for the bar, and the imported per-day
    /// `sleep_need_min` (else the personal-mean need) for the line — exactly `hoursVsNeeded`'s split.
    private func trendPoints() -> [AuroraSleepTrendPoint] {
        let rows = Array(repo.days.suffix(30))
        guard !rows.isEmpty else { return [] }
        let fallbackNeed = SleepModel.sleepNeedMin(days: repo.days)
        return rows.map { d in
            AuroraSleepTrendPoint(
                day: d.day,
                date: auroraDate(fromDayKey: d.day),
                hours: d.totalSleepMin.map { $0 / 60 }.flatMap { $0 > 0 ? $0 : nil },
                needHours: (repo.importedSleep[d.day]?.needMin ?? fallbackNeed) / 60
            )
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        AuroraCard(elevation: .base, padding: Aurora.Space.heroPadding, radius: Aurora.Radius.hero) {
            AuroraEmptyState(
                icon: repo.loaded ? "moon.zzz.fill" : "arrow.triangle.2.circlepath",
                headline: repo.loaded
                    ? String(localized: "No nights here yet")
                    : String(localized: "Loading your sleep history…"),
                message: repo.loaded
                    ? String(localized: "Import your WHOOP export in Data Sources to see every night, your stages and your trends straight away — or wear the strap to bed and NOOP computes last night on device.")
                    : nil,
                tint: AuroraSleepStage.light.color
            )
            .frame(minHeight: 260)
        }
    }

    // MARK: - Section scaffold

    /// One page section: a header, generous air above it, and the body. Vertical rhythm is the
    /// only thing separating sections — no boxes around boxes.
    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        subtitle: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Aurora.Space.s) {
            AuroraSectionHeader(title, subtitle: subtitle)
            content()
        }
        .auroraGutter()
        .padding(.top, Aurora.Space.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Rail construction

    /// Build the rail's pips and the wake-day → nav-index map. One pip per RECORDED night, newest
    /// 90, oldest first, coloured by that day's recovery band (the same colour language every
    /// Aurora screen's rail speaks).
    private func rebuildRail(resetSelection: Bool) {
        let days = navDays
        var recoveryByDay: [String: Double] = [:]
        for d in repo.days {
            if let r = d.recovery { recoveryByDay[d.day] = r }
        }

        var map: [String: Int] = [:]
        var built: [AuroraDayPip] = []   // newest first, matching navDays
        for (index, blocks) in days.enumerated() {
            guard let endTs = blocks.first?.endTs else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(endTs))
            let key = Repository.localDayKey(date)
            guard map[key] == nil else { continue }
            map[key] = index
            built.append(AuroraDayPip(dayKey: key, date: date, recovery: recoveryByDay[key]))
        }

        offsetByDay = map
        pips = Array(built.prefix(90)).reversed()

        if resetSelection || offsetByDay[selectedDayKey] == nil {
            selectedDayKey = pips.last?.dayKey ?? ""
        }
    }

    // MARK: - Overnight vitals construction

    /// Fold each vital against the user's OWN baseline, using the shipping estimator
    /// (`VitalBands.calendarSeries` → `Baselines.foldHistory` → `Baselines.deviation`) over the
    /// history up to and including the displayed night. Never computed in `body`.
    private func rebuildVitals() {
        guard let model, let night = displayedNight(model) else {
            vitals = []
            return
        }
        let wakeDay = wakeDayKey(night)
        let history = repo.days.filter { $0.day <= wakeDay }
        let row = repo.days.last(where: { $0.day == wakeDay })
        let tint = AuroraSleepStage.light.color

        var out: [AuroraVitalReadout] = []

        // Resting heart rate — the strap's own row wins, else the night's edit target.
        let rhr: Double? = {
            if let hr = row?.restingHr { return Double(hr) }
            if let hr = night.editTarget?.restingHr { return Double(hr) }
            return nil
        }()
        out.append(vitalReadout(
            id: "rhr", label: String(localized: "Resting HR"), icon: "heart.fill", tint: tint,
            value: rhr, unit: "bpm", decimals: 0, higherIsBetter: false,
            cfg: Baselines.restingHRCfg,
            history: history.map { (day: $0.day, value: $0.restingHr.map(Double.init)) },
            missing: String(localized: "No resting rate stored for this night")))

        let hrv = row?.avgHrv ?? night.editTarget?.avgHrv
        out.append(vitalReadout(
            id: "hrv", label: String(localized: "Heart-rate variability"), icon: "waveform.path.ecg",
            tint: tint, value: hrv, unit: "ms", decimals: 0, higherIsBetter: true,
            cfg: Baselines.hrvCfg,
            history: history.map { (day: $0.day, value: $0.avgHrv) },
            missing: String(localized: "No variability stored for this night")))

        out.append(vitalReadout(
            id: "resp", label: String(localized: "Respiratory rate"), icon: "lungs.fill",
            tint: tint, value: row?.respRateBpm, unit: "rpm", decimals: 1, higherIsBetter: false,
            cfg: Baselines.respCfg,
            history: history.map { (day: $0.day, value: $0.respRateBpm) },
            missing: String(localized: "No respiration stored for this night")))

        // SpO2 has NO personal MetricCfg by design (it is banded against the population range),
        // so the chip compares against the user's own trailing average instead of a folded baseline.
        out.append(vitalReadout(
            id: "spo2", label: String(localized: "Blood oxygen"), icon: "drop.fill",
            tint: tint, value: row?.spo2Pct, unit: "%", decimals: 0, higherIsBetter: true,
            cfg: nil,
            history: history.map { (day: $0.day, value: $0.spo2Pct) },
            missing: String(localized: "No blood oxygen stored for this night"),
            deltaDecimals: 1,
            comparisonLabel: String(localized: "vs your recent average")))

        out.append(skinTempReadout(history: history, value: row?.skinTempDevC, tint: tint))

        vitals = out
    }

    private func vitalReadout(id: String, label: String, icon: String, tint: Color,
                              value: Double?, unit: String, decimals: Int,
                              higherIsBetter: Bool,
                              cfg: MetricCfg?,
                              history: [(day: String, value: Double?)],
                              missing: String,
                              deltaDecimals: Int? = nil,
                              comparisonLabel: String? = nil) -> AuroraVitalReadout {
        let spark = Array(history.compactMap(\.value).filter { $0.isFinite }.suffix(30))
        guard let value, value.isFinite else {
            return AuroraVitalReadout(id: id, label: label, icon: icon, tint: tint,
                                      valueText: nil, unit: unit, delta: nil,
                                      caption: missing, sparkline: spark)
        }
        let text = decimals > 0 ? String(format: "%.\(decimals)f", value) : String(Int(value.rounded()))
        let chipDecimals = deltaDecimals ?? decimals

        if let cfg {
            let series = VitalBands.calendarSeries(history)
            let state = Baselines.foldHistory(series, cfg: cfg)
            if state.usable {
                let dev = Baselines.deviation(value, state: state)
                let baselineText = decimals > 0
                    ? String(format: "%.\(decimals)f", state.baseline)
                    : String(Int(state.baseline.rounded()))
                let caption = state.trusted
                    ? String(localized: "Baseline \(baselineText) \(unit) · \(state.nValid) nights")
                    : String(localized: "Provisional baseline \(baselineText) \(unit) · \(state.nValid) nights")
                return AuroraVitalReadout(
                    id: id, label: label, icon: icon, tint: tint,
                    valueText: text, unit: unit,
                    delta: AuroraDelta(dev.delta, unit: unit, decimals: chipDecimals,
                                       higherIsBetter: higherIsBetter),
                    caption: caption, sparkline: spark)
            }
            return AuroraVitalReadout(
                id: id, label: label, icon: icon, tint: tint,
                valueText: text, unit: unit, delta: nil,
                caption: String(localized: "Baseline still calibrating · \(state.nValid) of \(Baselines.minNightsSeed) nights"),
                sparkline: spark)
        }

        // No personal config for this metric: compare against the user's own trailing mean.
        let recent = Array(history.compactMap(\.value).filter { $0.isFinite }.suffix(30))
        guard recent.count >= 3 else {
            return AuroraVitalReadout(id: id, label: label, icon: icon, tint: tint,
                                      valueText: text, unit: unit, delta: nil,
                                      caption: String(localized: "Not enough nights to compare yet"),
                                      sparkline: spark)
        }
        let mean = recent.reduce(0, +) / Double(recent.count)
        let meanText = String(format: "%.1f", mean)
        return AuroraVitalReadout(
            id: id, label: label, icon: icon, tint: tint,
            valueText: text, unit: unit,
            delta: AuroraDelta(value - mean, unit: unit, decimals: chipDecimals,
                               higherIsBetter: higherIsBetter),
            caption: (comparisonLabel ?? String(localized: "vs your recent average")) + " \(meanText) \(unit)",
            sparkline: spark)
    }

    /// Skin temperature is BIMODAL: imports store absolute °C, the on-device pipeline stores a
    /// signed deviation from the personal baseline. The row picks the right unit, the right
    /// history partition and the right baseline config for whichever kind this night carries.
    private func skinTempReadout(history: [DailyMetric], value: Double?, tint: Color) -> AuroraVitalReadout {
        let label = String(localized: "Skin temperature")
        let rawHistory = history.map { (day: $0.day, value: $0.skinTempDevC) }
        let spark = Array(rawHistory.compactMap(\.value).filter { $0.isFinite }.suffix(30))

        guard let value, value.isFinite else {
            return AuroraVitalReadout(id: "skin", label: label, icon: "thermometer", tint: tint,
                                      valueText: nil, unit: showsFahrenheit ? "°F" : "°C",
                                      delta: nil,
                                      caption: String(localized: "No skin temperature stored for this night"),
                                      sparkline: spark)
        }

        let kind = SkinTempDisplay.kind(of: value)
        let unit = SkinTempDisplay.unitSymbol(kind: kind, fahrenheit: showsFahrenheit)
        let text = SkinTempDisplay.numberString(value, kind: kind, fahrenheit: showsFahrenheit, decimals: 1)

        // A DEVIATION reading already IS the delta against the personal baseline — restating it
        // as a chip would double-count it, so the row simply says what the number means.
        if kind == .deviation {
            return AuroraVitalReadout(id: "skin", label: label, icon: "thermometer", tint: tint,
                                      valueText: text, unit: unit, delta: nil,
                                      caption: String(localized: "Already a deviation from your own baseline"),
                                      sparkline: spark)
        }

        // Absolute °C: fold the same-kind history against the shipping absolute config.
        guard let cfg = Baselines.metricCfg["skin_temp"] else {
            return AuroraVitalReadout(id: "skin", label: label, icon: "thermometer", tint: tint,
                                      valueText: text, unit: unit, delta: nil,
                                      caption: String(localized: "Absolute wrist temperature"),
                                      sparkline: spark)
        }
        let matched = VitalBands.skinTempHistory(matching: value,
                                                 in: VitalBands.calendarSeries(rawHistory))
        let state = Baselines.foldHistory(matched, cfg: cfg)
        guard state.usable else {
            return AuroraVitalReadout(id: "skin", label: label, icon: "thermometer", tint: tint,
                                      valueText: text, unit: unit, delta: nil,
                                      caption: String(localized: "Baseline still calibrating · \(state.nValid) of \(Baselines.minNightsSeed) nights"),
                                      sparkline: spark)
        }
        let dev = Baselines.deviation(value, state: state)
        let shownDelta = showsFahrenheit ? dev.delta * 9.0 / 5.0 : dev.delta
        let baselineText = SkinTempDisplay.numberString(state.baseline, kind: .absolute,
                                                        fahrenheit: showsFahrenheit, decimals: 1)
        return AuroraVitalReadout(
            id: "skin", label: label, icon: "thermometer", tint: tint,
            valueText: text, unit: unit,
            // A raised skin temperature is the signal worth flagging, so higher is NOT better.
            delta: AuroraDelta(shownDelta, unit: unit, decimals: 1, higherIsBetter: false,
                               flatThreshold: 0.05),
            caption: String(localized: "Baseline \(baselineText) \(unit) · \(state.nValid) nights"),
            sparkline: spark)
    }

    // MARK: - Memoization plumbing (mirrors SleepView exactly)

    /// A cheap fingerprint of the repo inputs this screen derives from.
    private var dataKey: AuroraSleepInputKey {
        AuroraSleepInputKey(
            loaded: repo.loaded,
            daysCount: repo.days.count,
            sleepsCount: repo.sleeps.count,
            firstDay: repo.days.first?.day,
            lastDay: repo.days.last?.day,
            lastDayUpdated: repo.days.last,
            lastSleep: repo.sleeps.last,
            refreshSeq: repo.refreshSeq)
    }

    /// Snapshot the view's state into `SleepModelInputs` and hand off to the SAME pure builder
    /// `SleepView` uses. No derivation is duplicated here.
    private func buildModel() -> SleepModel? {
        SleepModel.build(SleepModelInputs(
            days: repo.days,
            sleeps: repo.sleeps,
            allSessions: allSessions,
            importedSleep: repo.importedSleep,
            habitualMidsleepSec: habitualMidsleepSec,
            motionByStart: motionByStart))
    }

    // MARK: - Derived night selection (mirrors SleepView)

    private var navSessions: [CachedSleepSession] {
        allSessions.isEmpty ? repo.sleeps : allSessions
    }

    private var navDays: [[CachedSleepSession]] {
        SleepModel.navDays(navSessions: navSessions)
    }

    /// Which recorded day the rail is pointing at. 0 = the newest night.
    private var nightOffset: Int { offsetByDay[selectedDayKey] ?? 0 }

    private func dayBlocks(at offset: Int) -> [CachedSleepSession] {
        let days = navDays
        return offset >= 0 && offset < days.count ? days[offset] : []
    }

    private func decodedNight(at offset: Int) -> Night? {
        SleepModel.decodedNight(at: offset, navDays: navDays,
                                habitualMidsleepSec: habitualMidsleepSec, motionByStart: motionByStart)
    }

    private func sessionRow(at offset: Int) -> CachedSleepSession? {
        SleepView.stubDaySession(dayBlocks(at: offset), habitualMidsleepSec: habitualMidsleepSec)
    }

    /// The night the whole screen reflects. Offset 0 reads the memoized latest night; a navigated
    /// offset reads the cached `navNight`; a day whose blocks decode to no usable stages degrades
    /// to the honest stage-less stub on that REAL session's window — never last night silently
    /// rendered under a navigated label.
    private func displayedNight(_ model: SleepModel) -> Night? {
        let offset = nightOffset
        if offset == 0, !model.isStubNight { return model.night }
        if let navNight { return navNight }
        if let session = sessionRow(at: offset) {
            return Night(session: session,
                         stages: Stages(awake: 0, light: 0, deep: 0, rem: 0),
                         sourceBlocks: dayBlocks(at: offset),
                         habitualMidsleepSec: habitualMidsleepSec)
        }
        // Offset 0 with a stub model still has the model's own stub night to show.
        return offset == 0 ? model.night : nil
    }

    /// The stage intervals for the displayed night — the model's memoized set at offset 0, the
    /// night's own otherwise. Never a fresh JSON decode.
    private func displayedIntervals(_ model: SleepModel, _ night: Night) -> [SleepInterval] {
        if nightOffset == 0, !model.isStubNight { return model.intervals }
        return night.intervals
    }

    private func isPersistedHypnogram(_ model: SleepModel, _ night: Night) -> Bool {
        if nightOffset == 0, !model.isStubNight { return model.isPersistedHypnogram }
        return (night.realSegments?.count ?? 0) >= 2
    }

    // MARK: - Labels (same semantics as SleepView)

    /// How many CALENDAR nights back the shown night is. The rail steps by RECORDED night, so a
    /// night with no data is a gap the flat index cannot see.
    private func nightsAgo(_ offset: Int) -> Int {
        let days = navDays
        guard offset >= 0, offset < days.count,
              let newestTs = days.first?.first?.endTs, let shownTs = days[offset].first?.endTs
        else { return offset }
        let cal = Calendar.current
        let shown = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(shownTs)))
        let newest = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(newestTs)))
        let d = cal.dateComponents([.day], from: shown, to: newest).day ?? offset
        return d >= 0 ? d : offset
    }

    private var nightRelativeLabel: String {
        let n = nightsAgo(nightOffset)
        if n == 0 { return String(localized: "Last night") }
        if n == 1 { return String(localized: "1 night ago") }
        return String(localized: "\(n) nights ago")
    }

    // MARK: - Per-night values (same resolution order as SleepView)

    /// Sleep is filed under the day you WOKE, so every per-night lookup keys on that.
    private func wakeDayKey(_ night: Night) -> String {
        Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(night.session.endTs)))
    }

    /// The sleep-performance score for a SPECIFIC night: the imported WHOOP figure for that
    /// night's LOCAL wake-day when the export carried one, else the resolved Rest composite for
    /// that day. Mirrors `performanceSeries`'s per-day transform exactly.
    private func performanceScore(for night: Night) -> Double? {
        let wakeDay = wakeDayKey(night)
        if let p = repo.importedSleep[wakeDay]?.performancePct { return p }
        guard let daily = repo.days.last(where: { $0.day == wakeDay }) else { return nil }
        return AnalyticsEngine.Rest.composite(daily: daily)
    }

    /// The night's sleep need in minutes: the imported per-day `sleep_need_min` when the export
    /// carried one, else the same personal-mean need `hoursVsNeededSeries` falls back to.
    private func sleepNeedMin(for night: Night) -> Double? {
        let wakeDay = wakeDayKey(night)
        if let n = repo.importedSleep[wakeDay]?.needMin, n > 0 { return n }
        guard !repo.days.isEmpty else { return nil }
        return SleepModel.sleepNeedMin(days: repo.days)
    }

    /// The REAL per-day merge winner for the displayed night, in the same brand wording the
    /// By-Day badge / Today / Intelligence use. Keyed by the night's LOCAL wake-day.
    private func nightSource(_ night: Night) -> String {
        let wakeDay = wakeDayKey(night)
        if repo.importedSleep[wakeDay] != nil { return String(localized: "Whoop") }
        if repo.activeDeviceIsOura { return String(localized: "Oura") }
        return String(localized: "On-device")
    }
}

// MARK: - Vital readout

/// One overnight vital, already resolved: value, unit, chip against the personal baseline, and
/// the sentence that says what the baseline is. Presentation only.
private struct AuroraVitalReadout: Identifiable, Equatable {
    let id: String
    let label: String
    let icon: String
    let tint: Color
    let valueText: String?
    let unit: String
    let delta: AuroraDelta?
    let caption: String
    let sparkline: [Double]
}

/// A reading list row: glyph, name, tabular value, delta chip, and a quiet trailing sparkline.
///
/// A ROW rather than a grid tile on purpose — five vitals in a grid read as five unrelated
/// dashboards; five rows in one card read as a single list of measurements taken the same night,
/// which is exactly what they are.
private struct AuroraVitalRow: View {
    let readout: AuroraVitalReadout

    var body: some View {
        HStack(alignment: .center, spacing: Aurora.Space.s) {
            Image(systemName: readout.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(readout.tint)
                .frame(width: Aurora.Layout.glyphPlate, height: Aurora.Layout.glyphPlate)
                .background(Circle().fill(readout.tint.opacity(0.14)))

            VStack(alignment: .leading, spacing: 2) {
                Text(readout.label)
                    .auroraBodyStrong()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(readout.caption)
                    .auroraFootnote()
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Aurora.Space.xs)

            if readout.sparkline.count > 1 {
                AuroraSparkline(values: readout.sparkline,
                                tint: readout.tint,
                                lineWidth: 1.5,
                                showsArea: false,
                                showsHead: false)
                    .frame(width: 54, height: 22)
                    .opacity(0.8)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .trailing, spacing: 4) {
                AuroraValueUnit(value: readout.valueText ?? "—",
                                unit: readout.valueText == nil ? nil : readout.unit,
                                role: .metricSmall,
                                valueColor: readout.valueText == nil ? Aurora.textDisabled : Aurora.textPrimary)
                if let delta = readout.delta {
                    AuroraDeltaChip(delta, showsUnit: false)
                }
            }
        }
        .padding(.horizontal, Aurora.Space.cardPadding)
        .padding(.vertical, Aurora.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Scrubbable hypnogram

/// The night's architecture, made interrogable.
///
/// `AuroraHypnogram` draws the night; this wrapper adds the thing a static chart cannot do —
/// a playhead you drag to ask "what was I doing at 03:40?". The read-out sits ABOVE the chart
/// (never a floating tooltip under the finger), and the chart is drawn with no stage-label
/// gutter so the playhead's x maps exactly onto the plot's time axis.
private struct AuroraScrubbableHypnogram: View {
    let segments: [AuroraSleepSegment]
    let style: AuroraHypnogram.Style
    let height: CGFloat

    @State private var fraction: Double?

    private var span: (start: Date, end: Date)? {
        guard let first = segments.min(by: { $0.start < $1.start }),
              let last = segments.max(by: { $0.end < $1.end }),
              last.end > first.start else { return nil }
        return (first.start, last.end)
    }

    private var scrubbedTime: Date? {
        guard let span, let fraction else { return nil }
        return span.start.addingTimeInterval(span.end.timeIntervalSince(span.start) * fraction)
    }

    private var scrubbedStage: AuroraSleepStage? {
        guard let t = scrubbedTime else { return nil }
        return segments.first(where: { $0.start <= t && t < $0.end })?.stage
            ?? segments.last(where: { $0.start <= t })?.stage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.s) {
            readout

            AuroraHypnogram(segments: segments,
                            style: style,
                            height: height,
                            showsStageLabels: false,
                            showsLegend: false)
                .overlay(scrubLayer)
        }
    }

    private var readout: some View {
        HStack(alignment: .firstTextBaseline, spacing: Aurora.Space.xs) {
            if let stage = scrubbedStage, let t = scrubbedTime {
                Circle().fill(stage.color).frame(width: 8, height: 8)
                Text(stage.label).auroraBodyStrong()
                Text(t, format: .dateTime.hour().minute())
                    .auroraCaption()
                    .monospacedDigit()
            } else {
                Image(systemName: "hand.draw")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Aurora.textTertiary)
                Text("Drag across the night to read any moment")
                    .auroraCaption()
            }
            Spacer(minLength: 0)
        }
        .frame(height: 18)
        .accessibilityHidden(true)
    }

    private var scrubLayer: some View {
        GeometryReader { geo in
            let w = Swift.max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                Color.clear.contentShape(Rectangle())

                if let fraction {
                    Rectangle()
                        .fill(Aurora.textPrimary.opacity(0.55))
                        .frame(width: 1.5)
                        .offset(x: CGFloat(fraction) * w - 0.75)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        fraction = Double(Swift.min(Swift.max(value.location.x / w, 0), 1))
                    }
                    .onEnded { _ in fraction = nil }
            )
        }
    }
}

// MARK: - Stage row

/// One stage of the night: name, exact duration, whole percentage, and a track whose fill grows
/// on appear. The hairline marker is the user's own typical for that stage — the context that
/// turns "82 minutes of deep" into a judgement the reader can make.
private struct AuroraStageRow: View {
    let stage: AuroraSleepStage
    let minutes: Double
    let percent: Int
    let total: Double
    let typicalMinutes: Double?
    let index: Int

    @State private var shownFraction: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return Swift.min(Swift.max(minutes / total, 0), 1)
    }

    private var typicalFraction: Double? {
        guard total > 0, let typicalMinutes, typicalMinutes > 0 else { return nil }
        let f = typicalMinutes / total
        return f > 0.02 && f < 0.98 ? f : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Aurora.Space.xs) {
                Circle()
                    .fill(stage.color)
                    .frame(width: 8, height: 8)
                    .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 1 }
                Text(stage.label).auroraBodyStrong()
                Spacer(minLength: Aurora.Space.xs)
                Text(minutes > 0 ? auroraDurationText(minutes) : "—")
                    .auroraBodyStrong()
                    .foregroundStyle(minutes > 0 ? Aurora.textPrimary : Aurora.textDisabled)
                    .monospacedDigit()
                Text("\(percent)%")
                    .auroraCaption()
                    .monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
            }

            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Aurora.surfaceInset)
                        .frame(height: Aurora.Layout.trackHeight)

                    Capsule(style: .continuous)
                        .fill(LinearGradient(colors: [stage.color.opacity(0.72), stage.color],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: Swift.max(w * CGFloat(shownFraction), fraction > 0 ? 5 : 0),
                               height: Aurora.Layout.trackHeight)

                    if let typicalFraction {
                        Capsule(style: .continuous)
                            .fill(Aurora.textSecondary)
                            .frame(width: 2, height: Aurora.Layout.trackHeight + 6)
                            .offset(x: w * CGFloat(typicalFraction) - 1)
                            .opacity(0.65)
                    }
                }
                .frame(height: Aurora.Layout.trackHeight + 6)
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: Aurora.Layout.trackHeight + 6)
        }
        .onAppear {
            let animation = Aurora.Motion.curve(Aurora.Motion.durationSlow)
                .delay(Double(index) * 0.05)
            withAnimation(Aurora.Motion.respecting(animation, reduced: reduceMotion)) {
                shownFraction = fraction
            }
        }
        .onChangeCompat(of: fraction) { newValue in
            withAnimation(Aurora.Motion.respecting(Aurora.Motion.standard, reduced: reduceMotion)) {
                shownFraction = newValue
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(stage.label), \(auroraDurationText(minutes)), \(percent) percent"))
    }
}

// MARK: - Sleep-debt strip

/// The REAL rolling ledger (`SleepModel.sleepDebtLedger`, built by `SleepDebt.ledger`): the net
/// 14-night balance and the per-night deltas behind it, drawn either side of a zero rule so a
/// run of short nights is visible as a shape rather than read as a number.
private struct AuroraSleepDebtStrip: View {
    let ledger: SleepDebtLedger

    private var balanceColor: Color {
        if ledger.magnitudeMin < SleepDebt.onTargetBandMin { return Aurora.statusGood }
        return ledger.isDebt ? Aurora.statusCaution : Aurora.statusGood
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Aurora.Space.xs) {
                Text("ROLLING BALANCE").auroraSectionHeader()
                Spacer(minLength: Aurora.Space.xs)
                Text(AuroraFormat.signedDuration(ledger.balanceMin * 60))
                    .font(AuroraType.number(14, weight: .bold))
                    .foregroundStyle(balanceColor)
            }

            if ledger.nights.isEmpty {
                Text("No nights with usable sleep in the window yet.")
                    .auroraFootnote()
            } else {
                deltaBars
                Text("\(ledger.nightCount) nights against your \(auroraDurationText(ledger.needMin)) need. A surplus night offsets a short one.")
                    .auroraFootnote()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Rolling sleep balance"))
        .accessibilityValue(Text(AuroraFormat.signedDuration(ledger.balanceMin * 60)))
    }

    private var deltaBars: some View {
        let peak = Swift.max(ledger.nights.map { abs($0.deltaMin) }.max() ?? 1, 1)
        return HStack(alignment: .center, spacing: 3) {
            ForEach(Array(ledger.nights.enumerated()), id: \.offset) { _, night in
                let f = Swift.min(abs(night.deltaMin) / peak, 1)
                let h = Swift.max(CGFloat(f) * 17, 2)
                VStack(spacing: 0) {
                    ZStack(alignment: .bottom) {
                        Color.clear.frame(height: 17)
                        if night.deltaMin > 0 {
                            Capsule(style: .continuous)
                                .fill(Aurora.statusGood)
                                .frame(height: h)
                        }
                    }
                    Rectangle()
                        .fill(Aurora.hairlineStrong)
                        .frame(height: Aurora.Stroke.hairline)
                    ZStack(alignment: .top) {
                        Color.clear.frame(height: 17)
                        if night.deltaMin <= 0 {
                            Capsule(style: .continuous)
                                .fill(Aurora.statusCaution)
                                .frame(height: h)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 35)
    }
}

// MARK: - Thirty-night trend

/// One night on the trend chart: what was slept, and what was needed that night.
private struct AuroraSleepTrendPoint: Identifiable, Equatable {
    let day: String
    let date: Date
    let hours: Double?
    let needHours: Double

    var id: String { day }
}

/// Duration bars with the per-night NEED drawn straight over them.
///
/// Hand-drawn rather than Swift Charts, because a per-mark corner radius is not available on
/// macOS 13 and a squared-off bar is exactly the detail that makes a chart look unfinished. The
/// need line is a real per-night series (the export's `sleep_need_min` where it exists, the
/// personal mean elsewhere), so the gap between a bar and the line above it is the shortfall.
private struct AuroraSleepTrendChart: View {
    let points: [AuroraSleepTrendPoint]
    let selectedDay: String
    let height: CGFloat

    @State private var reveal: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var scaleTop: Double {
        let topBar = points.compactMap(\.hours).max() ?? 0
        let topNeed = points.map(\.needHours).max() ?? 0
        return Swift.max(Swift.max(topBar, topNeed) * 1.12, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.s) {
            legend

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let slot = w / CGFloat(Swift.max(points.count, 1))
                let barWidth = Swift.max(slot - 3, 2)

                ZStack(alignment: .bottomLeading) {
                    ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                        let isSelected = point.day == selectedDay
                        let value = point.hours ?? 0
                        let met = point.hours.map { $0 >= point.needHours - 0.25 } ?? false
                        let barHeight = CGFloat(Swift.min(value / scaleTop, 1)) * h * CGFloat(reveal)

                        RoundedRectangle(cornerRadius: Swift.min(barWidth / 2, 4), style: .continuous)
                            .fill(point.hours == nil
                                  ? AnyShapeStyle(Aurora.surfaceInset)
                                  : AnyShapeStyle(LinearGradient(
                                        colors: [Aurora.sleepColor(met ? 92 : 58).opacity(0.62),
                                                 Aurora.sleepColor(met ? 92 : 58)],
                                        startPoint: .bottom, endPoint: .top)))
                            .frame(width: barWidth,
                                   height: point.hours == nil ? 3 : Swift.max(barHeight, 2))
                            .opacity(isSelected || selectedDay.isEmpty ? 1 : 0.55)
                            .overlay(alignment: .bottom) {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: Swift.min(barWidth / 2, 4),
                                                     style: .continuous)
                                        .strokeBorder(Aurora.textPrimary.opacity(0.8), lineWidth: 1.5)
                                        .frame(width: barWidth,
                                               height: point.hours == nil ? 3 : Swift.max(barHeight, 2))
                                }
                            }
                            .offset(x: CGFloat(index) * slot + (slot - barWidth) / 2)
                    }

                    needPath(width: w, height: h)
                        .stroke(Aurora.statusCaution.opacity(0.9),
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 3]))
                        .opacity(reveal)
                }
                .frame(width: w, height: h, alignment: .bottomLeading)
            }
            .frame(height: height)

            axisLabels
        }
        .onAppear {
            withAnimation(Aurora.Motion.respecting(Aurora.Motion.drawIn, reduced: reduceMotion)) {
                reveal = 1
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Sleep duration over the last \(points.count) nights, with the nightly need"))
    }

    private func needPath(width: CGFloat, height: CGFloat) -> Path {
        var path = Path()
        guard !points.isEmpty else { return path }
        let slot = width / CGFloat(points.count)
        for (index, point) in points.enumerated() {
            let x = CGFloat(index) * slot + slot / 2
            let y = height - CGFloat(Swift.min(point.needHours / scaleTop, 1)) * height
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }

    private var legend: some View {
        HStack(spacing: Aurora.Space.s) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Aurora.sleepColor(92))
                    .frame(width: 10, height: 10)
                Text("Slept").auroraFootnote()
            }
            HStack(spacing: 5) {
                Capsule(style: .continuous)
                    .fill(Aurora.statusCaution)
                    .frame(width: 14, height: 2)
                Text("Need").auroraFootnote()
            }
            Spacer(minLength: 0)
            if let last = points.last(where: { $0.hours != nil }), let hours = last.hours {
                Text("\(auroraDurationText(hours * 60)) latest")
                    .auroraCaptionStrong()
                    .monospacedDigit()
            }
        }
        .accessibilityHidden(true)
    }

    private var axisLabels: some View {
        HStack(spacing: 0) {
            Text(points.first?.date ?? Date(), format: .dateTime.day().month(.abbreviated))
                .auroraFootnote()
            Spacer(minLength: 0)
            Text(points.last?.date ?? Date(), format: .dateTime.day().month(.abbreviated))
                .auroraFootnote()
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Local value types & helpers

/// Cheap, Equatable fingerprint of the repo inputs this screen derives from — the twin of
/// `SleepView`'s private `SleepInputKey`, field for field, so both screens rebuild on exactly
/// the same changes.
private struct AuroraSleepInputKey: Equatable {
    let loaded: Bool
    let daysCount: Int
    let sleepsCount: Int
    let firstDay: String?
    let lastDay: String?
    let lastDayUpdated: DailyMetric?
    let lastSleep: CachedSleepSession?
    let refreshSeq: Int
}

/// "7h 24m" / "48m" — the same duration wording the original screen uses.
private func auroraDurationText(_ minutes: Double) -> String {
    let m = Swift.max(0, Int(minutes.rounded()))
    if m < 60 { return String(localized: "\(m)m") }
    return String(localized: "\(m / 60)h \(m % 60)m")
}

/// Parse a stored `yyyy-MM-dd` day key into a Date for axis labelling. Fixed POSIX parsing, the
/// same shape `VitalBands.calendarSeries` uses; an unparseable key degrades to `.distantPast`
/// rather than silently shifting a label onto today.
private func auroraDate(fromDayKey key: String) -> Date {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.date(from: key) ?? .distantPast
}

/// Map the repository's stage vocabulary onto Aurora's four hypnogram hues.
private func auroraStage(_ stage: SleepStage) -> AuroraSleepStage {
    switch stage {
    case .awake: return .awake
    case .light: return .light
    case .deep:  return .deep
    case .rem:   return .rem
    }
}

/// Lay elapsed-seconds intervals onto wall-clock segments for the Aurora hypnogram.
private func auroraSegments(_ intervals: [SleepInterval], onset: Date) -> [AuroraSleepSegment] {
    intervals.compactMap { iv in
        guard iv.end > iv.start else { return nil }
        return AuroraSleepSegment(stage: auroraStage(iv.stage),
                                  start: onset.addingTimeInterval(iv.start),
                                  end: onset.addingTimeInterval(iv.end))
    }
}
