import SwiftUI
import StrandAnalytics
import StrandDesign

// MARK: - 06 · Metric Detail — "The Athlete's Ledger"
//
// The spec's metric-detail template (`data-screen-label="Metric detail"`, HRV shown), transcribed
// item by item:
//
//   1. Back link "‹ Trends" (accent).
//   2. Hero: overline metric name → 58/700 value + unit + window delta; sub-line
//      "<catalog descriptor> · last reading <day> · <provenance>".
//   3. Range pill 7D/30D/90D/1Y/ALL — `ExploreRange` + `ExploreRangeGating` reused verbatim.
//   4. Chart: 172pt line, labeled baseline band ("baseline range 52–60"), area fill @7%,
//      terminal glowing dot, date axis.
//   5. Stat strip: MIN · AVG · MAX · Δ WINDOW · LATEST.
//   6. MOVES WITH · 90D PEARSON — label · magnitude bar · signed r.
//   7. "All readings ›" → the readings table with source provenance.
//
// ZERO new data. Every number here is one `Repository`/`StrandAnalytics` call the classic
// `MetricDetailView` already makes:
//   • `repo.exploreSeries(key:source:)`        — the plotted series
//   • `repo.resolvedSeries(key:source:)`       — per-day provenance
//   • `repo.exploreAllSeries()`                — the memoized cross-catalog scan behind MOVES WITH
//   • `ComparisonEngine.stat` / `.compare`     — MIN/AVG/MAX/Δ
//   • `CorrelationEngine.alignByDay` / `.pearson` — the correlation rows
//   • `Baselines.foldHistory` + `VitalBands`   — the "your normal" band
//   • `vitalReadingRows` / `TodayView.provenanceDisplayLabel` — the readings table
//
// PERF (spec §State Management): the screen observes NO live object. `Repository` is the same
// `@EnvironmentObject` the classic screen declares; every O(days) derivation — the window slice,
// the baseline fold, the stat pass, the correlation sweep — runs in `load()` / `rebuildWindow()`
// and lands in a memoized `@State` model. `body` only reads precomputed strings and normalized
// points.

// MARK: - Screen

/// One metric's full history, in the Ledger. Pushed, never a tab.
///
/// ```swift
/// LedgerMetricDetailView(metricKey: "hrv")
/// LedgerMetricDetailView(metricKey: "steps", source: "apple-health", backTitle: "Body")
/// ```
struct LedgerMetricDetailView: View {

    // MARK: Board constants
    //
    // Every value below is the board's own number (`NOOP Redesign.dc.html`,
    // `data-screen-label="Metric detail"`). Nothing here is rounded or "improved".

    /// Back link — `padding:16px 24px 0`, `font-size:13.5px`, `color:#3EE6A8`.
    private static let backLinkTopPadding: CGFloat = 16
    /// See `backLinkTopPadding`.
    private static let backLinkSize: CGFloat = 13.5

    /// Hero block — `padding:14px 24px 0`.
    private static let heroTopPadding: CGFloat = 14
    /// Hero overline — `font-size:11px; font-weight:600; letter-spacing:2.6px`. NOT the 10.5/700/+2.4
    /// section overline: this board element carries the header overline's metrics.
    private static let heroOverlineSize: CGFloat = 11
    /// See `heroOverlineSize`.
    private static let heroOverlineTracking: CGFloat = 2.6
    /// Gap above the value row — `margin-top:8px`.
    private static let heroValueTopGap: CGFloat = 8
    /// Baseline-aligned gap between the numeral, its unit and the delta — `gap:10px`.
    private static let heroValueGap: CGFloat = 10
    /// Hero unit — `font-size:14px; color:#5C6470`.
    private static let heroUnitSize: CGFloat = 14
    /// Hero window delta — `font-size:13.5px`.
    private static let heroDeltaSize: CGFloat = 13.5
    /// Sub-line — `margin-top:6px; font-size:12.5px; color:#9BA3B0`.
    private static let sublineTopGap: CGFloat = 6
    /// See `sublineTopGap`.
    private static let sublineSize: CGFloat = 12.5

    /// Range pill — `margin:18px 24px 0`, segments `padding:5px 13px`.
    private static let pillTopPadding: CGFloat = 18
    /// The five-segment pill's segment horizontal padding — **13** (the three-segment Trends pill
    /// uses 12).
    private static let pillSegmentPadding: CGFloat = 13

    /// Chart block — `margin:16px 24px 0`.
    private static let chartTopPadding: CGFloat = 16

    /// Stat strip — `margin:18px 24px 0`, `border-top` + `padding-top:14px`.
    private static let statStripTopPadding: CGFloat = 18

    /// MOVES WITH block — `margin:16px 24px 0`, `border-top` + `padding-top:14px`.
    private static let movesWithTopPadding: CGFloat = 16
    /// See `movesWithTopPadding`.
    private static let sectionRulePadding: CGFloat = 14

    /// Footer affordance — `margin:14px 24px 22px`.
    private static let footerTopPadding: CGFloat = 14
    /// See `footerTopPadding`.
    private static let footerBottomPadding: CGFloat = 22

    /// The five chips the board's pill shows. `ExploreRange` also carries `.twoWeeks` / `.threeWeeks`
    /// / `.half`, which this control deliberately does NOT surface — the spec names exactly five.
    private static let pillRanges: [ExploreRange] = [.week, .month, .quarter, .year, .all]

    // MARK: Inputs

    /// The `MetricCatalog` entry this screen draws, resolved once in `init`. `nil` when the key names
    /// no catalog metric — the screen then renders its honest "unknown metric" state rather than
    /// inventing a series.
    private let metric: MetricDescriptor?
    /// The key as passed, kept for the unknown-metric state's copy.
    private let requestedKey: String
    /// The word after the back chevron. Defaults to the spec's `"Trends"` — the tab the board's
    /// detail is pushed from — and is overridable so a push from Body or Today names ITS origin
    /// instead of claiming one it did not come from.
    private let backTitle: String

