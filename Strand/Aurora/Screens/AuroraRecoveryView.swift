//  AuroraRecoveryView.swift
//  NOOP · Aurora design language — the RECOVERY pillar screen.
//
//  A NEW screen. Nothing in the shipping app looks like this: the original surfaces treat recovery as one
//  tile inside a dashboard, so "why is my Charge 46 today?" is answered — if at all — by a collapsed
//  breakdown three taps down. This screen inverts that information architecture. Recovery IS the screen:
//
//    1. A pinned DAY RAIL. The user is always looking at a specific day and the chrome says so at all
//       times, so the whole screen is a day-scoped instrument rather than a "now" dashboard.
//    2. ONE dominant statement — a single ring with the percentage rolling into its centre on a
//       full-bleed wash in the band's own colour, plus one plain-English coaching line. No grid, no
//       peer metrics, nothing competing. It collapses into a one-line summary as you read downward.
//    3. WHAT DROVE THIS — the intellectual core. One row per real contributor, each showing the value,
//       its recent shape, its signed distance from the wearer's OWN baseline, and where it sits inside
//       the typical range. This is the section that answers "why", and it is the reason the screen
//       exists.
//    4. 30-DAY TREND — the same number in context, scrubbable.
//    5. YOUR BASELINE — how much the app actually knows about this wearer yet, in the engine's own
//       vocabulary (nights folded, provisional vs trusted, stale).
//
//  ADDITIVE AND PRESENTATION-ONLY. Every number is read through the SAME accessors the shipping screens
//  use (`Repository.lastVitalsDay` / `lastRespDay` / `lastSkinTempDay`, `TodayView.freshRestScore`,
//  `TodayView.lastScoredRecoveryDay`, `LiquidTodayView.ChargeDisplay.resolve`) and every attribution is
//  the ENGINE'S OWN (`RecoveryScorer.chargeDrivers`, `Baselines.foldHistory` / `deviation` / `sigma`,
//  `ScoreConfidence.charge`). No score, no baseline and no driver delta is recomputed here; nothing is
//  written; the original screens are untouched.
//
//  PERF CONTRACT (the same one `AuroraHomeView` documents): `repo.days` is up to ~4000 rows. Every
//  O(days) scan — the row lookup, the carries, the three baseline folds, the driver list, the window
//  slices and the day pips — happens ONCE in `load()` and lands in a single `Snapshot`. `body` reads
//  only that snapshot.

import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - AuroraRecoveryView

/// The Aurora Recovery pillar screen.
@MainActor
struct AuroraRecoveryView: View {

    // MARK: Environment
    //
    // Only the Repository. This screen is strictly read-only: it never syncs, never scores and never
    // mutates, so it deliberately does NOT hold `LiveState` / `BLEManager` (a strap publishes at ~1 Hz
    // and would re-evaluate this whole body on every heartbeat).
    @EnvironmentObject var repo: Repository

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameter initialDayKey: the `yyyy-MM-dd` day to open on. `nil` opens on today, which is what
    ///   every entry point wants; a caller that pushes from a specific day (a trend scrub, a pip on the
    ///   overview) passes that day so the push lands where the user was already looking.
    init(initialDayKey: String? = nil) {
        _selectedDayKey = State(initialValue: initialDayKey ?? "")
    }

    // MARK: State

    /// The selected `yyyy-MM-dd`. Empty means "not chosen yet" and resolves to today, so the screen has
    /// a correct first frame without an `onAppear` write.
    @State private var selectedDayKey: String
    @State private var scrollOffset: CGFloat = 0
    @State private var snapshot = Snapshot()
    @State private var pips: [AuroraDayPip] = []
    @State private var guideSection: ScoreSection?

    private static let scrollSpace = "aurora.recovery.scroll"
    /// How many calendar days the rail offers. A month of context is what the trend section shows, so
    /// the rail and the chart agree on the horizon.
    private static let railDays = 30

    // MARK: - Day keys
    //
    // Two formatters on purpose. Pips are LOCAL-calendar dates because the rail asks the calendar for
    // the weekday initial and for "is this today"; chart points are UTC-parsed because that is how
    // `AuroraTrendsView` keys its axes, and two Aurora charts must not disagree about which tick is
    // which day.

    private static let localDayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let utcDayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The key the app itself calls "today" — `repo.today` already resolves the 04:00 logical-day
    /// rollover and the #304 local-day preference, so the rail cannot disagree with the rest of the app.
    private var todayKey: String { repo.today?.day ?? Repository.logicalDayKey(Date()) }

    private var activeDayKey: String { selectedDayKey.isEmpty ? todayKey : selectedDayKey }

    private var dayBinding: Binding<String> {
        Binding(get: { activeDayKey }, set: { selectedDayKey = $0 })
    }

