//  AuroraStrainView.swift
//  NOOP · Aurora design language — the Strain / Effort PILLAR screen.
//
//  ADDITIVE. Nothing in the original app is touched: this screen does not exist outside the Aurora
//  fork, and every number it draws comes from the SAME public accessors the shipped screens read
//  (`Repository`, `StrainScorer`, `HRZones`, `WorkoutZones`, `UnitFormatter`). No scoring, no business
//  logic and no persistence is re-implemented or altered here — this file is presentation only.
//
//  WHY THIS IS A DIFFERENT SCREEN, NOT A RESTYLE
//  --------------------------------------------
//  The classic surfaces show Effort as one tile among many, inside a scroll of equal-weight cards, on
//  a screen whose subject is "today" in general. This screen inverts that:
//
//    • The DAY is chrome. A pinned `AuroraDayRail` sits above everything; the user is always looking at
//      one specific day and the rail says which, permanently. Scrolling never loses it.
//    • ONE dominant statement. The screen opens on a single arc + a 92pt rolling numeral and a plain
//      English coaching line. There is no grid at the top of this screen, and nothing competes with the
//      number. As the user reads downward the hero collapses into a one-line inline bar that keeps the
//      value available without owning the screen.
//    • COLOUR IS DATA. The whole canvas carries a band wash sampled from the day's own effort ramp, so
//      a hard day and a rest day are different colours from across a room before a digit is read.
//    • The body is a NARRATIVE, not a dashboard: how the load ARRIVED (accumulation) → what INTENSITY it
//      was made of (zones) → which SESSIONS produced it (activities) → where it SITS in the last month
//      (trend). Each section answers the question the previous one raises.
//
//  HONESTY RULES APPLIED HERE
//  --------------------------
//    • The accumulation curve is REBUILT from this day's own heart-rate stream by replaying the SAME
//      public scorer (`StrainScorer.strain`) over growing prefixes of the 1-minute means. It is labelled
//      as a shape, not as a second score, and when no HR was banked the section degrades to an honest
//      empty state instead of inventing a series.
//    • Zones come from the day's raw HR through `HRZones.timeInZone` against the user's OWN
//      `profile.hrZoneSet` — the same display-zone model live HR, workout splits and haptic coaching
//      use. When the day banked no HR, the bar falls back to imported per-workout `zonesJSON` and SAYS
//      SO ("logged sessions only"). Provenance is always on screen.
//    • The hero value is `StrainScorer.effectiveEffort(live:stored:)` — the shared never-drop floor, so
//      this screen cannot disagree with the Today hero or the Key Metrics tile.

import SwiftUI
import Charts
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopProtocol
import WhoopStore

// MARK: - AuroraStrainView

/// The Aurora Strain pillar screen. Day-centric, hero-led, progressive-disclosure.
@MainActor
struct AuroraStrainView: View {

    // MARK: Environment — the same objects the Aurora Home screen declares

    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: Preferences — the real, shipped keys

    /// #268. Display-only: the stored Effort is always 0–100; this picks the axis it is DRAWN on.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    /// The top of the gauge and of the 30-day axis, on the user's chosen scale.
    private var gaugeMax: Double { effortScale == .whoop ? 21 : 100 }
    private var effortDecimals: Int { effortScale == .whoop ? 1 : 0 }

    // MARK: Day selection

    /// 0 = today (logical day, 04:00 rollover), N = N days back. The rail writes this through a key.
    @State private var selectedDayOffset = 0

    // MARK: Scroll-linked hero

    private static let scrollSpace = "aurora.strain.scroll"
    @State private var scrollOffset: CGFloat = 0

    // MARK: Async-loaded state — resolved once per (day, refreshSeq), never in `body`

    /// Live, in-progress Effort recomputed from THIS day's raw HR with the same recipe the daily pass
    /// uses. `nil` below the scorer's data gate. Only meaningful for today.
    @State private var liveEffort: Double?
    /// The rebuilt accumulation curve, on the STORED 0–100 axis. Converted at render time.
    @State private var accumulation: [AuroraPoint] = []
    /// The day's heart rate in 1-minute means — the honest fallback when accumulation is not derivable.
    @State private var hrCurve: [AuroraPoint] = []
    /// Seconds in each of the five zones, index 0 = Z1, plus where they came from.
    @State private var zoneSeconds: [Double]?
    @State private var zoneOrigin: ZoneOrigin = .none
    /// Seconds below Zone 1 in the day's HR — the quiet majority of a real day, worth naming.
    @State private var belowZone1: Double = 0
    /// The selected day's sessions, newest first.
    @State private var dayWorkouts: [WorkoutRow] = []
    /// 30 days of stored Effort ending on the selected day, and its 7-day trailing mean.
    @State private var trendPoints: [AuroraPoint] = []
    @State private var weeklyPoints: [AuroraPoint] = []
    /// Day pips for the rail, oldest first.
    @State private var pips: [AuroraDayPip] = []
    /// The stored daily row for the selected day, resolved once per load.
    @State private var storedDay: DailyMetric?

