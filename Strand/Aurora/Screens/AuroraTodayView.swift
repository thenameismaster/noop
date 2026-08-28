//  AuroraTodayView.swift
//  NOOP · Aurora design language — the TODAY overview.
//
//  This is NOT a restyle of the old Home. The information architecture is different:
//
//    OLD (AuroraHomeView / LiquidTodayView)          NEW (this screen)
//    ────────────────────────────────────────        ─────────────────────────────────────
//    a header, then a hero CARD containing three     a persistent DAY RAIL pinned under the
//    gauges side by side (Charge ring + Effort       chrome — the app's primary navigation
//    arc + Rest arc), all competing for the eye      primitive — and then ONE full-bleed
//                                                    hero that owns the first screenful
//    a 2-column grid of metric tiles                 a linear reading order: hero →
//                                                    two pillar doorways → one vitals ROW
//    no day-navigation UI beyond a swipe and a       the selected day is stated at all
//    small stepper; the day is implicit              times, in the rail and above the hero
//
//  DESIGN LAW APPLIED LITERALLY
//    • ONE dominant statement. The hero is an 88pt recovery numeral, band-coloured, over a
//      full-bleed `AuroraBandWash` tinted by the same band. Nothing else is on that screen.
//    • Colour is data. The wash, the numeral, the spine of each pillar card and every pip
//      on the rail are sampled from `Aurora.recoveryColor(_:)` — never decorative.
//    • Coaching, not readout. The hero carries `AuroraCoachLine.forRecovery(_:)`; each
//      pillar card carries its own one-line interpretation.
//    • Progressive disclosure. The overview summarises and never explains; the pillar cards
//      are doorways that push the full pillar screen.
//    • Day-centric. Everything below the rail re-resolves for the selected day.
//
//  WHAT IS NOT NEW: the data. Every value binds through the SAME accessors the existing
//  screens use — `LiquidTodayView.ChargeDisplay.resolve`, `TodayView.freshRestScore`,
//  `TodayView.lastScoredRecoveryDay`, `Repository.lastVitalsDay/lastRespDay`,
//  `RecoveryScorer.calibrationNights` — so no scoring, business logic, data flow or
//  persistence is re-implemented here. Presentation only.
//
//  PERF CONTRACT (inherited): `repo.days` can be thousands of rows and the body is re-read
//  on every scroll tick (the collapsing hero is scroll-linked). Every O(days) scan is
//  resolved ONCE in `load()` into @State; `body` reads only caches.

import SwiftUI
import StrandDesign
import WhoopStore
import StrandAnalytics

// MARK: - Pillar routes

/// The four doorways this overview opens. A value type (not a closure destination) so the
/// push is programmatic from `AuroraPillarCard`'s `action:` and from the hero's own button.
private enum AuroraTodayPillar: Hashable {
    case recovery, strain, sleep, body
}

// MARK: - AuroraTodayView

/// The Aurora Today overview. Replaces the grid-of-tiles home with a day rail, one hero,
/// two pillar doorways and a single vitals row.
struct AuroraTodayView: View {

    // MARK: Environment — verbatim from LiquidTodayView / AuroraHomeView

    @EnvironmentObject var repo: Repository
    @EnvironmentObject var router: NavRouter
    @EnvironmentObject var profile: ProfileStore
    /// Only for `ble.syncNow()` on refresh (#334). Deliberately NOT AppModel/LiveState: neither the
    /// screen root nor this object publishes the ~1 Hz HR tick, so Today never re-renders on a heartbeat.
    @EnvironmentObject var ble: BLEManager

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Low Power Mode + the in-app "reduce motion in NOOP" toggle, folded into one gate.
    @ObservedObject private var motion = NoopMotionState.shared
    private var poseStill: Bool { motion.poseStill(reduceMotion) }

    /// iOS-only: an at-root Today re-tap bumps this and the scroll returns to the top.
    @Environment(\.scrollToTopSignal) private var scrollToTopSignal

    private static let scrollSpace = "aurora.today.scroll"
    private static let topAnchorID = "auroraToday.top"

    // MARK: Preferences — the same @AppStorage keys the Liquid / classic Today read

