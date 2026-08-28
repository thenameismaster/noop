import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - LedgerTodayView — spec §"01 · Today"
//
// The Athlete's Ledger Today screen, transcribed from the handoff board
// (`NOOP Redesign.dc.html`, `data-screen-label="Today"`) and the spec's numbered list:
//
//   1. Header      — overline date ("FRI · JUL 3") + title "Today"; trailing sync dot + battery,
//                    plus the "…" overflow the old More list moves behind.
//   2. Hero        — 270° open arc (start 125°), 216pt, 9pt round caps, track white@6%, band accent;
//                    66/700 numeral + tracked state word; 1–2 line deterministic synthesis beneath.
//   3. WHY ledger  — 4 rows (HRV / Resting HR / Sleep / Skin temp): 82pt label column, baseline-band
//                    track with a 9pt today-dot, value + unit + delta.
//   4. LAST NIGHT  — 31/700 score + single-line proportional stage ribbon (8pt, 1.5px gaps) +
//                    "23:12 · 7h 09m asleep · −0.7h vs need · 07:04".
//   5. TODAY'S LOAD— strain vs optimal + 7-day mini bars (today solid, past at 35%).
//   6. COACH       — 2px left-rule note: the optimal-strain band + the sleep-debt read.
//   7. Tab bar     — owned by the shell (`LedgerTabBar`), not by this screen. What IS this screen's
//                    share of item 7 is the header's "…" affordance (see `overflow`).
//
// CARDINAL RULE (spec §Design Tokens): no cards behind data. Every number below draws directly on
// `Ledger.bgScreen`, separated by 1px hairlines + overline labels. The only raised fill on this
// screen is… none: Today has no range pill.
//
// ZERO new data. Every value is one NOOP already computes:
//   • hero            `LiquidTodayView.ChargeDisplay.resolve` over `repo.today` /
//                     `TodayView.lastScoredRecoveryDay` / `RecoveryScorer.calibrationNights`
//   • synthesis       `TodayView.hrvBaselineDeltaPct(today:priorHrvs:)` + the existing whole-phrase
//                     charge×sleep matrix (same String Catalog keys as classic Today)
//   • WHY rows        `BodyVitalSigns.readings` + `Baselines.foldHistory` / `.deviation` /
//                     `VitalBands.sigmaK` — the identical construction `AuroraBodyView.makeCard` uses
//   • sleep row       `AnalyticsEngine.Rest.composite(daily:)` / the imported `sleep_performance`
//   • last night      `SleepModel.navDays` + `.decodedNight` (the Sleep tab's own browse path)
//   • load            `DailyMetric.strain` on `EffortScale` + `CoupledView.optimalStrainRange`
//   • coach           `CoupledView.optimalStrainRange` + `SleepModel.debtLedger`
//
// PERF CONTRACT (spec §State Management, and the app's own convention): this screen NEVER observes
// `AppModel` or `LiveState` at its root — a connected strap publishes `LiveState` at ~1 Hz and a
// root-level observation would re-render the arc, four ledger rows and two strips on every
// heartbeat. The two live regions are isolated leaves (`LedgerTodaySyncStatus`, `HealthAlertBanner`).
// Every O(days) scan is resolved ONCE in `load()` and cached in `@State model`; `body` reads only
// that snapshot.
//
// ADDITIVE + TOGGLE-GATED: nothing here is reachable unless the shell is behind
// `@AppStorage(LedgerFlags.ledgerUIEnabledKey)` (default false). The classic views and the
// `Strand/Aurora/**` fork are untouched.

/// The Ledger Today screen. Takes no parameters; every input comes from the environment.
struct LedgerTodayView: View {

    // MARK: - Environment
    //
    // Mirrors `AuroraTodayView` (itself copied from `TodayView` / `LiquidTodayView`): the repository
    // for data, the router + profile for shell parity, and `BLEManager` ONLY for `syncNow()` on a
    // pull-to-refresh (#334). Deliberately NOT `AppModel` / `LiveState` — see the perf contract above.

    @EnvironmentObject var repo: Repository
    @EnvironmentObject var router: NavRouter
    @EnvironmentObject var profile: ProfileStore
    /// Only for `ble.syncNow()` on refresh (#334). `BLEManager` does not publish the 1 Hz HR tick.
    @EnvironmentObject var ble: BLEManager

    /// iOS-only: an at-root Today re-tap bumps this and the scroll returns to the top (#135/#198).
    @Environment(\.scrollToTopSignal) private var scrollToTopSignal