    /// - Parameter metricKey: a `MetricCatalog` key (`"hrv"`, `"rhr"`, `"strain"`, …). When several
    ///   catalog entries share the key (`steps` exists under three sources) the first declared wins —
    ///   use `init(metricKey:source:)` to pin one.
    init(metricKey: String) {
        self.init(metricKey: metricKey, source: nil, backTitle: LedgerMetricDetailView.defaultBackTitle)
    }

    /// - Parameters:
    ///   - metricKey: a `MetricCatalog` key.
    ///   - source: the catalog source partition (`"my-whoop"`, `"apple-health"`, `"xiaomi-band"`, …).
    ///     `nil` resolves by bare key, matching `TabRoute.metric(_:)`.
    ///   - backTitle: the word after the back chevron.
    init(metricKey: String, source: String?, backTitle: String = LedgerMetricDetailView.defaultBackTitle) {
        self.requestedKey = metricKey
        self.backTitle = backTitle
        if let source {
            self.metric = MetricCatalog.metric(key: metricKey, source: source)
                ?? MetricCatalog.all.first { $0.key == metricKey }
        } else {
            self.metric = MetricCatalog.all.first { $0.key == metricKey }
        }
    }

    /// The spec's back-link word: the Trends tab owns the metric detail in the Tap Map.
    static var defaultBackTitle: String { String(localized: "Trends") }

    // MARK: Environment
    //
    // Copied from the classic `MetricDetailView`, which is the screen this replaces. `repo` supplies
    // every series; `profile` and `intelligence` are declared so the Ledger detail has the SAME
    // environment contract as the classic one (both are injected app-wide in `RootTabView`), and so a
    // later port of the `fitness_age` not-ready countdown needs no new binding.

    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore
    @EnvironmentObject var intelligence: IntelligenceEngine

    /// Imperial/Metric display preference (D#103) — byte-identical key to the classic screen.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    /// Effort display scale (#268) — routes the Effort metric onto the WHOOP 0–21 axis. Display-only;
    /// the plotted series stays 0–100.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue

    @Environment(\.dismiss) private var dismiss

    // MARK: State
    //
    // Three caches, all filled OFF the render path. `series`/`sourceByDay`/`others` are the raw reads;
    // `window` and `correlations` are the memoized derivations `body` actually renders.

    /// The pill's stored selection. `.month` = the board's highlighted 30D chip, and the classic
    /// screen's default.
    @State private var range: ExploreRange = .month
    /// Full ascending series for this metric — ALL history.
    @State private var series: [(day: String, value: Double)] = []
    /// day → the RAW source id that supplied that day's value, for the readings table's provenance
    /// column and the hero sub-line.
    @State private var sourceByDay: [String: String] = [:]
    /// True once this metric's own series is in — the gate for the whole screen.
    @State private var loaded = false
    /// Every OTHER catalog series, from the memoized cross-catalog scan. Only MOVES WITH reads it.
    @State private var others: [(metric: MetricDescriptor, series: [(day: String, value: Double)])] = []
    /// True once that scan has finished, so MOVES WITH can say "scanning" instead of "nothing".
    @State private var correlationsLoaded = false

    /// The memoized window model — everything `body` draws above MOVES WITH.
    @State private var window: WindowModel?
    /// The `(range, series.count)` the window model was built for.
    @State private var windowKey: String?
    /// The memoized 90D correlation rows.
    @State private var correlations: [MovesWithRow] = []
    /// The `(metric, others.count)` the correlation cache was built for.
    @State private var correlationKey: String?