    @AppStorage(DashboardCardPrefs.selectionKey) private var dashboardCardsRaw = ""
    @AppStorage(HostedCardPrefs.selectionKey) private var hostedCardsRaw = ""
    @AppStorage(HydrationStore.enabledKey) private var hydrationEnabled = false
    @AppStorage(LiveSessionPrefs.betaKey) private var liveSessionsBeta = true
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue

    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: unitSystem, override: temperatureRaw)
    }
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }
    private var effortMax: Double { effortScale == .whoop ? 21 : 100 }

    // MARK: Navigation / presentation state

    @State private var selectedDayOffset = 0
    @State private var scrollOffset: CGFloat = 0
    @State private var pillar: AuroraTodayPillar?
    @State private var guideSection: ScoreSection?
    @State private var customizationDestination: TodayCustomizationDestination?
    @State private var showSettings = false
    @State private var showLiveSession = false
    @State private var showDayPicker = false

    // MARK: Cached resolution — every O(days) scan lands here, once per load()

    @State private var dayPips: [AuroraDayPip] = []
    @State private var cachedDisplayDay: DailyMetric?
    @State private var cachedVitalsDay: DailyMetric?
    @State private var cachedRespDay: DailyMetric?
    @State private var cachedChargeDisplay: LiquidTodayView.ChargeDisplay = .noData
    @State private var cachedCalibrationNights: Int?
    @State private var cachedStaleNights: Int?
    @State private var restScore: Double?
    @State private var sleepPerfSpark: [Double] = []
    @State private var spo2Candidate: Double?
    @State private var hostedSleepModel: SleepModel?
    @State private var hydrationTotalML: Double?
    @State private var hydrationGoalML: Int?
    @State private var stress: Double?
    @State private var fitnessAge: Double?
    @State private var vo2max: Double?
    @State private var vitality: Double?
    @State private var stepsEst: Double?
    @State private var importedStepsDay: Int?
    @State private var importedActiveKcalDay: Double?

    /// Flips true once the first load() completes; gates the hero sweep so launch churn can't fight it.
    @State private var dataLoaded = false

    // MARK: - Day resolution
    //
    // The rail is the navigation. `selectedDayOffset` is the single source of truth; the rail's
    // string binding maps a pip key back onto an offset, so the two can never disagree.

    /// `yyyy-MM-dd` in the device's local zone, matching how `DailyMetric.day` is stored. Local
    /// (not UTC): `AuroraDayRail` calls `Calendar.current.isDateInToday(_:)` on the pip date, and a
    /// UTC-parsed midnight would mislabel "TODAY" for anyone west of Greenwich.
    private func dayDate(offset: Int) -> Date {
        let base = Repository.logicalDay(Date())
        return Calendar.current.date(byAdding: .day, value: -offset, to: base) ?? base
    }

    private func dayKey(offset: Int) -> String { Repository.localDayKey(dayDate(offset: offset)) }

    private var selectedLogicalDay: Date { dayDate(offset: selectedDayOffset) }

    /// The key the RAIL matches on. Derived purely from the offset so a pip and the selection are
    /// always the same string.
    private var railDayKey: String { dayKey(offset: selectedDayOffset) }

    /// The key every day-scoped read-out uses. Identical to `LiquidTodayView` / `AuroraHomeView`:
    /// at offset 0 the resolved `repo.today` row wins (it carries the #304 pre-04:00 carve-out).
    private var selectedDayKey: String {
        if selectedDayOffset == 0, let todayKey = repo.today?.day { return todayKey }
        return railDayKey
    }

    private var isSelectedToday: Bool { selectedDayOffset == 0 }

    private var displayDay: DailyMetric? { cachedDisplayDay }
    private var vitalsDay: DailyMetric? { cachedVitalsDay }
    private var respDay: DailyMetric? { cachedRespDay }
    private var chargeDisplay: LiquidTodayView.ChargeDisplay { cachedChargeDisplay }

    private func resolveDisplayDay() -> DailyMetric? {
        if isSelectedToday {
            return repo.today ?? repo.days.last(where: { $0.day == selectedDayKey })
        }
        return repo.days.last(where: { $0.day == selectedDayKey })
    }

    /// Reuses the Liquid screen's unit-tested clamp helper so the two day-navs cannot drift.
    private var earliestDayOffset: Int {
        LiquidTodayView.maxDayOffset(earliestDayKey: repo.freshness.earliestDay,
                                     todayKey: Repository.logicalDayKey(Date()))
    }

    /// The rail's two-way binding. Writing a key selects that day; an unknown key is ignored rather
    /// than silently snapping the screen to today.
    private var dayKeyBinding: Binding<String> {
        Binding(
            get: { railDayKey },
            set: { key in
                guard let index = dayPips.firstIndex(where: { $0.dayKey == key }) else { return }
                let offset = (dayPips.count - 1) - index
                guard offset != selectedDayOffset else { return }
                selectedDayOffset = offset
            }
        )
    }

    private var dayPickerBinding: Binding<Date> {
        Binding(
            get: { selectedLogicalDay },
            set: { newValue in
                selectedDayOffset = LiquidTodayView.pickedDayOffset(
                    pickedDate: newValue, anchorLogicalDay: Repository.logicalDay(Date()))
                showDayPicker = false
            }
        )
    }

    private func stepDay(_ delta: Int) {
        let next = LiquidTodayView.clampedDayOffset(current: selectedDayOffset, delta: delta,
                                                    maxOffset: earliestDayOffset)
        guard next != selectedDayOffset else { return }
        withAnimation(Aurora.Motion.respecting(Aurora.Motion.interactive, reduced: poseStill)) {
            selectedDayOffset = next
        }
    }

    /// The day line that sits above the hero. The screen states which day it is showing, always.
    private var dayLine: String {
        switch selectedDayOffset {
        case 0: return String(localized: "TODAY")
        case 1: return String(localized: "YESTERDAY")
        default:
            return selectedLogicalDay
                .formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)
                    .locale(AppLanguage.activeLocale))
                .uppercased(with: AppLanguage.activeLocale)
        }
    }

    private var dateLine: String {
        selectedLogicalDay.formatted(
            .dateTime.weekday(.wide).day().month(.wide).locale(AppLanguage.activeLocale))
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            chrome
            AuroraDayRail(days: dayPips, selection: dayKeyBinding)
            scroller
        }
        .auroraCanvas()
        .auroraBandWash(heroTint, intensity: washIntensity)
        .task(id: loadKey) { await load() }
        .navigationDestination(isPresented: pillarPresented) { pillarDestination }
        .sheet(item: $guideSection) { section in
            NavigationStack { ScoringGuideView(initialSection: section, onClose: { guideSection = nil }) }
        }
        .sheet(item: $customizationDestination) { destination in
            AuroraTodayCustomizationHost(initialDestination: destination,
                                         dashboardCardsRaw: $dashboardCardsRaw,
                                         hostedCardsRaw: $hostedCardsRaw)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView().background(Aurora.canvas.ignoresSafeArea())
            }
        }
        .auroraLiveSessionCover(isPresented: $showLiveSession)
    }

    /// One id for the whole reload. Mirrors the Liquid/Home contract: a repo refresh, a day change, a
    /// hydration write or a hosted-card edit all re-resolve; nothing else does.
    private var loadKey: String {
        "\(repo.refreshSeq)-\(selectedDayOffset)-\(repo.hydrationSeq)-\(hydrationEnabled)-\(hostedCardsRaw.count)"
    }

    // MARK: - Chrome (deliberately small — the rail and the hero are the screen)

    private var chrome: some View {
        HStack(spacing: Aurora.Space.xs) {
            VStack(alignment: .leading, spacing: 1) {
                Text(greeting).auroraLabel()
                Text(String(localized: "Today")).auroraTitle().lineLimit(1)
            }

            Spacer(minLength: Aurora.Space.xs)

            // Isolated leaf — it owns LiveState so the ~1 Hz tick re-renders the pill, not the screen.
            AuroraTodayConnectionPill()

            #if os(macOS)
            // iOS gets pull-to-refresh; the Mac has no pull gesture, so the same action needs a control.
            Button {
                Task {
                    ble.syncNow()
                    await repo.refresh()
                    await load()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Aurora.textSecondary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.auroraPress)
            .accessibilityLabel(Text("Sync and refresh"))
            #endif

            Button { showDayPicker = true } label: {
                Image(systemName: "calendar")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Aurora.textSecondary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.auroraPress)
            .accessibilityLabel(Text("Pick a day. Showing \(dateLine)."))
            .popover(isPresented: $showDayPicker) {
                DatePicker("", selection: dayPickerBinding, in: ...Repository.logicalDay(Date()),
                           displayedComponents: [.date])
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding(Aurora.Space.s)
                    .frame(minWidth: 320, minHeight: 360)
                    .auroraTodayPopoverAdaptation()
            }

            Button { customizationDestination = .today } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Aurora.textSecondary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.auroraPress)
            .accessibilityLabel(Text("Customize Today"))

            Button { showSettings = true } label: {
                ProfileAvatarView(imageData: profile.avatarImageData,
                                  size: Aurora.Layout.glyphPlate,
                                  fallbackTint: Aurora.textSecondary)
                    .frame(width: Aurora.Layout.glyphPlate, height: Aurora.Layout.glyphPlate)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.auroraPress)
            .accessibilityLabel(Text("Profile and settings"))
        }
        .auroraGutter()
        .padding(.top, Aurora.Space.xs)
        .padding(.bottom, Aurora.Space.xs)
    }

    // MARK: - Scroller

    private var scroller: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    AuroraScrollOffsetProbe(space: Self.scrollSpace)
                    Color.clear.frame(height: 0).id(Self.topAnchorID)

                    AuroraCollapsingHero(offset: scrollOffset,
                                         collapseDistance: 190,
                                         compactHeight: 46,
                                         minScale: 0.86) {
                        hero
                    } compact: {
                        compactHeroBar
                    }

                    detail
                }
                #if os(macOS)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                #endif
            }
            .auroraScrollSpace(Self.scrollSpace)
            .onAuroraScrollOffset { scrollOffset = $0 }
            .simultaneousGesture(daySwipeGesture)
            #if os(iOS)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .refreshable {
                // #334 parity: a pull requests a fresh strap offload, not just a UI reload. `syncNow()`
                // is internally gated, so a pull while disconnected safely no-ops.
                ble.syncNow()
                await repo.refresh()
                await load()
            }
            .onChange(of: scrollToTopSignal) { _, _ in
                withAnimation(.easeOut(duration: 0.35)) { proxy.scrollTo(Self.topAnchorID, anchor: .top) }
            }
            #endif
        }
    }

    private var daySwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.5, abs(dx) > 50 else { return }
                stepDay(dx < 0 ? 1 : -1)
            }
    }

    // MARK: - Hero
    //
    // ONE dominant statement. An 88pt band-coloured numeral, the band word beneath it in tracked
    // caps, and a single interpretive sentence. Nothing else competes for the first screenful.

    /// The colour the whole screen is washed in — the selected day's recovery band. Neutral accent
    /// while there is nothing honest to colour with.
    private var heroTint: Color {
        chargeDisplay.pct.map { Aurora.recoveryColor($0) } ?? Aurora.accent
    }

    /// The wash recedes as the user reads downward, so it never fights the detail below it.
    private var washIntensity: Double {
        let t = Double(min(max(scrollOffset / 260, 0), 1))
        return 1.0 - 0.55 * t
    }

    @ViewBuilder
    private var hero: some View {
        switch chargeDisplay {
        case .scored(let pct):
            scoredHero(pct: pct, carriedCaption: nil)
        case .carried(let pct, let caption):
            scoredHero(pct: pct, carriedCaption: caption)
        case .calibrating(let nights):
            baselineHero(nights: nights)
        case .noData:
            noDataHero
        }
    }

    private func scoredHero(pct: Double, carriedCaption: String?) -> some View {
        let band = AuroraRecoveryBand(pct: pct)
        return Button { pillar = .recovery } label: {
            VStack(spacing: Aurora.Space.s) {
                dayStamp

                AuroraRollingNumber(value: dataLoaded ? pct : nil,
                                    unit: "%",
                                    size: 88,
                                    color: band.color,
                                    placeholder: "—")
                    .padding(.top, Aurora.Space.xxs)

                Text(band.label)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .tracking(4.5)
                    .foregroundStyle(band.color)

                AuroraCoachLine.forRecovery(pct)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                    .padding(.top, Aurora.Space.xxs)

                if let carriedCaption {
                    AuroraStatusPill(carriedCaption, tone: .neutral, style: .outline)
                        .padding(.top, 2)
                }

                heroChevronHint
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Aurora.Space.xl)
            .padding(.bottom, Aurora.Space.xxl)
            .auroraGutter()
            .contentShape(Rectangle())
        }
        .buttonStyle(.auroraPress)
        .accessibilityLabel(Text("Recovery \(Int(pct.rounded())) percent, \(band.label.lowercased()). Open the recovery breakdown."))
    }

    /// FIRST RUN. There is no recovery yet because the baseline is still forming, so the hero
    /// becomes the progress itself: nights banked out of `Baselines.minNightsSeed`, rendered as
    /// filled pips, with a line naming what the next night unlocks. It reads as a product working
    /// toward something — never as a broken screen. The wash stays, neutral-toned.
    private func baselineHero(nights: Int) -> some View {
        let seed = Baselines.minNightsSeed
        let banked = min(max(nights, 0), seed)
        let remaining = max(0, seed - banked)
        return Button { pillar = .recovery } label: {
            VStack(spacing: Aurora.Space.s) {
                dayStamp

                HStack(alignment: .firstTextBaseline, spacing: Aurora.Space.xxs) {
                    AuroraRollingNumber(value: dataLoaded ? Double(banked) : nil,
                                        size: 88,
                                        color: Aurora.accent,
                                        placeholder: "0")
                    Text(verbatim: "/ \(seed)")
                        .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Aurora.textTertiary)
                }
                .padding(.top, Aurora.Space.xxs)

                Text(String(localized: "NIGHTS BANKED"))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .tracking(4.5)
                    .foregroundStyle(Aurora.accent)

                // The progress read at a glance, with no percentage invented.
                HStack(spacing: Aurora.Space.xs) {
                    ForEach(0..<seed, id: \.self) { index in
                        AuroraAnimatedValue(dataLoaded && index < banked ? 1 : 0) { t in
                            Capsule()
                                .fill(Aurora.accent.opacity(0.14 + 0.86 * t))
                                .frame(height: Aurora.Layout.trackHeight)
                        }
                    }
                }
                .frame(maxWidth: 260)
                .padding(.top, Aurora.Space.xxs)
                .animation(Aurora.Motion.respecting(Aurora.Motion.drawIn, reduced: poseStill),
                           value: banked)
                .accessibilityElement()
                .accessibilityLabel(Text("\(banked) of \(seed) nights banked"))

                AuroraCoachLine(
                    remaining == 0
                        ? String(localized: "Baseline seeded. Your first Recovery lands after tonight's sleep is scored.")
                        : String(localized: "Learning your baseline. \(remaining) more night\(remaining == 1 ? "" : "s") and Recovery starts scoring."),
                    emphasis: remaining == 0
                        ? String(localized: "Baseline seeded.")
                        : String(localized: "Learning your baseline."),
                    tint: Aurora.accent
                )
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
                .padding(.top, Aurora.Space.xxs)

                heroChevronHint
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Aurora.Space.xl)
            .padding(.bottom, Aurora.Space.xxl)
            .auroraGutter()
            .contentShape(Rectangle())
        }
        .buttonStyle(.auroraPress)
        .accessibilityLabel(Text("Learning your baseline, \(banked) of \(seed) nights banked. Open the recovery breakdown."))
    }

    /// Not calibrating, no score, no prior night to carry. Say exactly that, and say what would fix it.
    private var noDataHero: some View {
        Button { pillar = .recovery } label: {
            VStack(spacing: Aurora.Space.s) {
                dayStamp

                AuroraRollingNumber(value: nil, size: 88, placeholder: "—")
                    .padding(.top, Aurora.Space.xxs)

                Text(String(localized: "NO READING"))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .tracking(4.5)
                    .foregroundStyle(Aurora.textTertiary)

                AuroraCoachLine(noDataCopy,
                                emphasis: String(localized: "No scored night."),
                                tint: Aurora.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                    .padding(.top, Aurora.Space.xxs)

                heroChevronHint
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Aurora.Space.xl)
            .padding(.bottom, Aurora.Space.xxl)
            .auroraGutter()
            .contentShape(Rectangle())
        }
        .buttonStyle(.auroraPress)
        .accessibilityLabel(Text("No recovery reading for this day. Open the recovery breakdown."))
    }

    /// The honest "your strap stopped delivering nights" line beats a bland "no data".
    private var noDataCopy: String {
        if let stale = cachedStaleNights, stale > Baselines.staleDays {
            return String(localized: "No scored night. Nothing new from your strap for \(stale) days — check it's connected and saving.")
        }
        return isSelectedToday
            ? String(localized: "No scored night. Wear the strap tonight and this fills in by morning.")
            : String(localized: "No scored night. Nothing was recorded for this day.")
    }

    /// The day the screen is showing, stated above the number. Day-centric, always.
    private var dayStamp: some View {
        Text(dayLine)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .tracking(2.2)
            .foregroundStyle(Aurora.textSecondary)
    }

    private var heroChevronHint: some View {
        HStack(spacing: 4) {
            Text(String(localized: "Breakdown")).font(AuroraType.captionStrong)
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(Aurora.textTertiary)
        .padding(.top, Aurora.Space.s)
    }

    /// What the hero collapses into. Stays available while the user works through the detail.
    private var compactHeroBar: some View {
        HStack(spacing: Aurora.Space.xs) {
            Circle()
                .fill(heroTint)
                .frame(width: 8, height: 8)
            Text(String(localized: "RECOVERY"))
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.6)
                .foregroundStyle(heroTint)
            Text(compactHeroValue)
                .font(AuroraType.metricSmall)
                .foregroundStyle(Aurora.textPrimary)
            if let pct = chargeDisplay.pct {
                Text(AuroraRecoveryBand(pct: pct).label)
                    .font(AuroraType.footnote)
                    .foregroundStyle(Aurora.textTertiary)
            }
            Spacer(minLength: Aurora.Space.xs)
            Text(dayLine)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(Aurora.textTertiary)
        }
        .auroraGutter()
        .frame(height: 46)
        .accessibilityElement(children: .combine)
    }

    private var compactHeroValue: String {
        if let pct = chargeDisplay.pct { return "\(Int(pct.rounded()))%" }
        if case .calibrating(let n) = chargeDisplay { return "\(min(n, Baselines.minNightsSeed))/\(Baselines.minNightsSeed)" }
        return "—"
    }

    // MARK: - Detail (everything below the hero)

    private var detail: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.xl) {

            // Pinned above everything subordinate, exactly as both existing Today screens pin them.
            HealthAlertBanner()
            ActiveWorkoutIndicatorSection()

            pillars
            vitalsStrip

            if liveSessionsBeta { liveSessionRow }

            subordinate

            Color.clear.frame(height: Aurora.Space.tabBarClearance)
        }
        .auroraGutter()
        .padding(.top, Aurora.Space.xs)
    }

    // MARK: Pillars — two full-width doorways, stacked. Recovery is absent on purpose: the hero IS
    // recovery, and repeating it as a card would restore the "three equal things" grid this replaces.

    private var pillars: some View {
        VStack(spacing: Aurora.Space.cardGap) {
            strainPillar
            sleepPillar
        }
    }

    private var strainValue: Double? {
        displayDay?.strain.map { UnitFormatter.effortValue($0, scale: effortScale) }
    }

    private var strainPillar: some View {
        let value = strainValue
        let tint = value.map { Aurora.strainColor($0, scale: effortMax) } ?? Aurora.strainColor(0)
        let coach = Self.strainCoach(value, scale: effortMax, isToday: isSelectedToday,
                                     rawStrain: displayDay?.strain)
        return AuroraPillarCard(
            title: String(localized: "STRAIN"),
            value: displayDay?.strain.map { UnitFormatter.effortDisplay($0, scale: effortScale) } ?? "—",
            unit: nil,
            band: value.map { Self.strainBand(($0) / max(effortMax, 1)) },
            tint: tint,
            coach: coach.text,
            emphasis: coach.emphasis,
            icon: "bolt.fill",
            action: { pillar = .strain }
        ) {
            AuroraTodayMiniArc(progress: value.map { min(max($0 / max(effortMax, 1), 0), 1) },
                               ramp: .strain,
                               animate: dataLoaded && !poseStill)
                .frame(width: 54, height: 54)
        }
    }

    private var sleepPillar: some View {
        let minutes = displayDay?.totalSleepMin
        let tint = Aurora.sleepColor(restScore ?? 62)
        let coach = Self.sleepCoach(restScore, hasNight: minutes != nil)
        return AuroraPillarCard(
            title: String(localized: "SLEEP"),
            value: minutes.map { AuroraFormat.duration($0 * 60) } ?? "—",
            unit: nil,
            band: restScore.map { "\(Int($0.rounded()))%" },
            tint: tint,
            coach: coach.text,
            emphasis: coach.emphasis,
            icon: "moon.zzz.fill",
            action: { pillar = .sleep }
        ) {
            Group {
                if sleepPerfSpark.count > 1 {
                    AuroraSparkline(values: sleepPerfSpark, tint: tint,
                                    showsArea: true, showsHead: dataLoaded && !poseStill)
                } else {
                    AuroraTodayMiniArc(progress: restScore.map { min(max($0 / 100, 0), 1) },
                                       ramp: .sleep,
                                       animate: dataLoaded && !poseStill)
                }
            }
            .frame(width: 78, height: 40)
            .accessibilityHidden(true)
        }
    }

    // MARK: Vitals — ONE horizontal row of small readings. Not a grid; a grid is what this replaces.

    private var vitalsStrip: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.xs) {
            AuroraSectionHeader(String(localized: "Body"),
                                subtitle: vitalsProvenanceLine ?? String(localized: "Overnight vitals"),
                                actionTitle: String(localized: "Open"),
                                action: { pillar = .body })

            Button { pillar = .body } label: {
                AuroraCard(elevation: .base, padding: Aurora.Space.s + 2, radius: Aurora.Radius.card) {
                    AuroraTodayVitalsRow(items: vitalItems)
                }
            }
            .buttonStyle(.auroraPress)
            .accessibilityLabel(Text(vitalsAccessibilityLabel))
            .accessibilityHint(Text("Opens your body vitals"))
        }
    }

    private var vitalItems: [AuroraTodayVital] {
        let hrv = displayDay?.avgHrv ?? vitalsDay?.avgHrv
        let rhr = (displayDay?.restingHr ?? vitalsDay?.restingHr).map(Double.init)
        let resp = displayDay?.respRateBpm ?? respDay?.respRateBpm
        let spo2Real = displayDay?.spo2Pct ?? vitalsDay?.spo2Pct
        let spo2 = spo2Real ?? (PuffinExperiment.spo2CandidateDisplayEnabled ? spo2Candidate : nil)
        let skin = displayDay?.skinTempDevC ?? vitalsDay?.skinTempDevC

        return [
            AuroraTodayVital(label: String(localized: "RHR"),
                             value: rhr.map { String(Int($0.rounded())) },
                             unit: "bpm",
                             tint: Aurora.statusAlert),
            AuroraTodayVital(label: String(localized: "HRV"),
                             value: hrv.map { String(Int($0.rounded())) },
                             unit: "ms",
                             tint: Aurora.accent),
            AuroraTodayVital(label: String(localized: "RESP"),
                             value: resp.map { String(format: "%.1f", locale: AppLanguage.activeLocale, $0) },
                             unit: "br/min",
                             tint: Aurora.statusGood),
            AuroraTodayVital(label: String(localized: "SpO₂"),
                             value: spo2.map { String(format: "%.0f", locale: AppLanguage.activeLocale, $0) },
                             unit: "%",
                             tint: spo2Real == nil && spo2 != nil ? Aurora.textSecondary : Aurora.accent),
            AuroraTodayVital(label: String(localized: "TEMP"),
                             value: skin == nil
                                ? nil
                                : TodayView.skinTempCardValue(skin, fahrenheit: temperatureUnit == .fahrenheit),
                             unit: nil,
                             tint: Aurora.statusCaution),
        ]
    }

    private var vitalsAccessibilityLabel: String {
        let parts = vitalItems.map { item -> String in
            guard let value = item.value else { return "\(item.label), no reading" }
            return "\(item.label) \(value)\(item.unit.map { " \($0)" } ?? "")"
        }
        return parts.joined(separator: ", ")
    }

    /// Provenance caption, stamped with the row a vital actually came from — never a hardcoded
    /// "yesterday". nil when every shown vital is the selected day's own.
    private var vitalsProvenanceLine: String? {
        guard let carried = vitalsDay else { return nil }
        let carriedHrv = displayDay?.avgHrv == nil && carried.avgHrv != nil
        let carriedRhr = displayDay?.restingHr == nil && carried.restingHr != nil
        let carriedResp = displayDay?.respRateBpm == nil && carried.respRateBpm != nil
        guard carriedHrv || carriedRhr || carriedResp else { return nil }
        return TodayView.carriedCaption(priorDayKey: carried.day,
                                        todayKey: displayDay?.day ?? selectedDayKey)
    }

    // MARK: Live session

    private var liveSessionRow: some View {
        Button { showLiveSession = true } label: {
            AuroraCard(elevation: .base, padding: Aurora.Space.s + 2, radius: Aurora.Radius.m) {
                HStack(spacing: Aurora.Space.s) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Aurora.accent)
                    Text(String(localized: "Start session")).auroraBodyStrong()
                    AuroraStatusPill("BETA", tone: .neutral, style: .outline)
                    Spacer(minLength: Aurora.Space.xs)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Aurora.textTertiary)
                }
            }
        }
        .buttonStyle(.auroraPress)
        .accessibilityLabel(Text("Start a live session. Beta."))
    }

    // MARK: Subordinate — contextual and user-hosted cards, deliberately quieter than everything above

    @ViewBuilder
    private var subordinate: some View {
        if isSelectedToday { MenstrualCycleHomeCard() }
        if isSelectedToday { JournalReminderCard() }

        let cards = DashboardCardPrefs.decodeEnabled(dashboardCardsRaw)
            .filter { hydrationEnabled || $0 != .hydration }
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: Aurora.Space.xs) {
                AuroraSectionHeader(String(localized: "Your cards"),
                                    actionTitle: String(localized: "Edit"),
                                    actionIcon: nil,
                                    action: { customizationDestination = .yourCards })
                VStack(spacing: Aurora.Space.xxs) {
                    ForEach(cards) { card in
                        dashboardRow(for: card)
                    }
                }
            }
        }

        if isSelectedToday {
            let hosted = HostedCardPrefs.decodeEnabled(hostedCardsRaw)
            if !hosted.isEmpty {
                VStack(alignment: .leading, spacing: Aurora.Space.l) {
                    ForEach(hosted) { card in
                        hostedCard(for: card)
                    }
                }
            }
        }

        AutoWorkoutCard()
        dataSourcesRow
    }

    /// One "Your cards" row. Every value, tint and route is resolved exactly as the existing screens
    /// resolve it, including the SpO₂ candidate label and the imported-first steps / calories routing.
    @ViewBuilder
    private func dashboardRow(for card: DashboardCard) -> some View {
        switch card {
        case .stress:
            cardRow(.stress, card: card, value: stressText,
                    accent: stress.map { Aurora.stressColor($0 / 3 * 100) } ?? Aurora.statusNeutral)
        case .fitnessAge:
            cardRow(.metric("fitness_age"), card: card, value: unitText(fitnessAge, card.unit),
                    accent: Aurora.statusGood)
        case .vo2max:
            cardRow(.metric("vo2max_est"), card: card, value: unitText(vo2max, card.unit),
                    accent: Aurora.statusGood)
        case .vitality:
            cardRow(.metric("vitality"), card: card, value: intText(vitality) ?? "—",
                    accent: Aurora.accent)
        case .hrv:
            cardRow(.metric("hrv"), card: card, value: unitText(displayDay?.avgHrv, card.unit),
                    accent: Aurora.accent)
        case .restingHr:
            cardRow(.metric("rhr"), card: card,
                    value: unitText(displayDay?.restingHr.map(Double.init), card.unit),
                    accent: Aurora.statusAlert)
        case .respiratory:
            cardRow(.metric("resp_rate"), card: card,
                    value: unitText(displayDay?.respRateBpm, card.unit, decimals: 1),
                    accent: Aurora.statusGood)
        case .steps:
            cardRow(.metricSourced(key: stepsDetailKey, source: stepsDetailSource), card: card,
                    value: stepsText ?? "—", accent: Aurora.statusGood)
        case .bloodOxygen:
            let spo2Real = displayDay?.spo2Pct ?? vitalsDay?.spo2Pct
            let candidateOn = PuffinExperiment.spo2CandidateDisplayEnabled
            let candidate = spo2Real == nil && candidateOn ? spo2Candidate : nil
            let spo2 = spo2Real ?? candidate
            cardRow(.metric("spo2"), card: card,
                    subtitleOverride: candidate != nil
                        ? String(localized: "strap estimate (unverified)") : nil,
                    value: spo2.map { String(format: "%.0f%%", locale: AppLanguage.activeLocale, $0) } ?? "—",
                    accent: Aurora.accent)
        case .skinTemp:
            let skin = displayDay?.skinTempDevC ?? vitalsDay?.skinTempDevC
            cardRow(.metric("skin_temp"), card: card,
                    value: TodayView.skinTempCardValue(skin, fahrenheit: temperatureUnit == .fahrenheit),
                    accent: Aurora.statusCaution)
        case .calories:
            cardRow(.metricSourced(key: caloriesDetailKey, source: caloriesDetailSource), card: card,
                    value: intText(caloriesCount) ?? "—", accent: Aurora.statusCaution)
        case .sleep:
            cardRow(.sleep, card: card, value: sleepText, accent: Aurora.sleepColor(70))
        case .hydration:
            cardRow(.hydration, card: card,
                    value: hydrationGoalML.map {
                        HydrationGoal.cardValueString(totalML: hydrationTotalML ?? 0, goalML: $0)
                    } ?? "—",
                    accent: Aurora.accent)
        case .coupled:
            cardRow(.coupled, card: card, value: "", accent: Aurora.statusGood)
        }
    }

    private func cardRow(_ route: TabRoute, card: DashboardCard, subtitleOverride: String? = nil,
                         value: String, accent: Color) -> some View {
        NavigationLink(value: route) {
            AuroraCard(elevation: .base, padding: Aurora.Space.s, radius: Aurora.Radius.m) {
                HStack(spacing: Aurora.Space.s) {
                    Image(systemName: card.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 22)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(card.title).auroraCaptionStrong()
                        Text(subtitleOverride ?? card.subtitle).auroraFootnote().lineLimit(1)
                    }

                    Spacer(minLength: Aurora.Space.xs)

                    if !value.isEmpty {
                        Text(value)
                            .font(AuroraType.metricSmall)
                            .foregroundStyle(Aurora.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Aurora.textTertiary)
                }
            }
        }
        .buttonStyle(.auroraPress)
    }

    /// The Trends / Sleep cards the user hosted, in their arranged order — each rendered as the SAME
    /// view its home tab renders, so the copy and the original can never diverge.
    @ViewBuilder
    private func hostedCard(for card: HostedCard) -> some View {
        switch card {
        case .sleepMarks: SleepMarkCard()
        case .asleepDuration: AsleepDurationCard(data: AsleepDurationData.build(days: repo.days))
        case .stagesVsTypical:
            if let m = hostedSleepModel { StagesVsTypicalCard(model: m) } else { hostedPlaceholder(card) }
        case .nightDetail:
            if let m = hostedSleepModel { NightDetailCard(model: m) } else { hostedPlaceholder(card) }
        case .sleepDebt:
            if let m = hostedSleepModel { SleepDebtLedgerCard(model: m) } else { hostedPlaceholder(card) }
        case .stages:
            if let m = hostedSleepModel { StagesCard(model: m) } else { hostedPlaceholder(card) }
        case .hoursVsNeeded:
            if let m = hostedSleepModel { HoursVsNeededCard(model: m) } else { hostedPlaceholder(card) }
        case .consistency:
            if let m = hostedSleepModel { ConsistencyCard(model: m) } else { hostedPlaceholder(card) }
        }
    }

    private func hostedPlaceholder(_ card: HostedCard) -> some View {
        VStack(alignment: .leading, spacing: Aurora.Space.s) {
            AuroraSectionHeader(card.title, subtitle: card.origin)
            AuroraCard(elevation: .base) {
                AuroraEmptyState(
                    icon: card.customizationIcon,
                    headline: String(localized: "Not enough nights yet"),
                    message: String(localized: "This card fills in once a full night has been recorded and scored."),
                    tint: Aurora.sleepColor(60)
                )
            }
        }
    }

    private var dataSourcesRow: some View {
        NavigationLink(value: TabRoute.dataSources) {
            AuroraCard(elevation: .base, padding: Aurora.Space.s, radius: Aurora.Radius.m) {
                // Isolated leaf — strap link / battery / offload state, ~1 Hz safe.
                AuroraTodayStrapRow()
            }
        }
        .buttonStyle(.auroraPress)
        .accessibilityHint(Text("Opens your data sources"))
    }

    // MARK: - Pillar navigation

    private var pillarPresented: Binding<Bool> {
        Binding(get: { pillar != nil }, set: { if !$0 { pillar = nil } })
    }

    /// The pillar screens. Recovery is handed the day the overview is showing, so a push from a
    /// scrubbed-back day opens on THAT day rather than snapping to today; the others own their own
    /// day state and default to today, exactly as they do when reached from anywhere else.
    @ViewBuilder
    private var pillarDestination: some View {
        switch pillar {
        case .recovery: AuroraRecoveryView(initialDayKey: selectedDayKey)
        case .strain:   AuroraStrainView()
        case .sleep:    AuroraSleepView()
        case .body:     AuroraBodyView()
        case .none:     EmptyView()
        }
    }

    // MARK: - Load (identical accessors, identical order, identical fallbacks)

    private func load() async {
        // ── Day rail ────────────────────────────────────────────────────────────────────
        // The window is clamped to the earliest day the repository actually holds, then floored
        // at two weeks so a first-run rail is a real, navigable strip of ghost pips rather than a
        // single lonely dot.
        let maxOffset = earliestDayOffset
        let count = min(max(maxOffset + 1, 14), 60)
        var recoveryByDay: [String: Double] = [:]
        for row in repo.days {
            if let r = row.recovery { recoveryByDay[row.day] = r }
        }
        let todayRecovery = repo.today?.recovery
        var pips: [AuroraDayPip] = []
        pips.reserveCapacity(count)
        for offset in stride(from: count - 1, through: 0, by: -1) {
            let key = dayKey(offset: offset)
            let recovery = offset == 0 ? (todayRecovery ?? recoveryByDay[key]) : recoveryByDay[key]
            pips.append(AuroraDayPip(dayKey: key, date: dayDate(offset: offset), recovery: recovery))
        }
        dayPips = pips

        // ── Hydration ───────────────────────────────────────────────────────────────────
        if hydrationEnabled {
            hydrationTotalML = await repo.hydrationTotal(day: Repository.localDayKey(Date()))
            hydrationGoalML = repo.hydrationGoalML(profileSex: profile.sex)
        } else {
            hydrationTotalML = nil
            hydrationGoalML = nil
        }

        // ── Every O(days) scan, resolved ONCE ───────────────────────────────────────────
        let day = resolveDisplayDay()
        cachedDisplayDay = day
        let tkey = day?.day ?? selectedDayKey
        cachedVitalsDay = isSelectedToday ? Repository.lastVitalsDay(days: repo.days, todayKey: tkey) : nil
        cachedRespDay = isSelectedToday ? Repository.lastRespDay(days: repo.days, todayKey: tkey) : nil

        let calNights = isSelectedToday
            ? RecoveryScorer.calibrationNights(nightlyHrv: repo.days.map(\.avgHrv),
                                               dayKeys: repo.days.map(\.day),
                                               hasRecovery: day?.recovery != nil)
            : nil
        cachedCalibrationNights = calNights
        let priorScored = TodayView.lastScoredRecoveryDay(
            days: repo.days, selectedDayKey: tkey,
            isToday: isSelectedToday,
            todayScored: day?.recovery != nil,
            isCalibrating: calNights != nil
        )
        cachedChargeDisplay = LiquidTodayView.ChargeDisplay.resolve(
            todayRecovery: day?.recovery,
            priorScored: priorScored,
            calibrationNights: calNights,
            todayKey: tkey)
        cachedStaleNights = Baselines.nightsSinceNewestValidNight(
            dayKeys: repo.days.map(\.day),
            nightlyHrv: repo.days.map(\.avgHrv),
            today: Repository.logicalDayKey(Date()))

        // ── Series ──────────────────────────────────────────────────────────────────────
        async let restA = repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        async let stressA = repo.series(key: "stress", source: "my-whoop")
        async let fitA = repo.exploreSeries(key: "fitness_age", source: "my-whoop")
        async let vo2A = repo.exploreSeries(key: "vo2max_est", source: "my-whoop")
        async let vitA = repo.exploreSeries(key: "vitality", source: "my-whoop")
        async let stepsA = repo.exploreSeries(key: "steps_est", source: "my-whoop")
        async let spo2CandA = repo.exploreSeries(key: "spo2_candidate", source: "my-whoop")
        async let appleA = repo.appleDailyRows()

        let restSeries = await restA
        let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        restScore = TodayView.freshRestScore(
            todayValue: restByDay[selectedDayKey], lastDay: restSeries.last?.day,
            lastValue: restSeries.last?.value, isTodaySelected: isSelectedToday,
            todayKey: selectedDayKey)

        // The 14-night shape read the pillar accessories draw. A shape, not a value — so a nil
        // night is dropped rather than interpolated into a fabricated zero.
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: selectedLogicalDay)
        let sparkCutoff = Repository.localDayKey(cal.date(byAdding: .day, value: -13, to: dayStart) ?? dayStart)
        sleepPerfSpark = restSeries
            .filter { $0.day >= sparkCutoff && $0.day <= selectedDayKey }
            .map(\.value)

        let spo2CandSeries = await spo2CandA
        spo2Candidate = spo2CandSeries.last(where: { $0.day == tkey })?.value

        let storedStress = await stressA
        let daysSnapshot = repo.days
        // StressModel folds the full history — off the main actor so a long history can't stutter the UI.
        stress = await Task.detached(priority: .utility) {
            StressModel(days: daysSnapshot, stored: storedStress)?.score
        }.value

        fitnessAge = (await fitA).last?.value
        vo2max = (await vo2A).last?.value
        vitality = (await vitA).last?.value

        let stepsSeries = await stepsA
        let stepsByDay = Dictionary(stepsSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        stepsEst = stepsByDay[selectedDayKey] ?? (isSelectedToday ? stepsSeries.last?.value : nil)
        let appleRows = await appleA
        importedStepsDay = appleRows.filter { $0.day == selectedDayKey }.compactMap { $0.steps }.max()
        importedActiveKcalDay = appleRows.filter { $0.day == selectedDayKey }.compactMap { $0.activeKcal }.max()

        // Build the shared SleepModel ONLY when a sleep-origin card is actually hosted, so a Today
        // with no hosted sleep card pays none of the extra Repository work.
        let sleepOrigin = String(localized: "Sleep")
        if HostedCardPrefs.decodeEnabled(hostedCardsRaw).contains(where: { $0.origin == sleepOrigin }) {
            let hostedSessions = await repo.allSleepSessions()
            let hostedHabitual = await repo.habitualMidsleepSec()
            let hostedMotion = await repo.sessionMotions(starts: hostedSessions.map { $0.startTs })
            hostedSleepModel = SleepModel.build(SleepModelInputs(
                days: repo.days,
                sleeps: repo.sleeps,
                allSessions: hostedSessions,
                importedSleep: repo.importedSleep,
                habitualMidsleepSec: hostedHabitual,
                motionByStart: hostedMotion))
        } else {
            hostedSleepModel = nil
        }

        if !dataLoaded {
            withAnimation(Aurora.Motion.respecting(Aurora.Motion.drawIn, reduced: poseStill)) {
                dataLoaded = true
            }
        }
    }

    // MARK: - House coaching copy
    //
    // Presentation only: the same one-line verdicts `AuroraCoachLine`'s factories carry, restated
    // here as (sentence, emphasised phrase) pairs because `AuroraPillarCard` takes strings, not a
    // built line. No threshold here decides anything — the engine already decided the number.

    fileprivate struct Coach {
        let text: String
        let emphasis: String
    }

    private static func strainBand(_ fraction: Double) -> String {
        switch fraction {
        case ..<0.25: return String(localized: "LIGHT")
        case ..<0.50: return String(localized: "MODERATE")
        case ..<0.75: return String(localized: "HARD")
        default:      return String(localized: "ALL OUT")
        }
    }

    private static func strainCoach(_ value: Double?, scale: Double,
                                    isToday: Bool, rawStrain: Double?) -> Coach {
        guard let value else {
            if LiquidTodayView.EffortDisplay.showsZeroNote(strain: rawStrain, isToday: isToday) {
                return Coach(text: String(localized: "No cardio load yet. A calm day so far."),
                             emphasis: String(localized: "No cardio load yet."))
            }
            return Coach(text: String(localized: "Nothing logged yet. Effort scores the moment your heart rate climbs."),
                         emphasis: String(localized: "Nothing logged yet."))
        }
        switch scale > 0 ? value / scale : 0 {
        case ..<0.25:
            return Coach(text: String(localized: "Light day. Plenty of headroom before you dip into recovery."),
                         emphasis: String(localized: "Light day."))
        case ..<0.50:
            return Coach(text: String(localized: "Moderate load. A solid, repeatable day."),
                         emphasis: String(localized: "Moderate load."))
        case ..<0.75:
            return Coach(text: String(localized: "Hard day. Expect tomorrow's recovery to reflect it."),
                         emphasis: String(localized: "Hard day."))
        default:
            return Coach(text: String(localized: "All out. Protect tonight's sleep or you will pay for this."),
                         emphasis: String(localized: "All out."))
        }
    }

    private static func sleepCoach(_ pct: Double?, hasNight: Bool) -> Coach {
        guard let pct else {
            return hasNight
                ? Coach(text: String(localized: "Night recorded, not yet scored against your need."),
                        emphasis: String(localized: "Night recorded,"))
                : Coach(text: String(localized: "No sleep recorded for this night."),
                        emphasis: String(localized: "No sleep recorded"))
        }
        switch pct {
        case 95...:
            return Coach(text: String(localized: "Fully rested. You met your need in full."),
                         emphasis: String(localized: "Fully rested."))
        case 85..<95:
            return Coach(text: String(localized: "Close to need. A short lie-in would close the gap."),
                         emphasis: String(localized: "Close to need."))
        case 70..<85:
            return Coach(text: String(localized: "Under-slept. The debt is starting to accumulate."),
                         emphasis: String(localized: "Under-slept."))
        default:
            return Coach(text: String(localized: "Badly short. Make tonight an early one."),
                         emphasis: String(localized: "Badly short."))
        }
    }

    // MARK: - Derived / formatting

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? String(localized: "Good morning")
            : h < 17 ? String(localized: "Good afternoon")
            : String(localized: "Good evening")
    }

    private var stepCount: Double? {
        displayDay?.steps.map(Double.init) ?? importedStepsDay.map(Double.init) ?? stepsEst
    }

    private var stepsDetailMetric: MetricDescriptor? {
        MetricCatalog.todayStepsMetric(hasMeasuredSteps: displayDay?.steps != nil,
                                       hasImportedSteps: importedStepsDay != nil)
    }
    private var stepsDetailKey: String { stepsDetailMetric?.key ?? "steps_est" }
    private var stepsDetailSource: String { stepsDetailMetric?.source ?? "my-whoop" }

    private var caloriesCount: Double? { importedActiveKcalDay ?? displayDay?.activeKcalEst }

    private var caloriesDetailMetric: MetricDescriptor? {
        MetricCatalog.todayCaloriesMetric(hasImportedKcal: importedActiveKcalDay != nil,
                                          hasOnDeviceKcal: displayDay?.activeKcalEst != nil)
    }
    private var caloriesDetailKey: String { caloriesDetailMetric?.key ?? "energy_kcal" }
    private var caloriesDetailSource: String { caloriesDetailMetric?.source ?? "my-whoop" }

    private func intText(_ v: Double?) -> String? { v.map { String(Int($0.rounded())) } }

    private func unitText(_ v: Double?, _ unit: String, decimals: Int = 0) -> String {
        guard let v else { return "—" }
        let n = decimals > 0
            ? String(format: "%.\(decimals)f", locale: AppLanguage.activeLocale, v)
            : String(Int(v.rounded()))
        return unit.isEmpty ? n : "\(n) \(unit)"
    }

    private var stressText: String {
        stress.map { String(Int($0.rounded())) } ?? String(localized: "Calibrating")
    }

    private var sleepText: String {
        guard let m = displayDay?.totalSleepMin else { return "—" }
        return AuroraFormat.duration(m * 60)
    }

    private var stepsText: String? {
        guard let s = stepCount else { return nil }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = AppLanguage.activeLocale
        return f.string(from: NSNumber(value: Int(s))) ?? "\(Int(s))"
    }
}

