import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - AuroraBodyView
//
// A NEW screen. There is no "Body" tab in NOOP today — the five overnight vitals live as a
// LazyVGrid of small tiles buried inside the Health tab (`HealthView.VitalSignsSection`).
// This is not a restyle of that grid: the information architecture is different.
//
//   OLD: one scroll, a grid of ~168pt tiles, six vitals side by side, "latest" resolved
//        against the wall clock, no way to look at another day, no baseline drawn, no
//        explanation of what any number means.
//
//   NEW: a DAY-CENTRIC screen. A pinned day rail owns the top and every number below it is
//        that day's number. A single collapsing hero states the whole verdict in one
//        sentence — how many vitals sat in your range — and then the screen descends into
//        ONE FULL-WIDTH CARD PER VITAL, each of which is a small essay: the reading, its
//        distance from your own baseline, where it sits inside the band that baseline
//        defines, thirty days of shape, and a plain-English line saying what the metric
//        reflects. Depth over density: five tall cards, never a grid.
//
// ADDITIVE + PRESENTATION ONLY. Every value, every in/out-of-range verdict and every
// provenance string comes from the SAME pure pipeline the Health tab reads —
// `BodyVitalSigns.readings(sourceRows:temperatureUnit:now:spo2CandidateByDay:hrvOverCountByDay:)`.
// Nothing is re-derived here. The two things this screen computes that the tile grid does
// not draw — the personal typical BAND and the delta vs baseline — come from the same
// `Baselines` / `VitalBands` primitives `VitalBands.band` itself uses, with the same
// configs and the same history construction, so the bar can never contradict the pill.
//
// DAY SELECTION is done by narrowing the INPUT rows (`metric.day <= selectedDay`) and
// anchoring `now` at noon of the selected day, so the pipeline's own "today, else the
// freshest carried night within `Baselines.vitalCarryDays`" resolution runs unchanged —
// just relative to the day the user is looking at. No resolver was reimplemented.

/// The Aurora Body screen: the five overnight vitals, one rich card each, for one chosen day.
@MainActor
struct AuroraBodyView: View {

    // MARK: Data sources (same environment contract as `HealthView`'s vitals section)

    @EnvironmentObject var repo: Repository

    /// Temperature display preference (D#103). Skin temp is stored in °C — absolute or a
    /// ±deviation — and the toggle re-labels it to °F. Display-only: banding still runs on
    /// the stored °C value, exactly as in `HealthView`.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""

    private var temperatureUnit: TemperatureUnit {
        let system = UnitSystem(rawValue: unitSystemRaw) ?? .metric
        return UnitPrefs.resolveTemperature(system: system, override: temperatureRaw)
    }

    /// #103/queue-11a — SpO₂ candidate nightly means, loaded only when the experimental
    /// toggle is on. Loaded verbatim the way `HealthView` loads it; this screen never writes.
    @State private var spo2CandidateByDay: [String: Double] = [:]
    /// #1118 — per-night HRV R-R over-count flags, so an over-counted night is captioned
    /// "unverified" rather than presented as a clean reading.
    @State private var hrvOverCountByDay: [String: Double] = [:]

    /// The day the whole screen is about. `YYYY-MM-DD`, defaults to the logical day.
    @State private var selectedDay: String = Repository.logicalDayKey(Date())
    /// Points the content has scrolled up, feeding the collapsing hero.
    @State private var scrollOffset: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let scrollSpace = "aurora.body.scroll"

    /// How many days the rail offers. Long enough to walk back through a training block,
    /// short enough that the rail stays scannable.
    private static let railDays = 45
    /// The sparkline window, in days.
    private static let trendDays = 30

    // MARK: - Body

    var body: some View {
        #if os(iOS)
        content.refreshable { await repo.refresh() }
        #else
        content
        #endif
    }