    @State private var isLoading = true
    @State private var detail: WorkoutTarget?

    // MARK: - Derived day identity (the Aurora Home idiom, verbatim)

    private var selectedLogicalDay: Date {
        let base = Repository.logicalDay(Date())
        return Calendar.current.date(byAdding: .day, value: -selectedDayOffset, to: base) ?? base
    }

    private var selectedDayKey: String {
        if selectedDayOffset == 0, let todayKey = repo.today?.day { return todayKey }
        return Repository.localDayKey(selectedLogicalDay)
    }

    private var isToday: Bool { selectedDayOffset == 0 }

    /// The furthest day back the rail is allowed to reach. Reuses the shipped clamp so this screen's
    /// day-nav cannot drift from the Liquid / Aurora Home one.
    private var earliestDayOffset: Int {
        LiquidTodayView.maxDayOffset(earliestDayKey: repo.freshness.earliestDay,
                                     todayKey: Repository.logicalDayKey(Date()))
    }

    // MARK: - Derived effort

    /// THE number this screen exists to show. Shared floor so the pillar, the Today hero and the tile
    /// can never disagree.
    private var effort100: Double? {
        StrainScorer.effectiveEffort(live: isToday ? liveEffort : nil, stored: storedDay?.strain)
    }

    /// The same value on the user's chosen axis.
    private var effortDisplay: Double? {
        effort100.map { UnitFormatter.effortValue($0, scale: effortScale) }
    }

    private var effortFraction: Double {
        guard let v = effortDisplay, gaugeMax > 0 else { return 0 }
        return min(max(v / gaugeMax, 0), 1)
    }

    private var bandTint: Color {
        guard let v = effortDisplay else { return Aurora.textTertiary }
        return Aurora.strainColor(v, scale: gaugeMax)
    }

    /// The one-word verdict beside the numeral. Derived from the value, never stored.
    private var bandLabel: String {
        guard effortDisplay != nil else { return String(localized: "NO READING") }
        switch effortFraction {
        case ..<0.25: return String(localized: "LIGHT")
        case ..<0.50: return String(localized: "MODERATE")
        case ..<0.75: return String(localized: "HARD")
        default:      return String(localized: "ALL OUT")
        }
    }

    /// The honest-zero gate, reused verbatim so a genuinely calm day explains itself instead of
    /// showing a bare 0 that reads like a failure.
    private var showsZeroNote: Bool {
        LiquidTodayView.EffortDisplay.showsZeroNote(strain: storedDay?.strain, isToday: isToday)
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
        VStack(spacing: 0) {

            // 1. THE DAY IS CHROME. Pinned above the scroll, never lost.
            AuroraDayRail(days: pips, selection: dayKeyBinding)

            ScrollView {
                VStack(spacing: 0) {
                    AuroraScrollOffsetProbe(space: Self.scrollSpace)

                    // 2. ONE dominant statement, which demotes itself as the page is read.
                    AuroraCollapsingHero(offset: scrollOffset,
                                         collapseDistance: 190,
                                         compactHeight: 48,
                                         minScale: 0.82) {
                        hero
                    } compact: {
                        compactHeroBar
                    }

                    detailStack
                }
            }
            .auroraScrollSpace(Self.scrollSpace)
            .onAuroraScrollOffset { scrollOffset = $0 }
        }
        .auroraCanvas()
        // 3. COLOUR IS DATA — the whole canvas carries the day's band.
        .auroraBandWash(bandTint, intensity: effortDisplay == nil ? 0.35 : 0.95)
        .sheet(item: $detail) { target in
            NavigationStack {
                WorkoutDetailView(row: target.row)
                    .environmentObject(repo)
            }
            #if os(macOS)
            .frame(width: 620, height: 720)
            #endif
        }
        .task(id: loadKey) { await load() }
    }

    /// One fingerprint for "reload everything": the selected day plus the repo's own refresh counter.
    private var loadKey: String { "\(selectedDayKey)|\(repo.refreshSeq)" }

    // MARK: - The rail's binding