    /// `key` shifted by `days` calendar days, in the local calendar. Pure key arithmetic: no stored key
    /// is ever rewritten.
    private static func shiftKey(_ key: String, by days: Int) -> String? {
        guard let d = localDayFmt.date(from: key),
              let s = Calendar.current.date(byAdding: .day, value: days, to: d) else { return nil }
        return localDayFmt.string(from: s)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            AuroraDayRail(days: pips, selection: dayBinding)
            scroller
        }
        .auroraCanvas()
        .auroraBandWash(snapshot.bandColor, intensity: snapshot.heroPct == nil ? 0.45 : 1.0)
        .navigationTitle(Text("Recovery"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: "\(repo.refreshSeq)-\(activeDayKey)") { await load() }
        .sheet(item: $guideSection) { section in
            NavigationStack {
                ScoringGuideView(initialSection: section, onClose: { guideSection = nil })
            }
        }
    }

    /// The one permanently-visible day stamp. DAY-CENTRIC: even with the hero scrolled away and the rail
    /// scrolled off its selection, the screen still says which day it is describing.
    private var titleBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: Aurora.Space.xs) {
            Text("RECOVERY")
                .auroraSectionHeader()
                .foregroundStyle(snapshot.bandColor)
            Spacer(minLength: Aurora.Space.xs)
            Text(dayStamp)
                .auroraCaptionStrong()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .auroraGutter()
        .padding(.top, Aurora.Space.xs)
        .padding(.bottom, Aurora.Space.xxs)
    }

    private var scroller: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                AuroraScrollOffsetProbe(space: Self.scrollSpace)

                AuroraCollapsingHero(offset: scrollOffset, collapseDistance: 190, compactHeight: 46) {
                    hero
                } compact: {
                    compactBar
                }

                driversSection
                    .padding(.top, Aurora.Space.xxl)

                trendSection
                    .padding(.top, Aurora.Space.xxl)

                baselineSection
                    .padding(.top, Aurora.Space.xxl)

                Color.clear.frame(height: Aurora.Space.tabBarClearance)
            }
            #if os(macOS)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            #endif
        }
        .auroraScrollSpace(Self.scrollSpace)
        .onAuroraScrollOffset { scrollOffset = $0 }
        #if os(iOS)
        .refreshable { await repo.refresh() }
        #endif
    }

    // MARK: - 2 · Hero

    private var hero: some View {
        VStack(spacing: Aurora.Space.l) {
            ZStack {
                // The ring draws no centre text of its own (`value: ""`, `emptyHint: ""`) so the rolling
                // numeral owns the middle. Its footprint is identical either way.
                AuroraRing(progress: snapshot.heroProgress,
                           value: "",
                           ramp: .recovery,
                           lineWidth: Aurora.Stroke.ring,
                           size: 244,
                           showsGlow: true,
                           showsTip: true,
                           emptyHint: "")

                VStack(spacing: Aurora.Space.xxs) {
                    Text(snapshot.bandWord)
                        .auroraSectionHeader()
                        .foregroundStyle(snapshot.heroPct == nil ? Aurora.textTertiary : snapshot.bandColor)

                    AuroraRollingNumber(value: snapshot.heroPct,
                                        unit: snapshot.heroPct == nil ? nil : "%",
                                        size: 78,
                                        color: snapshot.bandColor)

                    if let sub = snapshot.heroSubtitle {
                        Text(sub)
                            .auroraFootnote()
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(maxWidth: 150)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            snapshot.coach

            if !snapshot.heroPills.isEmpty {
                HStack(spacing: Aurora.Space.xs) {
                    ForEach(snapshot.heroPills) { pill in
                        AuroraStatusPill(pill.text, icon: pill.icon, style: .tinted,
                                         overrideColor: pill.color)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .auroraGutter()
        .padding(.top, Aurora.Space.m)
    }

    /// What the hero becomes once the user starts reading. Same three facts — band, number, day — in one
    /// line, so the verdict never leaves the screen.
    private var compactBar: some View {
        HStack(spacing: Aurora.Space.s) {
            Circle()
                .fill(snapshot.bandColor)
                .frame(width: 9, height: 9)
                .opacity(snapshot.heroPct == nil ? 0.4 : 1)

            Text(snapshot.bandWord)
                .auroraSectionHeader()
                .foregroundStyle(snapshot.bandColor)

            Text(snapshot.heroValueText)
                .font(AuroraType.number(20, weight: .bold))
                .foregroundStyle(snapshot.heroPct == nil ? Aurora.textTertiary : snapshot.bandColor)

            Spacer(minLength: Aurora.Space.xs)

            Text(dayStamp)
                .auroraCaption()
                .lineLimit(1)
        }
        .auroraGutter()
    }

    // MARK: - 3 · What drove this

    @ViewBuilder
    private var driversSection: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.s) {
            AuroraSectionHeader("What drove this", subtitle: snapshot.driversSubtitle)
                .auroraGutter()

            if snapshot.contributors.isEmpty {
                AuroraCard {
                    AuroraEmptyState(
                        icon: "waveform.path.ecg",
                        headline: String(localized: "No contributors yet"),
                        message: String(localized: "Recovery is built from your overnight HRV, resting heart rate, respiratory rate and sleep. None of them landed for this day."),
                        tint: Aurora.statusNeutral
                    )
                }
                .auroraGutter()
            } else {
                VStack(spacing: Aurora.Space.cardGap) {
                    ForEach(snapshot.contributors) { c in
                        AuroraRecoveryDriverCard(contributor: c)
                    }
                }
                .auroraGutter()

                if let note = snapshot.driversNote {
                    Text(note)
                        .auroraFootnote()
                        .fixedSize(horizontal: false, vertical: true)
                        .auroraGutter()
                        .padding(.top, Aurora.Space.xxs)
                }
            }
        }
    }

    // MARK: - 4 · 30-day trend

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.s) {
            AuroraSectionHeader("30-day trend", subtitle: snapshot.trendSubtitle)
                .auroraGutter()

            AuroraCard(padding: Aurora.Space.m, radius: Aurora.Radius.card, tint: snapshot.bandColor) {
                AuroraTrendChart(
                    points: snapshot.recoveryPoints,
                    title: String(localized: "RECOVERY"),
                    ramp: .recovery,
                    unit: "%",
                    decimals: 0,
                    showsArea: true,
                    height: 210,
                    yDomain: 0...100,
                    emptyHeadline: String(localized: "Not enough scored days"),
                    emptyMessage: String(localized: "Two scored nights inside this window and the trend fills in.")
                )
            }
            .auroraGutter()

            if !snapshot.hrvPoints.isEmpty {
                AuroraCard(padding: Aurora.Space.m) {
                    AuroraTrendChart(
                        points: snapshot.hrvPoints,
                        title: String(localized: "HEART RATE VARIABILITY"),
                        tint: Aurora.accent,
                        unit: "ms",
                        decimals: 0,
                        showsArea: true,
                        height: 150,
                        emptyHeadline: String(localized: "No HRV history"),
                        emptyMessage: nil
                    )
                }
                .auroraGutter()
                .padding(.top, Aurora.Space.cardGap)
            }
        }
    }

    // MARK: - 5 · Your baseline

    private var baselineSection: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.s) {
            AuroraSectionHeader("Your baseline",
                                subtitle: String(localized: "What the score is measured against"),
                                actionTitle: String(localized: "How it works"),
                                action: { guideSection = .charge })
                .auroraGutter()

            AuroraCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(snapshot.baselines) { b in
                        AuroraRecoveryBaselineRow(item: b)
                            .padding(Aurora.Space.cardPadding)
                        if b.id != snapshot.baselines.last?.id {
                            AuroraDivider(inset: Aurora.Space.cardPadding)
                        }
                    }

                    if snapshot.baselines.isEmpty {
                        Text("No nights have been folded into a baseline yet.")
                            .auroraCaption()
                            .padding(Aurora.Space.cardPadding)
                    }
                }
            }
            .auroraGutter()

            VStack(alignment: .leading, spacing: Aurora.Space.xs) {
                ForEach(snapshot.baselineNotes, id: \.self) { note in
                    HStack(alignment: .top, spacing: Aurora.Space.xs) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 4))
                            .foregroundStyle(Aurora.textTertiary)
                            .padding(.top, 6)
                        Text(note)
                            .auroraFootnote()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .auroraGutter()
            .padding(.top, Aurora.Space.xs)
        }
    }

    // MARK: - Day stamp

    private var dayStamp: String {
        guard let d = Self.localDayFmt.date(from: activeDayKey) else { return activeDayKey }
        let cal = Calendar.current
        if activeDayKey == todayKey { return String(localized: "Today") + " · " + d.formatted(.dateTime.day().month(.abbreviated)) }
        if cal.isDateInYesterday(d) { return String(localized: "Yesterday") + " · " + d.formatted(.dateTime.day().month(.abbreviated)) }
        return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    // MARK: - Load
    //
    // Everything O(days) happens exactly once, here.

    private func load() async {
        let key = activeDayKey
        let days = repo.days
        let tKey = todayKey
        let isToday = (key == tKey)

        // ── The row for the selected day ────────────────────────────────────────────────
        let row: DailyMetric? = isToday
            ? (repo.today ?? days.last(where: { $0.day == key }))
            : days.last(where: { $0.day == key })
        let anchor = row?.day ?? key

        // ── Carries. A carry only ever applies to TODAY: a past day shows what that day had. ──
        let vitalsDay = isToday ? Repository.lastVitalsDay(days: days, todayKey: anchor) : nil
        let respDay   = isToday ? Repository.lastRespDay(days: days, todayKey: anchor) : nil
        let skinDay   = isToday ? Repository.lastSkinTempDay(days: days, todayKey: anchor) : nil

        let hrv  = row?.avgHrv ?? vitalsDay?.avgHrv
        let rhr  = (row?.restingHr ?? vitalsDay?.restingHr).map(Double.init)
        let resp = row?.respRateBpm ?? respDay?.respRateBpm
        let skin = row?.skinTempDevC ?? skinDay?.skinTempDevC

        // ── Charge state, resolved by the SAME truth table the Liquid screen uses ────────
        let calNights = isToday
            ? RecoveryScorer.calibrationNights(nightlyHrv: days.map(\.avgHrv),
                                               dayKeys: days.map(\.day),
                                               hasRecovery: row?.recovery != nil)
            : nil
        let priorScored = TodayView.lastScoredRecoveryDay(
            days: days, selectedDayKey: anchor,
            isToday: isToday,
            todayScored: row?.recovery != nil,
            isCalibrating: calNights != nil)
        let charge = LiquidTodayView.ChargeDisplay.resolve(
            todayRecovery: row?.recovery,
            priorScored: priorScored,
            calibrationNights: calNights,
            todayKey: anchor)

        // ── Personal baselines ──────────────────────────────────────────────────────────
        //
        // Folded over the nights UP TO AND INCLUDING the selected day. The engine's own call sites fold
        // the whole array because they only ever render today; this screen is day-navigable, so folding
        // nights that had not happened yet would judge a past day against a future baseline. Same API,
        // same config, same fold — only the input window is honest about the day on screen.
        let history = days.filter { $0.day <= anchor }
        let hrvBase  = Baselines.foldHistory(history.map(\.avgHrv), cfg: Baselines.hrvCfg)
        let rhrBase  = Baselines.foldHistory(history.map { $0.restingHr.map(Double.init) },
                                             cfg: Baselines.restingHRCfg)
        let respBase = Baselines.foldHistory(history.map(\.respRateBpm), cfg: Baselines.respCfg)

        // ── Windows ─────────────────────────────────────────────────────────────────────
        let trendCutoff = Self.shiftKey(anchor, by: -(Self.railDays - 1)) ?? anchor
        let window = days.filter { $0.day >= trendCutoff && $0.day <= anchor }

        let railCutoff = Self.shiftKey(tKey, by: -(Self.railDays - 1)) ?? tKey
        let railRows = days.filter { $0.day >= railCutoff && $0.day <= tKey }

        // ── The Rest composite. Series-backed and async; it is not a DailyMetric field. ──
        let restSeries = await repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        let restScore = TodayView.freshRestScore(
            todayValue: restByDay[key],
            lastDay: restSeries.last?.day,
            lastValue: restSeries.last?.value,
            isTodaySelected: isToday,
            todayKey: key)

        // ── The engine's own attribution. Never recomputed here. ────────────────────────
        var driverByLabel: [String: ChargeDriver] = [:]
        if let hrv, let rhr {
            let list = RecoveryScorer.chargeDrivers(
                hrv: hrv,
                rhr: rhr,
                resp: resp,
                hrvBaseline: hrvBase,
                rhrBaseline: rhrBase.usable ? rhrBase : nil,
                respBaseline: respBase.usable ? respBase : nil,
                sleepPerf: restScore.map { $0 / 100.0 },
                skinTempDev: skin)
            driverByLabel = Dictionary(list.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })
        }

        // ── Assemble ────────────────────────────────────────────────────────────────────
        var snap = Snapshot()
        snap.dayKey = anchor
        snap.isToday = isToday
        snap.charge = charge
        snap.confidence = ScoreConfidence.charge(recovery: row?.recovery, hrvBaseline: hrvBase)
        snap.calibrationNights = calNights
        snap.staleNights = Baselines.nightsSinceNewestValidNight(
            dayKeys: days.map(\.day), nightlyHrv: days.map(\.avgHrv), today: anchor)

        snap.recoveryPoints = window.compactMap { d in
            guard let v = d.recovery, let dt = Self.utcDayFmt.date(from: d.day) else { return nil }
            return AuroraPoint(date: dt, value: v)
        }
        snap.hrvPoints = window.compactMap { d in
            guard let v = d.avgHrv, let dt = Self.utcDayFmt.date(from: d.day) else { return nil }
            return AuroraPoint(date: dt, value: v)
        }

        snap.contributors = Self.buildContributors(
            hrv: hrv, rhr: rhr, resp: resp, skin: skin, rest: restScore,
            hrvBase: hrvBase, rhrBase: rhrBase, respBase: respBase,
            window: window,
            restWindow: restSeries.filter { $0.day >= trendCutoff && $0.day <= anchor }.map { $0.value },
            drivers: driverByLabel)

        snap.baselines = Self.buildBaselines(hrv: hrvBase, rhr: rhrBase, resp: respBase)
        snap.hasDriverAttribution = !driverByLabel.isEmpty
        snap.loaded = true

        // ── The rail ────────────────────────────────────────────────────────────────────
        var recoveryByDay: [String: Double] = [:]
        for r in railRows { if let v = r.recovery { recoveryByDay[r.day] = v } }
        var built: [AuroraDayPip] = []
        if let end = Self.localDayFmt.date(from: tKey) {
            let cal = Calendar.current
            for i in stride(from: Self.railDays - 1, through: 0, by: -1) {
                guard let d = cal.date(byAdding: .day, value: -i, to: end) else { continue }
                let k = Self.localDayFmt.string(from: d)
                built.append(AuroraDayPip(dayKey: k, date: d, recovery: recoveryByDay[k]))
            }
        }

        pips = built
        snapshot = snap
    }

    // MARK: - Contributor assembly (pure)

    private static func buildContributors(
        hrv: Double?, rhr: Double?, resp: Double?, skin: Double?, rest: Double?,
        hrvBase: BaselineState, rhrBase: BaselineState, respBase: BaselineState,
        window: [DailyMetric],
        restWindow: [Double],
        drivers: [String: ChargeDriver]
    ) -> [AuroraRecoveryContributor] {

        var out: [AuroraRecoveryContributor] = []

        // HRV — the dominant term (RecoveryScorer.wHRV == 0.55).
        out.append(vitalContributor(
            id: "hrv",
            label: String(localized: "Heart rate variability"),
            icon: "waveform.path.ecg",
            weight: RecoveryScorer.wHRV,
            value: hrv,
            unit: "ms",
            decimals: 0,
            higherIsBetter: true,
            state: hrvBase,
            cfg: Baselines.hrvCfg,
            history: window.compactMap(\.avgHrv),
            driver: drivers["Heart rate variability"],
            missing: String(localized: "No overnight HRV for this day.")))

        // Resting heart rate.
        out.append(vitalContributor(
            id: "rhr",
            label: String(localized: "Resting heart rate"),
            icon: "heart.fill",
            weight: RecoveryScorer.wRHR,
            value: rhr,
            unit: "bpm",
            decimals: 0,
            higherIsBetter: false,
            state: rhrBase,
            cfg: Baselines.restingHRCfg,
            history: window.compactMap { $0.restingHr.map(Double.init) },
            driver: drivers["Resting heart rate"],
            missing: String(localized: "No resting heart rate for this day.")))

        // Respiratory rate.
        out.append(vitalContributor(
            id: "resp",
            label: String(localized: "Respiratory rate"),
            icon: "lungs.fill",
            weight: RecoveryScorer.wResp,
            value: resp,
            unit: "br/min",
            decimals: 1,
            higherIsBetter: false,
            state: respBase,
            cfg: Baselines.respCfg,
            history: window.compactMap(\.respRateBpm),
            driver: drivers["Respiratory rate"],
            missing: String(localized: "No respiratory rate for this day.")))

        // Sleep performance — the Rest composite. It has no LEARNED baseline: the engine centres it on a
        // fixed "good night" (`RecoveryScorer.sleepPerfCenter`), so the band on the track is that centre,
        // labelled honestly, not a fabricated personal range.
        let centre = RecoveryScorer.sleepPerfCenter * 100
        var sleep = AuroraRecoveryContributor(
            id: "sleep",
            label: String(localized: "Sleep performance"),
            icon: "moon.zzz.fill",
            weightText: weightText(RecoveryScorer.wSleep),
            value: rest,
            valueText: rest.map { num($0, 0) } ?? "—",
            unit: rest == nil ? nil : "%",
            history: restWindow,
            sparkTint: Aurora.sleepColor(72),
            missingHint: String(localized: "No sleep score for this night."))
        if let rest {
            sleep.delta = AuroraDelta(rest - centre, unit: "%", decimals: 0, higherIsBetter: true)
            sleep.track = 0...100
            sleep.typical = centre...100
            sleep.typicalLabel = String(localized: "Good night")
            sleep.typicalDecimals = 0
            sleep.typicalUnit = "%"
            sleep.referenceText = String(localized: "\(num(centre, 0))% is a full night")
        }
        if let d = drivers["Sleep quality"] {
            sleep.deltaPoints = d.deltaPoints
            sleep.verdict = localized(d.verdict)
            sleep.accessibility = ChargeBreakdownFormat.driverAccessibilityLabel(d)
        }
        out.append(sleep)

        // Skin temperature — a DEVIATION, so it gets no up/down delta chip (drift in either direction
        // costs the same points). It gets the engine's own relative tier instead.
        if let skin {
            var st = AuroraRecoveryContributor(
                id: "skin",
                label: String(localized: "Skin temperature"),
                icon: "thermometer.medium",
                weightText: weightText(RecoveryScorer.wSkinTemp),
                value: skin,
                valueText: (skin >= 0 ? "+" : "−") + num(abs(skin), 1),
                unit: "°C",
                history: window.compactMap(\.skinTempDevC),
                sparkTint: Aurora.statusCaution,
                missingHint: nil)
            let band = RecoveryScorer.skinTempTypicalBandC
            st.track = -1.5...1.5
            st.typical = (-band)...band
            st.typicalLabel = String(localized: "Typical")
            st.typicalDecimals = 1
            st.typicalUnit = "°C"
            st.referenceText = String(localized: "Deviation from your baseline")
            if let rel = RecoveryScorer.skinTempRelative(deviationC: skin) {
                st.badge = ChargeBreakdownFormat.skinTempTierWord(rel.tier)
            }
            if let d = drivers["Skin temperature"] {
                st.deltaPoints = d.deltaPoints
                st.verdict = localized(d.verdict)
                st.accessibility = ChargeBreakdownFormat.driverAccessibilityLabel(d)
            }
            out.append(st)
        }

        // Biggest mover first where the engine attributed one; unattributed rows keep their declared
        // order behind them, so the section always opens with what actually moved the number.
        return out.enumerated()
            .sorted { a, b in
                let am = a.element.deltaPoints.map { abs($0) } ?? -1
                let bm = b.element.deltaPoints.map { abs($0) } ?? -1
                return am != bm ? am > bm : a.offset < b.offset
            }
            .map(\.element)
    }

    /// One contributor backed by a LEARNED personal baseline (HRV / resting HR / respiration).
    private static func vitalContributor(
        id: String, label: String, icon: String, weight: Double,
        value: Double?, unit: String, decimals: Int, higherIsBetter: Bool,
        state: BaselineState, cfg: MetricCfg,
        history: [Double], driver: ChargeDriver?, missing: String
    ) -> AuroraRecoveryContributor {

        var c = AuroraRecoveryContributor(
            id: id,
            label: label,
            icon: icon,
            weightText: weightText(weight),
            value: value,
            valueText: value.map { num($0, decimals) } ?? "—",
            unit: value == nil ? nil : unit,
            history: history,
            sparkTint: higherIsBetter ? Aurora.statusGood : Aurora.accent,
            missingHint: value == nil ? missing : nil)

        if state.usable {
            let sigma = Baselines.sigma(state)
            var lo = max(cfg.minVal, state.baseline - 4 * sigma)
            var hi = min(cfg.maxVal, state.baseline + 4 * sigma)
            // Keep the reading on the track: a genuinely extreme night must be visible sitting outside
            // the typical band, not pinned to the end cap where it reads as "just at the edge".
            if let v = value {
                let pad = max((hi - lo) * 0.06, sigma * 0.5)
                lo = min(lo, v - pad)
                hi = max(hi, v + pad)
            }
            let tLo = max(lo, state.baseline - VitalBands.sigmaK * sigma)
            let tHi = min(hi, state.baseline + VitalBands.sigmaK * sigma)
            if hi > lo, tHi > tLo {
                c.track = lo...hi
                c.typical = tLo...tHi
                c.typicalLabel = String(localized: "Typical")
                c.typicalDecimals = decimals
                c.typicalUnit = unit
            }
            c.referenceText = String(localized: "\(num(state.baseline, decimals)) \(unit) baseline")
            if let v = value {
                let dev = Baselines.deviation(v, state: state)
                c.delta = AuroraDelta(dev.delta, unit: unit, decimals: decimals,
                                      higherIsBetter: higherIsBetter)
            }
        } else {
            c.referenceText = String(localized: "Baseline still forming — \(state.nValid) of \(Baselines.minNightsSeed) nights")
        }

        if let driver {
            c.deltaPoints = driver.deltaPoints
            c.verdict = localized(driver.verdict)
            c.accessibility = ChargeBreakdownFormat.driverAccessibilityLabel(driver)
        }
        return c
    }

    private static func buildBaselines(hrv: BaselineState, rhr: BaselineState,
                                       resp: BaselineState) -> [AuroraRecoveryBaselineItem] {
        [
            AuroraRecoveryBaselineItem(id: "hrv", label: String(localized: "Heart rate variability"),
                                       state: hrv, unit: "ms", decimals: 0),
            AuroraRecoveryBaselineItem(id: "rhr", label: String(localized: "Resting heart rate"),
                                       state: rhr, unit: "bpm", decimals: 0),
            AuroraRecoveryBaselineItem(id: "resp", label: String(localized: "Respiratory rate"),
                                       state: resp, unit: "br/min", decimals: 1),
        ]
    }

    // MARK: - Formatting helpers (pure)

    fileprivate static func num(_ v: Double, _ decimals: Int) -> String {
        decimals > 0
            ? String(format: "%.\(decimals)f", locale: Locale(identifier: "en_US_POSIX"), v)
            : String(Int(v.rounded()))
    }

    /// The engine's driver `label` / `verdict` strings are runtime localization KEYS (see the contract
    /// note in `ChargeDrivers.swift`), so they are looked up rather than printed raw.
    fileprivate static func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key))
    }

    private static func weightText(_ w: Double) -> String {
        String(localized: "\(Int((w * 100).rounded()))% of the model")
    }
}

