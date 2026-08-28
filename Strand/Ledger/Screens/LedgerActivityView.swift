import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopProtocol
import WhoopStore

// MARK: - LedgerActivityView — spec section "04 · Activity"
//
// Board: `NOOP Redesign.dc.html` → `data-screen-label="Activity"`. Every value below is transcribed
// from that board's inline CSS/SVG; every number drawn is one NOOP already computes and every tap
// routes to a destination NOOP already has.
//
// THE SPEC'S FIVE NUMBERED ITEMS, IN THE SPEC'S ORDER:
//
//   1. Header + **strain hero** — 46/700 numeral "13.2 day strain", status line "in your optimal
//      band" (mint); progress track 8pt with a blue gradient fill + the **optimal band** overlay
//      (mint @18%) positioned from `CoupledView.optimalStrainRange(recovery:)`; axis caption
//      "0 · optimal 11.6–15.2 (from recovery 74) · 21". Strain on the WHOOP 0–21 axis.
//   2. **Totals strip** — kcal · steps · workout time · peak bpm.
//   3. **SESSIONS list** — 38pt icon tile · name + meta · per-session strain numeral. Row →
//      `WorkoutDetailView`. "+ Log a session" → `ManualWorkoutSheet`.
//   4. **TIME IN ZONES** — proportional Z1–Z5 ribbon (10pt, 3px gaps) + minute labels.
//   5. **TRAINING LOAD · 7D VS 28D** — 7-day rolling load line (blue) vs dashed 28-day line
//      (white @30%) — the existing readiness-signal values.
//
// ADDITIVE AND TOGGLE-GATED. This screen does not exist outside the Ledger fork
// (`LedgerFlags.ledgerUIEnabledKey`, default false); the classic `WorkoutsView` / `CoupledView` and
// the `Strand/Aurora/**` fork are untouched. NOTHING here changes a data model, a score, a
// repository, BLE or any business logic — presentation only.
//
// WHY THE WHOLE SCREEN IS PINNED TO THE 0–21 AXIS, NOT JUST THE HERO.
// Spec §Data-Model Notes: *"strain is shown on WHOOP's 0–21 axis — that's the existing
// `EffortScale.whoop` display option (stored value stays 0–100)"*, and §04.1 repeats it for the
// hero. `CoupledView` already ships that exact pin (`private let strainScale: EffortScale = .whoop`,
// CoupledView.swift:38) for the same reason: the optimal band it draws is expressed in 0–21 integers,
// so a screen that mixed axes would put a 0–100 hero above a 0–21 band. The `#268` effort-scale
// preference (`UnitPrefs.effortScaleKey`) therefore does NOT steer this screen — deliberately, and
// identically to the shipped coupled read. The STORED value is untouched either way; only the axis
// it is drawn on differs.
//
// PERF CONVENTIONS (spec §Architecture Constraints):
//   • `AppModel` and `LiveState` are NOT observed here. The screen declares `Repository`,
//     `ProfileStore` and `IntelligenceEngine` — the same objects `AuroraStrainView` (the equivalent
//     domain screen in the sibling fork) declares, plus the engine the manual-log save needs so a
//     just-added session is rescored immediately. None of them tick at 1 Hz.
//   • Every day scan, HR read and rolling mean happens ONCE in `load()`, keyed by
//     `repo.refreshSeq`, and is cached in a single `@State` model. `body` reads only that struct.
//   • The two draw-in charts animate on appear only (`LedgerDrawIn`), never on a data tick.

/// The Ledger "04 · Activity" screen — strain vs the optimal band, the day's totals, its sessions,
/// its time in zones, and the 7d-vs-28d training-load line.
@MainActor
struct LedgerActivityView: View {

    // MARK: - Environment
    //
    // Copied from `AuroraStrainView` — the equivalent Activity/Effort screen — plus
    // `IntelligenceEngine`, which `WorkoutsView` reaches through `model.intelligence` purely to
    // rescore a just-logged session. Taking the engine directly is what keeps `AppModel` (and with
    // it `LiveState`'s 1 Hz HR tick) off this screen's root.

    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore
    @EnvironmentObject var intelligence: IntelligenceEngine

    // MARK: - Preferences (byte-identical keys)

    /// #103. Display-only: workout distance is stored in metres; this re-labels it km/mi.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    /// The axis this screen draws Effort on. Pinned, exactly as `CoupledView` pins it — see the file
    /// header. The stored value stays 0–100.
    private let strainScale: EffortScale = .whoop

    // MARK: - The memoized model

    /// Everything the body draws, resolved once per `repo.refreshSeq` in `load()`.
    @State private var day = DayModel.empty