// MARK: - Vitals row
//
// ONE horizontal row. On a narrow phone it scrolls sideways rather than reflowing into a grid —
// the row IS the design decision, and a grid is exactly what this screen replaces.

private struct AuroraTodayVital: Identifiable, Equatable {
    let label: String
    let value: String?
    let unit: String?
    let tint: Color

    var id: String { label }

    static func == (lhs: AuroraTodayVital, rhs: AuroraTodayVital) -> Bool {
        lhs.label == rhs.label && lhs.value == rhs.value && lhs.unit == rhs.unit
    }
}

private struct AuroraTodayVitalsRow: View {
    let items: [AuroraTodayVital]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Rectangle()
                            .fill(Aurora.divider)
                            .frame(width: Aurora.Stroke.hairline, height: 30)
                            .padding(.horizontal, Aurora.Space.xs)
                            .accessibilityHidden(true)
                    }
                    cell(item)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
    }

    private func cell(_ item: AuroraTodayVital) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Capsule()
                    .fill(item.value == nil ? Aurora.textDisabled : item.tint)
                    .frame(width: 3, height: 9)
                Text(item.label)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(1.0)
                    .foregroundStyle(Aurora.textTertiary)
            }
            AuroraValueUnit(value: item.value ?? "—",
                            unit: item.value == nil ? nil : item.unit,
                            role: .metricSmall,
                            valueColor: item.value == nil ? Aurora.textDisabled : Aurora.textPrimary)
        }
        .frame(minWidth: 62, alignment: .leading)
    }
}