// MARK: - Snapshot

/// Everything `body` reads, resolved once per `load()`.
private struct Snapshot {
    var dayKey: String = ""
    var isToday: Bool = true
    var charge: LiquidTodayView.ChargeDisplay = .noData
    var confidence: ScoreConfidence = .calibrating
    var calibrationNights: Int? = nil
    var staleNights: Int? = nil
    var contributors: [AuroraRecoveryContributor] = []
    var baselines: [AuroraRecoveryBaselineItem] = []
    var recoveryPoints: [AuroraPoint] = []
    var hrvPoints: [AuroraPoint] = []
    var hasDriverAttribution = false
    var loaded = false

    // MARK: Hero derivations

    var heroPct: Double? { charge.pct }
    var heroProgress: Double? { heroPct.map { min(max($0 / 100, 0), 1) } }
    var bandColor: Color { heroPct.map { Aurora.recoveryColor($0) } ?? Aurora.statusNeutral }
    var bandWord: String {
        guard let p = heroPct else {
            if case .calibrating = charge { return String(localized: "CALIBRATING") }
            return String(localized: "NO READING")
        }
        return AuroraRecoveryBand(pct: p).label
    }
    var heroValueText: String { heroPct.map { "\(Int($0.rounded()))%" } ?? "—" }

    /// The quiet line inside the ring: what state the number is in, never a second number.
    var heroSubtitle: String? {
        switch charge {
        case .scored: return nil
        case .carried(_, let caption): return caption
        case .calibrating(let n): return String(localized: "\(n) of \(Baselines.minNightsSeed) nights")
        case .noData: return nil
        }
    }