    /// The tapped session's read-only detail (`WorkoutDetailView`), presented as a sheet exactly as
    /// `WorkoutsView` presents it.
    @State private var detail: SessionTarget?

    /// Drives the existing `ManualWorkoutSheet` behind "+ Log a session".
    @State private var showLogSheet = false

    /// - Note: takes no parameters; the shell hosts it inside its own `NavigationStack`.
    init() {}

    // MARK: - Board constants
    //
    // Transcribed from `data-screen-label="Activity"`. Where the board states a number, that number
    // is here.

    /// Hero numeral — `font-size:46px;font-weight:700`.
    private static let heroNumeralSize: CGFloat = 46
    /// Hero numeral tracking — `letter-spacing:-2px`. Deliberately NOT `LedgerType.sectionTracking`
    /// (−1): this hero sits above the spec's 31–34 section band, and the board pins its own value.
    private static let heroNumeralTracking: CGFloat = -2
    /// "day strain" suffix — `font-size:13.5px`, `#5C6470`.
    private static let heroSuffixSize: CGFloat = 13.5
    /// Status line — `font-size:12px`.
    private static let heroStatusSize: CGFloat = 12
    /// The 0–21 rail — `height:8px;border-radius:4px`, `margin-top:10px`.
    private static let railHeight: CGFloat = 8
    private static let railRadius: CGFloat = 4
    private static let railTopGap: CGFloat = 10
    /// The rail's axis caption — `font-size:10px`, `margin-top:6px`.
    private static let axisCaptionSize: CGFloat = 10
    private static let axisCaptionGap: CGFloat = 6
    /// The rail fill — `linear-gradient(90deg,#2E7FD4,#58B9FF)`. The dark stop is the same ramp step
    /// `LedgerZoneRibbon` uses for Z2; the light stop is `accent/strain`.
    private static let railGradient = LinearGradient(
        colors: [Ledger.hex(0x2E7FD4), Ledger.accentStrain],
        startPoint: .leading,
        endPoint: .trailing
    )
    /// "+ Log a session" — `padding:12px 0;font-size:12px;color:#58B9FF`.
    private static let logButtonSize: CGFloat = 12
    private static let logButtonPadding: CGFloat = 12
    /// "dashed = 28-day" — `font-size:11.5px`, `#5C6470`.
    private static let loadLegendSize: CGFloat = 11.5
    /// The training-load chart — `<svg height="84">`, `margin-top:10px`, caption `margin-top:4px`.
    private static let loadChartHeight: CGFloat = 84
    private static let loadChartTopGap: CGFloat = 10
    private static let loadCaptionGap: CGFloat = 4
    /// The yesterday coupling-verdict line beneath the axis caption — 11.5pt, 10pt clear of it.
    private static let yesterdayLineSize: CGFloat = 11.5
    private static let yesterdayLineGap: CGFloat = 10
    /// The 7-day line — `stroke="#58B9FF" stroke-width="2"`, terminal `<circle r="3.5">`.
    private static let loadLineWidth: CGFloat = 2
    private static let loadTerminalRadius: CGFloat = 3.5
    /// The 28-day line — `stroke="rgba(255,255,255,.3)" stroke-width="1.5" stroke-dasharray="4 5"`.
    private static let loadDashWidth: CGFloat = 1.5
    private static let loadDashPattern: [CGFloat] = [4, 5]

    /// Section top margins, verbatim from the board's `margin:<top>px 24px …` declarations.
    private static let heroTopGap: CGFloat = 16
    private static let totalsTopGap: CGFloat = 18
    private static let sessionsTopGap: CGFloat = 16
    private static let zonesTopGap: CGFloat = 12
    private static let loadTopGap: CGFloat = 16
    private static let pageBottomGap: CGFloat = 22

    /// The em-dash every absent value renders as. Never prose, never a fabricated zero.
    private static let absent = "\u{2014}"

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // 1 · Header + strain hero
                LedgerHeader(overline: String(localized: "Load & training"),
                             title: String(localized: "Activity"),
                             alignment: .lastTextBaseline)
                strainHero
                    .padding(.top, Self.heroTopGap)

                // 1b · Live now — renders only while the strap is streaming HR. Its OWN leaf view,
                // so the 1 Hz tick re-renders that row alone, never this screen (the same isolation
                // `LedgerTodaySyncStatus` uses; `LiveState` is deliberately not observed here).
                LedgerActivityLiveStrip(zoneSet: profile.hrZoneSet)

                // 2 · Totals strip
                totalsStrip
                    .padding(.top, Self.totalsTopGap)

                // 3 · Sessions
                sessionsSection
                    .padding(.top, Self.sessionsTopGap)