    // MARK: - Preferences — byte-identical keys to every other screen

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue

    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: unitSystem, override: temperatureRaw)
    }
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    // MARK: - Navigation / presentation state

    /// Day navigation. 0 = today; a swipe steps it, clamped to the earliest day the repo holds.
    @State private var selectedDayOffset = 0
    /// The pushed destination, presented through `.navigationDestination(isPresented:)` so a
    /// component's `action:` closure can route without owning the shell's `NavigationPath`.
    /// Metric cases open the Ledger detail (§06), matching what `TabRoute.metric` resolves to
    /// inside the Ledger shell; `.sleep` is the no-tab-switcher fallback only.
    @State private var route: LedgerTodayRoute?
    /// The header's "…" overflow.
    @State private var showOverflow = false

    /// The navigation hub the "…" presents, injected by the host shell (`LedgerOverflowContentKey`).
    /// The iOS shell supplies the real 28-destination More list; when nothing is injected the sheet
    /// falls back to Settings, which is what guarantees the Ledger toggle is always reachable from
    /// inside the Ledger shell.
    @Environment(\.ledgerOverflowContent) private var ledgerOverflowContent

    /// Host-injected tab switch (`LedgerTabSwitchKey`) for the tap-map routes that land on a TAB
    /// ("last-night strip → Sleep tab", "Activity ›"). `nil` (macOS) falls back to a push.
    @Environment(\.ledgerSwitchTab) private var switchTab

    // MARK: - The memoized model — every O(days) scan lands here, once per load()

    @State private var model = LedgerTodayModel()

    /// No parameters: the screen resolves everything from the environment.
    init() {}

    // MARK: - Scroll plumbing

    private static let topAnchorID = "ledgerToday.top"

    // MARK: - Day resolution
    //
    // Identical to `LiquidTodayView` / `AuroraTodayView`: at offset 0 the resolved `repo.today` row
    // wins (it carries the #304 pre-04:00 carve-out); otherwise the offset's local day key.

    private func dayDate(offset: Int) -> Date {
        let base = Repository.logicalDay(Date())
        return Calendar.current.date(byAdding: .day, value: -offset, to: base) ?? base
    }

    private func dayKey(offset: Int) -> String { Repository.localDayKey(dayDate(offset: offset)) }

    private var selectedLogicalDay: Date { dayDate(offset: selectedDayOffset) }

    private var selectedDayKey: String {
        if selectedDayOffset == 0, let todayKey = repo.today?.day { return todayKey }
        return dayKey(offset: selectedDayOffset)
    }

    private var isSelectedToday: Bool { selectedDayOffset == 0 }

    /// Reuses the Liquid screen's unit-tested clamp helpers so the day-navs cannot drift.
    private var earliestDayOffset: Int {
        LiquidTodayView.maxDayOffset(earliestDayKey: repo.freshness.earliestDay,
                                     todayKey: Repository.logicalDayKey(Date()))
    }

    private func stepDay(_ delta: Int) {
        let next = LiquidTodayView.clampedDayOffset(current: selectedDayOffset, delta: delta,
                                                   maxOffset: earliestDayOffset)
        guard next != selectedDayOffset else { return }
        selectedDayOffset = next
    }

    private func resolveDisplayDay() -> DailyMetric? {
        if isSelectedToday {
            return repo.today ?? repo.days.last(where: { $0.day == selectedDayKey })
        }
        return repo.days.last(where: { $0.day == selectedDayKey })
    }

    /// Board: `FRI · JUL 3` — 11/600, +2.6 tracking, uppercase (`LedgerHeader` applies the case).
    private var dateOverline: String {
        LedgerTodayModel.overline(selectedLogicalDay)
            .uppercased(with: AppLanguage.activeLocale)
    }

    // MARK: - Body

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.topAnchorID)

                    header
                    healthAlert
                    hero
                    whySection
                    lastNightSection
                    loadSection
                    coachSection
                }
                #if os(macOS)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                #endif
            }
            .scrollIndicators(.hidden)
            #if os(iOS)
            .refreshable {
                // #334 parity: a pull requests a fresh strap offload, not just a UI reload.
                // `syncNow()` is internally gated, so a pull while disconnected safely no-ops.
                ble.syncNow()
                await repo.refresh()
                await load()
            }
            .onChange(of: scrollToTopSignal) { _, _ in
                withAnimation(LedgerMotion.curve(0.35)) { proxy.scrollTo(Self.topAnchorID, anchor: .top) }
            }
            #endif
        }
        .background(Ledger.bgScreen.ignoresSafeArea())
        // Day swipe, attached to the SCREEN rather than to the `ScrollView` itself — the placement
        // `LiquidTodayView` uses. Attached directly to the scroll view, this recognizer competes with
        // the scroll's own pan for every touch, and a short, slow drag (the ordinary way anyone scrolls
        // a page) loses to it and moves nothing; only a long or fast flick got through. One level out,
        // the scroll view claims vertical panning first and the day flip still reads its horizontal
        // drags. `minimumDistance: 24` plus the horizontal-dominance check in `onEnded` remain the
        // guards that keep a scroll from ever being mistaken for a day change.
        .simultaneousGesture(daySwipeGesture)
        .ledgerMotionGate()
        .task(id: loadKey) { await load() }
        .navigationDestination(isPresented: routePresented) { routeDestination }
        .sheet(isPresented: $showOverflow) {
            // Spec §01.7 — all 28 destinations keep their EXISTING routes, so this presents the host
            // shell's own More hub rather than a re-declared copy of it. Settings is the fallback when
            // no host injected one (see `LedgerOverflowContentKey`).
            if let ledgerOverflowContent {
                ledgerOverflowContent
            } else {
                NavigationStack {
                    SettingsView()
                        .background(Ledger.bgScreen.ignoresSafeArea())
                }
            }
        }
    }

    /// One id for the whole reload: a repo refresh or a day change re-resolves; nothing else does.
    private var loadKey: String { "\(repo.refreshSeq)-\(selectedDayOffset)-\(temperatureRaw)" }

    private var daySwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.5, abs(dx) > 50 else { return }
                stepDay(dx < 0 ? 1 : -1)
            }
    }

    // MARK: - 1 · Header
    //
    // Board: `padding:22px 24px 0`, overline 11/600 +2.6 over the 27/700 title, baseline-aligned
    // trailing slot carrying a 6pt status dot and "synced · 68%".

    private var header: some View {
        LedgerHeader(overline: dateOverline, title: String(localized: "Today")) {
            HStack(spacing: Ledger.rowGap) {
                #if os(macOS)
                // The Mac has no pull gesture, so the status pill IS the sync control there.
                LedgerTodaySyncStatus {
                    Task {
                        ble.syncNow()
                        await repo.refresh()
                        await load()
                    }
                }
                #else
                LedgerTodaySyncStatus()
                #endif

                // Spec §01.7 — the old "More" list moves behind a "…"/profile affordance here.
                LedgerHeaderOverflow(label: String(localized: "More")) { showOverflow = true }
            }
        }
        .padding(.horizontal, Ledger.pageMargin)
    }

    /// Spec §Interactions: "health-alert banner pinned above the fold when raised."
    /// `LedgerTodayHealthAlert` is a leaf that owns the `AppModel` observation (see the perf
    /// contract) and occupies no space at all while the alert is down.
    private var healthAlert: some View { LedgerTodayHealthAlert() }

    // MARK: - 2 · Readiness hero
    //
    // Board: `padding:20px 0 4px`, a 216pt open arc, then the synthesis at `max-width:292px`,
    // centred, 13.5/1.55 in `text/secondary`, `margin-top:4px`.

    /// The synthesis paragraph's measured width on the board.
    private static let synthesisMaxWidth: CGFloat = 292
    /// `margin-top:4px` between the arc and the synthesis.
    private static let synthesisTopGap: CGFloat = 4

    private var hero: some View {
        VStack(spacing: 0) {
            Button {
                route = .metric("recovery")
            } label: {
                LedgerScoreArc(
                    score: model.chargeDisplay.pct,
                    style: .hero,
                    stateWord: model.chargeDisplay.pct == nil
                        ? model.chargeDisplay.stateLabel.uppercased(with: AppLanguage.activeLocale)
                        : nil
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(model.heroAccessibility))

            if !model.synthesis.isEmpty {
                Text(model.synthesis)
                    .ledgerBody()
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Self.synthesisMaxWidth)
                    .padding(.top, Self.synthesisTopGap)
            }

            // The carried-day provenance stamp: a prior night's score is never passed off as today's.
            if let carried = model.carriedCaption {
                Text(carried)
                    .ledgerCaptionStyle(11)
                    .padding(.top, Self.synthesisTopGap)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    // MARK: - 3 · WHY ledger
    //
    // Board: `margin:16px 24px 0`, top hairline, header row `padding:14px 0 2px` with the overline
    // and the caption "dot = today · band = your normal", then four 12pt-padded rows.

    private var whySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionRule
            sectionHeader(String(localized: "WHY")) {
                Text(String(localized: "dot = today · band = your normal"))
                    .font(LedgerType.label(11.5, LedgerType.regular))
                    .foregroundStyle(Ledger.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.bottom, 2)

            ForEach(Array(model.whyRows.enumerated()), id: \.element.id) { index, row in
                LedgerBaselineDotRow(
                    label: row.label,
                    reading: row.reading,
                    baseline: row.baseline,
                    scale: row.scale,
                    value: row.value,
                    unit: row.unit,
                    delta: row.delta,
                    accent: row.accent,
                    isNotable: row.isNotable,
                    showsDivider: index < model.whyRows.count - 1,
                    action: { route = .metric(row.metricKey) }
                )
            }
        }
        .padding(.horizontal, Ledger.pageMargin)
        .padding(.top, Ledger.sectionGap)
    }

    // MARK: - 4 · LAST NIGHT strip
    //
    // Board: `margin:18px 24px 0`, top hairline, `padding-top:14px`; the overline and a "Sleep ›"
    // link in `accent/sleep`; then `gap:16px` between the 31/700 score and the ribbon + caption.

    /// `font-size:31px` on the strip numerals.
    private static let stripNumeralSize: CGFloat = 31
    /// `margin-top:3px` between a strip numeral and its caption.
    private static let stripCaptionGap: CGFloat = 3
    /// `gap:16px` between the LAST NIGHT numeral and the ribbon.
    private static let lastNightGap: CGFloat = 16
    /// `margin-top:12px` from a section header to its content.
    private static let sectionContentGap: CGFloat = 12

    private var lastNightSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionRule
            sectionHeader(String(localized: "LAST NIGHT")) {
                sectionLink(String(localized: "Sleep ›"), tint: Ledger.accentSleep) { openSleep() }
            }

            Button {
                openSleep()
            } label: {
                HStack(alignment: .center, spacing: Self.lastNightGap) {
                    stripNumeral(model.lastNight.scoreText, caption: String(localized: "score"))

                    VStack(alignment: .leading, spacing: 5) {
                        LedgerTodayStageRibbon(segments: model.lastNight.segments)

                        HStack(spacing: 6) {
                            Text(model.lastNight.onsetText ?? LedgerTodayModel.absent)
                            Spacer(minLength: 0)
                            Text(model.lastNight.middleCaption)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Spacer(minLength: 0)
                            Text(model.lastNight.wakeText ?? LedgerTodayModel.absent)
                        }
                        .ledgerCaptionStyle(10)
                    }
                }
                .padding(.top, Self.sectionContentGap)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Ledger.pageMargin)
        .padding(.top, Ledger.sectionGapWide)
    }

    // MARK: - 5 · TODAY'S LOAD strip
    //
    // Board: same section chrome; "Activity ›" in `accent/strain`; the 31/700 strain numeral with a
    // 14pt tertiary " / optimal" suffix, then 7 mini bars (`height:40px; gap:5px; radius:3px`),
    // today solid `#58B9FF`, the past six at `rgba(88,185,255,.35)`.

    /// `gap:18px` between the load numeral and the bars.
    private static let loadGap: CGFloat = 18

    private var loadSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionRule
            sectionHeader(String(localized: "TODAY'S LOAD")) {
                // Spec §Tap Map offers "Activity tab / `TabRoute.metric("strain")`" for this strip:
                // the link NAMED Activity goes to the tab (when the host can switch), the strip body
                // below keeps the metric push.
                sectionLink(String(localized: "Activity ›"), tint: Ledger.accentStrain) {
                    if let switchTab { switchTab(.activity) } else { route = .metric("strain") }
                }
            }

            Button {
                route = .metric("strain")
            } label: {
                HStack(alignment: .bottom, spacing: Self.loadGap) {
                    VStack(alignment: .leading, spacing: Self.stripCaptionGap) {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(model.load.strainText)
                                .ledgerSectionNumeral(Self.stripNumeralSize)
                                .foregroundStyle(Ledger.textPrimary)
                            Text(model.load.optimalSuffix)
                                .font(LedgerType.label(14, LedgerType.semibold))
                                .foregroundStyle(Ledger.textTertiary)
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                        Text(String(localized: "strain vs optimal"))
                            .ledgerCaptionStyle(10.5)
                    }

                    LedgerTodayLoadBars(bars: model.load.bars)
                }
                .padding(.top, Self.sectionContentGap)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Ledger.pageMargin)
        .padding(.top, Ledger.sectionGapWide)
    }

    // MARK: - 6 · COACH note
    //
    // Board: `margin:18px 24px 22px; border-left:2px solid #3EE6A8; padding:2px 0 2px 14px`.
    // One per screen, and it renders nothing when there is nothing deterministic to say.

    @ViewBuilder
    private var coachSection: some View {
        if model.coachEffort != nil || model.coachSleep != nil {
            LedgerTodayCoachNote(effort: model.coachEffort,
                                 sleep: model.coachSleep,
                                 tonight: model.coachTonight)
                .padding(.horizontal, Ledger.pageMargin)
                .padding(.top, Ledger.sectionGapWide)
                .padding(.bottom, 22)
        } else {
            Color.clear.frame(height: 22)
        }
    }

    // MARK: - Section chrome
    //
    // A 1px hairline and an overline row. This is the ONLY separator the design allows — there is
    // no card, no fill, no radius behind any of the data above.

    private var sectionRule: some View {
        Rectangle()
            .fill(Ledger.hairline)
            .frame(height: Ledger.hairlineWidth)
            .frame(maxWidth: .infinity)
    }

    /// Board: the header row is `display:flex; justify-content:space-between; padding-top:14px`.
    private func sectionHeader<Trailing: View>(
        _ title: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Ledger.rowGap) {
            Text(title).ledgerOverline()
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.top, Ledger.sectionRulePadding)
    }

    /// The section's tap-through link — 12pt in the domain accent ("Sleep ›" / "Activity ›").
    private func sectionLink(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(LedgerType.label(12, LedgerType.semibold))
                .foregroundStyle(tint)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A 31/700 numeral over a 10.5pt tertiary caption (`line-height:1`, `margin-top:3px`).
    private func stripNumeral(_ value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: Self.stripCaptionGap) {
            Text(value)
                .ledgerSectionNumeral(Self.stripNumeralSize)
                .foregroundStyle(Ledger.textPrimary)
                .lineLimit(1)
            Text(caption).ledgerCaptionStyle(10.5)
        }
    }

    // MARK: - Routing
    //
    // Spec §Tap Map. Metric taps open the Ledger's own detail template (§06) with this screen named
    // after the back chevron; the last-night strip switches to the Sleep TAB through the host's
    // `\.ledgerSwitchTab` seam. The pushes go through `navigationDestination` because the Ledger
    // components take an `action:` closure rather than a `NavigationLink` value. `.sleep` survives as
    // a route case for the seam's fallback: a host with no tab bar (macOS) pushes the classic
    // `SleepView` instead, so the tap never dead-ends.

    /// The tap map's "→ Sleep tab". Falls back to pushing when no host injected a tab switcher.
    private func openSleep() {
        if let switchTab { switchTab(.sleep) } else { route = .sleep }
    }

    private var routePresented: Binding<Bool> {
        Binding(get: { route != nil }, set: { if !$0 { route = nil } })
    }

    @ViewBuilder
    private var routeDestination: some View {
        switch route {
        case .metric(let key):
            LedgerMetricDetailView(metricKey: key, source: nil,
                                   backTitle: String(localized: "Today"))
        case .sleep:
            SleepView()
        case .none:
            EmptyView()
        }
    }

    // MARK: - Load
    //
    // Every O(days) scan in this screen happens here, exactly once per `loadKey` change, and lands
    // in `model`. `body` never scans.

    private func load() async {
        let days = repo.days
        let dayKey = selectedDayKey
        let isToday = isSelectedToday
        let day = resolveDisplayDay()

        // ── 2 · Hero + synthesis ────────────────────────────────────────────────────────
        let calibrationNights = isToday
            ? RecoveryScorer.calibrationNights(nightlyHrv: days.map(\.avgHrv),
                                               dayKeys: days.map(\.day),
                                               hasRecovery: day?.recovery != nil)
            : nil
        let priorScored = TodayView.lastScoredRecoveryDay(
            days: days, selectedDayKey: dayKey,
            isToday: isToday,
            todayScored: day?.recovery != nil,
            isCalibrating: calibrationNights != nil)
        let charge = LiquidTodayView.ChargeDisplay.resolve(
            todayRecovery: day?.recovery,
            priorScored: priorScored,
            calibrationNights: calibrationNights,
            todayKey: dayKey)

        // The synthesis reads the day whose score the hero is drawing — today's, or the carried one.
        let synthesisDay = priorScored ?? day
        let synthesis = LedgerTodayModel.synthesis(day: synthesisDay,
                                                  charge: charge,
                                                  allDays: days)
        let carriedCaption: String? = {
            guard case .carried(_, let caption) = charge else { return nil }
            return caption
        }()

        // ── 3 · WHY ledger ──────────────────────────────────────────────────────────────
        // Rows scoped to the displayed day, anchored at local noon so `logicalDayKey` resolves it
        // back to exactly that day, well clear of the 04:00 rollover (the AuroraBodyView pattern).
        let vitalRows = repo.vitalMetricRows.filter { $0.metric.day <= dayKey }
        let readings = BodyVitalSigns.readings(sourceRows: vitalRows,
                                               temperatureUnit: temperatureUnit,
                                               now: LedgerTodayModel.referenceDate(for: dayKey))
        var readingByKey: [String: BodyVitalReading] = [:]
        for reading in readings { readingByKey[reading.key] = reading }

        // ── 4 · LAST NIGHT + the sleep WHY row ──────────────────────────────────────────
        let allSessions = await repo.allSleepSessions()
        let habitual = await repo.habitualMidsleepSec()
        let navSessions = allSessions.isEmpty ? repo.sleeps : allSessions
        let motions = await repo.sessionMotions(starts: navSessions.map(\.startTs))
        let sleepModel = SleepModel.build(SleepModelInputs(
            days: days,
            sleeps: repo.sleeps,
            allSessions: allSessions,
            importedSleep: repo.importedSleep,
            habitualMidsleepSec: habitual,
            motionByStart: motions))

        // The SELECTED day's night, resolved through the Sleep tab's own browse path so a swiped-to
        // day shows ITS night rather than the newest one. nil when that day recorded no sleep.
        let navDays = SleepModel.navDays(navSessions: navSessions)
        let nightIndex = navDays.firstIndex { group in
            guard let endTs = group.first?.endTs else { return false }
            return Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(endTs))) == dayKey
        }
        let night = nightIndex.flatMap {
            SleepModel.decodedNight(at: $0, navDays: navDays,
                                    habitualMidsleepSec: habitual, motionByStart: motions)
        }

        // The day's sleep SCORE, by the same rule `SleepModel.performanceSeries` applies per day:
        // the imported WHOOP figure wins, else the resolved Rest composite.
        let sleepScore: Double? = {
            if let imported = repo.importedSleep[dayKey]?.performancePct { return imported }
            guard let day else { return nil }
            return AnalyticsEngine.Rest.composite(daily: day)
        }()
        let sleepTypical = sleepModel?.performance.typical

        let whyRows = LedgerTodayModel.whyRows(
            readingByKey: readingByKey,
            rows: vitalRows,
            dayKey: dayKey,
            temperatureUnit: temperatureUnit,
            sleepScore: sleepScore,
            sleepTypical: sleepTypical)

        // ── 5 · TODAY'S LOAD ────────────────────────────────────────────────────────────
        let optimal = CoupledView.optimalStrainRange(recovery: charge.pct)
        let bars = LedgerTodayModel.loadBars(days: days, selectedDayKey: dayKey,
                                            dayKeyFor: { self.dayKey(offset: $0) })
        let load = LedgerTodayLoad(strain: day?.strain, optimal: optimal, scale: effortScale, bars: bars)

        // ── 6 · COACH ───────────────────────────────────────────────────────────────────
        let needMin = repo.importedSleep[dayKey]?.needMin ?? SleepModel.sleepNeedMin(days: days)
        let coach = LedgerTodayModel.coach(recovery: charge.pct,
                                           optimal: optimal,
                                           strain21: day?.strain.map { UnitFormatter.effortValue($0, scale: .whoop) },
                                           recentLoad: LedgerTodayModel.recentLoad(days: days),
                                           ledger: sleepModel?.sleepDebtLedger,
                                           bedtimeDriftMin: LedgerSleepSignals.bedtimeDriftMinutes(repo.sleeps),
                                           needMin: needMin)

        model = LedgerTodayModel(
            chargeDisplay: charge,
            synthesis: synthesis,
            carriedCaption: carriedCaption,
            whyRows: whyRows,
            lastNight: LedgerTodayLastNight(night: night,
                                            score: sleepScore,
                                            needMin: needMin),
            load: load,
            coachEffort: coach.effort,
            coachSleep: coach.sleep,
            coachTonight: coach.tonight)
    }
}