    /// The interpretive line under the hero. House copy comes from `AuroraCoachLine.forRecovery`, so this
    /// screen and the overview can never give the same score two different verdicts; only the calibrating
    /// state — which the shared factory has no way to know about — supplies its own sentence.
    var coach: AuroraCoachLine {
        if case .calibrating(let n) = charge {
            return AuroraCoachLine(
                String(localized: "Still learning. Your first Charge unlocks after \(Baselines.minNightsSeed) nights, and \(n) are banked."),
                emphasis: String(localized: "Still learning."),
                tint: Aurora.statusCaution,
                icon: "hourglass",
                size: 16)
        }
        return AuroraCoachLine.forRecovery(heroPct)
    }

    struct Pill: Identifiable {
        let id: String
        let text: String
        let icon: String?
        let color: Color
    }

    var heroPills: [Pill] {
        var out: [Pill] = []
        out.append(Pill(id: "state", text: charge.stateLabel, icon: nil,
                        color: heroPct == nil ? Aurora.statusNeutral : bandColor))
        if heroPct != nil {
            out.append(Pill(id: "confidence",
                            text: ChargeBreakdownFormat.tierTag(confidence),
                            icon: nil,
                            color: confidence == .solid ? Aurora.statusGood : Aurora.statusCaution))
        }
        if let stale = staleNights, stale > Baselines.staleDays {
            out.append(Pill(id: "stale",
                            text: String(localized: "\(stale) days since a night"),
                            icon: "exclamationmark.triangle.fill",
                            color: Aurora.statusCaution))
        }
        return out
    }