    private var content: some View {
        let cards = vitalCards()
        let verdict = BodyVerdict(cards: cards)

        return VStack(spacing: 0) {

            // 1. THE DAY RAIL. Pinned chrome — the screen always says which day it is about.
            AuroraDayRail(days: dayPips, selection: $selectedDay)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    AuroraScrollOffsetProbe(space: Self.scrollSpace)

                    // 2. THE VERDICT. One statement, one sentence. No gauge.
                    AuroraCollapsingHero(offset: scrollOffset, collapseDistance: 150, compactHeight: 40) {
                        verdictHero(verdict)
                    } compact: {
                        verdictCompact(verdict)
                    }
                    .auroraGutter()

                    // 3. ONE RICH FULL-WIDTH CARD PER VITAL.
                    VStack(alignment: .leading, spacing: Aurora.Space.m) {
                        AuroraSectionHeader("Your vitals",
                                            subtitle: "Measured overnight, one card each")
                            .padding(.top, Aurora.Space.xl)

                        ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                            vitalCard(card)
                                .auroraBodyAppear(index)
                        }
                    }
                    .auroraGutter()

                    disclosureFooter
                        .auroraGutter()
                        .padding(.top, Aurora.Space.xxl)

                    Color.clear.frame(height: Aurora.Space.tabBarClearance)
                }
            }
            .auroraScrollSpace(Self.scrollSpace)
            .onAuroraScrollOffset { scrollOffset = $0 }
        }
        .auroraCanvas()
        .auroraBandWash(verdict.tint, intensity: 0.85)
        .task(id: PuffinExperiment.spo2CandidateDisplayEnabled) { await loadCandidateSeries() }
    }

    // MARK: - 2. The verdict hero

    /// The one dominant statement. A count, not a dial: "4 of 5 in your range", with the
    /// sentence underneath saying what that means in plain English.
    @ViewBuilder
    private func verdictHero(_ verdict: BodyVerdict) -> some View {
        VStack(alignment: .leading, spacing: Aurora.Space.s) {

            Text(dayOverline)
                .auroraSectionHeader()
                .padding(.top, Aurora.Space.l)

            if verdict.measured == 0 {
                Text("No vitals")
                    .auroraDisplay(58)
                    .foregroundStyle(Aurora.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Aurora.Space.xs) {
                    AuroraRollingNumber(value: Double(verdict.inRange),
                                        size: 84,
                                        color: verdict.tint)
                    Text("of \(verdict.measured)")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(Aurora.textTertiary)
                        .padding(.bottom, 2)
                }
            }

            AuroraCoachLine(verdict.sentence,
                            emphasis: verdict.emphasis,
                            tint: verdict.tint,
                            size: 16)

            if verdict.missing > 0 && verdict.measured > 0 {
                Text(verdict.missing == 1
                     ? "One vital has no reading for this day."
                     : "\(verdict.missing) vitals have no reading for this day.")
                    .auroraFootnote()
            }
        }
        .padding(.bottom, Aurora.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the hero demotes to once the user starts reading downward.
    @ViewBuilder
    private func verdictCompact(_ verdict: BodyVerdict) -> some View {
        HStack(spacing: Aurora.Space.xs) {
            Circle()
                .fill(verdict.tint)
                .frame(width: 8, height: 8)
            Text(verdict.compactText)
                .auroraBodyStrong()
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(BodyVitalReading.dayLabel(selectedDay))
                .auroraCaption()
        }
    }

    private var dayOverline: String {
        let label = BodyVitalReading.dayLabel(selectedDay)
        return "BODY · \(label.uppercased())"
    }

    // MARK: - 3. One rich full-width card per vital

    @ViewBuilder
    private func vitalCard(_ card: BodyCard) -> some View {
        AuroraCard(elevation: .base, padding: Aurora.Space.l, radius: Aurora.Radius.card, tint: card.tint) {
            VStack(alignment: .leading, spacing: Aurora.Space.m) {

                // Name + icon, and the verdict pill on the far side.
                HStack(alignment: .center, spacing: Aurora.Space.s) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(card.tint.opacity(0.14))
                        Image(systemName: card.icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(card.tint)
                    }
                    .frame(width: Aurora.Layout.glyphPlate, height: Aurora.Layout.glyphPlate)

                    Text(card.title).auroraHeadline()

                    Spacer(minLength: Aurora.Space.xs)

                    AuroraStatusPill(card.verdictLabel,
                                     tone: card.verdictTone,
                                     style: .tinted,
                                     overrideColor: card.verdictTone == .neutral ? nil : card.verdictColor)
                }

                if card.value != nil {
                    filledBody(card)
                } else {
                    emptyBody(card)
                }

                AuroraDivider()

                // The plain-English line. Non-diagnostic by construction: it says what the
                // metric reflects and which ordinary things move it — never what a move means
                // about your health. NOOP is not a medical device (docs/SCOPE.md).
                AuroraCoachLine(card.meaning,
                                emphasis: card.meaningEmphasis,
                                tint: card.tint,
                                size: 14)
            }
        }
    }

    /// The card body when the day HAS a reading.
    @ViewBuilder
    private func filledBody(_ card: BodyCard) -> some View {
        VStack(alignment: .leading, spacing: Aurora.Space.m) {

            // The reading, big, in the vital's colour, with the delta beside it.
            HStack(alignment: .firstTextBaseline, spacing: Aurora.Space.s) {
                AuroraValueUnit(value: card.valueText ?? "—",
                                unit: card.unit,
                                role: .display(52),
                                valueColor: card.tint)
                if let delta = card.delta {
                    AuroraDeltaChip(delta)
                        .padding(.bottom, 4)
                }
                Spacer(minLength: 0)
            }

            if let provenance = card.provenance {
                Text(provenance)
                    .auroraFootnote()
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Today's value against the band it is judged by.
            VStack(alignment: .leading, spacing: Aurora.Space.xs) {
                Text(card.bandCaption)
                    .auroraCaption()
                AuroraRangeBar(value: card.displayValue,
                               bounds: card.bounds,
                               typical: card.typical,
                               tint: card.tint,
                               unit: nil,
                               decimals: card.decimals,
                               typicalLabel: card.typicalLabel,
                               emptyHint: "No reading")
            }

            // Thirty days of shape.
            trendBlock(card)
        }
    }

    /// The card body when the day has NO reading. Honest, never a bare dash: these vitals
    /// are sleep-gated, and the copy says so and names what is actually missing.
    @ViewBuilder
    private func emptyBody(_ card: BodyCard) -> some View {
        VStack(alignment: .leading, spacing: Aurora.Space.s) {

            HStack(alignment: .firstTextBaseline, spacing: Aurora.Space.xs) {
                Text("—")
                    .auroraDisplay(52)
                    .foregroundStyle(Aurora.textDisabled)
                Text(card.unit)
                    .auroraUnit()
                Spacer(minLength: 0)
            }

            Text("Measured while you sleep")
                .auroraBodyStrong()

            Text(card.missingCaption)
                .auroraBody()
                .fixedSize(horizontal: false, vertical: true)

            Text("Wear the strap overnight — or import a WHOOP CSV — and this card fills in for that night.")
                .auroraFootnote()
                .fixedSize(horizontal: false, vertical: true)

            if card.spark.count > 1 {
                trendBlock(card)
                    .padding(.top, Aurora.Space.xs)
            }
        }
    }

    /// The 30-day trail plus its own honest label — how many nights actually contributed.
    @ViewBuilder
    private func trendBlock(_ card: BodyCard) -> some View {
        VStack(alignment: .leading, spacing: Aurora.Space.xs) {
            HStack(spacing: Aurora.Space.xs) {
                Text("LAST \(Self.trendDays) DAYS")
                    .auroraSectionHeader()
                Spacer(minLength: Aurora.Space.xs)
                Text(card.spark.count == 1
                     ? "1 night"
                     : "\(card.spark.count) nights")
                    .auroraFootnote()
            }

            if card.spark.count > 1 {
                AuroraSparkline(values: card.spark,
                                tint: card.tint,
                                lineWidth: Aurora.Stroke.line,
                                showsArea: true,
                                showsHead: true)
                    .frame(height: 54)
            } else {
                Text("Not enough nights yet to draw a trend.")
                    .auroraFootnote()
                    .frame(height: 54, alignment: .center)
            }
        }
    }

    // MARK: - 4. Footer

    private var disclosureFooter: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.xs) {
            AuroraDivider()
            Text("How these are judged")
                .auroraCaptionStrong()
                .padding(.top, Aurora.Space.xs)
            Text("Once NOOP has \(Baselines.minNightsTrust) nights of a vital, it compares that night to YOUR own baseline and draws your typical band. Until then — and again after a long gap off the strap — the typical adult range is used instead, and the card says which one it used.")
                .auroraFootnote()
                .fixedSize(horizontal: false, vertical: true)
            Text("Approximate, on-device, and not medical advice. NOOP is not a medical device and never tells you what a reading means about your health.")
                .auroraFootnote()
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    // MARK: - Day rail source

    /// The rail's pips: the last `railDays` calendar days ending at the logical today, with
    /// each day's recovery when there is one and a hollow ghost pip when there is not. Built
    /// from the calendar rather than from `repo.days` so today is always present and wear
    /// gaps show as gaps instead of silently closing up.
    private var dayPips: [AuroraDayPip] {
        let recoveryByDay: [String: Double] = repo.days.reduce(into: [:]) { acc, d in
            if let r = d.recovery { acc[d.day] = r }
        }
        let todayKey = Repository.logicalDayKey(Date())
        guard let today = Self.dayKeyParser.date(from: todayKey) else { return [] }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current

        var pips: [AuroraDayPip] = []
        pips.reserveCapacity(Self.railDays)
        for back in stride(from: Self.railDays - 1, through: 0, by: -1) {
            guard let date = cal.date(byAdding: .day, value: -back, to: today) else { continue }
            let key = Self.dayKeyParser.string(from: date)
            pips.append(AuroraDayPip(dayKey: key, date: date, recovery: recoveryByDay[key]))
        }
        return pips
    }

    // MARK: - Card construction

    /// Build the five cards for `selectedDay`.
    ///
    /// The value, the unit, the format, the banding verdict, the day, the source and the
    /// missing-caption all come straight out of `BodyVitalSigns` — the same call `HealthView`
    /// makes, with the row set narrowed to the selected day and `now` anchored there.
    private func vitalCards() -> [BodyCard] {
        let dayKey = selectedDay
        let anchor = Self.referenceDate(for: dayKey)
        let rows = repo.vitalMetricRows.filter { $0.metric.day <= dayKey }

        let readings = BodyVitalSigns.readings(
            sourceRows: rows,
            temperatureUnit: temperatureUnit,
            now: anchor,
            spo2CandidateByDay: spo2CandidateByDay,
            hrvOverCountByDay: hrvOverCountByDay
        )
        var byKey: [String: BodyVitalReading] = [:]
        for r in readings { byKey[r.key] = r }

        let fahrenheit = temperatureUnit == .fahrenheit
        let trendCutoff = Self.cutoff(from: dayKey, days: Self.trendDays)

        var out: [BodyCard] = []

        // --- Resting HR -------------------------------------------------------------
        if let r = byKey["rhr"] {
            let pts = Self.series(rows, key: "rhr") { $0.restingHr.map(Double.init) }
            out.append(makeCard(
                reading: r,
                icon: "heart.fill",
                tint: Self.rhrTint,
                points: pts,
                cfg: Baselines.restingHRCfg,
                populationRange: 40...60,
                decimals: 0,
                higherIsBetter: false,
                trendCutoff: trendCutoff,
                meaning: "Resting heart rate is how hard your heart is working when you are completely at rest. It tends to sit higher after a hard day, alcohol, a late meal or a short night, and to settle again on easy days.",
                meaningEmphasis: "Resting heart rate"
            ))
        }

        // --- HRV --------------------------------------------------------------------
        if let r = byKey["hrv"] {
            let pts = Self.series(rows, key: "hrv") { $0.avgHrv }
            out.append(makeCard(
                reading: r,
                icon: "waveform.path.ecg",
                tint: Self.hrvTint,
                points: pts,
                cfg: Baselines.hrvCfg,
                populationRange: 40...120,
                decimals: 0,
                higherIsBetter: true,
                trendCutoff: trendCutoff,
                meaning: "HRV is the beat-to-beat variation your heart allows while you sleep. It is very personal — what matters is your own range, not anyone else's — and it typically dips after load, travel, alcohol or a broken night.",
                meaningEmphasis: "HRV"
            ))
        }

        // --- Respiratory rate -------------------------------------------------------
        if let r = byKey["resp"] {
            let pts = Self.series(rows, key: "resp") { $0.respRateBpm }
            out.append(makeCard(
                reading: r,
                icon: "lungs.fill",
                tint: Self.respTint,
                points: pts,
                cfg: Baselines.respCfg,
                populationRange: 12...20,
                decimals: 1,
                higherIsBetter: false,
                trendCutoff: trendCutoff,
                meaning: "Respiratory rate is your breaths per minute across the night. It is usually one of the steadiest things NOOP measures, so a night away from your own baseline is worth noticing rather than acting on.",
                meaningEmphasis: "Respiratory rate"
            ))
        }

        // --- Blood oxygen -----------------------------------------------------------
        if let r = byKey["spo2"] {
            let pts = Self.series(rows, key: "spo2") { $0.spo2Pct }
            let candidatePts: [BodyPoint] = spo2CandidateByDay
                .filter { $0.key <= dayKey }
                .map { BodyPoint(day: $0.key, value: $0.value) }
                .sorted { $0.day < $1.day }
            // The tile falls back to the (unverified) candidate mean when no calibrated
            // percentage exists; the trail must follow the value it is drawn under.
            let usingCandidate = pts.last(where: { $0.day == r.day }) == nil && r.value != nil
            out.append(makeCard(
                reading: r,
                icon: "drop.fill",
                tint: Self.spo2Tint,
                points: usingCandidate ? candidatePts : pts,
                // Population-only by design — there is no SpO₂ MetricCfg, and an absolute
                // floor is meaningful regardless of personal history.
                cfg: nil,
                populationRange: 95...100,
                decimals: 0,
                higherIsBetter: true,
                trendCutoff: trendCutoff,
                meaning: "Blood oxygen is the share of your haemoglobin carrying oxygen while you sleep. A wrist optical reading moves with strap fit, wrist position and altitude at least as much as anything else, so read the shape of the week rather than one night.",
                meaningEmphasis: "Blood oxygen"
            ))
        }

        // --- Skin temperature -------------------------------------------------------
        if let r = byKey["skin"] {
            // The stored column is bimodal — imports write an absolute wrist °C, the
            // on-device pipeline a ±°C deviation — so the series is partitioned to the KIND
            // the card is showing before anything is folded or drawn (#1636 / #622).
            let absolute = r.value.map(VitalBands.isAbsoluteSkinTemp) ?? true
            let raw = Self.series(rows, key: "skin") { $0.skinTempC ?? $0.skinTempDevC }
            let pts = raw.filter { VitalBands.isAbsoluteSkinTemp($0.value) == absolute }
            out.append(makeCard(
                reading: r,
                icon: "thermometer.medium",
                tint: Self.skinTint,
                points: pts,
                cfg: absolute ? Baselines.metricCfg["skin_temp"]! : VitalBands.skinTempDeviationCfg,
                populationRange: absolute ? 33...36 : (-0.6)...0.6,
                decimals: 1,
                higherIsBetter: false,
                trendCutoff: trendCutoff,
                meaning: "Skin temperature is taken at the wrist while you sleep. It moves with room temperature, bedding, alcohol and where you are in your cycle, so it is a trend to watch over nights, not a single-night verdict.",
                meaningEmphasis: "Skin temperature",
                // Skin temp is the one vital whose numbers may be re-expressed for display
                // (°C → °F). The whole axis — value, bounds, band, delta — is converted with
                // the SAME transform `SkinTempDisplay.numberString` uses, so nothing is mixed.
                displayTransform: fahrenheit
                    ? (absolute ? { $0 * 9.0 / 5.0 + 32.0 } : { $0 * 9.0 / 5.0 })
                    : nil,
                deltaScale: fahrenheit ? 9.0 / 5.0 : 1.0,
                // A deviation IS already "vs baseline" — a delta chip beside it would just
                // repeat the number back at the reader.
                suppressDelta: !absolute
            ))
        }

        return out
    }

    /// Assemble one card: the reading (authoritative) plus the personal baseline geometry
    /// (`Baselines` / `VitalBands`, same configs the banding used).
    private func makeCard(
        reading: BodyVitalReading,
        icon: String,
        tint: Color,
        points: [BodyPoint],
        cfg: MetricCfg?,
        populationRange: ClosedRange<Double>,
        decimals: Int,
        higherIsBetter: Bool,
        trendCutoff: String,
        meaning: String,
        meaningEmphasis: String,
        displayTransform: ((Double) -> Double)? = nil,
        deltaScale: Double = 1.0,
        suppressDelta: Bool = false
    ) -> BodyCard {

        let value = reading.value

        // History EXCLUDING the displayed night, calendar-padded so wear gaps are visible to
        // the staleness logic — the identical construction `BodyVitalSigns` hands to
        // `VitalBands.band`, so the band drawn here is the band the verdict was made against.
        let readingDay = reading.day
        let priorRows: [(day: String, value: Double?)] = points
            .filter { p in
                guard let readingDay else { return true }
                return p.day < readingDay
            }
            .map { ($0.day, Optional($0.value)) }
        let history = VitalBands.calendarSeries(priorRows)
        let state: BaselineState? = cfg.map { Baselines.foldHistory(history, cfg: $0) }

        // The typical band. Personal once trusted (baseline ± sigmaK·σ, exactly what
        // `VitalBands.band` z-tests against); the population range otherwise.
        let typicalStored: ClosedRange<Double>
        let typicalLabel: String
        let bandCaption: String
        if let state, state.trusted {
            let sigma = Baselines.sigma(state)
            let lo = state.baseline - VitalBands.sigmaK * sigma
            let hi = state.baseline + VitalBands.sigmaK * sigma
            typicalStored = min(lo, hi)...max(lo, hi)
            typicalLabel = "Yours"
            bandCaption = "Against your own baseline · \(state.nValid) nights"
        } else {
            typicalStored = populationRange
            typicalLabel = "Typical"
            if cfg == nil {
                bandCaption = "Against the typical adult range"
            } else {
                let n = state?.nValid ?? 0
                bandCaption = n >= Baselines.minNightsTrust
                    ? "Against the typical adult range · your baseline has gone stale"
                    : "Against the typical adult range · \(n) of \(Baselines.minNightsTrust) nights toward your own"
            }
        }

        // The delta vs baseline, in the SAME physical units as the value.
        var delta: AuroraDelta? = nil
        if !suppressDelta, let value, let state, state.usable {
            let d = Baselines.deviation(value, state: state).delta * deltaScale
            delta = AuroraDelta(d,
                                unit: reading.unit,
                                decimals: decimals,
                                higherIsBetter: higherIsBetter,
                                flatThreshold: decimals > 0 ? 0.05 : 0.5)
        }

        // Everything that is drawn on an axis moves into display units together.
        let transform: (Double) -> Double = displayTransform ?? { $0 }
        let displayValue = value.map(transform)
        let tLo = transform(typicalStored.lowerBound)
        let tHi = transform(typicalStored.upperBound)
        let typical = min(tLo, tHi)...max(tLo, tHi)

        // Track bounds: the band with headroom, always widened to contain the reading so a
        // far-out value pins to an edge instead of vanishing off the end of the track.
        var lo = typical.lowerBound
        var hi = typical.upperBound
        let pad = max((hi - lo) * 0.8, decimals > 0 ? 0.4 : 4)
        lo -= pad
        hi += pad
        if let displayValue {
            lo = min(lo, displayValue - pad * 0.25)
            hi = max(hi, displayValue + pad * 0.25)
        }
        let bounds = lo...max(hi, lo + 0.001)

        // The trail, in display units, oldest first.
        let spark = points
            .filter { p in
                guard p.day >= trendCutoff else { return false }
                guard let readingDay else { return true }
                return p.day <= readingDay
            }
            .map { transform($0.value) }

        let verdict = Self.verdictCopy(reading)

        return BodyCard(
            key: reading.key,
            title: reading.label,
            icon: icon,
            tint: tint,
            unit: reading.unit,
            value: value,
            valueText: value.map(reading.format),
            displayValue: displayValue,
            decimals: decimals,
            bounds: bounds,
            typical: typical,
            typicalLabel: typicalLabel,
            bandCaption: bandCaption,
            spark: spark,
            delta: delta,
            band: reading.banding.band,
            verdictLabel: verdict.label,
            verdictTone: verdict.tone,
            verdictColor: verdict.tone == .good ? tint : Aurora.statusCaution,
            provenance: value == nil ? nil : reading.stateCaption,
            missingCaption: reading.missingCaption,
            meaning: meaning,
            meaningEmphasis: meaningEmphasis
        )
    }

    /// The pill copy for a reading's verdict. Same four states `BodyVitalReading.stateText`
    /// distinguishes, worded for a pill rather than a caption.
    private static func verdictCopy(_ r: BodyVitalReading) -> (label: String, tone: AuroraTone) {
        switch (r.banding.band, r.banding.basis) {
        case (.noData, _):               return ("NO READING", .neutral)
        case (.inRange, .personal):      return ("IN YOUR RANGE", .good)
        case (.outOfRange, .personal):   return ("OFF BASELINE", .caution)
        case (.inRange, .population):    return ("TYPICAL", .good)
        case (.outOfRange, .population): return ("OUTSIDE TYPICAL", .caution)
        }
    }

    // MARK: - Series helpers

    /// One vital's per-day series across the source precedence, highest-priority source
    /// first per day — the same resolution `BodyVitalSigns` performs internally, mirrored
    /// here only so the sparkline and the baseline read the same rows the value came from.
    private static func series(_ rows: [SourcedDailyMetric],
                               key: String,
                               _ value: (DailyMetric) -> Double?) -> [BodyPoint] {
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
        return byDay.map { BodyPoint(day: $0.key, value: $0.value) }.sorted { $0.day < $1.day }
    }

    /// `dayKey` minus `days` days, as a day key. Pure UTC key math, never a local shift.
    private static func cutoff(from dayKey: String, days: Int) -> String {
        Baselines.cutoffKey(todayKey: dayKey, carryDays: days)
    }

    /// Noon (local) on `dayKey`, so `Repository.logicalDayKey` / `BodyVitalSigns.logicalDayKey`
    /// both resolve it back to exactly that day, well clear of the 04:00 rollover.
    private static func referenceDate(for dayKey: String) -> Date {
        guard let d = dayKeyParser.date(from: dayKey) else { return Date() }
        return d.addingTimeInterval(12 * 3_600)
    }

    private static let dayKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - Vital colour identities

    private static let rhrTint  = Aurora.dynamic(light: "C2255C", dark: "FF6B9D")
    private static let hrvTint  = Aurora.dynamic(light: "6D4BD6", dark: "A78BFA")
    private static let respTint = Aurora.dynamic(light: "0E7490", dark: "40C8E0")
    private static let spo2Tint = Aurora.dynamic(light: "0F766E", dark: "2DD4BF")
    private static let skinTint = Aurora.dynamic(light: "9A6C00", dark: "F5C518")

    // MARK: - Side series load (verbatim from HealthView's vitals section)

    private func loadCandidateSeries() async {
        // #1118 — always loaded (no toggle): the per-night HRV R-R over-count flags, so an
        // over-counted 4.0 night reads "unverified" instead of as a clean number.
        let ocPts = await repo.exploreSeries(key: "hrv_rr_overcount", source: "my-whoop", days: 60)
        hrvOverCountByDay = Dictionary(ocPts.map { ($0.day, $0.value) }, uniquingKeysWith: { a, _ in a })

        // #103/queue-11a — the SpO₂ candidate nightly means, only when the toggle is ON.
        guard PuffinExperiment.spo2CandidateDisplayEnabled else {
            spo2CandidateByDay = [:]
            return
        }
        let pts = await repo.exploreSeries(key: "spo2_candidate", source: "my-whoop", days: 60)
        spo2CandidateByDay = Dictionary(pts.map { ($0.day, $0.value) }, uniquingKeysWith: { a, _ in a })
    }
}

// MARK: - Local value types

/// One day's value for one vital, after source precedence.
private struct BodyPoint: Equatable {
    let day: String
    let value: Double
}

/// Everything one vital card draws. Built once per render pass; pure presentation.
private struct BodyCard: Identifiable {
    let key: String
    let title: String
    let icon: String
    let tint: Color
    let unit: String
    /// The reading in STORED units (nil = no reading for the day).
    let value: Double?
    /// The reading already formatted by the pipeline's own formatter.
    let valueText: String?
    /// The reading in DISPLAY units — what the range bar plots.
    let displayValue: Double?
    let decimals: Int
    let bounds: ClosedRange<Double>
    let typical: ClosedRange<Double>
    let typicalLabel: String
    let bandCaption: String
    let spark: [Double]
    let delta: AuroraDelta?
    let band: VitalBands.Band
    let verdictLabel: String
    let verdictTone: AuroraTone
    let verdictColor: Color
    let provenance: String?
    let missingCaption: String
    let meaning: String
    let meaningEmphasis: String

    var id: String { key }
}

/// The screen-level verdict: how many of the day's vitals sat inside the band they are
/// judged by. A count and a sentence — never a score, and never a health claim.
private struct BodyVerdict {
    let inRange: Int
    let offRange: Int
    let missing: Int

    init(cards: [BodyCard]) {
        inRange = cards.filter { $0.band == .inRange }.count
        offRange = cards.filter { $0.band == .outOfRange }.count
        missing = cards.filter { $0.band == .noData }.count
    }

    var measured: Int { inRange + offRange }

    var tint: Color {
        if measured == 0 { return Aurora.statusNeutral }
        if offRange == 0 { return Aurora.statusGood }
        return offRange >= 3 ? Aurora.statusAlert : Aurora.statusCaution
    }

    var emphasis: String {
        if measured == 0 { return "Nothing measured" }
        if offRange == 0 { return "All in range." }
        return offRange == 1 ? "One vital" : "\(offRange) vitals"
    }

    var sentence: String {
        if measured == 0 {
            return "Nothing measured for this day. These five vitals are read from an overnight wear, so a night off the strap leaves the whole screen blank."
        }
        if offRange == 0 {
            return "All in range. Every vital NOOP could read sat inside the band it is judged by."
        }
        let verb = offRange == 1 ? "sits" : "sit"
        return offRange == 1
            ? "One vital \(verb) outside its usual band today. That is common after load, a short night or a warm room — look at the trend, not the night."
            : "\(offRange) vitals \(verb) outside their usual band today. That is common after load, a short night or a warm room — look at the trend, not the night."
    }

    var compactText: String {
        if measured == 0 { return "No vitals for this day" }
        if offRange == 0 { return "All \(inRange) in range" }
        return "\(inRange) of \(measured) in range"
    }
}

// MARK: - Staggered appear

/// The house entrance for a list of cards: a short rise + fade, staggered so the eye is led
/// down the page rather than hit with the whole screen at once. Collapses to a plain fade
/// under Reduce Motion.
private struct AuroraBodyAppearModifier: ViewModifier {
    let index: Int
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 10)
            .onAppear {
                guard !appeared else { return }
                if reduceMotion {
                    appeared = true
                } else {
                    withAnimation(Aurora.Motion.curve(Aurora.Motion.durationSlow)
                        .delay(Double(min(index, 6)) * 0.05)) { appeared = true }
                }
            }
    }
}

private extension View {
    func auroraBodyAppear(_ index: Int) -> some View {
        modifier(AuroraBodyAppearModifier(index: index))
    }
}