// MARK: - Mini arc
//
// A compact arc with NO centre numerals — the pillar card already owns the number, and an arc that
// repeats it turns a doorway back into a gauge. Built straight on the public `AuroraArcShape`.

private struct AuroraTodayMiniArc: View {
    let progress: Double?
    let ramp: AuroraRamp
    let animate: Bool

    private let sweep: Double = 250
    private let lineWidth: CGFloat = 6

    private var start: Double { 90 + (360 - sweep) / 2 }
    private var target: Double { min(max(progress ?? 0, 0), 1) }

    var body: some View {
        ZStack {
            AuroraArcShape(startDegrees: start, sweepDegrees: sweep, progress: 1)
                .stroke(Aurora.surfaceInset,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round,
                                           dash: progress == nil ? [2, lineWidth * 0.75] : []))
            if progress != nil {
                AuroraAnimatedValue(animate ? target : 0) { t in
                    AuroraArcShape(startDegrees: start, sweepDegrees: sweep, progress: max(t, 0.001))
                        .stroke(AngularGradient(gradient: ramp.gradient, center: .center,
                                                startAngle: .degrees(start),
                                                endAngle: .degrees(start + sweep)),
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                }
            }
        }
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
    }
}

// MARK: - LiveState-isolated leaves
//
// PERF CONTRACT (inherited): `LiveState` publishes on the ~1 Hz heart-rate notify. ONLY these small
// leaves may observe it — never `AuroraTodayView` itself — so a heartbeat re-renders a pill, not the
// whole screen (which is scroll-linked and therefore expensive to invalidate).