                // 4 · Time in zones
                zonesSection
                    .padding(.top, Self.zonesTopGap)

                // 5 · Training load · 7d vs 28d
                trainingLoadSection
                    .padding(.top, Self.loadTopGap)
                    .padding(.bottom, Self.pageBottomGap)
            }
            .padding(.horizontal, Ledger.pageMargin)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Ledger.bgScreen)
        .ledgerMotionGate()
        // Pull-to-refresh, unchanged (spec §Interactions).
        .refreshable { await repo.refresh() }
        // Every heavy derivation, once per refresh — never in `body`.
        .task(id: repo.refreshSeq) { await load() }
        .sheet(item: $detail) { target in
            // The Ledger-styled session read, with the CLASSIC detail (edit, delete, splits,
            // export) one push away inside the same stack — no workflow lost to the restyle.
            NavigationStack {
                LedgerWorkoutDetailView(row: target.row)
                    .environmentObject(repo)
                    .environmentObject(profile)
            }
            #if os(iOS)
            .noopSheetPresentation(largeFirst: true)
            #else
            .frame(width: 620, height: 720)
            #endif
        }
        .sheet(isPresented: $showLogSheet) {
            ManualWorkoutSheet { row, replacing in
                Task {
                    await repo.saveManualWorkout(row, replacing: replacing)
                    // #598: rescore the just-added session from the strap's own HR now, so its
                    // strain / calories appear immediately instead of after the next analyze tick.
                    await intelligence.analyzeRecent()
                    await load()
                }
            }
        }
    }

    // MARK: - 1 · Strain hero

    /// The 0–21 axis the whole screen draws on.
    private var axisMax: Double { 21 }

    private var strainHero: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: Ledger.rowGap) {
                HStack(alignment: .lastTextBaseline, spacing: 0) {
                    Text(day.strain100.map { UnitFormatter.effortDisplay($0, scale: strainScale) }
                         ?? Self.absent)
                        .font(LedgerType.numeral(Self.heroNumeralSize, LedgerType.bold))
                        .tracking(Self.heroNumeralTracking)
                        .foregroundStyle(Ledger.textPrimary)
                    Text(verbatim: " ")
                        .font(LedgerType.label(Self.heroSuffixSize, LedgerType.regular))
                    Text(String(localized: "day strain"))
                        .font(LedgerType.label(Self.heroSuffixSize, LedgerType.regular))
                        .foregroundStyle(Ledger.textTertiary)
                }
                Spacer(minLength: Ledger.rowGap)
                Text(day.bandStatus.text)
                    .font(LedgerType.label(Self.heroStatusSize, LedgerType.regular))
                    .foregroundStyle(day.bandStatus.tone.color)
                    .multilineTextAlignment(.trailing)
            }

            strainRail
                .padding(.top, Self.railTopGap)

            HStack(spacing: Ledger.rowGap) {
                Text(verbatim: "0")
                Spacer(minLength: 4)
                Text(day.optimalCaption)
                Spacer(minLength: 4)
                Text(verbatim: UnitFormatter.effortScaleMax(strainScale))
            }
            .ledgerCaptionStyle(Self.axisCaptionSize)
            .padding(.top, Self.axisCaptionGap)
        }
        .accessibilityElement(children: .combine)
    }

    /// The 8pt rail: `white @6%` track, the mint @18% optimal band UNDER the blue gradient fill —
    /// the board's paint order (`band` div, then the in-flow fill div).
    private var strainRail: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Self.railRadius, style: .continuous)
                    .fill(Ledger.track)

                if let band = day.optimalBand {
                    let lower = CGFloat(Double(band.lowerBound) / axisMax)
                    let upper = CGFloat(Double(band.upperBound) / axisMax)
                    RoundedRectangle(cornerRadius: Self.railRadius, style: .continuous)
                        .fill(Ledger.accentRecovery.opacity(Ledger.optimalBandOpacity))
                        .frame(width: max(0, width * (upper - lower)))
                        .offset(x: width * lower)
                }

                if let strain21 = day.strain21 {
                    LedgerDrawIn(.chart) { progress in
                        RoundedRectangle(cornerRadius: Self.railRadius, style: .continuous)
                            .fill(Self.railGradient)
                            .frame(width: width * CGFloat(min(1, max(0, strain21 / axisMax)) * progress))
                    }
                }
            }
            .frame(width: width, height: Self.railHeight)
        }
        .frame(height: Self.railHeight)
    }

    // MARK: - 2 · Totals strip

    private var totalsStrip: some View {
        LedgerStatStrip([
            .init(value: day.kcalText, label: String(localized: "kcal")),
            .init(value: day.stepsText, label: String(localized: "steps")),
            .init(value: day.workoutTimeText, label: String(localized: "workout time")),
            .init(value: day.peakBpmText, label: String(localized: "peak bpm")),
        ], style: .labelBelow)
    }

    // MARK: - 3 · Sessions

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "Sessions · today"))
                .ledgerOverline()

            if day.sessions.isEmpty {
                Text(day.loaded
                     ? String(localized: "No sessions logged today.")
                     : String(localized: "Loading sessions…"))
                    .ledgerCaptionStyle(11)
                    .padding(.vertical, Ledger.sectionGap)
            } else {
                ForEach(Array(day.sessions.enumerated()), id: \.element.id) { index, session in
                    LedgerSessionRow(
                        icon: session.icon,
                        name: session.name,
                        meta: session.meta,
                        strain: session.strainText,
                        strainCaption: String(localized: "strain"),
                        showsDivider: index < day.sessions.count - 1,
                        action: { detail = SessionTarget(row: session.row) }
                    )
                }
            }

            Button { showLogSheet = true } label: {
                Text(String(localized: "+ Log a session"))
                    .font(LedgerType.label(Self.logButtonSize, LedgerType.regular))
                    .foregroundStyle(Ledger.accentStrain)
                    .padding(.vertical, Self.logButtonPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 4 · Time in zones

    private var zonesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Ledger.hairline)
                .frame(height: Ledger.hairlineWidth)

            Text(String(localized: "Time in zones"))
                .ledgerOverline()
                .padding(.top, Ledger.sectionRulePadding)

            // The board routes the ribbon to `TabRoute.fullDayChart`. Pushed as a VALUE so a
            // re-tap of the active tab pops back to the root (#135/#198).
            NavigationLink(value: TabRoute.fullDayChart) {
                LedgerZoneRibbon(minutes: day.zoneMinutes ?? [],
                                 labels: day.zoneLabels)
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
        }
    }

    // MARK: - 5 · Training load · 7d vs 28d

    private var trainingLoadSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Ledger.hairline)
                .frame(height: Ledger.hairlineWidth)

            HStack(alignment: .firstTextBaseline, spacing: Ledger.rowGap) {
                Text(String(localized: "Training load · 7d vs 28d"))
                    .ledgerOverline()
                Spacer(minLength: 4)
                Text(String(localized: "dashed = 28-day"))
                    .font(LedgerType.label(Self.loadLegendSize, LedgerType.regular))
                    .foregroundStyle(Ledger.textTertiary)
            }
            .padding(.top, Ledger.sectionRulePadding)

            if day.load7.count >= 2, day.load28.count == day.load7.count {
                trainingLoadChart
                    .padding(.top, Self.loadChartTopGap)

                HStack(spacing: Ledger.rowGap) {
                    Text(String(localized: "6 wks ago"))
                    Spacer(minLength: 4)
                    Text(String(localized: "7-day rolling load vs your 28-day norm"))
                    Spacer(minLength: 4)
                    Text(String(localized: "today"))
                }
                .ledgerCaptionStyle(Self.axisCaptionSize)
                .padding(.top, Self.loadCaptionGap)

                // Yesterday's coupling verdict — the load chart shows WHERE load sits; this states
                // whether yesterday's dose fit yesterday's readiness. Domain colour = meaning:
                // mint inside the band, caution above, tertiary below.
                if let line = day.yesterdayLine {
                    Text(line)
                        .font(LedgerType.label(Self.yesterdayLineSize, LedgerType.semibold))
                        .foregroundStyle(day.yesterdayTone.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.top, Self.yesterdayLineGap)
                }
            } else {
                // Honest empty state. ACWR needs ≥14 days of stored strain before the engine will
                // report one; below that there is no rolling load to draw and none is invented.
                Text(String(localized: "Not enough training history yet — this needs about two weeks of days with a strain score."))
                    .ledgerCaptionStyle(11)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Self.loadChartTopGap)
            }
        }
    }

    private var trainingLoadChart: some View {
        // One domain for both series so the 7-day line reads as ABOVE or BELOW the 28-day norm —
        // which is the whole point of the pair.
        let domain = LedgerScale.domain(values: day.load7 + day.load28) ?? 0...1
        let seven = normalized(day.load7, in: domain)
        let twentyEight = normalized(day.load28, in: domain)

        return ZStack(alignment: .topLeading) {
            // The 28-day norm, dashed — drawn first so the acute line sits on top.
            LedgerPolyline(points: twentyEight)
                .stroke(Ledger.comparisonLine,
                        style: StrokeStyle(lineWidth: Self.loadDashWidth,
                                           lineCap: .round,
                                           lineJoin: .round,
                                           dash: Self.loadDashPattern))

            LedgerDrawIn(.chart) { progress in
                LedgerPolyline(points: seven)
                    .trim(from: 0, to: progress)
                    .stroke(Ledger.accentStrain,
                            style: StrokeStyle(lineWidth: Self.loadLineWidth,
                                               lineCap: .round,
                                               lineJoin: .round))
            }

            // The terminal dot on today's rolling load.
            if let last = seven.last {
                GeometryReader { geo in
                    Circle()
                        .fill(Ledger.accentStrain)
                        .frame(width: Self.loadTerminalRadius * 2,
                               height: Self.loadTerminalRadius * 2)
                        .position(x: last.x * geo.size.width, y: last.y * geo.size.height)
                }
            }
        }
        .frame(height: Self.loadChartHeight)
        .accessibilityHidden(true)
    }

    private func normalized(_ values: [Double], in domain: ClosedRange<Double>) -> [CGPoint] {
        values.enumerated().map { index, value in
            CGPoint(x: LedgerScale.normalizedX(index, count: values.count),
                    y: LedgerScale.normalizedY(value, in: domain))
        }
    }

    // MARK: - Load
    //
    // Runs once per `repo.refreshSeq`. Every day scan, HR read and rolling mean is here; `body`
    // reads only the resulting struct.

    private func load() async {
        let now = Date()
        let dayKey = repo.today?.day ?? Repository.logicalDayKey(now)
        let stored = repo.today ?? repo.days.last(where: { $0.day == dayKey })

        // --- The day's window (the shipped 04:00-rollover idiom) ---
        let dayStart = Repository.logicalDayStart(now)
        let from = Int(dayStart.timeIntervalSince1970)
        let to = Int(now.timeIntervalSince1970)

        // --- The day's sessions (existing accessor, filtered to the logical day) ---
        let rows = await repo.workoutRows(days: 4)
        let todaysRows = rows
            .filter { Repository.logicalDayKey(Date(timeIntervalSince1970: TimeInterval($0.startTs))) == dayKey }
            .sorted { $0.startTs < $1.startTs }

        // --- Raw HR for the day: peak bpm, live effort, and the zone split ---
        var raw: [HRSample] = []
        if to > from {
            raw = await repo.hrSamples(from: from, to: to, limit: 120_000)
        }

        // Live, in-progress Effort from the SAME public scorer the daily pass uses, floored by the
        // stored value through `effectiveEffort` — the shared never-drop rule, so this hero cannot
        // disagree with the Today hero or the Key Metrics tile.
        let maxHR: Double? = profile.age > 0 ? StrainScorer.tanakaHRmax(age: Double(profile.age)) : nil
        let restHR = stored?.restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
        let liveEffort: Double? = raw.isEmpty
            ? nil
            : StrainScorer.strain(raw, maxHR: maxHR, restingHR: restHR,
                                  method: PuffinExperiment.effortMethod, sex: profile.sex)
        let effort100 = StrainScorer.effectiveEffort(live: liveEffort, stored: stored?.strain)

        // Zones: the whole day from raw HR through the user's OWN display zone set, else the
        // imported per-session percentages. nil when neither exists — the ribbon then draws its
        // designed empty state rather than five zeroed bars.
        var zoneMinutes: [Double]?
        if !raw.isEmpty {
            let tiz = HRZones.timeInZone(raw, zoneSet: profile.hrZoneSet)
            if tiz.seconds.reduce(0, +) > 0 {
                zoneMinutes = tiz.seconds.map { $0 / 60.0 }
            }
        }
        if zoneMinutes == nil, let summary = WorkoutZones.summary(from: todaysRows) {
            zoneMinutes = summary.minutes
        }

        // --- The 7d/28d rolling load, over the board's six-week window ---
        let (load7, load28) = Self.rollingLoad(days: repo.days, anchorKey: dayKey)

        // --- Yesterday's strain against ITS band (the coupling verdict) ---
        let yesterday = Self.yesterdayVerdict(days: repo.days, anchorKey: dayKey, scale: strainScale)

        // --- Assemble ---
        let strain21 = effort100.map { UnitFormatter.effortValue($0, scale: strainScale) }
        let band = CoupledView.optimalStrainRange(recovery: stored?.recovery)

        day = DayModel(
            loaded: true,
            strain100: effort100,
            recovery: stored?.recovery,
            optimalBand: band,
            optimalCaption: Self.optimalCaption(band: band, recovery: stored?.recovery),
            bandStatus: Self.bandStatus(strain21: strain21, band: band),
            kcalText: stored?.activeKcalEst.map { Self.grouped($0) } ?? Self.absent,
            stepsText: stored?.steps.map { Self.grouped(Double($0)) } ?? Self.absent,
            workoutTimeText: Self.workoutTimeText(todaysRows),
            peakBpmText: raw.map(\.bpm).max().map { "\($0)" } ?? Self.absent,
            sessions: todaysRows.map { row in
                Session(row: row,
                        name: WorkoutSource.displaySport(row.sport),
                        meta: Self.metaLine(row, system: unitSystem),
                        strainText: row.strain.map { UnitFormatter.effortDisplay($0, scale: strainScale) },
                        icon: Self.icon(for: row.sport))
            },
            zoneMinutes: zoneMinutes,
            zoneLabels: zoneMinutes.map(Self.zoneLabels),
            load7: load7,
            load28: load28,
            yesterdayLine: yesterday?.line,
            yesterdayTone: yesterday?.tone ?? .neutral
        )
    }

    /// Yesterday's strain read against ITS optimal band — the `CoupledView.optimalStrainRange`
    /// verdict the training-load chart never states. Resolved from stored figures only: the previous
    /// logical day's `DailyMetric` must carry BOTH a strain and a recovery, or nothing renders.
    private static func yesterdayVerdict(days: [DailyMetric],
                                         anchorKey: String,
                                         scale: EffortScale) -> (line: String, tone: LedgerTone)? {
        // Noon on the anchor key (well clear of DST edges), stepped back one day — the same
        // key-walking idiom `rollingLoad` uses through this file's own `dayKeyParser`.
        guard let anchorDate = dayKeyParser.date(from: anchorKey),
              let yesterdayDate = Calendar.current.date(byAdding: .day, value: -1,
                                                        to: anchorDate.addingTimeInterval(12 * 3_600))
        else { return nil }
        let yKey = Repository.localDayKey(yesterdayDate)
        guard let row = days.last(where: { $0.day == yKey }),
              let strain100 = row.strain, let recovery = row.recovery,
              let band = CoupledView.optimalStrainRange(recovery: recovery)
        else { return nil }

        // Compared on the same 0–21 axis the band is stated in (the screen's pinned display axis).
        let strain21 = UnitFormatter.effortValue(strain100, scale: .whoop)
        let strainText = UnitFormatter.effortDisplay(strain100, scale: scale)
        let charge = Int(recovery.rounded())

        let verdict: String
        let tone: LedgerTone
        if strain21 > Double(band.upperBound) {
            verdict = String(localized: "above your band")
            tone = .caution
        } else if strain21 < Double(band.lowerBound) {
            verdict = String(localized: "below your band")
            tone = .neutral
        } else {
            verdict = String(localized: "inside your band")
            tone = .good
        }
        return (String(localized: "yesterday \u{00B7} \(strainText) on charge \(charge) \u{00B7} \(verdict)"),
                tone)
    }

    // MARK: - Derivations (pure, static — nothing here reads `self` or a live object)

    /// The 7-day and 28-day rolling means of the stored daily Effort, over the board's trailing
    /// six weeks, on the display axis.
    ///
    /// These are the SAME two windows `ReadinessEngine`'s ACWR signal uses (acute 7 / chronic 28 over
    /// `DailyMetric.strain`) — this draws their history instead of only today's ratio. No new metric
    /// is computed: the inputs are stored Effort values and the windows are the engine's own.
    /// Returns two empty arrays when fewer than the engine's 14-day chronic minimum are available.
    private static func rollingLoad(days: [DailyMetric], anchorKey: String) -> ([Double], [Double]) {
        // The board's x-axis: "6 wks ago" → "today".
        let windowDays = 42
        // `ReadinessEngine`'s own acute / chronic windows, so this line and the ACWR signal on the
        // Today screen are reading the same two means.
        let acuteWindow = 7
        let chronicWindow = 28
        // `ReadinessEngine.minChronic` — below this the engine reports no ACWR at all, so neither
        // does this chart.
        let minimumHistory = 14

        let strainByDay = Dictionary(
            days.compactMap { row in row.strain.map { (row.day, $0) } },
            uniquingKeysWith: { _, latest in latest }
        )
        guard strainByDay.count >= minimumHistory else { return ([], []) }

        let calendar = Calendar.current
        guard let anchor = dayKeyParser.date(from: anchorKey) else { return ([], []) }

        // Precompute the trailing key list once, oldest first, so the rolling windows are plain
        // array slices rather than repeated date arithmetic.
        var keys: [String] = []
        keys.reserveCapacity(windowDays + chronicWindow)
        for offset in stride(from: -(windowDays - 1 + chronicWindow - 1), through: 0, by: 1) {
            guard let date = calendar.date(byAdding: .day, value: offset, to: anchor) else { continue }
            keys.append(Repository.localDayKey(date))
        }
        let values = keys.map { strainByDay[$0] }
        let head = chronicWindow - 1                    // the ramp-in the windows need
        guard values.count > head else { return ([], []) }

        func mean(_ slice: ArraySlice<Double?>) -> Double? {
            let present = slice.compactMap { $0 }
            guard !present.isEmpty else { return nil }
            return present.reduce(0, +) / Double(present.count)
        }

        var seven: [Double] = []
        var twentyEight: [Double] = []
        for index in head..<values.count {
            let acute = mean(values[(index - acuteWindow + 1)...index])
            let chronic = mean(values[(index - chronicWindow + 1)...index])
            guard let acute, let chronic else { continue }
            seven.append(UnitFormatter.effortValue(acute, scale: .whoop))
            twentyEight.append(UnitFormatter.effortValue(chronic, scale: .whoop))
        }
        // Both series must be the same length for a shared x-axis; the guard above keeps them so.
        return seven.count >= 2 ? (seven, twentyEight) : ([], [])
    }

    /// The rail's centre caption — "optimal 14 – 18 (from recovery 74)", or an honest dash when the
    /// day carries no recovery score (`optimalStrainRange` returns nil, and no band is guessed).
    private static func optimalCaption(band: ClosedRange<Int>?, recovery: Double?) -> String {
        guard let band, let recovery else {
            // No recovery score ⇒ no band. `optimalStrainRange` returns nil and the rail draws none;
            // the caption says so rather than guessing one.
            return String(localized: "optimal \u{2014}")
        }
        return String(localized: "optimal \(band.lowerBound) – \(band.upperBound) (from recovery \(Int(recovery.rounded())))")
    }

    /// The hero's status line. The tone is chosen by the SCREEN, which knows the polarity: sitting in
    /// the band is the good outcome, overshooting it is the caution one, and being short of it is a
    /// neutral statement of fact — not a failure.
    private static func bandStatus(strain21: Double?, band: ClosedRange<Int>?) -> BandStatus {
        guard let strain21, let band else {
            return BandStatus(text: String(localized: "no optimal band yet"), tone: .neutral)
        }
        if strain21 < Double(band.lowerBound) {
            return BandStatus(text: String(localized: "below your optimal band"), tone: .neutral)
        }
        if strain21 > Double(band.upperBound) {
            return BandStatus(text: String(localized: "above your optimal band"), tone: .caution)
        }
        return BandStatus(text: String(localized: "in your optimal band"), tone: .good)
    }

    /// "1:37" — the day's total workout time, h:mm.
    private static func workoutTimeText(_ rows: [WorkoutRow]) -> String {
        let seconds = rows.reduce(0.0) { $0 + ($1.durationS ?? Double($1.endTs - $1.startTs)) }
        guard seconds > 0 else { return absent }
        let minutes = Int((seconds / 60).rounded())
        return "\(minutes / 60):" + String(format: "%02d", minutes % 60)
    }

    /// "06:10 · 42m · 6.8 km · avg 158 bpm" — every fact the row actually carries, and no more.
    private static func metaLine(_ row: WorkoutRow, system: UnitSystem) -> String {
        var parts: [String] = [timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(row.startTs)))]

        let seconds = row.durationS ?? Double(row.endTs - row.startTs)
        if seconds > 0 {
            let minutes = Int((seconds / 60).rounded())
            parts.append(minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m")
        }
        if let metres = row.distanceM, metres > 0 {
            parts.append(UnitFormatter.distanceFromMeters(metres, system: system))
        }
        if let avg = row.avgHr, avg > 0 {
            parts.append(String(localized: "avg \(avg) bpm"))
        }
        return parts.joined(separator: " · ")
    }

    /// The tile glyph. The board draws exactly two icons — the interval/run zigzag and the dumbbell —
    /// so those are used for the sports they were drawn for, and every other sport falls back to the
    /// app's own shared `sportSymbol` mapping rather than being forced into one of the two.
    private static func icon(for sport: String) -> LedgerSessionIcon {
        let normalized = sport.trimmingCharacters(in: .whitespaces).lowercased()
        switch normalized {
        case "strength", "bodybuilding", "weightlifting":
            return .strength
        case "running", "treadmill run":
            return .cardio
        default:
            return .symbol(sportSymbol(sport))
        }
    }

    /// "Z1 33m" … per the board's label row.
    private static func zoneLabels(_ minutes: [Double]) -> [String] {
        minutes.enumerated().map { index, value in
            "Z\(index + 1) \(Int(value.rounded()))m"
        }
    }

    private static func grouped(_ value: Double) -> String {
        integerFormatter.string(from: NSNumber(value: Int(value.rounded()))) ?? "\(Int(value.rounded()))"
    }

    private static let integerFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// Parses a stored `yyyy-MM-dd` key back to a `Date`, with the same locale-stable settings the
    /// repository writes them with.
    private static let dayKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