// MARK: - Route

/// The first-hop destinations this screen opens. Value-typed so the same tap can fire again after a
/// pop; resolved in `routeDestination`.
private enum LedgerTodayRoute: Hashable {
    /// The Ledger metric detail (§06) for a `MetricCatalog` key.
    case metric(String)
    /// The classic Sleep screen — reached only as `openSleep()`'s fallback when no host injected a
    /// tab switcher (macOS).
    case sleep
}

// MARK: - LiveState-isolated leaf
//
// PERF: `LiveState` publishes on the ~1 Hz heart-rate notify. ONLY this small leaf observes it —
// never `LedgerTodayView` itself — so a heartbeat re-renders a 6pt dot and a caption, not the arc.

private struct LedgerTodaySyncStatus: View {
    @EnvironmentObject private var live: LiveState

    /// macOS only: the pill doubles as the sync control (there is no pull gesture on the Mac).
    var action: (() -> Void)? = nil

    var body: some View {
        LedgerHeaderSyncStatus(text: caption, isConnected: live.connected, action: action)
    }

    /// Board: "synced · 68%", extended with the classic header's sync detail: the live heart rate
    /// while the strap is streaming, HOW LONG AGO the last offload completed (`lastSyncedAt`, the
    /// same field the classic sync chip reads), and chunk progress while a drain is running. Every
    /// part renders only when its value is real — nothing is invented for a state LiveState cannot
    /// answer.
    private var caption: String {
        var parts: [String] = []

        // The heart-rate part deliberately carries NO heart glyph: U+2665 renders as the red emoji
        // heart on iOS, which shouted from a caption whose whole job is to be quiet. The bpm suffix
        // says what the number is; the caption stays tertiary grey end to end.
        if live.connected, let hr = live.heartRate {
            parts.append(String(localized: "\(hr) bpm"))
        }

        if live.backfilling {
            // The chunk count is the cheapest proof the drain is moving; suppressed at zero, the
            // same rule the classic `LiquidSyncStatusRow` applies.
            parts.append(live.syncChunksThisSession > 0
                ? String(localized: "syncing \u{00B7} \(live.syncChunksThisSession) chunks")
                : String(localized: "syncing"))
        } else if !live.connected {
            parts.append(String(localized: "offline"))
            if let ts = live.lastSyncedAt {
                parts.append(String(localized: "synced \(Self.relativeAgo(ts))"))
            }
        } else if let ts = live.lastSyncedAt {
            parts.append(String(localized: "synced \(Self.relativeAgo(ts))"))
        } else {
            parts.append(String(localized: "synced"))
        }

        if live.connected, let pct = live.batteryPct {
            parts.append("\(Int(pct.rounded()))%")
        }

        return parts.joined(separator: " \u{00B7} ")
    }