private struct AuroraTodayConnectionPill: View {
    @EnvironmentObject private var live: LiveState

    var body: some View {
        if live.backfilling {
            AuroraStatusPill(String(localized: "Syncing"), tone: .accent,
                             icon: "arrow.triangle.2.circlepath", style: .tinted)
        } else if live.connected, let bpm = live.heartRate {
            AuroraStatusPill("\(bpm)", tone: .alert, icon: "heart.fill", style: .tinted)
        } else if live.connected {
            AuroraStatusPill(String(localized: "Connected"), tone: .good,
                             icon: "dot.radiowaves.left.and.right", style: .tinted)
        } else {
            AuroraStatusPill(String(localized: "Offline"), tone: .neutral,
                             icon: "bolt.horizontal.circle", style: .outline)
        }
    }
}

private struct AuroraTodayStrapRow: View {
    @EnvironmentObject private var live: LiveState

    var body: some View {
        HStack(spacing: Aurora.Space.s) {
            Image(systemName: live.connected
                  ? "sensor.tag.radiowaves.forward.fill" : "sensor.tag.radiowaves.forward")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(live.connected ? Aurora.statusGood : Aurora.textTertiary)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "Data sources")).auroraCaptionStrong()
                Text(statusLine).auroraFootnote()
            }

            Spacer(minLength: Aurora.Space.xs)

            if live.connected, let pct = live.batteryPct {
                AuroraStatusPill("\(Int(pct.rounded()))%",
                                 tone: pct < 15 ? .alert : .neutral,
                                 icon: live.charging == true ? "bolt.fill" : "battery.100",
                                 style: .outline)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Aurora.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusLine: String {
        if live.backfilling { return String(localized: "Offloading history…") }
        if live.connected { return String(localized: "Strap connected") }
        return String(localized: "Strap not connected") }
}