// MARK: - The memoized model

extension LedgerActivityView {

    /// The hero's status line and the tone the screen paints it in.
    fileprivate struct BandStatus: Equatable {
        let text: String
        let tone: LedgerTone
    }

    /// One session row, pre-formatted. The row view formats nothing.
    fileprivate struct Session: Identifiable {
        let row: WorkoutRow
        let name: String
        let meta: String
        let strainText: String?
        let icon: LedgerSessionIcon
        /// The workout's natural key — stable across a reload, so `ForEach` does not rebuild rows.
        var id: String { "\(row.startTs)|\(row.sport)|\(row.source)" }
    }

    /// Wraps the tapped row so `.sheet(item:)` can present `WorkoutDetailView`.
    fileprivate struct SessionTarget: Identifiable {
        let row: WorkoutRow
        var id: String { "\(row.startTs)|\(row.sport)|\(row.source)" }
    }

    /// Everything `body` draws — resolved once in `load()`, never derived in `body`.
    fileprivate struct DayModel {
        var loaded: Bool
        /// The day's STORED Effort, 0–100 — exactly what `DailyMetric.strain` holds, floored by
        /// `StrainScorer.effectiveEffort`. nil ⇒ the hero renders an em-dash. Drawn on the 0–21
        /// axis via `strain21`; the stored value is never rewritten.
        var strain100: Double?
        /// `strain100` on the screen's pinned 0–21 display axis.
        var strain21: Double? { strain100.map { UnitFormatter.effortValue($0, scale: .whoop) } }
        var recovery: Double?
        var optimalBand: ClosedRange<Int>?
        var optimalCaption: String
        var bandStatus: BandStatus
        var kcalText: String
        var stepsText: String
        var workoutTimeText: String
        var peakBpmText: String
        var sessions: [Session]
        /// Minutes per zone, Z1 first. nil ⇒ the ribbon draws its designed empty state.
        var zoneMinutes: [Double]?
        var zoneLabels: [String]?
        var load7: [Double]
        var load28: [Double]
        /// Yesterday's strain-vs-band read ("yesterday · 12.4 on charge 58 · inside your band").
        /// nil when yesterday holds no scored strain + recovery pair — nothing is inferred.
        var yesterdayLine: String?
        var yesterdayTone: LedgerTone = .neutral

        static let empty = DayModel(
            loaded: false,
            strain100: nil,
            recovery: nil,
            optimalBand: nil,
            optimalCaption: "",
            bandStatus: BandStatus(text: "", tone: .neutral),
            kcalText: "\u{2014}",
            stepsText: "\u{2014}",
            workoutTimeText: "\u{2014}",
            peakBpmText: "\u{2014}",
            sessions: [],
            zoneMinutes: nil,
            zoneLabels: nil,
            load7: [],
            load28: [],
            yesterdayLine: nil
        )
    }
}