    // MARK: Section subtitles

    var driversSubtitle: String {
        if hasDriverAttribution {
            return String(localized: "Each term's real contribution, in points")
        }
        if case .calibrating = charge {
            return String(localized: "What is measured while the baseline forms")
        }
        return String(localized: "The measurements behind the score")
    }

    var driversNote: String? {
        guard hasDriverAttribution else { return nil }
        return String(localized: "The score is not a sum: each figure is what that term was worth on its own, measured against your personal baseline. Biggest mover first.")
    }

    var trendSubtitle: String {
        let n = recoveryPoints.count
        return n == 1
            ? String(localized: "1 scored day")
            : String(localized: "\(n) scored days")
    }

    var baselineNotes: [String] {
        var out: [String] = [
            String(localized: "A baseline needs \(Baselines.minNightsSeed) nights before Charge can be scored at all, and \(Baselines.minNightsTrust) before it is treated as trusted."),
            String(localized: "It is a recency-weighted centre, not an average of everything: recent nights count for more, and one wild night is folded in gently rather than allowed to move it."),
        ]
        if let stale = staleNights, stale > Baselines.staleDays {
            out.append(String(localized: "No new night has reached your baseline for \(stale) days, so it is marked stale and the score leans on older evidence."))
        }
        return out
    }
}