    /// Compact relative age — "<1m" / "5m" / "2h" / "3d", composed with "synced" above. The same
    /// terse vocabulary the classic sync chip prints (`SyncChipState.shortAgo`), restated here
    /// because that helper is private to `TodayView`.
    private static func relativeAgo(_ ts: TimeInterval) -> String {
        let secs = max(0, Int(Date().timeIntervalSince1970 - ts))
        if secs < 60 { return String(localized: "just now") }
        let mins = secs / 60
        if mins < 60 { return String(localized: "\(mins)m ago") }
        let hours = mins / 60
        if hours < 24 { return String(localized: "\(hours)h ago") }
        return String(localized: "\(hours / 24)d ago")
    }
}

// MARK: - 4 · The stage ribbon
//
// Board: `display:flex; height:8px; border-radius:4px; overflow:hidden; gap:1.5px`, one proportional
// segment per stage interval in night order, stage colours. NOT a chart — a single-line ribbon.

private struct LedgerTodayStageRibbon: View {
    /// `height:8px`.
    private static let height: CGFloat = 8
    /// `gap:1.5px`.
    private static let gap: CGFloat = 1.5
    /// `border-radius:4px`.
    private static let radius: CGFloat = 4

    /// Proportions of the night, in order. Empty renders the honest empty track.
    let segments: [LedgerTodayStageSegment]

