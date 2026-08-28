//  AuroraHomeView.swift
//  NOOP · Aurora design language — the Home / Today screen.
//
//  An ADDITIVE fork of `LiquidTodayView`. Every value binds to the SAME real data through the SAME
//  accessors (verified against LiquidTodayView.swift / TodayView.swift); every tap routes to the same
//  public destination; every preference is read from the same @AppStorage key. Only the PRESENTATION
//  changes — no scoring, no business logic, no data flow is re-implemented here. Where the resolution
//  is non-trivial (the Charge carry, the honest Rest fallback, the day-nav clamp, the score-source
//  label) this file calls the SAME internal statics the Liquid screen calls, rather than copying them,
//  so the two screens cannot drift apart.
//
//  The composition is the design decision:
//    • ONE dominant Charge ring, with its band name and a one-line interpretation — not three equal
//      rings in a row. Effort and Rest sit beneath it as secondary arc gauges, which is the actual
//      information hierarchy (recovery leads the day; load and sleep qualify it).
//    • The FIRST-RUN state is designed, not an afterthought: for the first four nights there is no
//      Charge to show, so the hero renders its honest empty ring and a baseline-progress card counts
//      the nights in and names exactly what each one unlocks.
//    • Key Metrics is a responsive tile grid with sparklines, honouring the editor's selection, order,
//      detailed switch and trend window.

import SwiftUI
import StrandDesign
import WhoopStore
import StrandAnalytics

// MARK: - AuroraHomeView

/// The Aurora Home screen. Data-identical to `LiquidTodayView`, rebuilt on the Aurora design system.
struct AuroraHomeView: View {

    // MARK: Environment — verbatim from LiquidTodayView

    @EnvironmentObject var repo: Repository
    @EnvironmentObject var router: NavRouter
    @EnvironmentObject var profile: ProfileStore
    /// Only for `ble.syncNow()` on refresh (#334). Deliberately NOT AppModel/LiveState: neither the
    /// screen root nor this object publishes the ~1 Hz HR tick, so Home never re-renders on a heartbeat.
    @EnvironmentObject var ble: BLEManager

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Low Power Mode + the in-app "reduce motion in NOOP" toggle, folded into one gate.
    @ObservedObject private var motion = NoopMotionState.shared
    private var poseStill: Bool { motion.poseStill(reduceMotion) }

    /// iOS-only: an at-root Today re-tap bumps this and the scroll returns to the top.
    @Environment(\.scrollToTopSignal) private var scrollToTopSignal
    private static let topAnchorID = "auroraHome.top"

    // MARK: Preferences — the same @AppStorage keys the Liquid / classic Today read