    /// Re-runs `load()` when the repository refreshes, exactly as the classic screen does.
    private var loadTaskID: String { "\(metric?.id ?? requestedKey)|\(repo.refreshSeq)" }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                backLink                                        // 1
                if let metric {
                    hero(metric)                                // 2
                    rangePill                                   // 3
                    if loaded && series.isEmpty {
                        emptyHistoryNote
                    } else if !loaded {
                        loadingNote(metric)
                    } else {
                        chartSection                            // 4
                        statStrip                               // 5
                        movesWith                               // 6
                        allReadingsLink(metric)                 // 7
                    }
                } else {
                    unknownMetricNote
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Ledger.pageMargin)
        }
        .background(Ledger.bgScreen.ignoresSafeArea())
        .ledgerMotionGate()
        #if os(iOS)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        // The board draws its own back link; the system bar would put a second one above it.
        .toolbar(.hidden, for: .navigationBar)
        // Pull-to-refresh, unchanged: the SAME `repo.refresh()` every other surface calls.
        .refreshable { await repo.refresh() }
        #endif
        .navigationTitle(metric?.title ?? requestedKey)
        .task(id: loadTaskID) { await load() }
        // A range change moves the window, hence every derivation above — rebuild the caches rather
        // than letting `body` scan the series.
        .onChangeCompat(of: range) { _ in
            rebuildWindow()
            rebuildCorrelations()
        }
        // Every rendered string is unit-formatted, so a units / effort-scale change in Settings must
        // rebuild the cached model too — the same inputs the memo key carries.
        .onChangeCompat(of: unitPrefsKey) { _ in rebuildWindow() }
    }

    /// The unit-preference inputs the window model's strings depend on, as one comparable value.
    private var unitPrefsKey: String { "\(unitSystemRaw)|\(temperatureRaw)|\(effortScaleRaw)" }

    // MARK: 1 · Back link

    /// `‹ Trends` — 13.5pt in the metric's accent. The only navigational text above the fold.
    private var backLink: some View {
        Button { dismiss() } label: {
            Text(verbatim: "\u{2039} \(backTitle)")
                .font(LedgerType.label(Self.backLinkSize, LedgerType.regular))
                .foregroundStyle(accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: Ledger.rowMinHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, Self.backLinkTopPadding)
        .accessibilityLabel(Text("Back to \(backTitle)"))
    }

    // MARK: 2 · Hero

    /// Overline metric name → 58/700 value + unit + window delta → sub-line.
    @ViewBuilder
    private func hero(_ metric: MetricDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(metric.title)
                .font(LedgerType.label(Self.heroOverlineSize, LedgerType.semibold))
                .tracking(Self.heroOverlineTracking)
                .textCase(.uppercase)
                .foregroundStyle(Ledger.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .lastTextBaseline, spacing: Self.heroValueGap) {
                Text(window?.heroValue ?? "\u{2014}")
                    .ledgerBigNumeral()
                    .foregroundStyle(Ledger.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit = window?.heroUnit, !unit.isEmpty {
                    Text(unit)
                        .font(LedgerType.label(Self.heroUnitSize, LedgerType.regular))
                        .foregroundStyle(Ledger.textTertiary)
                }
                if let delta = window?.deltaText {
                    Text(delta)
                        .font(LedgerType.label(Self.heroDeltaSize, LedgerType.regular))
                        .foregroundStyle((window?.deltaTone ?? .neutral).color)
                }
            }
            .padding(.top, Self.heroValueTopGap)

            if let subline = window?.subline, !subline.isEmpty {
                Text(subline)
                    .font(LedgerType.label(Self.sublineSize, LedgerType.regular))
                    .foregroundStyle(Ledger.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Self.sublineTopGap)
            }
        }
        .padding(.top, Self.heroTopPadding)
        .accessibilityElement(children: .combine)
    }

    // MARK: 3 · Range pill

    /// 7D · 30D · 90D · 1Y · ALL. Selection rides `ExploreRangeGating.coerced` (#943,
    /// non-destructive) and locked chips dim through the pill's own `isEnabled` hook.
    private var rangePill: some View {
        VStack(alignment: .leading, spacing: 6) {
            LedgerRangePill(
                options: Self.pillRanges,
                selection: pillSelectionBinding,
                label: Self.chipLabel,
                isEnabled: isUnlocked,
                horizontalPadding: Self.pillSegmentPadding
            )
            if loaded, !series.isEmpty, hasLockedRanges {
                // Existing copy, verbatim: without it the dimmed chips read as broken rather than
                // as "not yet".
                Text("Longer ranges unlock as more history builds.")
                    .ledgerCaptionStyle(11)
            }
        }
        .padding(.top, Self.pillTopPadding)
    }

    // MARK: 4 · Chart

    /// 172pt line with its labeled baseline band, 7% area fill, terminal glowing dot and date axis.
    @ViewBuilder
    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            LedgerMetricDetailChart(
                points: window?.chartPoints ?? [],
                bandTopFraction: window?.bandTopFraction,
                bandBottomFraction: window?.bandBottomFraction,
                bandLabel: window?.baselineLabel,
                accent: accent
            )

            HStack(spacing: 8) {
                ForEach(Array((window?.axisLabels ?? []).enumerated()), id: \.offset) { index, label in
                    if index > 0 { Spacer(minLength: 4) }
                    Text(label).ledgerCaptionStyle(10)
                }
            }
            .padding(.top, LedgerMetricDetailChart.axisGap)

            if let caption = window?.widenedCaption {
                Text(caption).ledgerCaptionStyle(11).padding(.top, 4)
            }
        }
        .padding(.top, Self.chartTopPadding)
    }

    // MARK: 5 · Stat strip

    /// MIN · AVG · MAX · Δ <window> · LATEST — the existing detail stats, on the board's
    /// label-above strip.
    private var statStrip: some View {
        LedgerStatStrip(window?.statItems ?? [], style: .labelAbove)
            .padding(.top, Self.statStripTopPadding)
    }

    // MARK: 6 · MOVES WITH

    /// The existing correlation scan, fixed at the board's 90-day window: label · magnitude bar ·
    /// signed r. Positive is mint; a negative is red at |r| ≥ 0.5 and caution below it, exactly the
    /// two negative rows the board draws.
    private var movesWith: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Ledger.hairline)
                .frame(height: Ledger.hairlineWidth)

            Text("Moves with · 90D Pearson")
                .ledgerOverline()
                .padding(.top, Self.sectionRulePadding)

            if !correlationsLoaded {
                Text("Scanning the catalog…")
                    .ledgerCaptionStyle(11)
                    .frame(maxWidth: .infinity, minHeight: Ledger.rowMinHeight, alignment: .leading)
            } else if correlations.isEmpty {
                Text("Nothing in the catalog moves clearly with this metric over 90 days.")
                    .ledgerCaptionStyle(11)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: Ledger.rowMinHeight, alignment: .leading)
            } else {
                ForEach(Array(correlations.enumerated()), id: \.element.id) { index, row in
                    LedgerMovesWithRowView(row: row, showsDivider: index < correlations.count - 1)
                }
            }
        }
        .padding(.top, Self.movesWithTopPadding)
    }

    // MARK: 7 · All readings

    /// "All readings ›" — one tap below, the existing readings table with its source provenance.
    @ViewBuilder
    private func allReadingsLink(_ metric: MetricDescriptor) -> some View {
        NavigationLink {
            LedgerMetricReadingsView(title: metric.title, rows: window?.readingRows ?? [])
        } label: {
            HStack(spacing: 6) {
                Text("All readings")
                Text(verbatim: "\u{203A}")
            }
            .font(LedgerType.label(Self.backLinkSize, LedgerType.regular))
            .foregroundStyle(accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: Ledger.rowMinHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, Self.footerTopPadding)
        .padding(.bottom, Self.footerBottomPadding)
    }

    // MARK: Empty / loading states

    private var unknownMetricNote: some View {
        VStack(alignment: .leading, spacing: Self.sublineTopGap) {
            Text(requestedKey)
                .font(LedgerType.label(Self.heroOverlineSize, LedgerType.semibold))
                .tracking(Self.heroOverlineTracking)
                .textCase(.uppercase)
                .foregroundStyle(Ledger.textTertiary)
            Text(verbatim: "\u{2014}")
                .ledgerBigNumeral()
                .foregroundStyle(Ledger.textPrimary)
            Text("No metric by that name.")
                .font(LedgerType.label(Self.sublineSize, LedgerType.regular))
                .foregroundStyle(Ledger.textSecondary)
        }
        .padding(.top, Self.heroTopPadding)
        .padding(.bottom, Self.footerBottomPadding)
    }

    private func loadingNote(_ metric: MetricDescriptor) -> some View {
        Text("Reading your \(metric.title.lowercased())…")
            .ledgerCaptionStyle(11)
            .padding(.top, Self.chartTopPadding)
            .padding(.bottom, Self.footerBottomPadding)
    }

    private var emptyHistoryNote: some View {
        Text("No readings yet. A WHOOP export in Data Sources fills every metric you can explore here.")
            .ledgerBody()
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Self.chartTopPadding)
            .padding(.bottom, Self.footerBottomPadding)
    }

    // MARK: - Formatting

    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: unitSystem, override: temperatureRaw)
    }
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    /// The metric's own formatter, with the unit appended — the classic screen's `fmt`.
    private func fmt(_ v: Double) -> String {
        guard let metric else { return "\u{2014}" }
        return metric.format(v, system: unitSystem, temperature: temperatureUnit, effortScale: effortScale)
    }

    /// The metric's formatted value with its unit STRIPPED. The board prints the numeral and the unit
    /// as two separately styled runs (58/700 primary, 14/400 tertiary), and the baseline-band label
    /// and stat strip print bare numbers — so the unit is removed from the formatted string rather
    /// than re-deriving the number, which would drop the kg/°C/0–21 conversions.
    private func bare(_ v: Double) -> String {
        guard metric != nil else { return "\u{2014}" }
        let text = fmt(v)
        let unit = displayUnit
        guard !unit.isEmpty, text.hasSuffix(" " + unit) else { return text }
        return String(text.dropLast(unit.count + 1))
    }

    private var displayUnit: String {
        metric?.displayUnit(system: unitSystem, temperature: temperatureUnit, effortScale: effortScale) ?? ""
    }

    /// A signed difference, unit-stripped — the board's `+6 over window`.
    private func signedBare(_ delta: Double) -> String {
        guard let metric else { return "\u{2014}" }
        let magnitude = metric.formatDelta(abs(delta), system: unitSystem,
                                           temperature: temperatureUnit, effortScale: effortScale)
        let unit = displayUnit
        let trimmed = (!unit.isEmpty && magnitude.hasSuffix(" " + unit))
            ? String(magnitude.dropLast(unit.count + 1))
            : magnitude
        return (delta >= 0 ? "+" : "\u{2212}") + trimmed
    }

    /// The chip's label. The spec names five chips by day-count (`7D`/`30D`/`90D`/`1Y`/`ALL`);
    /// `ExploreRange.label` says `W`/`M`/`3M`, so the display strings live here and the shared enum
    /// stays untouched.
    private static func chipLabel(_ r: ExploreRange) -> String {
        switch r {
        case .week:    return "7D"
        case .month:   return "30D"
        case .quarter: return "90D"
        case .year:    return "1Y"
        case .all:     return "ALL"
        default:       return r.label
        }
    }

    /// The metric's Ledger accent. `colour = meaning only`: the domain accents the spec assigns
    /// (Charge → recovery mint, Rest → sleep indigo, Effort → strain blue) plus the two overrides the
    /// Trends board states outright — RESTING HR is drawn grey there, and DAY STRAIN blue. Anything
    /// outside a named domain stays grayscale chrome rather than borrowing a meaning it does not have.
    private var accent: Color {
        guard let metric else { return Ledger.textSecondary }
        switch metric.key {
        case "rhr":               return Ledger.textSecondary
        case "strain":            return Ledger.accentStrain
        default: break
        }
        switch metric.category {
        case "Charge": return Ledger.accentRecovery
        case "Rest":   return Ledger.accentSleep
        case "Effort": return Ledger.accentStrain
        default:       return Ledger.textSecondary
        }
    }

    // MARK: - Range resolution (reused verbatim from the classic detail)

    /// The trailing-N-days slice for a range, taken RELATIVE TO THE LATEST data point (not "now"),
    /// so a stale-but-present series still resolves. `.all` returns everything.
    private func slice(for r: ExploreRange) -> [(day: String, value: Double)] {
        guard let days = r.days else { return series }
        guard let lastDay = series.last?.day, let last = LedgerMetricDay.parse(lastDay) else { return [] }
        let cutoff = last.addingTimeInterval(-Double(days - 1) * 86_400)
        return series.filter { row in
            guard let d = LedgerMetricDay.parse(row.day) else { return false }
            return d >= cutoff
        }
    }

    /// Whole days between the first and last reading (0 for a single point).
    private var historySpanDays: Int {
        guard let firstDay = series.first?.day, let lastDay = series.last?.day,
              let first = LedgerMetricDay.parse(firstDay), let last = LedgerMetricDay.parse(lastDay) else { return 0 }
        return Int(last.timeIntervalSince(first) / 86_400)
    }

    /// #943 unlock gate, copied verbatim: a longer range unlocks only once the history span EXCEEDS
    /// the previous window. W and ALL are never gated; nothing is gated until the series loads.
    private func isUnlocked(_ r: ExploreRange) -> Bool {
        guard loaded, !series.isEmpty else { return true }
        switch r {
        case .week, .all: return true
        case .twoWeeks:   return historySpanDays > ExploreRange.week.rawValue
        case .threeWeeks: return historySpanDays > ExploreRange.twoWeeks.rawValue
        case .month:      return historySpanDays > ExploreRange.threeWeeks.rawValue
        case .quarter:    return historySpanDays > ExploreRange.month.rawValue
        case .half:       return historySpanDays > ExploreRange.quarter.rawValue
        case .year:       return historySpanDays > ExploreRange.half.rawValue
        }
    }

    /// True when at least one of the five shown chips is locked.
    private var hasLockedRanges: Bool { !Self.pillRanges.allSatisfy(isUnlocked) }

    /// The non-destructive #943 coercion of the stored selection.
    private var coercedSelection: ExploreRange {
        ExploreRangeGating.coerced(selection: range, isUnlocked: isUnlocked)
    }

    /// The chip the pill HIGHLIGHTS. `coerced` may land on `.twoWeeks` / `.threeWeeks`, which this
    /// five-chip pill does not show, so the highlight steps down to the largest shown chip at or
    /// below it. Display only — the stored `range` and `coercedSelection` are untouched, so the
    /// window itself still resolves exactly as the classic screen's does.
    private var pillSelection: ExploreRange {
        let coerced = coercedSelection
        if Self.pillRanges.contains(coerced) { return coerced }
        return Self.pillRanges
            .filter { $0.days != nil && $0.rawValue <= coerced.rawValue }
            .max(by: { $0.rawValue < $1.rawValue }) ?? .week
    }

    /// Highlights the coerced chip; a tap writes straight to the stored selection. Reads never mutate.
    private var pillSelectionBinding: Binding<ExploreRange> {
        Binding(get: { pillSelection }, set: { range = $0 })
    }

    /// The range actually drawn: the coerced selection when its window holds ≥1 point, else the
    /// smallest larger range that does, else `.all`.
    private var effectiveRange: ExploreRange {
        guard !series.isEmpty else { return coercedSelection }
        for r in coercedSelection.widening where !slice(for: r).isEmpty { return r }
        return .all
    }

    /// The window immediately preceding the active one (equal length, by row count) — the Δ's
    /// comparison period.
    private func previousWindow(_ windowed: [(day: String, value: Double)]) -> [(day: String, value: Double)] {
        guard effectiveRange != .all else { return [] }
        let size = windowed.count
        guard size > 0, let firstDay = windowed.first?.day,
              let lo = series.firstIndex(where: { $0.day == firstDay }) else { return [] }
        let prevLo = max(0, lo - size)
        guard prevLo < lo else { return [] }
        return Array(series[prevLo..<lo])
    }

    // MARK: - Baseline band

    /// The `MetricCfg` behind this metric's personal baseline, or `nil` when the analytics layer has
    /// none. Only five metrics have one; the catalog's key is mapped to the config's key here rather
    /// than assumed equal (`rhr` → `resting_hr`, `resp_rate` → `resp`).
    private func baselineCfg(latest: Double?) -> MetricCfg? {
        guard let metric else { return nil }
        switch metric.key {
        case "hrv":       return Baselines.hrvCfg
        case "rhr":       return Baselines.restingHRCfg
        case "resp_rate": return Baselines.respCfg
        case "strain":    return Baselines.strainCfg
        case "skin_temp":
            // Bimodal: an imported absolute °C reading folds against the absolute config; an
            // on-device ±°C deviation folds against the deviation config.
            guard let latest else { return nil }
            return VitalBands.isAbsoluteSkinTemp(latest)
                ? Baselines.metricCfg["skin_temp"]
                : VitalBands.skinTempDeviationCfg
        default: return nil
        }
    }

    /// The fixed typical-adult range used when the personal baseline is not yet trusted. These are the
    /// SAME literals `VitalSignsSummary` and `AuroraBodyView` pass, so the Ledger band can never
    /// disagree with the verdicts those surfaces already ship.
    private func populationRange(latest: Double?) -> ClosedRange<Double>? {
        guard let metric else { return nil }
        switch metric.key {
        case "hrv":       return 40...120
        case "rhr":       return 40...60
        case "resp_rate": return 12...20
        case "spo2":      return 95...100
        case "skin_temp":
            guard let latest else { return nil }
            return VitalBands.isAbsoluteSkinTemp(latest) ? 33...36 : (-0.6)...0.6
        default: return nil
        }
    }

    /// "Your normal", in VALUE units: the personal band (`baseline ± 2σ`) once the baseline is
    /// trusted, else the population range, else nothing. History is every night STRICTLY BEFORE the
    /// latest reading, calendar-padded so real wear gaps make a stale baseline stale.
    private func baselineBand() -> ClosedRange<Double>? {
        let latest = series.last?.value
        guard let cfg = baselineCfg(latest: latest) else { return populationRange(latest: latest) }
        let priorRows: [(day: String, value: Double?)] = series.dropLast().map { ($0.day, $0.value) }
        var history = VitalBands.calendarSeries(priorRows)
        if metric?.key == "skin_temp", let latest {
            history = VitalBands.skinTempHistory(matching: latest, in: history)
        }
        let state = Baselines.foldHistory(history, cfg: cfg)
        guard state.trusted else { return populationRange(latest: latest) }
        let sigma = Baselines.sigma(state)
        let lower = state.baseline - VitalBands.sigmaK * sigma
        let upper = state.baseline + VitalBands.sigmaK * sigma
        guard upper > lower else { return populationRange(latest: latest) }
        return lower...upper
    }

    // MARK: - Load

    /// Two phases, exactly as the classic screen: this metric's own series first (everything the
    /// visible screen needs), then the cross-catalog scan that only MOVES WITH waits on.
    private func load() async {
        guard let metric else { loaded = true; return }

        series = await repo.exploreSeries(key: metric.key, source: metric.source)

        let resolution = await repo.resolvedSeries(key: metric.key, source: metric.source)
        sourceByDay = Dictionary(resolution.points.map { ($0.day, $0.source) },
                                 uniquingKeysWith: { first, _ in first })

        // #103/queue-11a: fill in the spo2 candidate fallback for days the calibrated series has no
        // reading for — the SAME fallback Today's Key Metrics tile and `VitalSignsSummary` show.
        // Calibrated days always win; this only ADDS days, never overwrites one.
        if metric.key == "spo2", metric.source == "my-whoop", PuffinExperiment.spo2CandidateDisplayEnabled {
            let candidates = await repo.exploreSeries(key: "spo2_candidate", source: metric.source)
            if !candidates.isEmpty {
                var byDay = Dictionary(series.map { ($0.day, $0.value) },
                                       uniquingKeysWith: { first, _ in first })
                for point in candidates where byDay[point.day] == nil {
                    byDay[point.day] = point.value
                    sourceByDay[point.day] = spo2CandidateAttributionSource
                }
                series = byDay.sorted { $0.key < $1.key }.map { (day: $0.key, value: $0.value) }
            }
        }

        loaded = true
        windowKey = nil          // the series changed; force a rebuild.
        rebuildWindow()

        // Phase 2 — the memoized cross-catalog scan behind MOVES WITH.
        guard let allSeries = await repo.exploreAllSeries() else { return }
        var loadedOthers: [(metric: MetricDescriptor, series: [(day: String, value: Double)])] = []
        for other in MetricCatalog.all where other.id != metric.id {
            guard !Task.isCancelled else { return }
            if let s = allSeries[other.id], !s.isEmpty { loadedOthers.append((other, s)) }
        }
        guard !Task.isCancelled else { return }
        others = loadedOthers
        correlationsLoaded = true
        correlationKey = nil
        rebuildCorrelations()
    }

    // MARK: - Memoized derivations
    //
    // Everything below runs OFF the render path — from `load()` and from the range's `onChange`.

    /// Rebuild the window model for the current selection, but only when its inputs actually changed.
    private func rebuildWindow() {
        guard let metric else { return }
        let key = "\(range.rawValue)|\(series.count)|\(unitPrefsKey)"
        guard windowKey != key else { return }
        windowKey = key

        let effRange = effectiveRange
        let windowed = slice(for: effRange)
        let values = windowed.map(\.value)
        let fellBack = effRange != range

        let stat = ComparisonEngine.stat(values)
        let comparison = ComparisonEngine.compare(current: values,
                                                  previous: previousWindow(windowed).map(\.value))
        let hasDelta = comparison.current.n > 0 && comparison.previous.n > 0

        // Tone by the metric's own polarity, never by the sign — `higherIsBetter == nil` (respiratory
        // rate, skin temp) stays tertiary because "up" is neither good nor bad there.
        let deltaTone: LedgerTone = {
            guard hasDelta, comparison.direction != 0, let better = metric.higherIsBetter else { return .neutral }
            return ((comparison.direction > 0) == better) ? .good : .critical
        }()
        let deltaText: String? = hasDelta
            ? String(localized: "\(signedBare(comparison.delta)) over window")
            : nil

        let band = baselineBand()
        let domain = LedgerScale.domain(values: values, including: band)

        var chartPoints: [CGPoint] = []
        var bandTop: CGFloat?
        var bandBottom: CGFloat?
        if let domain, values.count >= 2 {
            chartPoints = values.enumerated().map { index, value in
                CGPoint(x: LedgerScale.normalizedX(index, count: values.count),
                        y: LedgerScale.normalizedY(value, in: domain))
            }
        }
        if let domain, let band {
            bandTop = min(max(LedgerScale.normalizedY(band.upperBound, in: domain), 0), 1)
            bandBottom = min(max(LedgerScale.normalizedY(band.lowerBound, in: domain), 0), 1)
        }

        let bandLabel = band.map {
            String(localized: "baseline range \(bare($0.lowerBound))\u{2013}\(bare($0.upperBound))")
        }

        let statItems: [LedgerStatStrip.Item] = values.isEmpty ? [] : [
            .init(value: bare(stat.min), label: String(localized: "MIN")),
            .init(value: bare(stat.mean), label: String(localized: "AVG")),
            .init(value: bare(stat.max), label: String(localized: "MAX")),
            .init(value: hasDelta ? signedBare(comparison.delta) : "\u{2014}",
                  label: "\u{0394} " + Self.chipLabel(effRange),
                  tint: hasDelta ? deltaTone.color : Ledger.textPrimary),
            .init(value: series.last.map { bare($0.value) } ?? "\u{2014}",
                  label: String(localized: "LATEST")),
        ]

        // The sub-line: the catalog's own descriptor (only the three headline scores carry one, so
        // the category is the honest fallback) plus the latest reading's day and the source that
        // actually supplied it. There is no time-of-day here because these series are day-keyed.
        let descriptor = metric.description ?? MetricCatalog.categoryDisplayName(metric.category)
        let subline: String = {
            guard let last = series.last else { return descriptor }
            let provenance = TodayView.provenanceDisplayLabel(
                rawSource: sourceByDay[last.day] ?? metric.source, deviceId: repo.deviceId)
            return String(localized: "\(descriptor) · last reading \(vitalReadingDateLabel(last.day)) · \(provenance)")
        }()

        let widened: String? = {
            guard fellBack, !windowed.isEmpty else { return nil }
            let n = windowed.count
            return n == 1
                ? String(localized: "1 reading · sparse, widened to \(effRange.name)")
                : String(localized: "\(n) readings · sparse, widened to \(effRange.name)")
        }()

        window = WindowModel(
            heroValue: series.last.map { bare($0.value) } ?? "\u{2014}",
            heroUnit: displayUnit,
            deltaText: deltaText,
            deltaTone: deltaTone,
            subline: subline,
            chartPoints: chartPoints,
            bandTopFraction: bandTop,
            bandBottomFraction: bandBottom,
            baselineLabel: bandLabel,
            axisLabels: Self.axisLabels(windowed.map(\.day)),
            statItems: statItems,
            widenedCaption: widened,
            readingRows: readingRows(metric, windowed: windowed)
        )
    }

    /// Rebuild the 90-day correlation rows. The board's MOVES WITH block is fixed at 90D — it does
    /// NOT follow the pill — so this is keyed on the metric and the scan's size only.
    private func rebuildCorrelations() {
        guard let metric else { return }
        let key = "\(metric.id)|\(others.count)|\(series.count)"
        guard correlationKey != key else { return }
        correlationKey = key

        let windowed = slice(for: .quarter)
        let myDays = Set(windowed.map(\.day))
        guard !myDays.isEmpty else { correlations = []; return }

        var rows: [MovesWithRow] = []
        for entry in others {
            let otherWindowed = entry.series.filter { myDays.contains($0.day) }
            let pairs = CorrelationEngine.alignByDay(windowed, otherWindowed)
            guard pairs.count >= 10, let c = CorrelationEngine.pearson(pairs) else { continue }
            guard abs(c.r) >= 0.3 else { continue }
            rows.append(MovesWithRow(id: entry.metric.id, title: entry.metric.title, r: c.r, n: c.n))
        }
        rows.sort { abs($0.r) > abs($1.r) }
        correlations = Array(rows.prefix(6))
    }

    /// The readings table's rows, from the SAME window the chart draws — the existing
    /// `vitalReadingRows` projection, newest first, with `TodayView.provenanceDisplayLabel` naming
    /// each source.
    private func readingRows(_ metric: MetricDescriptor,
                             windowed: [(day: String, value: Double)]) -> [VitalReadingRow] {
        let readings = windowed.map {
            VitalReading(day: $0.day, value: $0.value, source: sourceByDay[$0.day] ?? metric.source)
        }
        return vitalReadingRows(readings: readings, unit: metric.unit,
                                strapDeviceId: repo.deviceId, format: fmt)
    }

    /// The board's three date labels — first, middle, last day of the window.
    private static func axisLabels(_ days: [String]) -> [String] {
        guard !days.isEmpty else { return [] }
        let indices = days.count >= 3 ? [0, days.count / 2, days.count - 1] : Array(0..<days.count)
        return indices.map { LedgerMetricDay.axisLabel(days[$0]) }
    }

    // MARK: - Models

    /// Everything `body` draws above MOVES WITH, precomputed. Strings are final; points are
    /// normalized. Nothing in here is derived a second time at render.
    private struct WindowModel {
        let heroValue: String
        let heroUnit: String
        let deltaText: String?
        let deltaTone: LedgerTone
        let subline: String
        /// Normalized chart points — x 0…1 left→right, y 0…1 top→bottom.
        let chartPoints: [CGPoint]
        /// The baseline band's edges as 0…1 fractions of the plot height (`top` is the upper bound).
        let bandTopFraction: CGFloat?
        /// See `bandTopFraction`.
        let bandBottomFraction: CGFloat?
        let baselineLabel: String?
        let axisLabels: [String]
        let statItems: [LedgerStatStrip.Item]
        /// The existing auto-widen caption, shown only when the window actually fell back.
        let widenedCaption: String?
        /// The readings table's rows for this window, projected here rather than in `body`:
        /// a `NavigationLink`'s destination is built EAGERLY, so slicing inside it would put an
        /// O(days) filter on the render path.
        let readingRows: [VitalReadingRow]
    }

    /// One MOVES WITH row.
    struct MovesWithRow: Identifiable, Equatable {
        let id: String
        let title: String
        /// Pearson r over the 90-day window.
        let r: Double
        /// Paired observations behind it.
        let n: Int
    }
}