    var body: some View {
        GeometryReader { geo in
            if segments.isEmpty {
                Rectangle().fill(Ledger.track)
            } else {
                let gaps = Self.gap * CGFloat(max(0, segments.count - 1))
                let usable = max(0, geo.size.width - gaps)
                HStack(spacing: Self.gap) {
                    ForEach(segments) { segment in
                        Rectangle()
                            .fill(segment.stage.color)
                            .frame(width: usable * CGFloat(segment.fraction))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// One proportional slice of the night's stage ribbon.
private struct LedgerTodayStageSegment: Identifiable {
    let id: Int
    let stage: Ledger.Stage
    /// 0…1 of the night.
    let fraction: Double
}

// MARK: - 5 · The 7-day mini bars
//
// Board: `height:40px; gap:5px`, each bar `flex:1; border-radius:3px`; the past six at
// `rgba(88,185,255,.35)` (= `Ledger.pastBarOpacity`), the selected day solid `#58B9FF`.

private struct LedgerTodayLoadBars: View {
    /// `height:40px`.
    private static let height: CGFloat = 40
    /// `gap:5px`.
    private static let gap: CGFloat = 5
    /// A day with a reading always draws something, so an easy day is not mistaken for a missing one.
    private static let minimumBarHeight: CGFloat = 2

    let bars: [LedgerTodayLoadBar]

    var body: some View {
        let peak = bars.compactMap(\.value).max() ?? 0
        HStack(alignment: .bottom, spacing: Self.gap) {
            ForEach(bars) { bar in
                Group {
                    if let value = bar.value, peak > 0 {
                        RoundedRectangle(cornerRadius: Ledger.barRadiusTight, style: .continuous)
                            .fill(Ledger.accentStrain.opacity(bar.isSelected ? 1 : Ledger.pastBarOpacity))
                            .frame(height: max(Self.minimumBarHeight, Self.height * CGFloat(value / peak)))
                    } else {
                        // No reading for that day: nothing is drawn rather than a fabricated zero.
                        Color.clear.frame(height: Self.minimumBarHeight)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: Self.height, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// One day in the load strip's 7-day window. `value` is the stored 0–100 Effort; `nil` = no reading.
private struct LedgerTodayLoadBar: Identifiable {
    let id: Int
    let value: Double?
    let isSelected: Bool
}

// MARK: - The memoized model
//
// A plain value snapshot built once per `load()`. Nothing in it observes anything; `body` reads it
// and never scans `repo.days`.

private struct LedgerTodayModel {
    /// Shown where a value genuinely does not exist. An em-dash, never a fabricated zero.
    static let absent = "\u{2014}"

    var chargeDisplay: LiquidTodayView.ChargeDisplay = .noData
    var synthesis: String = ""
    var carriedCaption: String?
    var whyRows: [LedgerTodayWhyRow] = []
    var lastNight = LedgerTodayLastNight()
    var load = LedgerTodayLoad()
    /// The coach's effort verdict. Kept separate from `coachSleep` so the rendering leaf can swap
    /// it for the illness watch's verdict without touching the sleep sentence.
    var coachEffort: String?
    var coachSleep: String?
    /// Tonight's asleep target for the coach note's action row. nil = no row.
    var coachTonight: String?

    /// The arc's spoken label — the number, the band word, and the synthesis.
    var heroAccessibility: String {
        guard let pct = chargeDisplay.pct else {
            return chargeDisplay.calibrationDetail ?? chargeDisplay.stateLabel
        }
        return String(localized: "Charge \(Int(pct.rounded())), \(Ledger.recoveryWord(pct)). \(synthesis)")
    }

    // MARK: Synthesis (spec §01.2 — "existing Synthesis logic")
    //
    // The classic wrappers (`TodayView.hrvInsightDetail` / `synthesisDetail`) are PRIVATE, so the
    // pure core is called and the copy literals are restated verbatim — same String Catalog keys,
    // one translation for both screens. No new sentence is invented here.

    static func synthesis(day: DailyMetric?,
                          charge: LiquidTodayView.ChargeDisplay,
                          allDays: [DailyMetric]) -> String {
        // Calibration owns its own copy — "Learning your baseline, N of 4 nights."
        if let calibration = charge.calibrationDetail { return calibration }
        guard let day else {
            return String(localized: "No metrics yet. Import your Whoop export or wear the strap to begin.")
        }

        let detail = synthesisDetail(day)
        // The HRV-vs-baseline lead, when the baseline is deep enough to be honest about it.
        guard let hrv = day.avgHrv, hrv > 0 else { return detail }
        let prior = allDays
            .filter { $0.day != day.day }
            .compactMap(\.avgHrv)
            .filter { $0 > 0 }
        guard let pct = TodayView.hrvBaselineDeltaPct(today: hrv, priorHrvs: prior) else { return detail }

        let lead: String
        if pct >= 8 {
            lead = String(localized: "Your nervous system is well-recovered, so you're primed to push")
        } else if pct >= -8 {
            lead = String(localized: "You're in balance with your baseline, so moderate strain is well-judged")
        } else {
            lead = String(localized: "HRV is below your baseline, so ease into the day")
        }
        return lead + ". " + detail
    }

    /// The whole-phrase (charge band × slept 7h+) matrix, restated from classic `TodayView`.
    private static func synthesisDetail(_ d: DailyMetric) -> String {
        guard let rec = d.recovery else {
            return String(localized: "No metrics yet. Import your Whoop export or wear the strap to begin.")
        }
        let sleptWell: Bool? = d.totalSleepMin.map { $0 / 60.0 >= 7 }
        switch rec {
        case ..<50:
            switch sleptWell {
            case true?:  return String(localized: "Charge is low and sleep was consistent.")
            case false?: return String(localized: "Charge is low but sleep ran short.")
            case nil:    return String(localized: "Charge is low.")
            }
        case ..<70:
            switch sleptWell {
            case true?:  return String(localized: "Charge is steady and sleep was consistent.")
            case false?: return String(localized: "Charge is steady but sleep ran short.")
            case nil:    return String(localized: "Charge is steady.")
            }
        default:
            switch sleptWell {
            case true?:  return String(localized: "Charge is strong and sleep was consistent.")
            case false?: return String(localized: "Charge is strong but sleep ran short.")
            case nil:    return String(localized: "Charge is strong.")
            }
        }
    }

    // MARK: WHY rows (spec §01.3)

    static func whyRows(readingByKey: [String: BodyVitalReading],
                        rows: [SourcedDailyMetric],
                        dayKey: String,
                        temperatureUnit: TemperatureUnit,
                        sleepScore: Double?,
                        sleepTypical: Double?) -> [LedgerTodayWhyRow] {
        var out: [LedgerTodayWhyRow] = []

        // Row 1 · HRV — mint, percent delta ("+9% vs base").
        if let reading = readingByKey["hrv"] {
            out.append(vitalRow(reading: reading,
                                label: String(localized: "HRV"),
                                metricKey: "hrv",
                                points: series(rows, key: "hrv") { $0.avgHrv },
                                cfg: Baselines.hrvCfg,
                                populationRange: 40...120,
                                accent: Ledger.accentRecovery,
                                delta: .percent,
                                deltaScale: 1,
                                decimals: 0))
        }

        // Row 2 · Resting HR — grey unless it is off baseline ("on baseline").
        if let reading = readingByKey["rhr"] {
            out.append(vitalRow(reading: reading,
                                label: String(localized: "Resting HR"),
                                metricKey: "rhr",
                                points: series(rows, key: "rhr") { $0.restingHr.map(Double.init) },
                                cfg: Baselines.restingHRCfg,
                                populationRange: 40...60,
                                accent: Ledger.accentRecovery,
                                delta: .units,
                                deltaScale: 1,
                                decimals: 0))
        }

        // Row 3 · Sleep — indigo, the day's sleep SCORE against the personal mean.
        //
        // HONEST LIMIT: NOOP computes no `MetricCfg` for sleep performance, so there is no
        // baseline BAND to draw — only the arithmetic mean of the series (`SleepModel.mean`). The
        // row therefore carries a dot and a "vs base" delta on the score's own 0…100 axis, and no
        // band. Inventing a spread for it would be new scoring, which this redesign forbids.
        let sleepDelta: String? = {
            guard let sleepScore, let sleepTypical else { return nil }
            let d = Int((sleepScore - sleepTypical).rounded())
            return d == 0
                ? String(localized: "on baseline")
                : String(localized: "\(signed(d)) vs base")
        }()
        out.append(LedgerTodayWhyRow(
            id: "sleep",
            metricKey: "sleep_performance",
            label: String(localized: "Sleep"),
            reading: sleepScore,
            baseline: nil,
            scale: 0...100,
            value: sleepScore.map { "\(Int($0.rounded()))" },
            unit: String(localized: "score"),
            delta: sleepDelta,
            accent: Ledger.accentSleep,
            isNotable: sleepScore != nil && sleepTypical != nil))

        // Row 4 · Skin temp — bimodal (an absolute °C from imports, a ±°C deviation on-device);
        // the reading pipeline already resolved which, along with the label, unit and formatter.
        if let reading = readingByKey["skin"] {
            let absolute = reading.value.map(VitalBands.isAbsoluteSkinTemp) ?? true
            let raw = series(rows, key: "skin") { $0.skinTempC ?? $0.skinTempDevC }
            out.append(vitalRow(reading: reading,
                                label: String(localized: "Skin temp"),
                                metricKey: "skin_temp",
                                points: raw.filter { VitalBands.isAbsoluteSkinTemp($0.value) == absolute },
                                cfg: absolute ? Baselines.metricCfg["skin_temp"]! : VitalBands.skinTempDeviationCfg,
                                populationRange: absolute ? 33...36 : (-0.6)...0.6,
                                accent: Ledger.accentRecovery,
                                delta: .range,
                                deltaScale: temperatureUnit == .fahrenheit ? 9.0 / 5.0 : 1.0,
                                decimals: 1))
        }

        return out
    }

    /// How a row words its delta line. The board does not derive this from the sign.
    enum DeltaStyle { case percent, units, range }

    /// One vital's row: the reading (authoritative, from `BodyVitalSigns`) plus the personal
    /// baseline geometry (`Baselines` / `VitalBands`, the same configs the banding used).
    ///
    /// The band + track construction is the verified `AuroraBodyView.makeCard` precedent, unchanged:
    /// history EXCLUDING the displayed night, calendar-padded; the band is `baseline ± sigmaK·σ`
    /// once trusted and the population range otherwise; the track is that band with headroom,
    /// always widened to contain the reading.
    private static func vitalRow(reading: BodyVitalReading,
                                 label: String,
                                 metricKey: String,
                                 points: [(day: String, value: Double)],
                                 cfg: MetricCfg,
                                 populationRange: ClosedRange<Double>,
                                 accent: Color,
                                 delta style: DeltaStyle,
                                 deltaScale: Double,
                                 decimals: Int) -> LedgerTodayWhyRow {
        let readingDay = reading.day
        let priorRows: [(day: String, value: Double?)] = points
            .filter { point in
                guard let readingDay else { return true }
                return point.day < readingDay
            }
            .map { ($0.day, Optional($0.value)) }
        let state = Baselines.foldHistory(VitalBands.calendarSeries(priorRows), cfg: cfg)

        let band: ClosedRange<Double>?
        if state.trusted {
            let sigma = Baselines.sigma(state)
            let lo = state.baseline - VitalBands.sigmaK * sigma
            let hi = state.baseline + VitalBands.sigmaK * sigma
            band = min(lo, hi)...max(lo, hi)
        } else if state.usable {
            band = populationRange
        } else {
            // Not even provisionally usable: no honest "your normal" to draw.
            band = nil
        }

        // Track bounds: the band with headroom, widened to contain the reading so a far-out value
        // pins to an edge instead of vanishing off the end.
        let reference = band ?? populationRange
        var lo = reference.lowerBound
        var hi = reference.upperBound
        let pad = max((hi - lo) * 0.8, decimals > 0 ? 0.4 : 4)
        lo -= pad
        hi += pad
        if let value = reading.value {
            lo = min(lo, value - pad * 0.25)
            hi = max(hi, value + pad * 0.25)
        }
        let scale = lo...max(hi, lo + 0.001)

        var deltaText: String?
        var isNotable = false
        if let value = reading.value, state.usable {
            let deviation = Baselines.deviation(value, state: state)
            isNotable = !deviation.inNormalRange
            switch style {
            case .percent:
                let pct = Int((deviation.ratio * 100).rounded())
                deltaText = pct == 0
                    ? String(localized: "on baseline")
                    : String(localized: "\(signed(pct))% vs base")
            case .units:
                deltaText = deviation.inNormalRange
                    ? String(localized: "on baseline")
                    : String(localized: "\(signed(deviation.delta * deltaScale, decimals: decimals)) \(reading.unit) vs base")
            case .range:
                deltaText = deviation.inNormalRange
                    ? String(localized: "in range")
                    : String(localized: "\(signed(deviation.delta * deltaScale, decimals: decimals)) \(reading.unit) vs base")
            }
        }

        return LedgerTodayWhyRow(
            id: reading.key,
            metricKey: metricKey,
            label: label,
            reading: reading.value,
            baseline: band,
            scale: scale,
            value: reading.value.map(reading.format),
            unit: reading.unit,
            delta: deltaText,
            accent: accent,
            isNotable: isNotable)
    }

    /// One vital's per-day series across the source precedence, highest-priority source first per
    /// day — mirrors `AuroraBodyView.series`, itself a mirror of what `BodyVitalSigns` does
    /// internally, so the band reads the same rows the value came from.
    private static func series(_ rows: [SourcedDailyMetric],
                               key: String,
                               _ value: (DailyMetric) -> Double?) -> [(day: String, value: Double)] {
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
        return byDay.map { (day: $0.key, value: $0.value) }.sorted { $0.day < $1.day }
    }

    // MARK: Load bars (spec §01.5)

    /// The seven days ending on the selected day, oldest first. A day with no Effort reading carries
    /// `nil` — the strip draws nothing for it rather than a fabricated zero.
    static func loadBars(days: [DailyMetric],
                         selectedDayKey: String,
                         dayKeyFor: (Int) -> String) -> [LedgerTodayLoadBar] {
        var strainByDay: [String: Double] = [:]
        for row in days {
            if let strain = row.strain { strainByDay[row.day] = strain }
        }
        // The selected day's own key can be the resolved `repo.today` key rather than the offset's,
        // so the newest slot is keyed explicitly and the six before it walk back from its date.
        var keys: [String] = [selectedDayKey]
        if let anchor = dayKeyParser.date(from: selectedDayKey) {
            for back in 1...6 {
                let date = Calendar.current.date(byAdding: .day, value: -back, to: anchor) ?? anchor
                keys.append(Repository.localDayKey(date))
            }
        } else {
            for back in 1...6 { keys.append(dayKeyFor(back)) }
        }
        return keys.reversed().enumerated().map { index, key in
            LedgerTodayLoadBar(id: index, value: strainByDay[key], isSelected: key == selectedDayKey)
        }
    }

    // MARK: Coach (spec §01.6 — optimal-strain band + sleep-debt read, no fabricated pattern claims)

    /// The coach output: the effort and sleep verdicts (kept SEPARATE so the rendering leaf can
    /// swap the effort sentence for the illness watch's without re-deriving the sleep one), plus an
    /// optional concrete "TONIGHT · <target> asleep" row.
    struct CoachAdvice {
        var effort: String?
        var sleep: String?
        /// Tonight's asleep target, pre-formatted ("≈ 9h 10m asleep"). nil = no action row.
        var tonight: String?
    }

    /// The realistic nightly catch-up. An hour is what a person can actually add to a night; the
    /// old flat 30 min stretched a big debt into a month-long promise nobody keeps.
    private static let catchUpMin: Double = 60
    /// Debt one early night can cover.
    private static let smallDebtMin: Double = 90
    /// Debt a same-week plan can honestly promise to clear (5 nights × the catch-up).
    private static let planDebtMin: Double = 300

    /// How the last week's training compares to the month's norm, resolved by the caller from the
    /// same rolling-load figures the Activity screen plots. `.unknown` says nothing about it.
    enum RecentLoad {
        case light, typical, heavy, unknown
    }

    /// The 7-day mean strain against the 28-day mean, banded ±15% — the same acute-vs-chronic
    /// comparison the Activity screen's TRAINING LOAD chart draws, reduced to a word. `.unknown`
    /// below 5 scored days in the week or 14 in the month, so a sparse history claims nothing.
    static func recentLoad(days: [DailyMetric]) -> RecentLoad {
        let sorted = days.sorted { $0.day < $1.day }
        let week = sorted.suffix(7).compactMap { $0.strain }
        let month = sorted.suffix(28).compactMap { $0.strain }
        guard week.count >= 5, month.count >= 14 else { return .unknown }
        let weekMean = week.reduce(0, +) / Double(week.count)
        let monthMean = month.reduce(0, +) / Double(month.count)
        guard monthMean > 0 else { return .unknown }
        let ratio = weekMean / monthMean
        if ratio < 0.85 { return .light }
        if ratio > 1.15 { return .heavy }
        return .typical
    }

    /// Deterministic, HUMANE copy: the verdicts come from the bands the app already computes (the
    /// recovery band, today's strain against the optimal band, the 7d-vs-28d load ratio, the debt
    /// tiers), but the prose states the CONCLUSION, not the inputs. The numbers stay on the screen's
    /// data sections where they belong; the one number the note carries is the TONIGHT target. No
    /// em-dashes, no ranges, no scores.
    static func coach(recovery: Double?,
                      optimal: ClosedRange<Int>?,
                      strain21: Double?,
                      recentLoad: RecentLoad,
                      ledger: SleepDebtLedger?,
                      bedtimeDriftMin: Double?,
                      needMin: Double) -> CoachAdvice {
        var effort: String?
        var sleep: String?
        var tonight: Double?

        // ── The effort verdict ─────────────────────────────────────────────────────────
        if let recovery {
            let band = LedgerRecoveryBand.band(for: recovery)
            // Already past the day's band: the verdict is "stop", whatever the charge says.
            if let optimal, let strain21, strain21 > Double(optimal.upperBound) {
                effort = String(localized:
                    "You've already put in a big day, let it wind down.")
            } else {
                switch band {
                case .depleted, .low:
                    effort = recentLoad == .heavy
                        ? String(localized: "You've been training hard and your body is asking for a break. Keep today easy.")
                        : String(localized: "Your body is asking for an easy day. Keep it light.")
                case .moderate:
                    effort = String(localized:
                        "You're set for a steady day. Move, but no need to push.")
                case .primed, .peak:
                    effort = recentLoad == .light
                        ? String(localized: "Good day to go hard. Your training has been light lately and your body is ready for more.")
                        : String(localized: "Green light. A hard session will land well today.")
                }
            }
        }

        // ── The sleep verdict, sized to the debt ───────────────────────────────────────
        // Naps are CREDITED against debt (SleepDebt.creditedSleepMin adds recorded nap minutes to
        // the night), so suggesting one is honest advice, not a platitude.
        // Bedtime drift joins the verdict only when it is a real signal: later than the steady
        // band (the same cut the Sleep screen's caption uses). An earlier drift is never nagged.
        let driftingLater = (bedtimeDriftMin ?? 0) >= LedgerSleepSignals.driftSteadyBandMin
        if let ledger, ledger.nightCount > 0 {
            if ledger.magnitudeMin < SleepDebt.onTargetBandMin {
                sleep = driftingLater
                    ? String(localized: "Sleep is holding up, but your bedtime keeps sliding later. Worth pulling back before it bites.")
                    : String(localized: "Sleep has been steady. Keep the rhythm going.")
            } else if ledger.isDebt {
                let debt = ledger.magnitudeMin
                if debt <= Self.smallDebtMin {
                    sleep = String(localized:
                        "You're a touch short on sleep. One early night sorts it.")
                    tonight = needMin + debt
                } else if debt <= Self.planDebtMin {
                    sleep = driftingLater
                        ? String(localized: "You're short on sleep and your bedtime keeps sliding later. Pull it back this week.")
                        : String(localized: "You're running short on sleep. Earlier nights bring it back, and a nap counts too.")
                    tonight = needMin + Self.catchUpMin
                } else {
                    sleep = driftingLater
                        ? String(localized: "Sleep debt has piled up and bedtime keeps sliding later. Pull it back, a nap helps too.")
                        : String(localized: "Sleep debt has piled up. Keep bedtimes earlier this week, and a nap helps too.")
                    tonight = needMin + Self.catchUpMin
                }
            } else {
                sleep = String(localized:
                    "You're ahead on sleep, and it shows.")
            }
        }

        // The action row states an ASLEEP target: need + tonight's catch-up, capped at 10 h — past
        // that a target reads as parody, not advice. Skipped when the app holds no need to anchor it.
        var tonightText: String?
        if let tonight, needMin > 0 {
            let capped = min(tonight, 600)
            tonightText = String(localized: "\u{2248} \(CoupledView.hoursMinutes(capped)) asleep")
        }

        return CoachAdvice(effort: effort, sleep: sleep, tonight: tonightText)
    }

    // MARK: Formatting helpers

    /// A signed whole number: `+9` / `−4` (a true minus sign, not a hyphen).
    static func signed(_ value: Int) -> String {
        value >= 0 ? "+\(value)" : "\u{2212}\(abs(value))"
    }

    /// A signed decimal: `+0.4` / `−0.7`.
    static func signed(_ value: Double, decimals: Int) -> String {
        let magnitude = String(format: "%.\(decimals)f", abs(value))
        return value < 0 ? "\u{2212}\(magnitude)" : "+\(magnitude)"
    }

    /// Noon (local) on `dayKey`, so `BodyVitalSigns.logicalDayKey` resolves it back to exactly that
    /// day, well clear of the 04:00 rollover. Mirrors `AuroraBodyView.referenceDate`.
    static func referenceDate(for dayKey: String) -> Date {
        guard let date = dayKeyParser.date(from: dayKey) else { return Date() }
        return date.addingTimeInterval(12 * 3_600)
    }

    /// Board: `FRI · JUL 3` — the weekday and the date joined by a middot. Two locale-aware
    /// templates rather than one, because a single combined pattern puts the locale's own comma
    /// where the board draws the middot.
    static func overline(_ date: Date) -> String {
        "\(weekdayFormatter.string(from: date)) \u{00B7} \(monthDayFormatter.string(from: date))"
    }

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()

    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    static let dayKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - WHY row model

/// One WHY-ledger row, fully resolved. The view does no arithmetic beyond the normalization
/// `LedgerBaselineDotRow` performs on `reading` / `baseline` / `scale`.
private struct LedgerTodayWhyRow: Identifiable {
    let id: String
    /// The `MetricCatalog` key this row taps through to (`TabRoute.metric(key)`).
    let metricKey: String
    let label: String
    /// Today's reading in the metric's own stored units. `nil` → no dot.
    let reading: Double?
    /// The "your normal" band in the same units. `nil` → no band (no trustworthy baseline yet).
    let baseline: ClosedRange<Double>?
    /// The axis the track spans.
    let scale: ClosedRange<Double>
    let value: String?
    let unit: String
    let delta: String?
    let accent: Color
    let isNotable: Bool
}

// MARK: - LAST NIGHT model

/// The LAST NIGHT strip, resolved for the selected day. Every field is `nil`/empty when that day
/// recorded no sleep — the strip then draws its empty track and em-dashes rather than a guess.
private struct LedgerTodayLastNight {
    var scoreText: String = LedgerTodayModel.absent
    var segments: [LedgerTodayStageSegment] = []
    var onsetText: String?
    var wakeText: String?
    var middleCaption: String = ""

    init() {}

    /// - Parameters:
    ///   - night: the selected day's night, from `SleepModel.decodedNight` (the Sleep tab's own path).
    ///   - score: the day's sleep score — the imported `sleep_performance`, else the Rest composite.
    ///   - needMin: the day's sleep need — the imported `sleep_need_min`, else `SleepModel.sleepNeedMin`.
    init(night: Night?, score: Double?, needMin: Double) {
        scoreText = score.map { "\(Int($0.rounded()))" } ?? LedgerTodayModel.absent
        guard let night else { return }

        onsetText = night.onsetText
        wakeText = night.wakeText

        // Proportional segments in night order, from the night's own stage timeline (the stager's
        // persisted segments when it has them, the reconstructed architecture otherwise).
        let intervals = night.intervals
        let total = intervals.reduce(0.0) { $0 + $1.duration }
        if total > 0 {
            segments = intervals.enumerated().compactMap { index, interval in
                let fraction = interval.duration / total
                guard fraction > 0 else { return nil }
                return LedgerTodayStageSegment(id: index,
                                               stage: interval.stage.ledgerStage,
                                               fraction: fraction)
            }
        }

        // Board: "7h 09m asleep · −0.7h vs need". `hoursMinutes` is the existing shared formatter.
        let asleep = night.stages.asleep
        var parts = [String(localized: "\(CoupledView.hoursMinutes(asleep)) asleep")]
        if needMin > 0 {
            let deltaHours = (asleep - needMin) / 60.0
            parts.append(String(localized: "\(LedgerTodayModel.signed(deltaHours, decimals: 1))h vs need"))
        }
        middleCaption = parts.joined(separator: " · ")
    }
}

// MARK: - LOAD model

/// The TODAY'S LOAD strip. Effort is stored 0–100; the numeral and the optimal band are both drawn
/// on whichever axis `EffortScale` selects, converted with the SAME factor the importer uses.
private struct LedgerTodayLoad {
    var strainText: String = LedgerTodayModel.absent
    var optimalSuffix: String = ""
    var bars: [LedgerTodayLoadBar] = []

    init() {}

    init(strain: Double?, optimal: ClosedRange<Int>?, scale: EffortScale, bars: [LedgerTodayLoadBar]) {
        self.bars = bars
        strainText = strain.map { UnitFormatter.effortDisplay($0, scale: scale) } ?? LedgerTodayModel.absent
        if let optimal {
            let lower = Self.optimalText(Double(optimal.lowerBound), scale: scale)
            let upper = Self.optimalText(Double(optimal.upperBound), scale: scale)
            optimalSuffix = " / \(lower)\u{2013}\(upper)"
        }
    }

    /// `CoupledView.optimalStrainRange` is stated on WHOOP's 0–21 axis. `UnitFormatter`'s documented
    /// inverse (`effortScaleFactor` = 21/100) maps it back onto the stored 0–100 scale so the band
    /// and the numeral are always on the SAME axis, whichever the user has selected.
    static func optimalText(_ whoopAxisValue: Double, scale: EffortScale) -> String {
        let stored = whoopAxisValue / UnitFormatter.effortScaleFactor
        return UnitFormatter.effortDisplay(stored, scale: scale)
    }
}

// MARK: - AppModel-isolated leaf
//
// The health-alert banner is the one piece of `AppModel` state this screen surfaces. It lives in
// its own leaf for the same reason the sync pill does: the screen root must never observe
// `AppModel`. It also owns the banner's spacing, so a quiet day reserves NO height at all.

private struct LedgerTodayHealthAlert: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        if app.healthAlert != nil {
            HealthAlertBanner()
                .padding(.horizontal, Ledger.pageMargin)
                .padding(.top, Ledger.sectionGap)
        }
    }
}

// MARK: - The coach note leaf

/// Renders the COACH note, letting the illness watch OVERRIDE the effort verdict: when the
/// early-warning state is raised, "green light" would be exactly wrong, so the effort sentence is
/// replaced with the watch's own and the note turns caution. The sleep sentence and the TONIGHT
/// target stay, because an early night is the right advice either way.
///
/// A LEAF observer of `AppModel` (which owns `illnessSignal`), so the live object stays out of the
/// screen root per the perf contract — the same isolation `LedgerBodyWatchingNote` uses.
private struct LedgerTodayCoachNote: View {
    @EnvironmentObject private var appModel: AppModel

    let effort: String?
    let sleep: String?
    let tonight: String?

    private var illnessRaised: Bool {
        guard let signal = appModel.illnessSignal else { return false }
        return signal.level != .quiet
    }

    var body: some View {
        let effortText = illnessRaised
            ? String(localized: "Your signals look strained today, so treat it as a rest day. The Body tab has the details.")
            : effort
        let message = [effortText, sleep].compactMap { $0 }.joined(separator: " ")

        LedgerCoachNote(title: String(localized: "COACH"),
                        message: message,
                        accent: illnessRaised ? Ledger.accentCaution : Ledger.accentRecovery,
                        action: tonight.map {
                            .init(label: String(localized: "Tonight"), value: $0)
                        })
    }
}