    /// The rail speaks day KEYS; the rest of this screen thinks in OFFSETS (so the 04:00 rollover and
    /// the shipped clamp keep working). This is the only place the two meet.
    private var dayKeyBinding: Binding<String> {
        Binding(
            get: { selectedDayKey },
            set: { key in
                guard let pip = pips.first(where: { $0.dayKey == key }) else { return }
                let base = Repository.logicalDay(Date())
                let days = Calendar.current.dateComponents([.day], from: pip.date, to: base).day ?? 0
                let next = min(max(days, 0), max(earliestDayOffset, 0))
                guard next != selectedDayOffset else { return }
                withAnimation(Aurora.Motion.standard) { selectedDayOffset = next }
            }
        )
    }

    // MARK: - 2. HERO

    private var hero: some View {
        VStack(spacing: Aurora.Space.l) {

            // The day, stated. Day-centric means the screen never stops saying which day.
            Text(dayOverline)
                .auroraSectionHeader()
                .foregroundStyle(Aurora.textTertiary)

            ZStack {
                arcGauge
                heroCentre
            }
            .frame(width: Aurora.Layout.heroRingSize, height: Aurora.Layout.heroRingSize)

            AuroraCoachLine.forStrain(effortDisplay, scale: gaugeMax)
                .frame(maxWidth: 340)
                .multilineTextAlignment(.center)

            if showsZeroNote {
                Text(String(localized: "A genuinely calm day scores near zero. Nothing is missing."))
                    .auroraFootnote()
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            } else if effort100 == nil {
                Text(String(localized: "No heart rate was banked for this day, so there is no Effort to score."))
                    .auroraFootnote()
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Aurora.Space.l)
        .padding(.bottom, Aurora.Space.xl)
        .auroraGutter()
    }

    /// The arc, drawn from the design system's own `AuroraArcShape` so the rolling numeral can own the
    /// centre. Same geometry, ramp and easing as `AuroraArcGauge`; only the centre content differs.
    private var arcGauge: some View {
        let sweepDegrees: Double = 250
        let start = 90 + (360 - sweepDegrees) / 2
        let lineWidth = Aurora.Stroke.ring
        return ZStack {
            AuroraArcShape(startDegrees: start, sweepDegrees: sweepDegrees, progress: 1)
                .stroke(Aurora.surfaceInset,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round,
                                           dash: effortDisplay == nil ? [2, lineWidth * 0.75] : []))
                .padding(lineWidth / 2)

            if effortDisplay != nil {
                AuroraArcShape(startDegrees: start, sweepDegrees: sweepDegrees,
                               progress: heroSweep)
                    .stroke(
                        AngularGradient(gradient: Aurora.strainRamp.gradient, center: .center,
                                        startAngle: .degrees(start),
                                        endAngle: .degrees(start + sweepDegrees)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .padding(lineWidth / 2)
                    .shadow(color: bandTint.opacity(0.55), radius: lineWidth * 0.7)
            }
        }
        .onAppear { sweepHero(to: effortFraction) }
        .onChangeCompat(of: effortFraction) { sweepHero(to: $0) }
    }

    @State private var heroSweep: Double = 0

    private func sweepHero(to value: Double) {
        withAnimation(Aurora.Motion.respecting(Aurora.Motion.drawIn, reduced: reduceMotion)) {
            heroSweep = value
        }
    }

    private var heroCentre: some View {
        VStack(spacing: Aurora.Space.xxs) {
            Text(String(localized: "EFFORT"))
                .auroraSectionHeader()
                .foregroundStyle(Aurora.textTertiary)

            AuroraRollingNumber(value: effortDisplay,
                                size: 92,
                                decimals: effortDecimals,
                                color: bandTint)

            Text(String(localized: "of \(UnitFormatter.effortScaleMax(effortScale))"))
                .auroraFootnote()

            AuroraStatusPill(bandLabel, style: .tinted, overrideColor: bandTint)
                .padding(.top, 2)
        }
        .padding(.horizontal, Aurora.Stroke.ring * 2)
    }

    /// What replaces the hero once the user starts reading. One line, always available.
    private var compactHeroBar: some View {
        HStack(spacing: Aurora.Space.s) {
            Circle()
                .fill(bandTint)
                .frame(width: 9, height: 9)

            Text(dayOverline)
                .auroraCaptionStrong()
                .foregroundStyle(Aurora.textSecondary)
                .lineLimit(1)

            Spacer(minLength: Aurora.Space.xs)

            Text(effortDisplay.map {
                effortDecimals > 0
                    ? String(format: "%.1f", locale: AppLanguage.activeLocale, $0)
                    : String(Int($0.rounded()))
            } ?? "—")
                .font(AuroraType.number(20, weight: .bold))
                .foregroundStyle(bandTint)

            Text(bandLabel)
                .auroraFootnote()
                .foregroundStyle(Aurora.textTertiary)
        }
        .auroraGutter()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dayOverline: String {
        let date = selectedLogicalDay.formatted(
            .dateTime.weekday(.abbreviated).day().month(.abbreviated)
                .locale(AppLanguage.activeLocale))
        switch selectedDayOffset {
        case 0: return String(localized: "TODAY · \(date)")
        case 1: return String(localized: "YESTERDAY · \(date)")
        default: return date.uppercased(with: AppLanguage.activeLocale)
        }
    }

    // MARK: - The detail narrative

    private var detailStack: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.sectionGap) {
            accumulationSection
            zonesSection
            activitiesSection
            trendSection
        }
        .auroraGutter()
        .padding(.top, Aurora.Space.s)
        .padding(.bottom, Aurora.Space.tabBarClearance)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 3. TODAY'S ACCUMULATION

    private var accumulationSection: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.s) {
            AuroraSectionHeader(accumulationTitle, subtitle: accumulationSubtitle)

            AuroraCard(elevation: .base) {
                if !accumulation.isEmpty {
                    VStack(alignment: .leading, spacing: Aurora.Space.s) {
                        AuroraTrendChart(
                            points: accumulation.map {
                                AuroraPoint(date: $0.date,
                                            value: UnitFormatter.effortValue($0.value, scale: effortScale))
                            },
                            title: String(localized: "Effort accrued"),
                            ramp: .strain,
                            decimals: effortDecimals,
                            height: 190,
                            yDomain: 0...max(gaugeMax * 0.35, (effortDisplay ?? 0) * 1.15),
                            dateStyle: .dateTime.hour().minute()
                        )

                        if let note = accumulationReconciliationNote {
                            Text(note).auroraFootnote()
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else if hrCurve.count > 1 {
                    VStack(alignment: .leading, spacing: Aurora.Space.s) {
                        AuroraTrendChart(
                            points: hrCurve,
                            title: String(localized: "Heart rate"),
                            tint: Aurora.strainColor(9, scale: 21),
                            unit: String(localized: "bpm"),
                            height: 190,
                            dateStyle: .dateTime.hour().minute()
                        )
                        Text(String(localized: "There was not enough continuous heart rate to rebuild the Effort accumulation for this day, so this is the raw heart-rate trace instead."))
                            .auroraFootnote()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if isLoading {
                    VStack(alignment: .leading, spacing: Aurora.Space.s) {
                        AuroraSkeleton(height: 150, radius: Aurora.Radius.m)
                        AuroraSkeleton(width: 180, height: 10)
                    }
                } else {
                    AuroraEmptyState(
                        icon: "waveform.path.ecg",
                        headline: String(localized: "No heart rate for this day"),
                        message: String(localized: "Effort is built entirely from your heart-rate stream. Wear the strap through the day and this curve fills in on its own."),
                        tint: Aurora.strainColor(11, scale: 21)
                    )
                }
            }
        }
    }

    private var accumulationTitle: String {
        isToday ? String(localized: "Today's accumulation")
                : String(localized: "How the day accumulated")
    }

    private var accumulationSubtitle: String? {
        if !accumulation.isEmpty {
            return String(localized: "Rebuilt from this day's heart rate in one-minute means — the shape of the load, hour by hour.")
        }
        if hrCurve.count > 1 {
            return String(localized: "Heart rate through the day, in one-minute means.")
        }
        return nil
    }

    /// When the stored day total sits above where the rebuilt curve lands, say why rather than letting
    /// the two numbers quietly contradict each other.
    private var accumulationReconciliationNote: String? {
        guard let stored = effort100, let last = accumulation.last?.value else { return nil }
        guard stored - last > 0.75 else { return nil }
        let shown = UnitFormatter.effortDisplay(stored, scale: effortScale)
        return String(localized: "The day total of \(shown) also counts load recorded outside this continuous trace — a logged session, or a stretch the strap banked separately.")
    }

    // MARK: - 4. HEART RATE ZONES

    private var zonesSection: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.s) {
            AuroraSectionHeader(String(localized: "Heart rate zones"),
                                subtitle: zoneScopeLine)

            AuroraCard(elevation: .base) {
                VStack(alignment: .leading, spacing: Aurora.Space.m) {

                    HStack(spacing: Aurora.Space.xs) {
                        AuroraStatusPill(zoneOriginPill,
                                         tone: zoneOrigin == .dayHeartRate ? .accent : .neutral,
                                         icon: zoneOrigin == .dayHeartRate ? "waveform.path.ecg" : "square.and.arrow.down",
                                         style: .outline)
                        Spacer(minLength: Aurora.Space.xs)
                        Text(zoneModelLine)
                            .auroraFootnote()
                            .lineLimit(1)
                    }

                    if let seconds = zoneSeconds, seconds.reduce(0, +) > 0 {
                        AuroraZoneBar(zones: zoneSlices(seconds), height: 22)

                        if zoneOrigin == .dayHeartRate, belowZone1 > 0 {
                            HStack(spacing: Aurora.Space.xs) {
                                Circle()
                                    .strokeBorder(Aurora.hairlineStrong, lineWidth: 1)
                                    .frame(width: 7, height: 7)
                                Text(String(localized: "Below Zone 1"))
                                    .auroraLabel()
                                    .foregroundStyle(Aurora.textTertiary)
                                Spacer(minLength: Aurora.Space.xs)
                                Text(AuroraFormat.duration(belowZone1))
                                    .font(AuroraType.number(13, weight: .semibold))
                                    .foregroundStyle(Aurora.textTertiary)
                                    .frame(minWidth: 56, alignment: .trailing)
                            }
                        }
                    } else if isLoading {
                        AuroraSkeleton(height: 22, radius: Aurora.Radius.s)
                        AuroraSkeleton(width: 220, height: 10)
                    } else {
                        AuroraEmptyState(
                            icon: "chart.bar.xaxis",
                            headline: String(localized: "No zone split for this day"),
                            message: String(localized: "Zones need either a continuous heart-rate stream or an imported session that carries its own zone percentages. This day has neither."),
                            tint: Aurora.strainColor(9, scale: 21)
                        )
                    }
                }
            }
        }
    }

    private var zoneScopeLine: String {
        switch zoneOrigin {
        case .dayHeartRate:
            return String(localized: "Whole day, derived from your heart-rate stream.")
        case .importedWorkouts:
            return String(localized: "Logged sessions only — the rest of the day is not covered.")
        case .none:
            return String(localized: "Nothing to distribute for this day.")
        }
    }

    private var zoneOriginPill: String {
        switch zoneOrigin {
        case .dayHeartRate:     return String(localized: "Whole day")
        case .importedWorkouts: return String(localized: "Sessions only")
        case .none:             return String(localized: "No data")
        }
    }

    /// Names the actual zone model on screen — the user's own max HR and where it came from — so the
    /// bands are never anonymous.
    private var zoneModelLine: String {
        let zs = profile.hrZoneSet
        let ceiling = Int(zs.maxHR.rounded())
        switch zs.source {
        case "custom": return String(localized: "Your zones · max \(ceiling) bpm")
        case "manual": return String(localized: "Manual max \(ceiling) bpm")
        default:       return String(localized: "Age-derived max \(ceiling) bpm")
        }
    }

    /// Slices labelled with their REAL bpm edges, so "Z4" means something without leaving the screen.
    private func zoneSlices(_ seconds: [Double]) -> [AuroraZoneSlice] {
        let zs = profile.hrZoneSet
        return (0..<min(5, seconds.count)).map { i in
            let n = i + 1
            let label: String
            if let z = zs.zones.first(where: { $0.number == n }) {
                label = n == 5
                    ? String(localized: "Z5 · \(Int(z.lower.rounded()))+ bpm")
                    : String(localized: "Z\(n) · \(Int(z.lower.rounded()))–\(Int(z.upper.rounded())) bpm")
            } else {
                label = String(localized: "Zone \(n)")
            }
            return AuroraZoneSlice(zone: n, label: label, seconds: max(seconds[i], 0))
        }
    }

    // MARK: - 5. ACTIVITIES

    private var activitiesSection: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.s) {
            AuroraSectionHeader(String(localized: "Activities"),
                                subtitle: dayWorkouts.isEmpty
                                    ? nil
                                    : String(localized: "\(dayWorkouts.count) session\(dayWorkouts.count == 1 ? "" : "s") on this day"))

            if dayWorkouts.isEmpty {
                AuroraCard(elevation: .base) {
                    if isLoading {
                        VStack(alignment: .leading, spacing: Aurora.Space.s) {
                            AuroraSkeleton(height: 44, radius: Aurora.Radius.m)
                            AuroraSkeleton(height: 44, radius: Aurora.Radius.m)
                        }
                    } else {
                        AuroraEmptyState(
                            icon: "figure.run",
                            headline: String(localized: "No sessions logged"),
                            message: isToday
                                ? String(localized: "Nothing recorded yet today. Effort still accrues from everything your heart does — a session is not required for the number above to move.")
                                : String(localized: "Nothing was recorded for this day. Effort above still reflects the whole day's heart rate."),
                            tint: Aurora.strainColor(8, scale: 21)
                        )
                    }
                }
            } else {
                VStack(spacing: Aurora.Space.cardGap) {
                    ForEach(dayWorkouts, id: \.startTs) { row in
                        activityRow(row)
                    }
                }
            }
        }
    }

    private func activityRow(_ row: WorkoutRow) -> some View {
        let sessionEffort = row.strain.map { UnitFormatter.effortValue($0, scale: effortScale) }
        let tint = row.strain.map { Aurora.strainColor($0, scale: 100) } ?? Aurora.textTertiary
        let seconds = row.durationS ?? Double(row.endTs - row.startTs)

        return Button {
            detail = WorkoutTarget(row: row)
        } label: {
            AuroraCard(elevation: .base, tint: tint) {
                VStack(alignment: .leading, spacing: Aurora.Space.s) {

                    HStack(alignment: .center, spacing: Aurora.Space.s) {
                        ZStack {
                            RoundedRectangle(cornerRadius: Aurora.Radius.s, style: .continuous)
                                .fill(tint.opacity(0.16))
                            Image(systemName: sportSymbol(row.sport))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(tint)
                        }
                        .frame(width: 36, height: 36)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(WorkoutSource.displaySport(row.sport))
                                .auroraHeadline()
                                .lineLimit(1)
                            Text(sessionTimeSpan(row))
                                .auroraCaption()
                                .lineLimit(1)
                        }

                        Spacer(minLength: Aurora.Space.xs)

                        VStack(alignment: .trailing, spacing: 0) {
                            Text(sessionEffort.map {
                                effortDecimals > 0
                                    ? String(format: "%.1f", locale: AppLanguage.activeLocale, $0)
                                    : String(Int($0.rounded()))
                            } ?? "—")
                                .font(AuroraType.number(24, weight: .bold))
                                .foregroundStyle(sessionEffort == nil ? Aurora.textDisabled : tint)
                            Text(String(localized: "EFFORT"))
                                .auroraSectionHeader()
                                .foregroundStyle(Aurora.textTertiary)
                        }

                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Aurora.textTertiary)
                    }

                    Rectangle()
                        .fill(Aurora.divider)
                        .frame(height: Aurora.Stroke.hairline)

                    HStack(spacing: 0) {
                        statCell(String(localized: "TIME"), AuroraFormat.duration(seconds))
                        statCell(String(localized: "AVG HR"),
                                 row.avgHr.map { "\($0)" }.map { $0 + " bpm" } ?? "—")
                        statCell(String(localized: "MAX HR"),
                                 row.maxHr.map { "\($0)" }.map { $0 + " bpm" } ?? "—")
                        statCell(String(localized: "KCAL"),
                                 row.energyKcal.map { String(Int($0.rounded())) } ?? "—")
                    }
                }
            }
        }
        .buttonStyle(.auroraPress)
        .accessibilityLabel(Text("\(WorkoutSource.displaySport(row.sport)), \(AuroraFormat.duration(seconds))"))
    }

    private func statCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .auroraSectionHeader()
                .foregroundStyle(Aurora.textTertiary)
            Text(value)
                .font(AuroraType.number(14, weight: .semibold))
                .foregroundStyle(Aurora.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sessionTimeSpan(_ row: WorkoutRow) -> String {
        let start = Date(timeIntervalSince1970: TimeInterval(row.startTs))
        let end = Date(timeIntervalSince1970: TimeInterval(row.endTs))
        let f = Date.FormatStyle.dateTime.hour().minute().locale(AppLanguage.activeLocale)
        return "\(start.formatted(f)) – \(end.formatted(f)) · \(WorkoutSource.sourceLabel(row))"
    }

    // MARK: - 6. 30-DAY TREND

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.s) {
            AuroraSectionHeader(String(localized: "30-day trend"),
                                subtitle: String(localized: "Daily Effort with its seven-day average."))

            AuroraCard(elevation: .base) {
                if trendPoints.isEmpty {
                    if isLoading {
                        AuroraSkeleton(height: 170, radius: Aurora.Radius.m)
                    } else {
                        AuroraEmptyState(
                            icon: "calendar",
                            headline: String(localized: "No scored days yet"),
                            message: String(localized: "Once a few days have been scored, the last month lands here with its rolling average."),
                            tint: Aurora.strainColor(9, scale: 21)
                        )
                    }
                } else {
                    VStack(alignment: .leading, spacing: Aurora.Space.s) {
                        trendChart
                            .frame(height: 180)

                        HStack(spacing: Aurora.Space.m) {
                            legendDot(Aurora.strainColor(gaugeMax * 0.6, scale: gaugeMax),
                                      String(localized: "Daily"))
                            legendDot(Aurora.textSecondary, String(localized: "7-day average"))
                            Spacer(minLength: 0)
                        }

                        HStack {
                            Text(trendPoints.first.map { shortDate($0.date) } ?? "")
                            Spacer(minLength: Aurora.Space.xs)
                            Text(trendPoints.last.map { shortDate($0.date) } ?? "")
                        }
                        .auroraFootnote()
                    }
                }
            }
        }
    }

    private var trendChart: some View {
        Chart {
            ForEach(trendPoints) { p in
                BarMark(
                    x: .value("Day", p.date, unit: .day),
                    y: .value("Effort", UnitFormatter.effortValue(p.value, scale: effortScale)),
                    width: .fixed(6)
                )
                .foregroundStyle(Aurora.strainColor(UnitFormatter.effortValue(p.value, scale: effortScale),
                                                    scale: gaugeMax))
                .cornerRadius(3)
            }
            ForEach(weeklyPoints) { p in
                LineMark(
                    x: .value("Day", p.date, unit: .day),
                    y: .value("7-day average", UnitFormatter.effortValue(p.value, scale: effortScale)),
                    series: .value("Series", "avg")
                )
                .foregroundStyle(Aurora.textSecondary)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.catmullRom)
            }
        }
        .chartYScale(domain: 0...gaugeMax)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3))
        }
        .chartXAxis(.hidden)
        .accessibilityLabel(Text("Daily Effort over the last 30 days, with a seven-day average"))
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: Aurora.Space.xxs) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).auroraFootnote()
        }
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).locale(AppLanguage.activeLocale))
    }

    // MARK: - Load

    /// Every expensive derivation happens here, once per (day, refreshSeq) — never in `body`.
    private func load() async {
        isLoading = true

        // --- Day identity and window (the shipped 04:00-rollover idiom) ---
        let dayKey = selectedDayKey
        let logical = selectedLogicalDay
        let dayStart = Calendar.current.startOfDay(for: logical)
        let from = Int(dayStart.timeIntervalSince1970)
        let to = isToday
            ? Int(Date().timeIntervalSince1970)
            : Int((Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart)
                .timeIntervalSince1970)

        // --- The stored daily row ---
        let stored: DailyMetric? = isToday
            ? (repo.today ?? repo.days.last(where: { $0.day == dayKey }))
            : repo.days.last(where: { $0.day == dayKey })
        storedDay = stored

        // --- Rail pips (up to 30 days back, clamped by the shipped helper) ---
        pips = buildPips()

        // --- 30-day trend + its 7-day trailing mean ---
        let (trend, weekly) = buildTrend(anchor: logical)
        trendPoints = trend
        weeklyPoints = weekly

        // --- The day's sessions ---
        let rows = await repo.workoutRows(days: max(selectedDayOffset + 3, 4))
        dayWorkouts = rows.filter {
            Repository.logicalDayKey(Date(timeIntervalSince1970: TimeInterval($0.startTs))) == dayKey
        }

        guard to > from else {
            liveEffort = nil; accumulation = []; hrCurve = []
            applyWorkoutZoneFallback()
            isLoading = false
            return
        }

        // --- Raw HR for the day. 120k so a fully-worn day is not silently truncated. ---
        let raw = await repo.hrSamples(from: from, to: to, limit: 120_000)

        // --- LIVE effort, same recipe as the daily pass ---
        let maxHR: Double? = profile.age > 0 ? StrainScorer.tanakaHRmax(age: Double(profile.age)) : nil
        let restHR = stored?.restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
        liveEffort = raw.isEmpty
            ? nil
            : StrainScorer.strain(raw, maxHR: maxHR, restingHR: restHR,
                                  method: PuffinExperiment.effortMethod, sex: profile.sex)

        // --- Zones: whole day from raw HR, else imported per-session percentages ---
        if !raw.isEmpty {
            let tiz = HRZones.timeInZone(raw, zoneSet: profile.hrZoneSet)
            if tiz.seconds.reduce(0, +) > 0 {
                zoneSeconds = tiz.seconds
                belowZone1 = tiz.belowZone1
                zoneOrigin = .dayHeartRate
            } else {
                belowZone1 = tiz.belowZone1
                applyWorkoutZoneFallback()
            }
        } else {
            belowZone1 = 0
            applyWorkoutZoneFallback()
        }

        // --- The accumulation shape, from 1-minute means of the same window ---
        let buckets = await repo.hrBuckets(from: from, to: to, bucketSeconds: 60)
        hrCurve = buckets.map {
            AuroraPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.bpm)
        }
        accumulation = buildAccumulation(buckets: buckets, maxHR: maxHR, restingHR: restHR)

        isLoading = false
    }

    private func applyWorkoutZoneFallback() {
        if let summary = WorkoutZones.summary(from: dayWorkouts) {
            zoneSeconds = summary.minutes.map { $0 * 60.0 }
            zoneOrigin = .importedWorkouts
        } else {
            zoneSeconds = nil
            zoneOrigin = .none
        }
    }

    /// Replay the SAME public scorer over growing prefixes of the day's one-minute means. The result is
    /// the genuine arrival curve of the day's load — not a fabricated series and not a re-derivation of
    /// the scoring rules, which stay entirely inside `StrainScorer`.
    private func buildAccumulation(buckets: [HRBucket],
                                   maxHR: Double?,
                                   restingHR: Double) -> [AuroraPoint] {
        guard buckets.count >= 20 else { return [] }
        let samples = buckets
            .sorted { $0.ts < $1.ts }
            .map { HRSample(ts: $0.ts, bpm: Int($0.bpm.rounded())) }

        // ~28 checkpoints: enough for a smooth arrival, few enough to stay cheap and to leave the
        // scorer's memo cache usable afterwards.
        let steps = min(28, samples.count)
        guard steps >= 2 else { return [] }

        var points: [AuroraPoint] = []
        points.reserveCapacity(steps)
        var previous: Double = 0
        for k in 1...steps {
            let end = Int((Double(samples.count) * Double(k) / Double(steps)).rounded()) - 1
            guard end >= 0, end < samples.count else { continue }
            let prefix = Array(samples[0...end])
            let scored = StrainScorer.strain(prefix, maxHR: maxHR, restingHR: restingHR,
                                             method: PuffinExperiment.effortMethod,
                                             sex: profile.sex)
            // Below the scorer's data gate the honest answer is "nothing scoreable yet", which is a
            // genuine zero on this axis — never an interpolation.
            let value = max(scored ?? 0, previous)
            previous = value
            points.append(AuroraPoint(date: Date(timeIntervalSince1970: TimeInterval(samples[end].ts)),
                                      value: value))
        }
        guard points.count > 1, (points.last?.value ?? 0) > 0 else { return [] }
        return points
    }

    /// Rail pips: up to 30 days back from today, clamped to the earliest day the store actually has.
    private func buildPips() -> [AuroraDayPip] {
        let base = Repository.logicalDay(Date())
        let last = min(max(earliestDayOffset, 0), 29)
        var byKey: [String: Double] = [:]
        for d in repo.days { if let r = d.recovery { byKey[d.day] = r } }

        var out: [AuroraDayPip] = []
        out.reserveCapacity(last + 1)
        for offset in stride(from: last, through: 0, by: -1) {
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: base) else { continue }
            let key = Repository.localDayKey(date)
            out.append(AuroraDayPip(dayKey: key, date: date, recovery: byKey[key]))
        }
        return out
    }

    /// 30 days of stored Effort ending on the selected day, plus a 7-day trailing mean that only
    /// emits a point when the window actually holds enough readings to average.
    private func buildTrend(anchor: Date) -> ([AuroraPoint], [AuroraPoint]) {
        var byKey: [String: Double] = [:]
        for d in repo.days { if let s = d.strain { byKey[d.day] = s } }

        var dates: [Date] = []
        var values: [Double?] = []
        for i in stride(from: 29, through: 0, by: -1) {
            guard let date = Calendar.current.date(byAdding: .day, value: -i, to: anchor) else { continue }
            dates.append(date)
            values.append(byKey[Repository.localDayKey(date)])
        }

        var daily: [AuroraPoint] = []
        for (i, v) in values.enumerated() where v != nil {
            daily.append(AuroraPoint(date: dates[i], value: v ?? 0))
        }

        var weekly: [AuroraPoint] = []
        for i in values.indices {
            let lo = Swift.max(0, i - 6)
            let window = values[lo...i].compactMap { $0 }
            guard window.count >= 3 else { continue }
            weekly.append(AuroraPoint(date: dates[i],
                                      value: window.reduce(0, +) / Double(window.count)))
        }
        return (daily, weekly)
    }

    // MARK: - Local types

    /// Where the zone split on screen came from. Never hidden from the user.
    private enum ZoneOrigin: Equatable {
        case dayHeartRate
        case importedWorkouts
        case none
    }

    /// `WorkoutRow` is not `Identifiable`; this is the sheet's identity, keyed on the row's natural key.
    private struct WorkoutTarget: Identifiable {
        let row: WorkoutRow
        var id: String { "\(row.startTs)-\(row.endTs)-\(row.sport)" }
    }
}