// MARK: - Customisation host

/// The Customise sheet needs bindings for every editable list. Today owns only the two card lists;
/// the section-order / key-metric keys it no longer renders are still bound here so an edit made in
/// the sheet is written to the SAME @AppStorage keys the classic and Liquid screens read.
private struct AuroraTodayCustomizationHost: View {
    let initialDestination: TodayCustomizationDestination
    @Binding var dashboardCardsRaw: String
    @Binding var hostedCardsRaw: String

    @AppStorage(TodayLayoutPrefs.orderKey) private var sectionOrderRaw = ""
    @AppStorage(TodayLayoutPrefs.hiddenKey) private var hiddenSectionsRaw = ""
    @AppStorage(KeyMetricPrefs.layoutKey) private var keyMetricsRaw = ""
    @AppStorage("today.keyMetricsDetailed") private var keyMetricsDetailed = false
    @AppStorage("today.keyMetricsWindowDays") private var keyMetricsWindowDays = 14

    var body: some View {
        TodayCustomizationSheet(
            initialDestination: initialDestination,
            sectionOrderRaw: $sectionOrderRaw,
            hiddenSectionsRaw: $hiddenSectionsRaw,
            keyMetricsRaw: $keyMetricsRaw,
            keyMetricsDetailed: $keyMetricsDetailed,
            keyMetricsWindowDays: $keyMetricsWindowDays,
            dashboardCardsRaw: $dashboardCardsRaw,
            hostedCardsRaw: $hostedCardsRaw
        )
    }
}

// MARK: - Platform helpers

private extension View {
    /// Keep a popover a popover in compact width (iOS 16.4+); a no-op on macOS where popovers never adapt.
    @ViewBuilder func auroraTodayPopoverAdaptation() -> some View {
        #if os(iOS)
        if #available(iOS 16.4, *) { self.presentationCompactAdaptation(.popover) } else { self }
        #else
        self
        #endif
    }

    /// Present the Live Session screen: `fullScreenCover` on iOS (the guardian owns the display
    /// mid-workout), a plain sheet on macOS where `fullScreenCover` does not exist.
    @ViewBuilder func auroraLiveSessionCover(isPresented: Binding<Bool>) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented) {
            LiveSessionView(onClose: { isPresented.wrappedValue = false })
        }
        #else
        self.sheet(isPresented: isPresented) {
            LiveSessionView(onClose: { isPresented.wrappedValue = false })
        }
        #endif
    }
}