// MARK: - Live strip

/// The "live now" row under the strain hero: current heart rate and its zone, while the strap
/// streams. A LEAF observer of `LiveState` — the 1 Hz heart-rate tick re-renders only this row.
/// Renders nothing (zero height) when no live HR is arriving, so the screen is unchanged offline.
private struct LedgerActivityLiveStrip: View {
    @EnvironmentObject private var live: LiveState
    let zoneSet: HRZoneSet

    private static let dotDiameter: CGFloat = 6
    private static let textSize: CGFloat = 12
    private static let topGap: CGFloat = 12

    var body: some View {
        if live.connected, let hr = live.heartRate {
            HStack(spacing: 7) {
                Circle()
                    .fill(Ledger.accentLiveHR)
                    .frame(width: Self.dotDiameter, height: Self.dotDiameter)
                Text(String(localized: "live \u{00B7} \u{2665} \(hr) bpm \u{00B7} zone \(zoneSet.zoneNumber(forBPM: Double(hr)))"))
                    .font(LedgerType.label(Self.textSize, LedgerType.semibold))
                    .foregroundStyle(Ledger.textSecondary)
                    .monospacedDigit()
            }
            .padding(.top, Self.topGap)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("LedgerActivityView") {
    let repo = Repository(deviceId: "preview")
    let profile = ProfileStore()
    return NavigationStack {
        LedgerActivityView()
            .environmentObject(repo)
            .environmentObject(profile)
            .environmentObject(IntelligenceEngine(repo: repo, profile: profile, deviceId: "preview"))
    }
    .preferredColorScheme(.dark)
}
#endif