    @AppStorage(DashboardCardPrefs.selectionKey) private var dashboardCardsRaw = ""
    @AppStorage(HostedCardPrefs.selectionKey) private var hostedCardsRaw = ""
    @AppStorage(HydrationStore.enabledKey) private var hydrationEnabled = false
    @AppStorage(TodayLayoutPrefs.orderKey) private var sectionOrderRaw = ""
    @AppStorage(TodayLayoutPrefs.hiddenKey) private var hiddenSectionsRaw = ""
    @AppStorage(KeyMetricPrefs.layoutKey) private var keyMetricsRaw = ""
    @AppStorage("today.keyMetricsDetailed") private var keyMetricsDetailed = false
    @AppStorage("today.keyMetricsWindowDays") private var keyMetricsWindowDays = 14
    @AppStorage(LiveSessionPrefs.betaKey) private var liveSessionsBeta = true
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue

    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: unitSystem, override: temperatureRaw)
    }
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    private var sectionOrder: [TodaySection] {
        TodayLayoutPrefs.visibleOrder(orderRaw: sectionOrderRaw, hiddenRaw: hiddenSectionsRaw)
    }
    private var enabledKeyMetrics: [KeyMetric] { KeyMetricPrefs.decodeEnabled(keyMetricsRaw) }

    // MARK: Async-loaded state — the same accessors, resolved once per load()

    @State private var hydrationTotalML: Double?
    @State private var hydrationGoalML: Int?
    @State private var restScore: Double?
    @State private var heroProviderByMetric: [String: ScoreInputProvider] = [:]
    @State private var stress: Double?
    @State private var fitnessAge: Double?
    @State private var vo2max: Double?
    @State private var vitality: Double?
    @State private var spo2CandidateByDay: [String: Double] = [:]
    @State private var stepsEst: Double?
    @State private var importedStepsDay: Int?
    @State private var importedActiveKcalDay: Double?
    @State private var hrValues: [Double] = []
    @State private var workouts: [WorkoutRow] = []
    @State private var hostedSleepModel: SleepModel?
    @State private var kSparks: [String: [(String, Double)]] = [:]

    /// PERF: `repo.days` is up to 4000 rows and the body reads these ~20× a pass. Resolve the O(days)
    /// scans ONCE per load(), never in `body` — the same contract the Liquid screen documents.
    @State private var cachedDisplayDay: DailyMetric?
    @State private var cachedVitalsDay: DailyMetric?
    @State private var cachedRespDay: DailyMetric?
    @State private var cachedReadiness: ReadinessEngine.Readiness?
    @State private var cachedChargeDisplay: LiquidTodayView.ChargeDisplay = .noData
    /// Nights banked toward the 4-night baseline gate, or nil once the baseline is seeded. Drives the
    /// first-run progress card.
    @State private var cachedCalibrationNights: Int?

    /// Flips true once the first load() completes; gates the hero sweep so launch churn doesn't fight it.
    @State private var dataLoaded = false

    // MARK: Navigation / sheets

    @State private var selectedDayOffset = 0
    @State private var showDayPicker = false
    @State private var guideSection: ScoreSection?
    @State private var customizationDestination: TodayCustomizationDestination?
    @State private var showSettings = false
    @State private var showLiveSession = false
    @State private var synthesisExpanded = false

    // MARK: - Day navigation (identical semantics to Liquid Today)

    private var selectedLogicalDay: Date {
        let base = Repository.logicalDay(Date())
        return Calendar.current.date(byAdding: .day, value: -selectedDayOffset, to: base) ?? base
    }

    private var selectedDayKey: String {
        if selectedDayOffset == 0, let todayKey = repo.today?.day { return todayKey }
        return Repository.localDayKey(selectedLogicalDay)
    }

    private var displayDay: DailyMetric? { cachedDisplayDay }
    private var vitalsDay: DailyMetric? { cachedVitalsDay }
    private var respDay: DailyMetric? { cachedRespDay }
    private var chargeDisplay: LiquidTodayView.ChargeDisplay { cachedChargeDisplay }

    private func resolveDisplayDay() -> DailyMetric? {
        if selectedDayOffset == 0 {
            return repo.today ?? repo.days.last(where: { $0.day == selectedDayKey })
        }
        return repo.days.last(where: { $0.day == selectedDayKey })
    }

    /// Reuses the Liquid screen's unit-tested clamp helpers so the two day-navs cannot drift.
    private var earliestDayOffset: Int {
        LiquidTodayView.maxDayOffset(earliestDayKey: repo.freshness.earliestDay,
                                     todayKey: Repository.logicalDayKey(Date()))
    }

    private var dayTitle: String {
        switch selectedDayOffset {
        case 0: return String(localized: "Today")
        case 1: return String(localized: "Yesterday")
        default:
            return selectedLogicalDay.formatted(.dateTime.weekday(.wide).locale(AppLanguage.activeLocale))
        }
    }

    private var dateLine: String {
        selectedLogicalDay.formatted(
            .dateTime.weekday(.wide).day().month(.wide).locale(AppLanguage.activeLocale))
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

    private var daySwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.5, abs(dx) > 50 else { return }
                let delta = dx < 0 ? 1 : -1
                let next = LiquidTodayView.clampedDayOffset(current: selectedDayOffset, delta: delta,
                                                            maxOffset: earliestDayOffset)
                guard next != selectedDayOffset else { return }
                withAnimation(Aurora.Motion.interactive) { selectedDayOffset = next }
            }
    }

    private func stepDay(_ delta: Int) {
        let next = LiquidTodayView.clampedDayOffset(current: selectedDayOffset, delta: delta,
                                                    maxOffset: earliestDayOffset)
        guard next != selectedDayOffset else { return }
        withAnimation(Aurora.Motion.interactive) { selectedDayOffset = next }
    }

    // MARK: - Body

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Aurora.Space.xl) {
                    Color.clear.frame(height: 0).id(Self.topAnchorID)

                    header

                    // Pinned above the reorderable block, exactly as both existing Today screens pin them:
                    // a raised health alert and a live workout must never be reorderable below the fold.
                    HealthAlertBanner()
                    ActiveWorkoutIndicatorSection()

                    ForEach(sectionOrder) { section in
                        sectionBody(section)
                    }

                    AutoWorkoutCard()
                    dataSourcesSection

                    Color.clear.frame(height: Aurora.Space.tabBarClearance)
                }
                .auroraGutter()
                .padding(.top, Aurora.Space.m)
                #if os(macOS)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                #endif
            }
            .auroraCanvas()
            .simultaneousGesture(daySwipeGesture)
            .task(id: "\(repo.refreshSeq)-\(selectedDayOffset)-\(repo.hydrationSeq)-\(hydrationEnabled)") {
                await load()
            }
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
            .sheet(item: $guideSection) { section in
                NavigationStack { ScoringGuideView(initialSection: section, onClose: { guideSection = nil }) }
            }
            .sheet(item: $customizationDestination) { destination in
                TodayCustomizationSheet(
                    initialDestination: destination,
                    sectionOrderRaw: $sectionOrderRaw,
                    hiddenSectionsRaw: $hiddenSectionsRaw,
                    keyMetricsRaw: $keyMetricsRaw,
                    keyMetricsDetailed: $keyMetricsDetailed,
                    keyMetricsWindowDays: $keyMetricsWindowDays,
                    dashboardCardsRaw: $dashboardCardsRaw,
                    hostedCardsRaw: $hostedCardsRaw
                )
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    SettingsView().background(Aurora.canvas.ignoresSafeArea())
                }
            }
            .auroraLiveSessionCover(isPresented: $showLiveSession)
        }
    }

    /// One reorderable section. Every `TodaySection` case is handled, and a gated-off section renders
    /// nothing while keeping its slot in the saved order — the same contract Liquid Today honours.
    @ViewBuilder
    private func sectionBody(_ section: TodaySection) -> some View {
        switch section {
        case .hero: heroSection
        case .liveSession: if liveSessionsBeta { liveSessionStartRow }
        case .synthesis: synthesisSection
        case .keyMetrics: keyMetricsSection
        case .workouts: workoutsSection
        case .heartRate: heartRateSection
        case .recoveryVitals: recoveryVitalsSection
        case .yourCards: yourCardsSection
        case .menstrualCycle: if selectedDayOffset == 0 { MenstrualCycleHomeCard() }
        case .journal: if selectedDayOffset == 0 { JournalReminderCard() }
        case .addedCards: if selectedDayOffset == 0 { hostedCardsSection }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.m) {
            HStack(alignment: .top, spacing: Aurora.Space.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(greeting).auroraLabel()
                    Text(dayTitle)
                        .auroraTitleLarge()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(dateLine).auroraCaption()
                }

                Spacer(minLength: Aurora.Space.xs)

                HStack(spacing: Aurora.Space.xs) {
                    // Isolated leaf — it owns LiveState so the ~1 Hz tick re-renders the pill, not Home.
                    AuroraConnectionPill()

                    #if os(macOS)
                    // iOS gets pull-to-refresh; the Mac has no pull gesture, so the same action
                    // (offload request + reload) needs an explicit control or it is unreachable here.
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
                            .frame(width: Aurora.Layout.minTapTarget,
                                   height: Aurora.Layout.minTapTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.auroraPress)
                    .accessibilityLabel(Text("Sync and refresh"))
                    #endif

                    Button { showSettings = true } label: {
                        ProfileAvatarView(imageData: profile.avatarImageData,
                                          size: Aurora.Layout.glyphPlate,
                                          fallbackTint: Aurora.textSecondary)
                            .frame(width: Aurora.Layout.glyphPlate, height: Aurora.Layout.glyphPlate)
                            .frame(width: Aurora.Layout.minTapTarget,
                                   height: Aurora.Layout.minTapTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.auroraPress)
                    .accessibilityLabel(Text("Profile and settings"))

                    Button { customizationDestination = .today } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Aurora.textSecondary)
                            .frame(width: Aurora.Layout.minTapTarget,
                                   height: Aurora.Layout.minTapTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.auroraPress)
                    .accessibilityLabel(Text("Customize Today"))
                }
            }

            dayNavigator
        }
    }

    /// Explicit day stepper. The horizontal swipe is still the primary gesture (and unchanged); these
    /// controls make the same navigation discoverable and keyboard/pointer reachable on the Mac.
    private var dayNavigator: some View {
        HStack(spacing: Aurora.Space.xs) {
            Button { stepDay(1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.auroraPress)
            .disabled(selectedDayOffset >= earliestDayOffset)
            .foregroundStyle(selectedDayOffset >= earliestDayOffset ? Aurora.textDisabled : Aurora.textSecondary)
            .accessibilityLabel(Text("Previous day"))

            Button { showDayPicker = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar").font(.system(size: 11, weight: .semibold))
                    Text(dateLine).font(AuroraType.captionStrong).lineLimit(1)
                }
                .foregroundStyle(Aurora.textSecondary)
                .padding(.horizontal, Aurora.Space.s)
                .frame(height: 28)
                .background(
                    Capsule().fill(Aurora.surfaceInset)
                        .overlay(Capsule().strokeBorder(Aurora.hairline, lineWidth: Aurora.Stroke.hairline))
                )
            }
            .buttonStyle(.auroraPress)
            .accessibilityLabel(Text("\(dayTitle). Pick a day, or swipe to change day."))
            .popover(isPresented: $showDayPicker) {
                DatePicker("", selection: dayPickerBinding, in: ...Repository.logicalDay(Date()),
                           displayedComponents: [.date])
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding(Aurora.Space.s)
                    .frame(minWidth: 320, minHeight: 360)
                    .auroraPopoverAdaptation()
            }

            Button { stepDay(-1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.auroraPress)
            .disabled(selectedDayOffset == 0)
            .foregroundStyle(selectedDayOffset == 0 ? Aurora.textDisabled : Aurora.textSecondary)
            .accessibilityLabel(Text("Next day"))

            Spacer(minLength: 0)
        }
    }

    // MARK: - Hero

    /// The hero composition: one dominant Charge ring carrying the band name and a one-line read, with
    /// Effort and Rest as secondary arc gauges beneath it. When the baseline is still forming the ring
    /// renders its honest empty state and the progress card below counts the nights in.
    private var heroSection: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.s) {
            AuroraCard(elevation: .raised,
                       padding: Aurora.Space.heroPadding,
                       radius: Aurora.Radius.hero,
                       tint: chargeTint) {
                VStack(spacing: Aurora.Space.l) {
                    chargeRing
                    chargeReadout
                    AuroraDivider()
                    secondaryGauges
                    if let sourceLabel = heroSourceLabel {
                        Text(String(localized: "Source: \(sourceLabel)"))
                            .auroraFootnote()
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }

            if let nights = calibrationNights {
                baselineProgressCard(nights: nights)
            }
        }
    }

    /// The Charge tint drives the hero's card wash and the band pill. Falls back to the neutral accent
    /// while there is no honest number to colour with.
    private var chargeTint: Color {
        chargeDisplay.pct.map { Aurora.recoveryColor($0) } ?? Aurora.accent
    }

    private var chargeRing: some View {
        Button { guideSection = .charge } label: {
            AuroraRing(
                progress: chargeDisplay.pct.map { max(0, min(1, $0 / 100)) },
                value: chargeDisplay.pct.map { String(Int($0.rounded())) },
                unit: chargeDisplay.pct == nil ? nil : "%",
                label: String(localized: "Charge"),
                caption: chargeRingCaption,
                ramp: .recovery,
                lineWidth: Aurora.Stroke.ring,
                size: Aurora.Layout.heroRingSize,
                showsGlow: dataLoaded && !poseStill,
                emptyHint: chargeRingCaption
            )
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.auroraPress)
        .accessibilityLabel(Text("Charge, \(chargeDisplay.pct.map { String(Int($0.rounded())) } ?? String(localized: "no data yet")). See how it is scored."))
    }

    /// The ring's own quiet line: the band name for a real score, the carried-day stamp for a carry,
    /// and the honest calibration / no-data line otherwise.
    private var chargeRingCaption: String {
        switch chargeDisplay {
        case .scored(let pct): return AuroraRecoveryBand(pct: pct).label
        case .carried(_, let caption): return caption
        case .calibrating: return String(localized: "Calibrating")
        case .noData: return String(localized: "No data yet")
        }
    }

    /// Band pill + state pill + the one-line interpretation directly under the number.
    private var chargeReadout: some View {
        VStack(spacing: Aurora.Space.s) {
            HStack(spacing: Aurora.Space.xs) {
                if let pct = chargeDisplay.pct {
                    let band = AuroraRecoveryBand(pct: pct)
                    AuroraStatusPill(band.label, style: .tinted, overrideColor: band.color)
                }
                AuroraStatusPill(chargeDisplay.stateLabel,
                                 tone: chargeStateTone,
                                 style: .outline)
                if let word = readinessWord {
                    AuroraStatusPill(word.uppercased(), tone: .accent, style: .tinted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Text(chargeDisplay.calibrationDetail ?? synthLine)
                .auroraBody()
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var chargeStateTone: AuroraTone {
        switch chargeDisplay {
        case .scored: return .good
        case .carried: return .neutral
        case .calibrating: return .caution
        case .noData: return .neutral
        }
    }

    /// Effort and Rest — secondary by design. Each is tappable through to its scoring-guide section,
    /// exactly as the Liquid hero's label rows are.
    private var secondaryGauges: some View {
        HStack(alignment: .top, spacing: Aurora.Space.m) {
            secondaryGauge(
                label: String(localized: "Effort"),
                value: effortValue,
                maxValue: effortScale == .whoop ? 21 : 100,
                decimals: effortScale == .whoop ? 1 : 0,
                ramp: .strain,
                caption: effortCaption,
                section: .effort
            )

            Rectangle()
                .fill(Aurora.divider)
                .frame(width: Aurora.Stroke.hairline, height: Aurora.Layout.compactRingSize)
                .accessibilityHidden(true)

            secondaryGauge(
                label: String(localized: "Rest"),
                value: restScore,
                maxValue: 100,
                decimals: 0,
                ramp: .sleep,
                caption: restCaption,
                section: .rest
            )
        }
    }

    private func secondaryGauge(label: String, value: Double?, maxValue: Double, decimals: Int,
                                ramp: AuroraRamp, caption: String, section: ScoreSection) -> some View {
        Button { guideSection = section } label: {
            VStack(spacing: Aurora.Space.xs) {
                AuroraArcGauge(
                    progress: value.map { max(0, min(1, $0 / maxValue)) },
                    value: value.map {
                        decimals > 0
                            ? String(format: "%.\(decimals)f", locale: AppLanguage.activeLocale, $0)
                            : String(Int($0.rounded()))
                    },
                    label: label,
                    ramp: ramp,
                    lineWidth: Aurora.Stroke.ringCompact,
                    emptyHint: ""
                )
                .frame(height: Aurora.Layout.compactRingSize)

                Text(caption)
                    .auroraFootnote()
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.auroraPress)
        .accessibilityLabel(Text("\(label), \(value.map { String(Int($0.rounded())) } ?? String(localized: "no data yet")). See how it is scored."))
    }

    /// The Effort hero honours the user's Effort scale (#45) — the value AND its gauge max move together.
    private var effortValue: Double? {
        displayDay?.strain.map { UnitFormatter.effortValue($0, scale: effortScale) }
    }

    /// The calm-day note, verbatim from the shared gate, so a genuine ~0 explains itself.
    private var effortCaption: String {
        if LiquidTodayView.EffortDisplay.showsZeroNote(strain: displayDay?.strain,
                                                       isToday: selectedDayOffset == 0) {
            return String(localized: "No cardio load yet")
        }
        guard effortValue != nil else { return String(localized: "Not measured yet") }
        return effortScale == .whoop
            ? String(localized: "Day strain, 0–21")
            : String(localized: "Day strain, 0–100")
    }

    private var restCaption: String {
        restScore == nil
            ? String(localized: "No scored night yet")
            : String(localized: "Sleep performance")
    }

    // MARK: - First-run baseline gate

    /// Nights banked toward the 4-night seed, or nil once Charge is scoring. Non-nil ONLY while the
    /// baseline is genuinely still forming — the same distinction `ChargeDisplay` draws, so a wearer who
    /// simply skipped a night is never told they are "calibrating".
    private var calibrationNights: Int? {
        if case .calibrating(let n) = chargeDisplay { return n }
        return cachedCalibrationNights
    }

    /// The first-run experience, designed rather than tolerated: four night pips fill in, the copy says
    /// exactly how many nights remain, and each row names what that night unlocks. Nothing here claims a
    /// number it does not have.
    private func baselineProgressCard(nights: Int) -> some View {
        let seed = Baselines.minNightsSeed
        let remaining = max(0, seed - nights)
        return AuroraCard(elevation: .base, tint: Aurora.accent) {
            VStack(alignment: .leading, spacing: Aurora.Space.m) {
                HStack(alignment: .firstTextBaseline, spacing: Aurora.Space.xs) {
                    Text(String(localized: "Learning your baseline")).auroraHeadline()
                    Spacer(minLength: Aurora.Space.xs)
                    Text(verbatim: "\(min(nights, seed))/\(seed)")
                        .font(AuroraType.tabularLabel)
                        .foregroundStyle(Aurora.accent)
                }

                // Night pips — the progress read at a glance, no percentage invented.
                HStack(spacing: Aurora.Space.xs) {
                    ForEach(0..<seed, id: \.self) { index in
                        AuroraAnimatedValue(dataLoaded && index < nights ? 1 : 0) { t in
                            Capsule()
                                .fill(Aurora.accent.opacity(0.16 + 0.84 * t))
                                .frame(height: Aurora.Layout.trackHeight)
                        }
                    }
                }
                .animation(Aurora.Motion.respecting(Aurora.Motion.drawIn, reduced: poseStill),
                           value: nights)
                .accessibilityElement()
                .accessibilityLabel(Text("\(nights) of \(seed) nights banked"))

                Text(remaining == 0
                     ? String(localized: "Baseline seeded. Your first Charge lands after tonight's sleep is scored.")
                     : String(localized: "NOOP scores Charge against your own baseline, not an average person's. \(remaining) more night\(remaining == 1 ? "" : "s") of sleep and it starts scoring."))
                    .auroraBody()
                    .fixedSize(horizontal: false, vertical: true)

                AuroraDivider()

                VStack(alignment: .leading, spacing: Aurora.Space.s) {
                    unlockRow(icon: "waveform.path.ecg",
                              title: String(localized: "Already recording"),
                              detail: String(localized: "HRV, resting heart rate, breathing rate and sleep stages are banked every night from the first one."))
                    unlockRow(icon: "bolt.fill",
                              title: String(localized: "Effort works today"),
                              detail: String(localized: "Effort needs no baseline — it scores from the moment your heart rate climbs."))
                    unlockRow(icon: "heart.fill",
                              title: String(localized: "Charge unlocks at \(seed) nights"),
                              detail: String(localized: "Recovery is only meaningful against your own normal, so it waits until it knows what yours is."))
                }
            }
        }
    }

    private func unlockRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Aurora.Space.s) {
            ZStack {
                RoundedRectangle(cornerRadius: Aurora.Radius.xs, style: .continuous)
                    .fill(Aurora.accent.opacity(0.12))
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Aurora.accent)
            }
            .frame(width: Aurora.Layout.glyphPlate, height: Aurora.Layout.glyphPlate)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).auroraCaptionStrong()
                Text(detail).auroraFootnote().fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Live session

    private var liveSessionStartRow: some View {
        Button { showLiveSession = true } label: {
            AuroraCard(elevation: .base, padding: Aurora.Space.s + 2) {
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
        .accessibilityLabel(Text("Start a live session. Beta. Silent strap coaching against today's Charge."))
    }

    // MARK: - Synthesis

    /// The editorial read. A headline, the one-line verdict, and — on tap — the engine's own longer
    /// summary. Reads as writing, not as a debug string.
    private var synthesisSection: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.s) {
            AuroraSectionHeader(String(localized: "Today's read"),
                                subtitle: readinessConfidenceLine)

            Button {
                withAnimation(Aurora.Motion.respecting(Aurora.Motion.standard, reduced: poseStill)) {
                    synthesisExpanded.toggle()
                }
            } label: {
                AuroraCard(elevation: .base) {
                    VStack(alignment: .leading, spacing: Aurora.Space.s) {
                        Text(LocalizedStringKey(readiness.headline))
                            .auroraTitle()
                            .fixedSize(horizontal: false, vertical: true)

                        Text(chargeDisplay.calibrationDetail ?? synthLine)
                            .auroraBody()
                            .fixedSize(horizontal: false, vertical: true)

                        if synthesisExpanded {
                            AuroraDivider()
                            Text(LocalizedStringKey(readiness.summary))
                                .auroraCaption()
                                .fixedSize(horizontal: false, vertical: true)

                            if !readiness.signals.isEmpty {
                                VStack(alignment: .leading, spacing: Aurora.Space.xs) {
                                    ForEach(readiness.signals, id: \.key) { signal in
                                        signalRow(signal)
                                    }
                                }
                            }
                        }

                        HStack(spacing: 4) {
                            Text(synthesisExpanded ? String(localized: "hide") : String(localized: "show"))
                                .font(AuroraType.captionStrong)
                            Image(systemName: synthesisExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(Aurora.accent)
                    }
                }
            }
            .buttonStyle(.auroraPress)
        }
    }

    private func signalRow(_ signal: ReadinessEngine.Signal) -> some View {
        HStack(alignment: .top, spacing: Aurora.Space.xs) {
            Circle()
                .fill(signalTone(signal.flag).foreground)
                .frame(width: 6, height: 6)
                .padding(.top, 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(signal.label).auroraCaptionStrong()
                    if let evidence = signal.evidence {
                        Text(evidence).auroraFootnote()
                    }
                }
                Text(signal.detail).auroraFootnote().fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func signalTone(_ flag: ReadinessEngine.Flag) -> AuroraTone {
        switch flag {
        case .good: return .good
        case .neutral: return .neutral
        case .watch: return .caution
        case .bad: return .alert
        }
    }

    /// How much history backs the read — surfaced so a confident sentence off a thin baseline is
    /// labelled as such instead of reading like a verdict.
    private var readinessConfidenceLine: String? {
        switch readiness.confidence {
        case .calibrating: return String(localized: "Baseline still calibrating")
        case .building: return String(localized: "Baseline still building")
        case .solid: return nil
        }
    }

    // MARK: - Key metrics

    private var sparkWindowCutoffKey: String {
        let days = (keyMetricsWindowDays == 7 || keyMetricsWindowDays == 30) ? keyMetricsWindowDays : 14
        let cal = Calendar.current
        let anchor = cal.startOfDay(for: selectedLogicalDay)
        return Repository.localDayKey(cal.date(byAdding: .day, value: -(days - 1), to: anchor) ?? anchor)
    }

    private func windowedSpark(_ key: String) -> [Double] {
        let cutoff = sparkWindowCutoffKey
        return (kSparks[key] ?? []).filter { $0.0 >= cutoff }.map { $0.1 }
    }

    private var trendWindowLabel: String {
        switch keyMetricsWindowDays {
        case 7: return String(localized: "7-day trend")
        case 30: return String(localized: "30-day trend")
        default: return String(localized: "14-day trend")
        }
    }

    private var keyMetricsSection: some View {
        // The same per-field, today-first vitals carry the Liquid grid uses, coalesced once so a tile's
        // number and its fill can never disagree.
        let hrv = displayDay?.avgHrv ?? vitalsDay?.avgHrv
        let rhr = (displayDay?.restingHr ?? vitalsDay?.restingHr).map(Double.init)
        return VStack(alignment: .leading, spacing: Aurora.Space.s) {
            AuroraSectionHeader(String(localized: "Key metrics"),
                                subtitle: trendWindowLabel,
                                actionTitle: String(localized: "Edit"),
                                actionIcon: nil,
                                action: { customizationDestination = .keyMetrics })

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Aurora.Space.cardGap)],
                      spacing: Aurora.Space.cardGap) {
                ForEach(enabledKeyMetrics) { metric in
                    tile(for: metric, hrv: hrv, rhr: rhr)
                }
            }

            NavigationLink(value: TabRoute.metricExplorer) {
                AuroraCard(elevation: .flat, padding: Aurora.Space.s + 2) {
                    HStack {
                        Text(String(localized: "Show all metrics")).auroraBodyStrong()
                        Spacer(minLength: Aurora.Space.xs)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Aurora.textTertiary)
                    }
                }
            }
            .buttonStyle(.auroraPress)
        }
    }

    /// One editor-selected Key-Metric tile. Every value, tint, fallback tier and tap-through route is the
    /// SAME one the Liquid grid resolves — only the tile that draws it is Aurora's.
    @ViewBuilder
    private func tile(for metric: KeyMetric, hrv: Double?, rhr: Double?) -> some View {
        switch metric {
        case .charge:
            // Reads the RESOLVED Charge the hero draws, never `displayDay?.recovery` raw, so one screen
            // never shows two answers for Charge (#543).
            metricTile(String(localized: "Recovery"), icon: icon(for: metric),
                       value: intText(chargeDisplay.pct), unit: "%",
                       accent: chargeDisplay.pct.map { Aurora.recoveryColor($0) } ?? Aurora.statusNeutral,
                       sparkKey: "recovery", detailKey: "recovery",
                       emptyHint: chargeDisplay.calibrationDetail ?? String(localized: "No scored night yet"))
        case .effort:
            metricTile(String(localized: "Strain"), icon: icon(for: metric),
                       value: intText(displayDay?.strain), unit: "%",
                       accent: displayDay?.strain.map { Aurora.strainColor($0, scale: 100) } ?? Aurora.statusNeutral,
                       sparkKey: "strain", detailKey: "strain")
        case .rest:
            metricTile(String(localized: "Rest"), icon: icon(for: metric),
                       value: intText(restScore), unit: "%",
                       accent: restScore.map { Aurora.sleepColor($0) } ?? Aurora.statusNeutral,
                       sparkKey: "sleep_performance", detailKey: "sleep_performance")
        case .hrv:
            metricTile("HRV", icon: icon(for: metric), value: intText(hrv), unit: "ms",
                       accent: Aurora.accent, sparkKey: "hrv", detailKey: "hrv",
                       caption: vitalsCarryCaption)
        case .restingHr:
            metricTile(String(localized: "Rest HR"), icon: icon(for: metric), value: intText(rhr), unit: "bpm",
                       accent: Aurora.statusAlert, sparkKey: "rhr", detailKey: "rhr",
                       caption: vitalsCarryCaption)
        case .bloodOxygen:
            // The candidate fallback is gated exactly as everywhere else: only when the real reading is
            // missing AND the experimental toggle is on, and it ALWAYS carries its label.
            let spo2Real = displayDay?.spo2Pct ?? vitalsDay?.spo2Pct
            let candidateOn = PuffinExperiment.spo2CandidateDisplayEnabled
            let candidate = spo2Real == nil && candidateOn
                ? spo2CandidateByDay[cachedDisplayDay?.day ?? selectedDayKey]
                : nil
            let spo2 = spo2Real ?? candidate
            metricTile(String(localized: "Blood Oxygen"), icon: icon(for: metric),
                       value: intText(spo2), unit: "%", accent: Aurora.accent,
                       sparkKey: candidate != nil ? "spo2_candidate" : "spo2",
                       detailKey: "spo2",
                       caption: candidate != nil ? String(localized: "strap estimate (unverified)") : nil)
        case .respiratory:
            let resp = displayDay?.respRateBpm ?? vitalsDay?.respRateBpm ?? respDay?.respRateBpm
            metricTile(String(localized: "Respiratory"), icon: icon(for: metric),
                       value: resp.map { String(format: "%.1f", locale: AppLanguage.activeLocale, $0) },
                       unit: "rpm", accent: Aurora.accent,
                       sparkKey: "resp_rate", detailKey: "resp_rate")
        case .steps:
            metricTile(String(localized: "Steps"), icon: icon(for: metric),
                       value: stepsText, unit: nil, accent: Aurora.statusGood,
                       sparkKey: stepsDetailKey, detailMetric: stepsDetailMetric,
                       detailKey: stepsDetailKey)
        case .weight:
            // No liquid/aurora value source for weight yet — the tile still taps through to the weight
            // trend, which has its own series. An honest empty tile, not a fabricated number.
            metricTile(String(localized: "Weight"), icon: icon(for: metric),
                       value: nil, unit: nil, accent: Aurora.statusCaution,
                       sparkKey: nil, detailKey: "weight",
                       emptyHint: String(localized: "Log a weight to start this trend"))
        case .calories:
            metricTile(String(localized: "Calories"), icon: icon(for: metric),
                       value: intText(caloriesCount), unit: "kcal", accent: Aurora.statusCaution,
                       sparkKey: "energy_kcal", detailMetric: caloriesDetailMetric,
                       detailKey: "energy_kcal")
        case .skinTemp:
            let skinValue = displayDay?.skinTempDevC ?? vitalsDay?.skinTempDevC
            metricTile(String(localized: "Skin Temp"), icon: icon(for: metric),
                       value: skinValue.map {
                           SkinTempDisplay.format($0, fahrenheit: temperatureUnit == .fahrenheit)
                       },
                       unit: nil, accent: Aurora.statusCaution,
                       sparkKey: "skin_temp", detailKey: "skin_temp")
        }
    }

    /// One tile, wrapped in the same closure-based `NavigationLink` the Liquid grid pushes so the
    /// tap-through destination is unchanged. A metric with no catalog entry stays inert.
    @ViewBuilder
    private func metricTile(_ label: String, icon: String, value: String?, unit: String?,
                            accent: Color, sparkKey: String?, detailMetric: MetricDescriptor? = nil,
                            detailKey: String? = nil, caption: String? = nil,
                            emptyHint: String = "") -> some View {
        let spark = sparkKey.map { windowedSpark($0) } ?? []
        let tile = AuroraMetricTile(
            label: label,
            value: value,
            unit: unit,
            icon: icon,
            accent: accent,
            sparkline: spark.count >= 2 ? spark : nil,
            caption: caption,
            emptyHint: emptyHint.isEmpty ? String(localized: "Not measured yet") : emptyHint,
            elevation: .base,
            height: keyMetricsDetailed ? 168 : Aurora.Layout.metricTileHeight
        )
        if let descriptor = detailMetric ?? detailKey.flatMap({ key in
            MetricCatalog.all.first(where: { $0.key == key })
        }) {
            NavigationLink { MetricDetailView(metric: descriptor) } label: { tile }
                .buttonStyle(.plain)
        } else {
            tile
        }
    }

    private func icon(for metric: KeyMetric) -> String {
        switch metric {
        case .charge: return "heart.fill"
        case .effort: return "bolt.fill"
        case .rest: return "moon.stars.fill"
        case .hrv: return "waveform.path.ecg"
        case .restingHr: return "heart.circle.fill"
        case .bloodOxygen: return "drop.fill"
        case .respiratory: return "lungs.fill"
        case .steps: return "figure.walk"
        case .weight: return "scalemass.fill"
        case .calories: return "flame.fill"
        case .skinTemp: return "thermometer.medium"
        }
    }

    // MARK: - Recovery vitals

    private var recoveryVitalsSection: some View {
        let hrv = displayDay?.avgHrv ?? vitalsDay?.avgHrv
        let rhr = (displayDay?.restingHr ?? vitalsDay?.restingHr).map(Double.init)
        let resp = displayDay?.respRateBpm ?? vitalsDay?.respRateBpm
        return VStack(alignment: .leading, spacing: Aurora.Space.s) {
            AuroraSectionHeader(String(localized: "Recovery vitals"),
                                subtitle: vitalsProvenanceLine)
            AuroraCard(elevation: .base) {
                VStack(spacing: Aurora.Space.rowGap) {
                    vitalRow(String(localized: "Heart-rate variability"),
                             value: hrv, unit: "ms", decimals: 0,
                             fraction: fracOver(hrv, 120), spark: windowedSpark("hrv"),
                             accent: Aurora.accent)
                    AuroraDivider()
                    vitalRow(String(localized: "Resting heart rate"),
                             value: rhr, unit: "bpm", decimals: 0,
                             fraction: fracOver(rhr, 100), spark: windowedSpark("rhr"),
                             accent: Aurora.statusAlert)
                    AuroraDivider()
                    vitalRow(String(localized: "Breaths per minute"),
                             value: resp, unit: "rpm", decimals: 1,
                             fraction: fracOver(resp, 24), spark: windowedSpark("resp_rate"),
                             accent: Aurora.statusGood)
                }
            }
        }
    }

    private func vitalRow(_ label: String, value: Double?, unit: String, decimals: Int,
                          fraction: Double?, spark: [Double], accent: Color) -> some View {
        HStack(spacing: Aurora.Space.s) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).auroraCaption().lineLimit(1).minimumScaleFactor(0.8)
                // A quiet magnitude track: it reads the same fraction the number does, so the bar can
                // never disagree with the value beside it.
                AuroraAnimatedValue(dataLoaded ? (fraction ?? 0) : 0) { t in
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Aurora.surfaceInset)
                            Capsule().fill(accent.opacity(0.85))
                                .frame(width: max(0, geo.size.width * t))
                        }
                    }
                }
                .frame(height: 5)
                .opacity(fraction == nil ? 0.35 : 1)
                .accessibilityHidden(true)
            }

            if spark.count >= 2 {
                AuroraSparkline(values: spark, tint: accent, showsArea: false, showsHead: false)
                    .frame(width: 56, height: 22)
                    .accessibilityHidden(true)
            }

            AuroraValueUnit(value: value.map {
                decimals > 0
                    ? String(format: "%.\(decimals)f", locale: AppLanguage.activeLocale, $0)
                    : String(Int($0.rounded()))
            } ?? "—", unit: value == nil ? nil : unit, role: .metricSmall)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Heart rate

    private var heartRateSection: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.s) {
            AuroraSectionHeader(String(localized: "Heart rate"), subtitle: String(localized: "Live"))
            NavigationLink(value: TabRoute.fullDayChart) {
                // Isolated leaf: it owns LiveState so the ~1 Hz notify re-renders ONLY this card.
                AuroraLiveHRCard(fallback: hrValues, animated: dataLoaded)
            }
            .buttonStyle(.auroraPress)
            .accessibilityHint(Text("Opens the full-day heart rate timeline"))
        }
    }

    // MARK: - Workouts

    private var workoutsSection: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.s) {
            AuroraSectionHeader(String(localized: "Workouts"),
                                subtitle: workouts.isEmpty ? nil : "\(workouts.count) total")
            if let w = workouts.first {
                NavigationLink(value: TabRoute.workouts) { workoutCard(w) }
                    .buttonStyle(.auroraPress)
            } else {
                AuroraCard(elevation: .base) {
                    AuroraEmptyState(
                        icon: "figure.run",
                        headline: String(localized: "No workouts yet"),
                        message: String(localized: "Record a session, or import one, and your last workout shows up here with its Effort.")
                    )
                }
            }
        }
    }

    private func workoutCard(_ w: WorkoutRow) -> some View {
        AuroraCard(elevation: .base) {
            VStack(alignment: .leading, spacing: Aurora.Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: Aurora.Space.xs) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(WorkoutSource.displaySport(w.sport)).auroraBodyStrong()
                        Text(workoutSub(w)).auroraFootnote()
                    }
                    Spacer(minLength: Aurora.Space.xs)
                    AuroraValueUnit(value: effortText(w.strain),
                                    unit: String(localized: "Effort"),
                                    role: .metricSmall,
                                    valueColor: w.strain.map { Aurora.strainColor($0, scale: 100) })
                }
                AuroraAnimatedValue(dataLoaded ? min(1, max(0, (w.strain ?? 0) / 100)) : 0) { t in
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Aurora.surfaceInset)
                            Capsule()
                                .fill(AuroraRamp.strain.areaFill(topOpacity: 1, bottomOpacity: 0.7))
                                .frame(width: max(0, geo.size.width * t))
                        }
                    }
                }
                .frame(height: Aurora.Layout.trackHeight)
                .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Your cards

    private var yourCardsSection: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.s) {
            AuroraSectionHeader(String(localized: "Your cards"),
                                actionTitle: String(localized: "Edit"),
                                actionIcon: nil,
                                action: { customizationDestination = .yourCards })
            VStack(spacing: Aurora.Space.xs) {
                ForEach(DashboardCardPrefs.decodeEnabled(dashboardCardsRaw)
                    .filter { hydrationEnabled || $0 != .hydration }) { card in
                    dashboardRow(for: card)
                }
            }
        }
    }

    /// One "Your cards" row. Every value, tint and route is resolved exactly as the Liquid screen
    /// resolves it, including the SpO₂ candidate label and the imported-first steps / calories routing.
    @ViewBuilder
    private func dashboardRow(for card: DashboardCard) -> some View {
        switch card {
        case .stress:
            cardRow(.stress, card: card, value: stressText,
                    accent: stress.map { Aurora.stressColor($0 / 3 * 100) } ?? Aurora.statusNeutral,
                    fraction: fracOver(stress, 3))
        case .fitnessAge:
            cardRow(.metric("fitness_age"), card: card, value: unitText(fitnessAge, card.unit),
                    accent: Aurora.statusGood, fraction: nil)
        case .vo2max:
            cardRow(.metric("vo2max_est"), card: card, value: unitText(vo2max, card.unit),
                    accent: Aurora.statusGood, fraction: nil)
        case .vitality:
            cardRow(.metric("vitality"), card: card, value: intText(vitality) ?? "—",
                    accent: Aurora.accent, fraction: frac(vitality))
        case .hrv:
            cardRow(.metric("hrv"), card: card, value: unitText(displayDay?.avgHrv, card.unit),
                    accent: Aurora.accent, fraction: fracOver(displayDay?.avgHrv, 120))
        case .restingHr:
            cardRow(.metric("rhr"), card: card,
                    value: unitText(displayDay?.restingHr.map(Double.init), card.unit),
                    accent: Aurora.statusAlert,
                    fraction: fracOver(displayDay?.restingHr.map(Double.init), 100))
        case .respiratory:
            cardRow(.metric("resp_rate"), card: card,
                    value: unitText(displayDay?.respRateBpm, card.unit, decimals: 1),
                    accent: Aurora.statusGood, fraction: fracOver(displayDay?.respRateBpm, 24))
        case .steps:
            cardRow(.metricSourced(key: stepsDetailKey, source: stepsDetailSource), card: card,
                    value: stepsText ?? "—", accent: Aurora.statusGood,
                    fraction: fracOver(stepCount, 10000))
        case .bloodOxygen:
            let spo2Real = displayDay?.spo2Pct ?? vitalsDay?.spo2Pct
            let candidateOn = PuffinExperiment.spo2CandidateDisplayEnabled
            let candidate = spo2Real == nil && candidateOn
                ? spo2CandidateByDay[cachedDisplayDay?.day ?? selectedDayKey]
                : nil
            let spo2 = spo2Real ?? candidate
            cardRow(.metric("spo2"), card: card,
                    subtitleOverride: candidate != nil
                        ? String(localized: "strap estimate (unverified)") : nil,
                    value: spo2.map { String(format: "%.0f%%", locale: AppLanguage.activeLocale, $0) } ?? "—",
                    accent: Aurora.accent, fraction: fracOver(spo2, 100))
        case .skinTemp:
            let skin = displayDay?.skinTempDevC ?? vitalsDay?.skinTempDevC
            cardRow(.metric("skin_temp"), card: card,
                    value: TodayView.skinTempCardValue(skin, fahrenheit: temperatureUnit == .fahrenheit),
                    accent: Aurora.statusCaution, fraction: nil)
        case .calories:
            cardRow(.metricSourced(key: caloriesDetailKey, source: caloriesDetailSource), card: card,
                    value: intText(caloriesCount) ?? "—", accent: Aurora.statusCaution,
                    fraction: fracOver(caloriesCount, 800))
        case .sleep:
            cardRow(.sleep, card: card, value: sleepText, accent: Aurora.sleepColor(70),
                    fraction: fracOver(displayDay?.totalSleepMin, 480))
        case .hydration:
            cardRow(.hydration, card: card,
                    value: hydrationGoalML.map {
                        HydrationGoal.cardValueString(totalML: hydrationTotalML ?? 0, goalML: $0)
                    } ?? "—",
                    accent: Aurora.accent,
                    fraction: hydrationGoalML.map {
                        HydrationGoal.fraction(totalML: hydrationTotalML ?? 0, goalML: $0)
                    })
        case .coupled:
            cardRow(.coupled, card: card, value: "", accent: Aurora.statusGood, fraction: nil)
        }
    }

    private func cardRow(_ route: TabRoute, card: DashboardCard, subtitleOverride: String? = nil,
                         value: String, accent: Color, fraction: Double?) -> some View {
        NavigationLink(value: route) {
            AuroraCard(elevation: .base, padding: Aurora.Space.s + 2, radius: Aurora.Radius.m) {
                HStack(spacing: Aurora.Space.s) {
                    ZStack {
                        Circle().fill(accent.opacity(0.12))
                        if let fraction {
                            AuroraAnimatedValue(dataLoaded ? fraction : 0) { t in
                                Circle()
                                    .trim(from: 0, to: max(0.001, t))
                                    .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                    .padding(3)
                            }
                        }
                        Image(systemName: card.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                    .frame(width: 34, height: 34)
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

    // MARK: - Hosted cards (#today-hosted-cards)

    /// The Trends / Sleep cards the user hosted, in their arranged order — each rendered as the SAME
    /// view its home tab renders, so the copy and the original can never diverge.
    @ViewBuilder
    private var hostedCardsSection: some View {
        let cards = HostedCardPrefs.decodeEnabled(hostedCardsRaw)
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: Aurora.Space.l) {
                ForEach(cards) { card in
                    hostedCard(for: card)
                }
            }
        }
    }

    @ViewBuilder
    private func hostedCard(for card: HostedCard) -> some View {
        switch card {
        case .sleepMarks: SleepMarkCard()
        case .asleepDuration: AsleepDurationCard(data: AsleepDurationData.build(days: repo.days))
        case .stagesVsTypical:
            if let m = hostedSleepModel { StagesVsTypicalCard(model: m) }
            else { hostedPlaceholder(card) }
        case .nightDetail:
            if let m = hostedSleepModel { NightDetailCard(model: m) }
            else { hostedPlaceholder(card) }
        case .sleepDebt:
            if let m = hostedSleepModel { SleepDebtLedgerCard(model: m) }
            else { hostedPlaceholder(card) }
        case .stages:
            if let m = hostedSleepModel { StagesCard(model: m) }
            else { hostedPlaceholder(card) }
        case .hoursVsNeeded:
            if let m = hostedSleepModel { HoursVsNeededCard(model: m) }
            else { hostedPlaceholder(card) }
        case .consistency:
            if let m = hostedSleepModel { ConsistencyCard(model: m) }
            else { hostedPlaceholder(card) }
        }
    }

    /// Graceful empty state for a `SleepModel`-backed hosted card before its model builds (first frame)
    /// or when there is no usable latest night. Keeps the hosted slot present and labelled so
    /// add / remove / reorder in Customise still reads.
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

    // MARK: - Data sources

    private var dataSourcesSection: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.s) {
            AuroraSectionHeader(String(localized: "Data sources"),
                                subtitle: String(localized: "Provenance"))
            NavigationLink(value: TabRoute.dataSources) {
                AuroraCard(elevation: .base) {
                    VStack(spacing: Aurora.Space.rowGap) {
                        HStack {
                            Text(String(localized: "Synced from")).auroraCaption()
                            Spacer(minLength: Aurora.Space.xs)
                            HStack(spacing: 4) {
                                Text(String(localized: "View sources")).auroraCaptionStrong()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(Aurora.accent)
                        }
                        AuroraDivider()
                        // Isolated leaf — strap link / battery / offload state, ~1 Hz safe.
                        AuroraStrapStatusRow()
                    }
                }
            }
            .buttonStyle(.auroraPress)
        }
    }

    // MARK: - Load (identical accessors, identical order, identical fallbacks)

    private func load() async {
        if hydrationEnabled {
            hydrationTotalML = await repo.hydrationTotal(day: Repository.localDayKey(Date()))
            hydrationGoalML = repo.hydrationGoalML(profileSex: profile.sex)
        } else {
            hydrationTotalML = nil
            hydrationGoalML = nil
        }

        // Resolve every O(days) scan ONCE here, never in body.
        let day = resolveDisplayDay()
        cachedDisplayDay = day
        cachedReadiness = ReadinessEngine.evaluate(days: repo.days, today: day?.day)
        let tkey = cachedDisplayDay?.day ?? selectedDayKey
        cachedVitalsDay = (selectedDayOffset == 0) ? Repository.lastVitalsDay(days: repo.days, todayKey: tkey) : nil
        cachedRespDay = (selectedDayOffset == 0) ? Repository.lastRespDay(days: repo.days, todayKey: tkey) : nil

        let calNights = (selectedDayOffset == 0)
            ? RecoveryScorer.calibrationNights(nightlyHrv: repo.days.map(\.avgHrv),
                                               dayKeys: repo.days.map(\.day),
                                               hasRecovery: day?.recovery != nil)
            : nil
        cachedCalibrationNights = calNights
        let priorScored = TodayView.lastScoredRecoveryDay(
            days: repo.days, selectedDayKey: tkey,
            isToday: selectedDayOffset == 0,
            todayScored: day?.recovery != nil,
            isCalibrating: calNights != nil
        )
        cachedChargeDisplay = LiquidTodayView.ChargeDisplay.resolve(
            todayRecovery: day?.recovery,
            priorScored: priorScored,
            calibrationNights: calNights,
            todayKey: tkey)

        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: selectedLogicalDay)
        let from = Int(dayStart.timeIntervalSince1970)
        let to: Int = selectedDayOffset == 0
            ? Int(Date().timeIntervalSince1970)
            : Int((cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart).timeIntervalSince1970)

        async let restA = repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        async let stressA = repo.series(key: "stress", source: "my-whoop")
        async let fitA = repo.exploreSeries(key: "fitness_age", source: "my-whoop")
        async let vo2A = repo.exploreSeries(key: "vo2max_est", source: "my-whoop")
        async let vitA = repo.exploreSeries(key: "vitality", source: "my-whoop")
        async let stepsA = repo.exploreSeries(key: "steps_est", source: "my-whoop")
        async let spo2CandA = repo.exploreSeries(key: "spo2_candidate", source: "my-whoop")
        async let appleA = repo.appleDailyRows()
        async let hrA = repo.hrBuckets(from: from, to: to, bucketSeconds: 300)
        async let wkA = repo.workoutRows()

        let sourceDayKey = selectedDayKey
        let sourceFromDay = min(sourceDayKey, priorScored?.day ?? sourceDayKey)
        async let chargeSourceA = repo.resolvedSeries(key: "recovery", source: Repository.whoopSource,
                                                      from: sourceFromDay, to: sourceDayKey)
        async let effortSourceA = repo.resolvedSeries(key: "strain", source: Repository.whoopSource,
                                                      from: sourceDayKey, to: sourceDayKey)
        async let restSourceA = repo.resolvedSeries(key: "sleep_performance", source: Repository.whoopSource,
                                                    from: sourceDayKey, to: sourceDayKey)

        let restSeries = await restA
        let stepsSeries = await stepsA
        let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        restScore = TodayView.freshRestScore(
            todayValue: restByDay[selectedDayKey], lastDay: restSeries.last?.day,
            lastValue: restSeries.last?.value, isTodaySelected: selectedDayOffset == 0,
            todayKey: selectedDayKey)

        let storedStress = await stressA
        let daysSnapshot = repo.days

        // The 30-day SUPERSET the tiles graph; the chosen 1-week / 2-week / 1-month window filters at
        // render, so a picker change applies with no reload.
        let sparkCutoff = Repository.localDayKey(cal.date(byAdding: .day, value: -29, to: dayStart) ?? dayStart)
        let sparkRows = daysSnapshot.filter { $0.day >= sparkCutoff && $0.day <= selectedDayKey }
        let appleRowsForSpark = await appleA
        let spo2CandSeries = await spo2CandA
        spo2CandidateByDay = Dictionary(spo2CandSeries.map { ($0.day, $0.value) },
                                        uniquingKeysWith: { _, last in last })
        var winImportedKcal: [String: Double] = [:]
        for r in appleRowsForSpark where r.day >= sparkCutoff && r.day <= selectedDayKey {
            if let k = r.activeKcal { winImportedKcal[r.day] = max(winImportedKcal[r.day] ?? 0, k) }
        }
        var winOnDeviceKcal: [String: Double] = [:]
        for r in sparkRows { if let k = r.activeKcalEst { winOnDeviceKcal[r.day] = k } }
        let energyKcalSpark: [(String, Double)] = Set(winImportedKcal.keys).union(winOnDeviceKcal.keys).sorted()
            .compactMap { day in (winImportedKcal[day] ?? winOnDeviceKcal[day]).map { (day, $0) } }
        kSparks = [
            "recovery": sparkRows.compactMap { r in r.recovery.map { (r.day, $0) } },
            "strain": sparkRows.compactMap { r in r.strain.map { (r.day, $0) } },
            "hrv": sparkRows.compactMap { r in r.avgHrv.map { (r.day, $0) } },
            "rhr": sparkRows.compactMap { r in r.restingHr.map { (r.day, Double($0)) } },
            "spo2": sparkRows.compactMap { r in r.spo2Pct.map { (r.day, $0) } },
            "spo2_candidate": spo2CandSeries.filter { $0.day >= sparkCutoff && $0.day <= selectedDayKey },
            "skin_temp": sparkRows.compactMap { r in r.skinTempDevC.map { (r.day, $0) } },
            "resp_rate": sparkRows.compactMap { r in r.respRateBpm.map { (r.day, $0) } },
            "steps": sparkRows.compactMap { r in r.steps.map { (r.day, Double($0)) } },
            "energy_kcal": energyKcalSpark,
            "steps_est": stepsSeries.filter { $0.day >= sparkCutoff && $0.day <= selectedDayKey }
                .map { ($0.day, $0.value) },
            "sleep_performance": restSeries.filter { $0.day >= sparkCutoff && $0.day <= selectedDayKey }
                .map { ($0.day, $0.value) },
        ]

        // StressModel folds the full history — off the main actor so a long history can't stutter the UI.
        stress = await Task.detached(priority: .utility) {
            StressModel(days: daysSnapshot, stored: storedStress)?.score
        }.value

        fitnessAge = (await fitA).last?.value
        vo2max = (await vo2A).last?.value
        vitality = (await vitA).last?.value

        let stepsByDay = Dictionary(stepsSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        stepsEst = stepsByDay[selectedDayKey] ?? (selectedDayOffset == 0 ? stepsSeries.last?.value : nil)
        importedStepsDay = (await appleA).filter { $0.day == selectedDayKey }.compactMap { $0.steps }.max()
        importedActiveKcalDay = (await appleA).filter { $0.day == selectedDayKey }.compactMap { $0.activeKcal }.max()
        hrValues = (await hrA).map { $0.bpm }
        workouts = await wkA

        let (chargeSource, effortSource, restSource) = await (chargeSourceA, effortSourceA, restSourceA)
        let sourceResolutions = [
            ("recovery", chargeSource),
            ("strain", effortSource),
            ("sleep_performance", restSource),
        ]
        var providers: [String: ScoreInputProvider] = [:]
        for (metric, resolution) in sourceResolutions {
            let selectedPoint = resolution.points.last(where: { $0.day == sourceDayKey })
            let winner = selectedPoint
                ?? (metric == "recovery"
                    ? priorScored.flatMap { prior in resolution.points.last(where: { $0.day == prior.day }) }
                    : nil)
            if let winner {
                providers[metric] = await repo.scoreInputProvider(
                    resolvedSource: winner.source,
                    day: winner.day,
                    metricKey: metric
                )
            }
        }
        heroProviderByMetric = providers

        // Build the shared SleepModel ONLY when a sleep-origin card is actually hosted, so a Home with no
        // hosted sleep card pays none of the extra Repository work.
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

    // MARK: - Derived (sync, off the caches)

    private var readiness: ReadinessEngine.Readiness {
        cachedReadiness ?? ReadinessEngine.evaluate(days: repo.days, today: cachedDisplayDay?.day)
    }

    /// One card-level provenance label, built by the SAME aggregation the Liquid hero badge uses.
    private var heroSourceLabel: String? {
        LiquidTodayView.heroSourceLabel(
            providers: ["recovery", "strain", "sleep_performance"].compactMap { heroProviderByMetric[$0] })
    }

    private var readinessWord: String? {
        switch readiness.level {
        case .primed: return String(localized: "Push")
        case .balanced: return String(localized: "Maintain")
        case .strained, .rundown: return String(localized: "Rest")
        case .insufficient: return nil
        }
    }

    private var synthLine: String {
        // The honest "your strap stopped delivering nights" line beats a bland "still learning".
        if readiness.level == .insufficient,
           let stale = Baselines.nightsSinceNewestValidNight(dayKeys: repo.days.map(\.day),
                                                             nightlyHrv: repo.days.map(\.avgHrv),
                                                             today: Repository.logicalDayKey(Date())),
           stale > Baselines.staleDays {
            return String(localized: "No new nights from your strap for \(stale) days. Check it's connected and saving data.")
        }
        switch readiness.level {
        case .primed: return String(localized: "You're primed. A hard session should land well today.")
        case .balanced: return String(localized: "You're in a good spot for training.")
        case .strained: return String(localized: "Signals are down a touch. Keep it easy today.")
        case .rundown: return String(localized: "Several recovery signals are down. Prioritise rest today.")
        case .insufficient: return String(localized: "Still learning your baseline. A few more nights and this fills in.")
        }
    }

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

    /// Provenance caption for the vitals card, stamped with the row a vital actually came from — never a
    /// hardcoded "yesterday". nil when every shown vital is today's own.
    private var vitalsProvenanceLine: String? {
        guard let carried = vitalsDay else { return nil }
        let carriedHrv = displayDay?.avgHrv == nil && carried.avgHrv != nil
        let carriedRhr = displayDay?.restingHr == nil && carried.restingHr != nil
        let carriedResp = displayDay?.respRateBpm == nil && carried.respRateBpm != nil
        guard carriedHrv || carriedRhr || carriedResp else { return nil }
        return TodayView.carriedCaption(priorDayKey: carried.day,
                                        todayKey: displayDay?.day ?? selectedDayKey)
    }

    /// The same stamp, reused as a tile caption so a carried HRV / RHR tile says whose night it is.
    private var vitalsCarryCaption: String? { vitalsProvenanceLine }

    // MARK: - Formatting

    private func frac(_ v: Double?) -> Double? { v.map { max(0, min(1, $0 / 100)) } }
    private func fracOver(_ v: Double?, _ over: Double) -> Double? { v.map { max(0, min(1, $0 / over)) } }

    /// nil (not a dash) when there is no value — Aurora's tiles own the empty presentation.
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
        return "\(Int(m) / 60)h \(Int(m) % 60)m"
    }

    private var stepsText: String? {
        guard let s = stepCount else { return nil }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = AppLanguage.activeLocale
        return f.string(from: NSNumber(value: Int(s))) ?? "\(Int(s))"
    }

    private func effortText(_ s: Double?) -> String {
        guard let s else { return "—" }
        return UnitFormatter.effortDisplay(s, scale: effortScale)
    }

    private func workoutSub(_ w: WorkoutRow) -> String {
        var parts: [String] = []
        let secs = w.durationS ?? Double(max(w.endTs - w.startTs, 0))
        parts.append("\(Int(secs / 60)) min")
        if let dm = w.distanceM, dm > 0 {
            parts.append(String(format: "%.1f km", locale: AppLanguage.activeLocale, dm / 1000))
        }
        if let k = w.energyKcal { parts.append("\(Int(k.rounded())) kcal") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - LiveState-isolated leaves
//
// PERF CONTRACT (inherited from Liquid Today): `LiveState` publishes on the ~1 Hz heart-rate notify.
// ONLY these small leaves may observe it — never `AuroraHomeView` itself — so a heartbeat re-renders a
// pill or one card, not the whole screen.

/// The header's live connection / strap status pill.
private struct AuroraConnectionPill: View {
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

/// The live heart-rate card. Shows the current bpm when the strap is streaming, and today's banked
/// 5-minute trace either way, so the card is never blank on an idle day with history.
private struct AuroraLiveHRCard: View {
    let fallback: [Double]
    let animated: Bool

    @EnvironmentObject private var live: LiveState

    var body: some View {
        AuroraCard(elevation: .base, tint: Aurora.statusAlert) {
            HStack(alignment: .center, spacing: Aurora.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Heart rate")).auroraLabel()
                    AuroraValueUnit(
                        value: live.heartRate.map(String.init) ?? latestFallback ?? "—",
                        unit: (live.heartRate != nil || latestFallback != nil) ? "bpm" : nil,
                        role: .metricMedium,
                        valueColor: Aurora.statusAlert
                    )
                    Text(caption).auroraFootnote()
                }

                Spacer(minLength: Aurora.Space.xs)

                if fallback.count >= 2 {
                    AuroraSparkline(values: fallback, tint: Aurora.statusAlert,
                                    showsArea: true, showsHead: animated)
                        .frame(height: 44)
                        .frame(maxWidth: 180)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Aurora.textTertiary)
                }
            }
        }
    }

    private var latestFallback: String? {
        fallback.last.map { String(Int($0.rounded())) }
    }

    private var caption: String {
        if live.heartRate != nil { return String(localized: "Live from your strap") }
        if fallback.count >= 2 { return String(localized: "Today so far") }
        return String(localized: "Connect your strap to see live heart rate")
    }
}

/// The strap link / battery / offload row inside the Data Sources card.
private struct AuroraStrapStatusRow: View {
    @EnvironmentObject private var live: LiveState

    var body: some View {
        HStack(spacing: Aurora.Space.s) {
            Image(systemName: live.connected ? "sensor.tag.radiowaves.forward.fill" : "sensor.tag.radiowaves.forward")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(live.connected ? Aurora.statusGood : Aurora.textTertiary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "Strap")).auroraCaptionStrong()
                Text(statusLine).auroraFootnote()
            }

            Spacer(minLength: Aurora.Space.xs)

            if live.connected, let pct = live.batteryPct {
                AuroraStatusPill("\(Int(pct.rounded()))%",
                                 tone: pct < 15 ? .alert : .neutral,
                                 icon: live.charging == true ? "bolt.fill" : "battery.100",
                                 style: .outline)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusLine: String {
        if live.backfilling { return String(localized: "Offloading history…") }
        if live.connected { return String(localized: "Connected") }
        return String(localized: "Not connected")
    }
}

// MARK: - Platform helpers

private extension View {
    /// Keep a popover a popover in compact width (iOS 16.4+); a no-op on macOS where popovers never adapt.
    @ViewBuilder func auroraPopoverAdaptation() -> some View {
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