// MARK: - Day parsing

/// The screen's day helpers. `MetricExplorerView`'s own parser is file-private, so this is the same
/// UTC / `en_US_POSIX` contract restated rather than a second, looser convention.
enum LedgerMetricDay {
    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let axisFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MMM d"
        return f
    }()

    /// `"yyyy-MM-dd"` → `Date`, fixed UTC.
    static func parse(_ day: String) -> Date? { parser.date(from: day) }

    /// `"Jun 3"` — the chart's date axis. The verbatim key if it does not parse.
    static func axisLabel(_ day: String) -> String {
        guard let date = parse(day) else { return day }
        return axisFormatter.string(from: date)
    }
}

// MARK: - The 172pt detail chart

/// The board's hero chart: a `<rect>` baseline band with its label, a 7% area fill, a 2.2pt line and
/// a glowing terminal dot.
///
/// `Shape` + `.trim`, not `LineMark`: the spec's §Motion mandates a "single path draw-in 1.2 s
/// (trim)", and a Swift Charts `LineMark` cannot be trimmed. The area fill is revealed by a mask on
/// the same progress, because trimming a closed region shows a wedge rather than a chart.
struct LedgerMetricDetailChart: View {

    /// Chart height — **172pt** (`<svg height="172">`).
    static let chartHeight: CGFloat = 172
    /// Line stroke — 2.2pt (`stroke-width="2.2"`).
    static let lineWidth: CGFloat = 2.2
    /// Terminal dot radius — 4pt (`<circle r="4">`).
    static let dotRadius: CGFloat = 4
    /// The dot's glow. CSS's `drop-shadow(0 0 8px …)` third length is the blur DIAMETER; SwiftUI's
    /// `.shadow(radius:)` is the blur RADIUS, so the board's 8 is applied as 4.
    static let dotGlowCSSBlur: CGFloat = 8
    /// Baseline label — `font-size:9`, `x="4"`, and `y` 12 below the band's top edge (SVG `y` is the
    /// text baseline).
    static let bandLabelSize: CGFloat = 9
    /// See `bandLabelSize`.
    static let bandLabelInset: CGFloat = 4
    /// See `bandLabelSize`.
    static let bandLabelBaseline: CGFloat = 12
    /// Gap between the plot and its date axis — `margin-top:6px`.
    static let axisGap: CGFloat = 6