// MARK: - Driver card

private struct AuroraRecoveryDriverCard: View {

    let contributor: AuroraRecoveryContributor

    var body: some View {
        AuroraCard(elevation: .base, padding: Aurora.Space.cardPadding, tint: pointsColor) {
            VStack(alignment: .leading, spacing: Aurora.Space.s) {

                // Header — the term, its weight in the model, and the engine's signed points.
                HStack(alignment: .firstTextBaseline, spacing: Aurora.Space.xs) {
                    Image(systemName: contributor.icon)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(pointsColor)
                    Text(contributor.label)
                        .auroraBodyStrong()
                    Spacer(minLength: Aurora.Space.xs)
                    if let p = contributor.deltaPoints {
                        AuroraStatusPill(ChargeBreakdownFormat.chipLabel(deltaPoints: p),
                                         style: .tinted, overrideColor: pointsColor)
                    } else if let badge = contributor.badge {
                        AuroraStatusPill(badge, style: .tinted, overrideColor: Aurora.statusNeutral)
                    }
                }

                // Value · shape · distance from baseline.
                HStack(alignment: .center, spacing: Aurora.Space.s) {
                    AuroraValueUnit(value: contributor.valueText,
                                    unit: contributor.unit,
                                    role: .metricMedium,
                                    valueColor: contributor.value == nil ? Aurora.textDisabled : Aurora.textPrimary)

                    Spacer(minLength: Aurora.Space.xs)

                    if contributor.history.count > 1 {
                        AuroraSparkline(values: contributor.history,
                                        tint: contributor.sparkTint,
                                        lineWidth: Aurora.Stroke.line,
                                        showsArea: true,
                                        showsHead: true)
                            .frame(width: 88, height: 30)
                    }

                    if let delta = contributor.delta {
                        AuroraDeltaChip(delta)
                    }
                }

                // Where the reading sits inside the wearer's own normal.
                if let track = contributor.track, let typical = contributor.typical {
                    AuroraRangeBar(value: contributor.value,
                                   bounds: track,
                                   typical: typical,
                                   tint: pointsColor,
                                   unit: contributor.typicalUnit,
                                   decimals: contributor.typicalDecimals,
                                   showsScale: true,
                                   typicalLabel: contributor.typicalLabel,
                                   emptyHint: contributor.missingHint ?? String(localized: "No reading"))
                }

                // The engine's plain-English read, and what it was measured against.
                VStack(alignment: .leading, spacing: 2) {
                    if let verdict = contributor.verdict {
                        Text(verdict.prefix(1).uppercased() + String(verdict.dropFirst()))
                            .auroraCaption()
                            .foregroundStyle(Aurora.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let hint = contributor.missingHint {
                        Text(hint)
                            .auroraCaption()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: Aurora.Space.xs) {
                        if let ref = contributor.referenceText {
                            Text(ref).auroraFootnote()
                        }
                        Spacer(minLength: 0)
                        Text(contributor.weightText).auroraFootnote()
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(contributor.accessibility ?? defaultAccessibility))
    }

    private var pointsColor: Color {
        guard let p = contributor.deltaPoints, p != 0 else {
            return contributor.value == nil ? Aurora.textDisabled : Aurora.statusNeutral
        }
        // The recovery ramp's own end stops, so a supporting term reads in the same green the ring uses
        // at its peak and a limiting term in the same red it uses at the floor.
        return p > 0 ? Aurora.recoveryColor(96) : Aurora.recoveryColor(4)
    }

    private var defaultAccessibility: String {
        var parts = [contributor.label, contributor.valueText]
        if let u = contributor.unit { parts.append(u) }
        if let r = contributor.referenceText { parts.append(r) }
        if let h = contributor.missingHint, contributor.value == nil { parts.append(h) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Contributor model

private struct AuroraRecoveryContributor: Identifiable {
    let id: String
    let label: String
    let icon: String
    let weightText: String
    let value: Double?
    let valueText: String
    let unit: String?
    let history: [Double]
    let sparkTint: Color
    let missingHint: String?

    var delta: AuroraDelta? = nil
    var track: ClosedRange<Double>? = nil
    var typical: ClosedRange<Double>? = nil
    var typicalLabel: String = ""
    var typicalUnit: String? = nil
    var typicalDecimals: Int = 0
    var referenceText: String? = nil
    var deltaPoints: Int? = nil
    var verdict: String? = nil
    var badge: String? = nil
    var accessibility: String? = nil
}

// MARK: - Baseline row

private struct AuroraRecoveryBaselineItem: Identifiable {
    let id: String
    let label: String
    let state: BaselineState
    let unit: String
    let decimals: Int
}

private struct AuroraRecoveryBaselineRow: View {

    let item: AuroraRecoveryBaselineItem

    var body: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Aurora.Space.xs) {
                Text(item.label).auroraBodyStrong()
                Spacer(minLength: Aurora.Space.xs)
                AuroraStatusPill(statusWord, style: .tinted, overrideColor: statusColor)
            }

            HStack(alignment: .firstTextBaseline, spacing: Aurora.Space.xs) {
                if item.state.nValid > 0 {
                    AuroraValueUnit(value: AuroraRecoveryView.num(item.state.baseline, item.decimals),
                                    unit: item.unit,
                                    role: .metricSmall)
                } else {
                    AuroraValueUnit(value: "—", unit: nil, role: .metricSmall,
                                    valueColor: Aurora.textDisabled)
                }
                Spacer(minLength: Aurora.Space.xs)
                Text(nightsText).auroraFootnote()
            }

            // Progress toward TRUSTED. Reads as evidence accumulating, not as a loading bar.
            GeometryReader { geo in
                let w = geo.size.width
                let seed = CGFloat(Baselines.minNightsSeed) / CGFloat(Baselines.minNightsTrust)
                let f = min(CGFloat(item.state.nValid) / CGFloat(Baselines.minNightsTrust), 1)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Aurora.surfaceInset)
                        .frame(height: 6)
                    Capsule(style: .continuous)
                        .fill(statusColor)
                        .frame(width: max(w * f, f > 0 ? 4 : 0), height: 6)
                    // The seed gate — the point at which a score can exist at all.
                    Rectangle()
                        .fill(Aurora.hairlineStrong)
                        .frame(width: 1, height: 10)
                        .offset(x: w * seed)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 12)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusWord: String {
        switch item.state.status {
        case .calibrating: return String(localized: "CALIBRATING")
        case .provisional: return String(localized: "PROVISIONAL")
        case .trusted:     return String(localized: "TRUSTED")
        case .stale:       return String(localized: "STALE")
        }
    }

    private var statusColor: Color {
        switch item.state.status {
        case .calibrating: return Aurora.statusNeutral
        case .provisional: return Aurora.statusCaution
        case .trusted:     return Aurora.statusGood
        case .stale:       return Aurora.statusAlert
        }
    }

    private var nightsText: String {
        let n = item.state.nValid
        if n >= Baselines.minNightsTrust {
            return n == 1
                ? String(localized: "1 night folded in")
                : String(localized: "\(n) nights folded in")
        }
        return String(localized: "\(n) of \(Baselines.minNightsTrust) nights")
    }
}