    let points: [CGPoint]
    let bandTopFraction: CGFloat?
    let bandBottomFraction: CGFloat?
    let bandLabel: String?
    let accent: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    band(in: geo.size)
                    if points.count >= 2 {
                        LedgerDrawIn(.chart) { progress in
                            plot(progress: progress, size: geo.size)
                        }
                    }
                }
            }
            if points.count < 2 {
                Text("Not enough history yet")
                    .ledgerCaptionStyle(11)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        // Exactly the board's 172pt — no inset. `LedgerScale.domain` already pads the value range
        // by 8%, so the terminal dot's 4pt radius sits well inside the plot's own edge.
        .frame(height: Self.chartHeight)
    }

    /// `<rect fill="rgba(255,255,255,.05)">` plus its label — "your normal", positioned in value
    /// space so the line's relationship to the band is real.
    @ViewBuilder
    private func band(in size: CGSize) -> some View {
        if let top = bandTopFraction, let bottom = bandBottomFraction {
            let y = top * size.height
            let height = max(0, (bottom - top) * size.height)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Ledger.baselineBand)
                    .frame(width: size.width, height: height)
                if let bandLabel {
                    Text(bandLabel)
                        .font(LedgerType.label(Self.bandLabelSize, LedgerType.regular))
                        .foregroundStyle(Ledger.textTertiary)
                        .lineLimit(1)
                        .padding(.leading, Self.bandLabelInset)
                        // SVG `y` is the text BASELINE: the label's bottom sits 12pt below the
                        // band's top edge.
                        .frame(height: Self.bandLabelBaseline, alignment: .bottom)
                }
            }
            .offset(y: y)
        }
    }

    @ViewBuilder
    private func plot(progress: Double, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            LedgerPolyline(points: points, closed: true)
                .fill(accent.opacity(Ledger.detailAreaFillOpacity))
                .mask(alignment: .leading) {
                    Rectangle().frame(width: size.width * CGFloat(progress))
                }
            LedgerPolyline(points: points)
                .trim(from: 0, to: progress)
                .stroke(accent, style: StrokeStyle(lineWidth: Self.lineWidth,
                                                   lineCap: .round, lineJoin: .round))
            if let last = points.last, progress >= 1 {
                Circle()
                    .fill(accent)
                    .frame(width: Self.dotRadius * 2, height: Self.dotRadius * 2)
                    .shadow(color: accent, radius: Self.dotGlowCSSBlur / 2)
                    .offset(x: last.x * size.width - Self.dotRadius,
                            y: last.y * size.height - Self.dotRadius)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - MOVES WITH row

/// `label · magnitude bar · signed r`. The bar is `|r|` of a 110pt track; the tint carries the sign
/// and the strength, exactly as the board paints its three rows (`+.61` mint, `−.54` red,
/// `−.32` caution).
struct LedgerMovesWithRowView: View {

    /// Row vertical padding — 11pt (`padding:11px 0`).
    private static let verticalPadding: CGFloat = 11
    /// Gap between the label, the bar and the value — 14pt (`gap:14px`).
    private static let columnGap: CGFloat = 14
    /// Magnitude bar — `width:110px; height:4px; border-radius:2px`.
    private static let barWidth: CGFloat = 110
    /// See `barWidth`.
    private static let barHeight: CGFloat = 4
    /// See `barWidth`.
    private static let barRadius: CGFloat = 2
    /// Row label — `font-size:13px; color:#C9CFD8`.
    private static let labelSize: CGFloat = 13
    /// The signed r — Space Grotesk 13/600, right-aligned in a 44pt column.
    private static let valueWidth: CGFloat = 44
    /// See `valueWidth`.
    private static let valueSize: CGFloat = 13
    /// A negative correlation is drawn in `accent/live-hr` at or above this magnitude and in
    /// `accent/caution` below it — the only rule consistent with the board's `−.54` red and
    /// `−.32` caution.
    private static let strongNegative: Double = 0.5

    let row: LedgerMetricDetailView.MovesWithRow
    let showsDivider: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Self.columnGap) {
                Text(row.title)
                    .font(LedgerType.label(Self.labelSize, LedgerType.regular))
                    .foregroundStyle(Ledger.textCoach)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: Self.barRadius, style: .continuous)
                        .fill(Ledger.track)
                    RoundedRectangle(cornerRadius: Self.barRadius, style: .continuous)
                        .fill(tint)
                        .frame(width: Self.barWidth * CGFloat(min(abs(row.r), 1)))
                }
                .frame(width: Self.barWidth, height: Self.barHeight)

                Text(signedR)
                    .font(LedgerType.numeral(Self.valueSize, LedgerType.semibold))
                    .foregroundStyle(tint)
                    .frame(width: Self.valueWidth, alignment: .trailing)
            }
            .padding(.vertical, Self.verticalPadding)
            .frame(minHeight: Ledger.rowMinHeight)

            if showsDivider {
                Rectangle()
                    .fill(Ledger.hairlineSoft)
                    .frame(height: Ledger.hairlineWidth)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(row.title), correlation \(signedR), \(row.n) days"))
    }

    private var tint: Color {
        if row.r >= 0 { return Ledger.accentRecovery }
        return abs(row.r) >= Self.strongNegative ? Ledger.accentLiveHR : Ledger.accentCaution
    }

    /// `+.61` / `−.54` — the board drops the leading zero.
    private var signedR: String {
        let magnitude = String(format: "%.2f", abs(row.r))
        let trimmed = magnitude.hasPrefix("0") ? String(magnitude.dropFirst()) : magnitude
        return (row.r >= 0 ? "+" : "\u{2212}") + trimmed
    }
}

// MARK: - Readings table

/// The existing readings table, one tap below the detail: date · value · source, newest first.
///
/// Rows arrive already projected by `vitalReadingRows` — the SAME projection the classic detail's
/// table uses, so the two can never disagree about a value or a source label. This view only
/// restyles them onto the Ledger's hairline-separated canvas.
struct LedgerMetricReadingsView: View {

    /// Row vertical padding — the ledger row rhythm.
    private static let rowVerticalPadding: CGFloat = 11
    /// Column gap.
    private static let columnGap: CGFloat = 12

    let title: String
    let rows: [VitalReadingRow]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LedgerHeader(overline: String(localized: "Readings"), title: title, alignment: .bottom)

                if rows.isEmpty {
                    Text("No readings in this window.")
                        .ledgerBody()
                        .padding(.top, Ledger.sectionGap)
                } else {
                    columnHeader
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        readingRow(row, showsDivider: index < rows.count - 1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Ledger.pageMargin)
            .padding(.bottom, Ledger.pageMargin)
        }
        .background(Ledger.bgScreen.ignoresSafeArea())
        .navigationTitle(title)
    }

    private var columnHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: Self.columnGap) {
                Text("Date").frame(maxWidth: .infinity, alignment: .leading)
                Text("Value")
                Text("Source").frame(maxWidth: .infinity, alignment: .trailing)
            }
            .ledgerOverline()
            .padding(.top, Ledger.sectionGapWide)
            .padding(.bottom, 8)
            Rectangle().fill(Ledger.hairline).frame(height: Ledger.hairlineWidth)
        }
    }

    private func readingRow(_ row: VitalReadingRow, showsDivider: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Self.columnGap) {
                Text(row.time)
                    .font(LedgerType.label(13, LedgerType.regular))
                    .foregroundStyle(Ledger.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(row.value)
                    .ledgerRowValue(16)
                    .foregroundStyle(Ledger.textPrimary)
                Text(row.source)
                    .font(LedgerType.label(11, LedgerType.regular))
                    .foregroundStyle(Ledger.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.vertical, Self.rowVerticalPadding)
            .frame(minHeight: Ledger.rowMinHeight)

            if showsDivider {
                Rectangle().fill(Ledger.hairlineSoft).frame(height: Ledger.hairlineWidth)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(row.time), \(row.value), \(row.source)"))
    }
}
