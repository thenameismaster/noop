import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Aurora Trends
//
// The longitudinal screen, rebuilt on the Aurora design system. This is an ADDITIVE fork of
// `TrendsView` — the original file is untouched and keeps working. Every data source, window
// rule, scoring path and navigation route below is copied from that screen VERBATIM; only the
// presentation changes.
//
// What is deliberately identical to `TrendsView`:
//   • `@EnvironmentObject var repo: Repository` is the only data source, and `LiveState` is
//     deliberately NOT observed (observing it forced a full re-render of this subtree on every
//     ~1 Hz live-HR tick).
//   • The six-range widening window (`AuroraTrendsRange` mirrors `TrendsView.Range`, which is
//     private-by-nesting and therefore cannot be imported).
//   • Rest is the `sleep_performance` COMPOSITE loaded via `repo.exploreSeries` (#732), not
//     `DailyMetric.efficiency`.
//   • Windows cut against TODAY's local day key, not the latest recorded day (issue #23).
//   • `resolve(_:)` runs EXACTLY ONCE per metric per body evaluation; results are passed down
//     as parameters and never recomputed inside a subview.
//   • The Effort scale (#268) and the line-vs-bar trend style are display-only reads of the
//     same two `@AppStorage` keys.
//   • The week digest comes from `WeeklyDigestSource.digest(from:anchorDay:)` and the stepper
//     clamps to `[minWeekOffset, 0]` (#710).
//   • Tap-through routes stay `TabRoute.metric(_:)`, and macOS still wraps its own
//     `NavigationStack` + `tabRouteDestinations()` because the `.trends` detail pane has none.

// MARK: - Range

/// The shared range control: W(7) / M(30) / 3M(90) / 6M(180) / 1Y(365) / ALL.
///
/// A verbatim copy of `TrendsView.Range`. That enum is nested inside `TrendsView` and so is not
/// reachable from another file; duplicating it is the only way to keep the two screens'
/// windowing byte-identical without editing the original.
enum AuroraTrendsRange: Int, CaseIterable, Identifiable, Sendable {
    case week = 7, month = 30, quarter = 90, half = 180, year = 365, all = 0

    var id: Int { rawValue }

    /// The segmented control's label.
    var label: String {
        switch self {
        case .week:    return String(localized: "W")
        case .month:   return String(localized: "M")
        case .quarter: return String(localized: "3M")
        case .half:    return String(localized: "6M")
        case .year:    return String(localized: "1Y")
        case .all:     return String(localized: "ALL")
        }
    }

    /// The spelled-out name used in captions ("widened to 3 months").
    var longName: String {
        switch self {
        case .week:    return String(localized: "week")
        case .month:   return String(localized: "month")
        case .quarter: return String(localized: "3 months")
        case .half:    return String(localized: "6 months")
        case .year:    return String(localized: "year")
        case .all:     return String(localized: "all history")
        }
    }

    /// The VoiceOver name for one segment of the selector.
    var accessibilityName: String {
        switch self {
        case .all: return String(localized: "All history")
        default:   return longName
        }
    }

    /// Trailing-day window, or nil for "all history".
    var days: Int? { self == .all ? nil : rawValue }

    /// This range plus every LARGER range, ascending — the auto-expand search order when the
    /// selected window holds zero points.
    var widening: [AuroraTrendsRange] {
        let order: [AuroraTrendsRange] = [.week, .month, .quarter, .half, .year, .all]
        guard let i = order.firstIndex(of: self) else { return [.all] }
        return Array(order[i...])
    }
}

// MARK: - Screen

/// The Aurora Trends screen: a week-in-review digest with week stepping, a range selector, a
/// hero Charge chart with a scrub read-out, three metric trend cards, the training-load model,
/// a year heat-strip and the PDF export row.
@MainActor
struct AuroraTrendsView: View {

    // MARK: Data sources (identical to TrendsView)

    @EnvironmentObject var repo: Repository
    // NOTE: deliberately does NOT observe LiveState — Trends shows historical data only.

    /// Current appearance, passed into the off-screen recap render so the shared PNG matches.
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Effort display scale (#268). Display-only: Effort is always stored and plotted 0–100.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    /// Line-vs-bar trend style. Display-only; the plotted data is identical on both settings.
    @AppStorage(UnitPrefs.trendChartStyleKey) private var trendChartStyleRaw = TrendChartStyle.line.rawValue

    @State private var range: AuroraTrendsRange = .quarter
    /// Rest's per-day series, keyed by "yyyy-MM-dd" — the sleep_performance COMPOSITE (#732).
    @State private var sleepPerfByDay: [String: Double] = [:]
    /// #710 — 0 = the week containing today; each -1 steps one Mon–Sun week earlier.
    @State private var weekOffset = 0
    /// #436 — presents the shareable offline trends report.
    @State private var showingReport = false

    init() {}

    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }
    /// Honour the line-vs-bar preference: the hero swaps its mark geometry, never its data.
    private var showsBars: Bool { TrendChartStyle(rawValue: trendChartStyleRaw) == .bar }

    // MARK: Day parsing

    // yyyy-MM-dd → Date (en_US_POSIX, UTC) — the same keying TrainingLoadCard uses, so the axes match.
    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private func date(_ day: String) -> Date? { Self.dayParser.date(from: day) }

    // MARK: Window selection (relative to TODAY, with auto-expand)

    /// Days for a given range, taken RELATIVE TO TODAY (the phone's local date) — not the latest
    /// recorded day, which on a stale import anchored W/M/3M to months-old data (issue #23).
    /// ISO yyyy-MM-dd compares chronologically.
    private func days(for r: AuroraTrendsRange) -> [DailyMetric] {
        guard let n = r.days else { return repo.days }
        let base = Calendar.current.date(byAdding: .day, value: -(n - 1), to: Date()) ?? Date()
        let cutoffKey = Repository.localDayKey(base)
        return repo.days.filter { $0.day >= cutoffKey }
    }

    /// Build chart points from a metric accessor over a day slice. A nil reading is dropped —
    /// there is no gap mark, exactly as in the original.
    private func points(_ slice: [DailyMetric], _ value: (DailyMetric) -> Double?) -> [AuroraPoint] {
        slice.compactMap { d in
            guard let v = value(d), let dt = date(d.day) else { return nil }
            return AuroraPoint(date: dt, value: v)
        }
    }

    /// One metric's resolved window: its points, the range that actually held them, and the caption.
    private struct Resolved {
        var points: [AuroraPoint]
        var effective: AuroraTrendsRange
        var widened: Bool
        var caption: String
    }

    /// Walk the widening order ONCE and keep the first window that holds at least one point.
    ///
    /// PERF CONTRACT: called exactly once per metric per body evaluation; the result is passed
    /// down as a parameter. Never call this from inside a subview.
    private func resolve(_ value: (DailyMetric) -> Double?) -> Resolved {
        for r in range.widening {
            let pts = points(days(for: r), value)
            if !pts.isEmpty {
                return Resolved(points: pts, effective: r, widened: r != range,
                                caption: caption(count: pts.count, eff: r))
            }
        }
        let pts = points(days(for: .all), value)
        return Resolved(points: pts, effective: .all, widened: .all != range,
                        caption: caption(count: pts.count, eff: .all))
    }

    /// "90 readings · 3 months", or "12 readings · sparse, widened to year".
    private func caption(count n: Int, eff: AuroraTrendsRange) -> String {
        if eff != range {
            return n == 1
                ? String(localized: "1 reading · sparse, widened to \(eff.longName)")
                : String(localized: "\(n) readings · sparse, widened to \(eff.longName)")
        }
        return n == 1
            ? String(localized: "1 reading · \(range.longName)")
            : String(localized: "\(n) readings · \(range.longName)")
    }

    // MARK: Series statistics

    private func mean(_ pts: [AuroraPoint]) -> Double? {
        guard !pts.isEmpty else { return nil }
        return pts.map(\.value).reduce(0, +) / Double(pts.count)
    }

    /// The window's trend as mean(recent half) − mean(earlier half). nil for a window too short
    /// to split. Identical to the original's `periodChange`.
    private func periodChange(_ pts: [AuroraPoint]) -> Double? {
        guard pts.count >= 4 else { return nil }
        let mid = pts.count / 2
        let earlier = pts.prefix(mid).map(\.value)
        let recent = pts.suffix(pts.count - mid).map(\.value)
        guard !earlier.isEmpty, !recent.isEmpty else { return nil }
        let e = earlier.reduce(0, +) / Double(earlier.count)
        let r = recent.reduce(0, +) / Double(recent.count)
        return r - e
    }

    /// A padded value range so a flat series isn't pinned to the axis.
    private func valueRange(_ pts: [AuroraPoint],
                            fallback: ClosedRange<Double>,
                            pad: Double = 0.12) -> ClosedRange<Double> {
        let vals = pts.map(\.value)
        guard let lo = vals.min(), let hi = vals.max() else { return fallback }
        if hi <= lo { return (lo - 1)...(hi + 1) }
        let span = hi - lo
        return (lo - span * pad)...(hi + span * pad)
    }

    /// "Trailing 90 days" / "All history".
    private var rangeSubtitle: String {
        guard let n = range.days else { return String(localized: "All history") }
        return String(localized: "Trailing \(n) days")
    }

    // MARK: Body

    var body: some View {
        // The metric cards tap through to their MetricDetailView. On iOS each tab already supplies
        // a NavigationStack; on macOS the .trends detail pane has NONE (RootView), so — exactly as
        // TrendsView does — wrap the scaffold in one here. Registering the value routes twice in one
        // stack double-pushes (#38), so this registration lives at THIS stack's root only.
        #if os(macOS)
        NavigationStack { scaffold.tabRouteDestinations() }
        #else
        scaffold
        #endif
    }

    private var scaffold: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Aurora.Space.sectionGap) {
                pageHeader
                sections
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .auroraGutter()
            .padding(.top, Aurora.Space.m)
            .padding(.bottom, Aurora.Space.tabBarClearance)
        }
        .auroraCanvas()
        .refreshable { await repo.refresh() }
        // #436 — the offline trends-report exporter (range picker + PDF export).
        .sheet(isPresented: $showingReport) {
            TrendsReportSheet(days: repo.days)
        }
        // #732 — load the resolved sleep_performance series so Rest reads the SAME composite the
        // Today Rest score uses. Keyed on the day count so a newly-scored night refreshes Rest.
        .task(id: repo.days.count) {
            let s = await repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
            sleepPerfByDay = Dictionary(s.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.xxs) {
            Text("Trends").auroraTitleLarge()
            Text("The thread of you over time.").auroraBody()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var sections: some View {
        if repo.days.isEmpty {
            AuroraEmptyState(
                icon: "chart.xyaxis.line",
                headline: repo.loaded
                    ? String(localized: "No history yet")
                    : String(localized: "Loading your history…"),
                message: repo.loaded
                    ? String(localized: "Import your WHOOP export in Data Sources and weeks, months and years draw here instantly.")
                    : nil,
                tint: Aurora.accent
            )
            .padding(.top, Aurora.Space.xxl)
            .frame(maxWidth: .infinity)
        } else {
            // Resolve each metric's window ONCE per body and pass the results down.
            let recovery = resolve { $0.recovery }
            let hrv = resolve { $0.avgHrv }
            let rhr = resolve { $0.restingHr.map(Double.init) }
            let strain = resolve { $0.strain }
            let rest = resolve { sleepPerfByDay[$0.day] }

            weekSection(charge: recovery, effort: strain, rest: rest)
                .auroraSectionAppear(0)
            rangeSection(recovery: recovery)
                .auroraSectionAppear(1)
            heroSection(recovery: recovery)
                .auroraSectionAppear(2)
            signalsSection(hrv: hrv, rhr: rhr, strain: strain)
                .auroraSectionAppear(3)
            loadSection
                .auroraSectionAppear(4)
            yearSection
                .auroraSectionAppear(5)
            exportSection
                .auroraSectionAppear(6)
        }
    }

    // MARK: - Week in review (#710)

    /// The earliest "yyyy-MM-dd" we hold (history is oldest → newest).
    private var earliestDay: String? { repo.days.first?.day }

    /// The most negative `weekOffset` allowed: the whole weeks between the earliest day's week and
    /// this week. 0 when history is empty or unparseable.
    private var minWeekOffset: Int {
        guard
            let earliest = earliestDay,
            let earliestMon = WeeklyDigestEngine.mondayOfWeek(containing: earliest),
            let thisMon = WeeklyDigestEngine.mondayOfWeek(containing: Repository.localDayKey(Date()))
        else { return 0 }
        var off = 0
        var mon = thisMon
        while mon > earliestMon && off > -520 {   // hard cap ~10 years so a bad date can't spin
            mon = WeeklyDigestEngine.addDays(mon, -7)
            off -= 1
        }
        return off
    }

    /// Any day inside the target week; the engine snaps it to that week's Monday.
    private var weekAnchorDay: String {
        WeeklyDigestEngine.addDays(Repository.localDayKey(Date()), weekOffset * 7)
    }

    /// Move the digest one week earlier (-1) or later (+1), clamped to [minWeekOffset, 0].
    private func stepWeek(_ delta: Int) {
        let next = weekOffset + delta
        let clamped = max(minWeekOffset, min(0, next))
        guard clamped != weekOffset else { return }
        withAnimation(Aurora.Motion.respecting(Aurora.Motion.standard, reduced: reduceMotion)) {
            weekOffset = clamped
        }
    }

    /// "Last week" for -1, else "3 weeks ago".
    private var weekOffsetLabel: String {
        let n = -weekOffset
        if n == 1 { return String(localized: "Last week") }
        return String(localized: "\(n) weeks ago")
    }

    @ViewBuilder
    private func weekSection(charge: Resolved, effort: Resolved, rest: Resolved) -> some View {
        let digest = WeeklyDigestSource.digest(from: repo.days, anchorDay: weekAnchorDay)
        VStack(alignment: .leading, spacing: Aurora.Space.cardGap) {
            AuroraSectionHeader(String(localized: "Week in review"),
                                subtitle: String(localized: "Charge · Effort · Rest"))
            AuroraCard(elevation: .raised, padding: Aurora.Space.cardPadding, radius: Aurora.Radius.card) {
                VStack(alignment: .leading, spacing: Aurora.Space.m) {
                    weekNavBar(digest: digest)
                    AuroraDivider()
                    weekBody(digest: digest)
                }
            }
            windowAverages(charge: charge, effort: effort, rest: rest)
        }
    }

    /// Prev/next week stepper. Back clamps at the earliest week we hold; forward clamps at this week.
    private func weekNavBar(digest: WeeklyDigest) -> some View {
        let atOldest = weekOffset <= minWeekOffset
        let atNewest = weekOffset >= 0
        let daysSummary = String(localized: "\(digest.daysWithData)/7 days")
        let daysAccessibility = String(localized: "\(digest.daysWithData) of 7 days had data")
        let rangeLabel = weeklyDigestRangeLabel(digest)
        return HStack(spacing: Aurora.Space.s) {
            weekChevron(systemName: "chevron.left",
                        label: String(localized: "Previous week"),
                        disabled: atOldest) { stepWeek(-1) }
            VStack(spacing: 2) {
                Text(weekOffset == 0 ? String(localized: "This week") : weekOffsetLabel)
                    .auroraHeadline()
                Text("\(rangeLabel) · \(daysSummary)")
                    .auroraCaption()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .accessibilityLabel(Text("\(rangeLabel), \(daysAccessibility)"))
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            weekChevron(systemName: "chevron.right",
                        label: String(localized: "Next week"),
                        disabled: atNewest) { stepWeek(1) }
        }
        .accessibilityElement(children: .contain)
    }

    private func weekChevron(systemName: String, label: String,
                             disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(disabled ? Aurora.textDisabled : Aurora.accent)
                .frame(width: Aurora.Layout.glyphPlate, height: Aurora.Layout.glyphPlate)
                .background(
                    Circle().fill(disabled ? Aurora.surfaceInset : Aurora.accentMuted)
                )
                .contentShape(Circle())
                .frame(width: Aurora.Layout.minTapTarget, height: Aurora.Layout.minTapTarget)
        }
        .buttonStyle(.auroraPress)
        .disabled(disabled)
        .accessibilityLabel(Text(label))
    }

    @ViewBuilder
    private func weekBody(digest: WeeklyDigest) -> some View {
        if digest.isEmpty {
            AuroraEmptyState(
                icon: "calendar.badge.exclamationmark",
                headline: String(localized: "No readings this week"),
                message: String(localized: "Step to another week with the arrows above to see its review."),
                tint: Aurora.statusNeutral
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, Aurora.Space.xs)
        } else {
            VStack(alignment: .leading, spacing: Aurora.Space.m) {
                weekChargeBars(digest: digest)
                AuroraDivider()
                weekMetricRows(digest: digest)
                weekBalance(digest: digest)
                weekFocalPoints(digest)
                shareRecapButton(digest: digest)
            }
        }
    }

    // MARK: Weekly comparison bars

    /// The selected week's seven Charge readings as one bar per day, ramp-coloured so magnitude
    /// reads twice (height and hue). A day with no reading stays a ghost bar rather than a zero.
    private func weekChargeBars(digest: WeeklyDigest) -> some View {
        let keys = (0..<7).map { WeeklyDigestEngine.addDays(digest.weekStart, $0) }
        let labels = [String(localized: "M"), String(localized: "T"), String(localized: "W"),
                      String(localized: "T"), String(localized: "F"), String(localized: "S"),
                      String(localized: "S")]
        var byDay: [String: Double] = [:]
        for d in repo.days where d.day >= digest.weekStart && d.day <= digest.weekEnd {
            if let v = d.recovery { byDay[d.day] = v }
        }
        let bars: [AuroraBar] = keys.enumerated().map { i, key in
            let v = byDay[key]
            return AuroraBar(label: labels[i], value: v, colorFraction: v.map { $0 / 100 })
        }
        let todayKey = Repository.localDayKey(Date())
        let highlight = keys.firstIndex(of: todayKey)
        return VStack(alignment: .leading, spacing: Aurora.Space.xs) {
            Text("Charge by day").auroraSectionHeader()
            AuroraBarSeries(
                bars: bars,
                ramp: Aurora.recoveryRamp,
                maxValue: 100,
                height: 132,
                highlightIndex: highlight,
                showsLabels: true,
                showsValues: true,
                decimals: 0,
                emptyHeadline: String(localized: "No Charge readings this week")
            )
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Week-over-week metric rows

    private static let weeklyOrder: [WeeklyMetric] = [.charge, .effort, .rest, .hrv, .rhr]

    private func weekMetricRows(digest: WeeklyDigest) -> some View {
        // Filter first, then index: a divider keyed on the CATALOGUE position would draw a rule
        // above the first row whenever an earlier metric had no readings this week.
        let rows = Self.weeklyOrder.compactMap { digest.summary($0) }.filter { $0.thisWeek.n > 0 }
        return VStack(alignment: .leading, spacing: Aurora.Space.xs) {
            Text("This week vs last").auroraSectionHeader()
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, s in
                    if idx > 0 { AuroraDivider() }
                    weekMetricRow(s)
                }
            }
        }
    }

    private func weekMetricRow(_ s: WeeklyMetricSummary) -> some View {
        HStack(alignment: .center, spacing: Aurora.Space.s) {
            Text(s.metric.label).auroraBodyStrong()
            Spacer(minLength: Aurora.Space.xs)
            AuroraValueUnit(value: weeklyValueText(s),
                            unit: s.metric.unit.isEmpty ? nil : s.metric.unit,
                            role: .metricSmall,
                            valueColor: weeklyTint(s.metric))
            weekMetricDelta(s)
        }
        .padding(.vertical, Aurora.Space.xs)
        .accessibilityElement(children: .combine)
    }

    /// This week's mean on the user's chosen display scale. Effort is stored 0–100 and converts
    /// here for display only (#268); every other metric prints its stored value.
    private func weeklyValueText(_ s: WeeklyMetricSummary) -> String {
        let m = s.thisWeek.mean
        if s.metric == .effort { return UnitFormatter.effortDisplay(m, scale: effortScale) }
        return "\(Int(m.rounded()))"
    }

    private func weeklyTint(_ metric: WeeklyMetric) -> Color {
        switch metric {
        case .charge: return Aurora.recoveryRamp.end
        case .effort: return Aurora.strainRamp.end
        case .rest:   return Aurora.sleepRamp.end
        case .hrv:    return Aurora.accent
        case .rhr:    return Aurora.stressRamp.end
        }
    }

    /// The week-over-week move. A ROUGH comparison (either side under
    /// `WeeklyDigestEngine.minDaysForFocus` days) shows its raw number in a neutral pill instead of
    /// a good/bad chip — a 43% "drop" off two days is not a verdict (#463).
    @ViewBuilder
    private func weekMetricDelta(_ s: WeeklyMetricSummary) -> some View {
        if s.weekOverWeek.previous.n > 0, abs(s.wowDelta) > 0.0001 {
            let raw = s.metric == .effort
                ? UnitFormatter.effortValue(s.wowDelta, scale: effortScale)
                : s.wowDelta
            let decimals = s.metric == .effort && effortScale == .whoop ? 1 : 0
            if s.isRoughComparison {
                AuroraStatusPill(signedText(raw, decimals: decimals), tone: .neutral, style: .outline)
            } else {
                AuroraDeltaChip(value: raw, decimals: decimals,
                                higherIsBetter: s.metric.higherIsBetter)
            }
        } else {
            AuroraStatusPill(String(localized: "New"), tone: .neutral, style: .outline)
        }
    }

    /// "+4" / "−1.2", using the typographic minus the rest of the app prints.
    private func signedText(_ v: Double, decimals: Int) -> String {
        let sign = v >= 0 ? "+" : "−"
        let magnitude = abs(v)
        let body = decimals > 0 ? String(format: "%.\(decimals)f", magnitude) : "\(Int(magnitude.rounded()))"
        return "\(sign)\(body)"
    }

    /// The week's Effort-vs-Charge balance read, as a toned pill plus its sentence.
    private func weekBalance(digest: WeeklyDigest) -> some View {
        let tone: AuroraTone
        let title: String
        switch digest.balance {
        case .overreaching: tone = .alert;   title = String(localized: "Overreaching")
        case .balanced:     tone = .good;    title = String(localized: "Balanced")
        case .underloaded:  tone = .caution; title = String(localized: "Underloaded")
        case .insufficient: tone = .neutral; title = String(localized: "Not enough data")
        }
        return VStack(alignment: .leading, spacing: Aurora.Space.xs) {
            AuroraStatusPill(title, tone: tone, icon: "scalemass", style: .tinted)
            Text(digest.balance.sentence)
                .auroraCaption()
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func weekFocalPoints(_ digest: WeeklyDigest) -> some View {
        if !digest.focalPoints.isEmpty {
            VStack(alignment: .leading, spacing: Aurora.Space.xs) {
                Text("Focal points").auroraSectionHeader()
                ForEach(Array(digest.focalPoints.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: Aurora.Space.xs) {
                        Circle()
                            .fill(Aurora.accent)
                            .frame(width: 5, height: 5)
                            .padding(.top, 6)
                            .accessibilityHidden(true)
                        Text(line)
                            .auroraBody()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Share this week's recap as an image. Reuses the SAME renderer and the SAME digest card the
    /// original screen exports, so the shared PNG is unchanged.
    private func shareRecapButton(digest: WeeklyDigest) -> some View {
        Button {
            let page = WeeklyDigestContent(digest: digest, compact: true, showsHeader: true)
                .frame(width: 380)
                .padding(24)
                .background(StrandPalette.surfaceBase)
                .environment(\.colorScheme, colorScheme)
            TrendsReportRenderer.exportPNG(page: page, suggestedName: "noop-recap-\(weekAnchorDay).png")
        } label: {
            HStack(spacing: Aurora.Space.xs) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                Text("Share recap").font(AuroraType.bodyStrong)
            }
            .foregroundStyle(Aurora.accent)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: Aurora.Radius.s, style: .continuous)
                    .fill(Aurora.accentMuted)
            )
            .contentShape(RoundedRectangle(cornerRadius: Aurora.Radius.s, style: .continuous))
        }
        .buttonStyle(.auroraPress)
        .accessibilityLabel(Text("Share recap"))
    }

    // MARK: Window averages (the Charge / Effort / Rest trio)

    /// The three headline scores over the RESOLVED window, as ramp-coloured range bars. Each row
    /// self-hides when its window mean is nil; the card hides when all three are.
    @ViewBuilder
    private func windowAverages(charge: Resolved, effort: Resolved, rest: Resolved) -> some View {
        let chargeAvg = mean(charge.points)
        let effortAvg = mean(effort.points)   // stored 0–100 internal Effort scale
        let restAvg = mean(rest.points)
        if chargeAvg != nil || effortAvg != nil || restAvg != nil {
            AuroraCard {
                VStack(alignment: .leading, spacing: Aurora.Space.m) {
                    Text("Window averages").auroraSectionHeader()
                    if let v = chargeAvg {
                        averageRow(label: String(localized: "Charge"),
                                   text: "\(Int(v.rounded()))", unit: nil,
                                   fraction: v / 100, ramp: Aurora.recoveryRamp)
                    }
                    if let v = effortAvg {
                        // Effort is stored 0–100 but reads on the user's chosen axis. The bar fills
                        // off the STORED value so the three rows agree regardless of the unit shown.
                        averageRow(label: String(localized: "Effort"),
                                   text: UnitFormatter.effortDisplay(v, scale: effortScale),
                                   unit: "/ \(UnitFormatter.effortScaleMax(effortScale))",
                                   fraction: v / 100, ramp: Aurora.strainRamp)
                    }
                    if let v = restAvg {
                        averageRow(label: String(localized: "Rest"),
                                   text: "\(Int(v.rounded()))", unit: nil,
                                   fraction: v / 100, ramp: Aurora.sleepRamp)
                    }
                }
            }
        }
    }

    private func averageRow(label: String, text: String, unit: String?,
                            fraction: Double, ramp: AuroraRamp) -> some View {
        let clamped = min(max(fraction, 0), 1)
        return VStack(alignment: .leading, spacing: Aurora.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Aurora.Space.xs) {
                Text(label).auroraLabel()
                Spacer(minLength: Aurora.Space.xs)
                AuroraValueUnit(value: text, unit: unit, role: .metricMedium,
                                valueColor: ramp.color(at: clamped))
            }
            AuroraMeter(fraction: clamped, ramp: ramp)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(text))
    }

    // MARK: - Range selector

    private func rangeSection(recovery: Resolved) -> some View {
        VStack(alignment: .leading, spacing: Aurora.Space.xs) {
            AuroraRangeSelector(selection: $range)
            HStack(alignment: .firstTextBaseline, spacing: Aurora.Space.xs) {
                Text(recovery.caption)
                    .font(AuroraType.caption)
                    .foregroundStyle(recovery.widened ? Aurora.statusCaution : Aurora.textTertiary)
                Spacer(minLength: Aurora.Space.xs)
                Text(rangeSubtitle).auroraSectionHeader()
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Hero — Charge over time

    @ViewBuilder
    private func heroSection(recovery: Resolved) -> some View {
        let pts = recovery.points
        let avg = mean(pts)
        NavigationLink(value: TabRoute.metric("recovery")) {
            AuroraCard(elevation: .raised,
                       padding: Aurora.Space.heroPadding,
                       radius: Aurora.Radius.hero,
                       tint: Aurora.recoveryRamp.end) {
                VStack(alignment: .leading, spacing: Aurora.Space.m) {
                    heroPlot(pts)
                    AuroraDivider()
                    heroFooter(pts: pts, avg: avg)
                }
            }
        }
        .buttonStyle(.auroraPress)
        .accessibilityHint(Text(String(localized: "Opens the full Charge metric.")))
    }

    /// The hero plot. Honours the line-vs-bar preference: identical data, different geometry.
    @ViewBuilder
    private func heroPlot(_ pts: [AuroraPoint]) -> some View {
        if showsBars {
            VStack(alignment: .leading, spacing: Aurora.Space.xs) {
                Text("Charge").auroraSectionHeader()
                AuroraBarSeries(
                    bars: heroBars(pts),
                    ramp: Aurora.recoveryRamp,
                    maxValue: 100,
                    height: Aurora.Layout.chartHeight,
                    showsLabels: pts.count <= 14,
                    emptyHeadline: String(localized: "Not enough data for this window.")
                )
            }
        } else {
            AuroraTrendChart(
                points: pts,
                title: String(localized: "Charge"),
                ramp: Aurora.recoveryRamp,
                // Lift the ceiling ~6% so a near-100 peak clears the top gridline.
                height: Aurora.Layout.chartHeight,
                yDomain: 0...106,
                emptyHeadline: String(localized: "Not enough data for this window."),
                emptyMessage: String(localized: "Two days of readings and this chart fills in.")
            )
        }
    }

    private func heroBars(_ pts: [AuroraPoint]) -> [AuroraBar] {
        pts.map { p in
            AuroraBar(label: Self.barLabel(p.date), value: p.value, colorFraction: p.value / 100)
        }
    }

    private static let barLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d")
        return f
    }()
    private static func barLabel(_ d: Date) -> String { barLabelFormatter.string(from: d) }

    private func heroFooter(pts: [AuroraPoint], avg: Double?) -> some View {
        let intFmt: (Double) -> String = { "\(Int($0.rounded()))" }
        return HStack(alignment: .top, spacing: Aurora.Space.s) {
            statColumns([
                (String(localized: "Avg"), avg.map(intFmt) ?? "—"),
                (String(localized: "Peak"), pts.map(\.value).max().map(intFmt) ?? "—"),
                (String(localized: "Low"), pts.map(\.value).min().map(intFmt) ?? "—"),
                (String(localized: "Days"), "\(pts.count)"),
            ])
            trendColumn(pts, higherIsBetter: true, decimals: 0, convert: { $0 })
        }
    }

    // MARK: - Daily signals

    private func signalsSection(hrv: Resolved, rhr: Resolved, strain: Resolved) -> some View {
        VStack(alignment: .leading, spacing: Aurora.Space.cardGap) {
            AuroraSectionHeader(String(localized: "Daily signals"),
                                subtitle: String(localized: "HRV · Resting HR · Effort"))
            signalCard(
                title: String(localized: "Heart rate variability"),
                accessibilityTitle: String(localized: "Heart rate variability"),
                metricKey: "hrv",
                icon: "waveform.path.ecg",
                accent: Aurora.accent,
                unit: "ms",
                resolved: hrv,
                fallback: 20...120,
                higherIsBetter: true,
                decimals: 0,
                convert: { $0 },
                format: { "\(Int($0.rounded()))" }
            )
            signalCard(
                title: String(localized: "Resting heart rate"),
                accessibilityTitle: String(localized: "Resting heart rate"),
                metricKey: "rhr",
                icon: "heart.fill",
                accent: Aurora.stressRamp.end,
                unit: "bpm",
                resolved: rhr,
                fallback: 40...80,
                higherIsBetter: false,
                decimals: 0,
                convert: { $0 },
                format: { "\(Int($0.rounded()))" }
            )
            signalCard(
                // Plotted points and the y-range stay on the stored 0–100 scale; only the printed
                // numbers and the unit follow the Effort-scale toggle (#268).
                title: String(localized: "Effort"),
                accessibilityTitle: String(localized: "Effort"),
                metricKey: "strain",
                icon: "bolt.fill",
                accent: Aurora.strainRamp.end,
                unit: "/ \(UnitFormatter.effortScaleMax(effortScale))",
                resolved: strain,
                fallback: 0...100,
                higherIsBetter: nil,
                decimals: effortScale == .whoop ? 1 : 0,
                convert: { UnitFormatter.effortValue($0, scale: self.effortScale) },
                format: { UnitFormatter.effortDisplay($0, scale: self.effortScale) }
            )
        }
    }

    /// One metric trend card: name, latest reading, a delta chip against the previous half of the
    /// window, a sparkline, and the window's mean / min / max. Taps through to the metric's detail.
    ///
    /// - Parameters:
    ///   - convert: stored value → displayed number, for the delta chip's magnitude.
    ///   - format: stored value → display string, for the read-outs.
    @ViewBuilder
    private func signalCard(
        title: String,
        accessibilityTitle: String,
        metricKey: String,
        icon: String,
        accent: Color,
        unit: String,
        resolved: Resolved,
        fallback: ClosedRange<Double>,
        higherIsBetter: Bool?,
        decimals: Int,
        convert: @escaping (Double) -> Double,
        format: @escaping (Double) -> String
    ) -> some View {
        let pts = resolved.points
        NavigationLink(value: TabRoute.metric(metricKey)) {
            AuroraCard(tint: accent) {
                VStack(alignment: .leading, spacing: Aurora.Space.s) {
                    signalHeader(title: title, icon: icon, accent: accent, caption: resolved.caption)
                    signalValue(pts: pts, unit: unit, accent: accent,
                                higherIsBetter: higherIsBetter, decimals: decimals,
                                convert: convert, format: format)
                    AuroraSparkline(values: pts.map(\.value), tint: accent,
                                    range: valueRange(pts, fallback: fallback))
                        .frame(height: Aurora.Layout.sparklineHeight)
                        .accessibilityHidden(true)
                    signalFooter(pts: pts, unit: unit, format: format)
                }
            }
        }
        .buttonStyle(.auroraPress)
        .accessibilityHint(Text(String(localized: "Opens the full \(accessibilityTitle) metric.")))
    }

    private func signalHeader(title: String, icon: String, accent: Color, caption: String) -> some View {
        HStack(alignment: .top, spacing: Aurora.Space.xs) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: Aurora.Layout.glyphPlate, height: Aurora.Layout.glyphPlate)
                .background(
                    RoundedRectangle(cornerRadius: Aurora.Radius.xs, style: .continuous)
                        .fill(accent.opacity(0.14))
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).auroraBodyStrong()
                Text(caption).auroraFootnote()
            }
            Spacer(minLength: Aurora.Space.xs)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Aurora.textTertiary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func signalValue(pts: [AuroraPoint], unit: String, accent: Color,
                             higherIsBetter: Bool?, decimals: Int,
                             convert: @escaping (Double) -> Double,
                             format: @escaping (Double) -> String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Aurora.Space.xs) {
            if let latest = pts.last?.value {
                AuroraValueUnit(value: format(latest), unit: unit,
                                role: .metricLarge, valueColor: accent)
            } else {
                AuroraValueUnit(value: "–", unit: unit, role: .metricLarge,
                                valueColor: Aurora.textDisabled)
            }
            trendChip(pts, higherIsBetter: higherIsBetter, decimals: decimals, convert: convert)
            Spacer(minLength: 0)
        }
    }

    private func signalFooter(pts: [AuroraPoint], unit: String,
                              format: @escaping (Double) -> String) -> some View {
        statColumns([
            (String(localized: "Mean"), mean(pts).map { "\(format($0)) \(unit)" } ?? "—"),
            (String(localized: "Min"), pts.map(\.value).min().map(format) ?? "—"),
            (String(localized: "Max"), pts.map(\.value).max().map(format) ?? "—"),
        ])
    }

    // MARK: - Training load

    private var loadSection: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.cardGap) {
            AuroraSectionHeader(String(localized: "Training load"),
                                subtitle: String(localized: "Chronic vs acute · full history"))
            // Long-horizon by nature: this card models the FULL history, not the range window,
            // and self-hides its chart behind an honest "needs N more days" state.
            AuroraCard(insets: EdgeInsets(top: Aurora.Space.xs, leading: Aurora.Space.xs,
                                          bottom: Aurora.Space.xs, trailing: Aurora.Space.xs)) {
                TrainingLoadCard(days: repo.days)
            }
        }
    }

    // MARK: - Year heat-strip

    private var yearSection: some View {
        // Always show at least a full year for context; expand to all history on ALL.
        let stripDays = max(range.days ?? repo.days.count, 365)
        let recent = Array(repo.days.suffix(stripDays))
        let recoveryDays: [RecoveryDay] = recent.compactMap { d in
            guard let dt = date(d.day) else { return nil }
            return RecoveryDay(date: dt, score: d.recovery)
        }
        let withData = recoveryDays.filter { $0.score != nil }.count
        let title = (range == .all && repo.days.count > 365)
            ? String(localized: "Charge (all history)")
            : String(localized: "Charge (past year)")
        return VStack(alignment: .leading, spacing: Aurora.Space.cardGap) {
            AuroraSectionHeader(title, subtitle: String(localized: "\(withData) days recorded"))
            AuroraCard {
                VStack(alignment: .leading, spacing: Aurora.Space.m) {
                    if recoveryDays.isEmpty {
                        AuroraEmptyState(
                            icon: "square.grid.3x3",
                            headline: String(localized: "Nothing to map yet"),
                            message: String(localized: "Each recorded day paints one square here."),
                            tint: Aurora.recoveryRamp.end
                        )
                        .frame(maxWidth: .infinity)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            YearHeatStrip(days: recoveryDays)
                                .padding(.vertical, Aurora.Space.xxs)
                        }
                        AuroraDivider()
                        yearLegend
                    }
                }
            }
        }
    }

    private var yearLegend: some View {
        HStack(spacing: Aurora.Space.xs) {
            Text("Depleted").auroraFootnote().fixedSize()
            LinearGradient(gradient: Aurora.recoveryRamp.gradient,
                           startPoint: .leading, endPoint: .trailing)
                .frame(maxWidth: .infinity)
                .frame(height: Aurora.Layout.trackHeight)
                .clipShape(Capsule())
                .accessibilityHidden(true)
            Text("Peaked").auroraFootnote().fixedSize()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Charge scale, depleted to peaked"))
    }

    // MARK: - Export (#436)

    private var exportSection: some View {
        AuroraCard(tint: Aurora.accent) {
            HStack(alignment: .center, spacing: Aurora.Space.s) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Aurora.accent)
                    .frame(width: Aurora.Layout.glyphPlate + 8,
                           height: Aurora.Layout.glyphPlate + 8)
                    .background(
                        RoundedRectangle(cornerRadius: Aurora.Radius.s, style: .continuous)
                            .fill(Aurora.accentMuted)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Aurora.Space.xxs) {
                    Text("Export trends report").auroraBodyStrong()
                    Text("A shareable one-page PDF of recovery, sleep, HRV, resting HR and strain over a range, saved on your \(Platform.deviceNoun).")
                        .auroraFootnote()
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Aurora.Space.xs)
                Button { showingReport = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Export").font(AuroraType.captionStrong)
                    }
                    .foregroundStyle(Aurora.textOnAccent)
                    .padding(.horizontal, Aurora.Space.s)
                    .frame(height: 34)
                    .background(Capsule().fill(Aurora.accent))
                    .contentShape(Capsule())
                }
                .buttonStyle(.auroraPress)
                .fixedSize()
                .accessibilityLabel(Text("Export trends report"))
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Shared bits

    /// A row of small labelled statistics, matching the footer rhythm of every Aurora card.
    private func statColumns(_ items: [(String, String)]) -> some View {
        HStack(alignment: .top, spacing: Aurora.Space.l) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.0).auroraSectionHeader()
                    Text(item.1).auroraCaptionStrong()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
        }
    }

    /// The window's period change as a delta chip. Renders nothing when the window is too short to
    /// split or the move is flat — identical to the original's `changeChip`.
    @ViewBuilder
    private func trendChip(_ pts: [AuroraPoint], higherIsBetter: Bool?,
                           decimals: Int, convert: (Double) -> Double) -> some View {
        if let d = periodChange(pts), abs(d) > 0.0001 {
            let shown = convert(d)
            if let better = higherIsBetter {
                AuroraDeltaChip(value: shown, decimals: decimals, higherIsBetter: better)
            } else {
                // No valence (Effort): a neutral pill, never a green/red verdict.
                AuroraStatusPill(signedText(shown, decimals: decimals),
                                 tone: .neutral, style: .outline)
            }
        }
    }

    /// The labelled "TREND" column that sits beside a footer's statistics.
    @ViewBuilder
    private func trendColumn(_ pts: [AuroraPoint], higherIsBetter: Bool?,
                             decimals: Int, convert: (Double) -> Double) -> some View {
        if let d = periodChange(pts), abs(d) > 0.0001 {
            VStack(alignment: .leading, spacing: 3) {
                Text("Trend").auroraSectionHeader()
                trendChip(pts, higherIsBetter: higherIsBetter, decimals: decimals, convert: convert)
            }
        }
    }
}

// MARK: - Range selector control

/// The range segmented control: one pill track, a sliding selected thumb, equal-width cells so
/// six segments still fit an iPhone gutter.
@MainActor
private struct AuroraRangeSelector: View {
    @Binding var selection: AuroraTrendsRange
    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AuroraTrendsRange.allCases) { r in
                segment(r)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: Aurora.Radius.m, style: .continuous)
                .fill(Aurora.surfaceInset)
                .overlay(
                    RoundedRectangle(cornerRadius: Aurora.Radius.m, style: .continuous)
                        .strokeBorder(Aurora.hairline, lineWidth: Aurora.Stroke.hairline)
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Range"))
    }

    private func segment(_ r: AuroraTrendsRange) -> some View {
        let selected = r == selection
        return Button {
            guard !selected else { return }
            withAnimation(Aurora.Motion.respecting(Aurora.Motion.interactive, reduced: reduceMotion)) {
                selection = r
            }
        } label: {
            Text(r.label)
                .font(AuroraType.captionStrong)
                .tracking(0.4)
                .foregroundStyle(selected ? Aurora.textPrimary : Aurora.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(thumbBackground(selected))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(r.accessibilityName))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func thumbBackground(_ selected: Bool) -> some View {
        if selected {
            RoundedRectangle(cornerRadius: Aurora.Radius.s, style: .continuous)
                .fill(Aurora.surface3)
                .overlay(
                    RoundedRectangle(cornerRadius: Aurora.Radius.s, style: .continuous)
                        .strokeBorder(Aurora.hairlineStrong, lineWidth: Aurora.Stroke.hairline)
                )
                .matchedGeometryEffect(id: "auroraRangeThumb", in: thumb)
        }
    }
}

// MARK: - Meter

/// A recessed track with a ramp-filled bar — the compact companion to `AuroraRangeBar` for a row
/// that already prints its own number, so the bar only has to carry the proportion.
private struct AuroraMeter: View {
    let fraction: Double
    let ramp: AuroraRamp

    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Aurora.surfaceInset)
                Capsule()
                    .fill(LinearGradient(gradient: ramp.gradient,
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(geo.size.width * clamped * (grown ? 1 : 0),
                                      clamped > 0 && grown ? Aurora.Layout.trackHeight : 0))
            }
        }
        .frame(height: Aurora.Layout.trackHeight)
        .onAppear {
            guard !grown else { return }
            withAnimation(Aurora.Motion.respecting(Aurora.Motion.drawIn, reduced: reduceMotion)) {
                grown = true
            }
        }
    }
}

// MARK: - Section entrance

/// The staggered section reveal: a short rise and fade, ~45 ms apart, collapsing to an instant
/// appearance under Reduce Motion.
private struct AuroraSectionAppear: ViewModifier {
    let index: Int

    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .onAppear {
                guard !shown else { return }
                let base = Aurora.Motion.respecting(Aurora.Motion.standard, reduced: reduceMotion)
                let delay = reduceMotion ? 0 : Double(index) * 0.045
                withAnimation(base?.delay(delay)) { shown = true }
            }
    }
}

private extension View {
    /// Stagger this section's entrance by its position in the page.
    func auroraSectionAppear(_ index: Int) -> some View {
        modifier(AuroraSectionAppear(index: index))
    }
}

// MARK: - Preview

#if DEBUG
@MainActor
private func auroraTrendsPreviewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    let cal = Calendar(identifier: .gregorian)
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(identifier: "UTC")
    fmt.dateFormat = "yyyy-MM-dd"
    let today = Date()
    var seeded: [DailyMetric] = []
    let span = 365
    for i in stride(from: span - 1, through: 0, by: -1) {
        guard let d = cal.date(byAdding: .day, value: -i, to: today) else { continue }
        let phase = Double(span - 1 - i)
        let rec = 55 + 28 * sin(phase / 11.0) + Double((Int(phase) * 31) % 17) - 8
        let hrv = 58 + 16 * sin(phase / 9.0) + Double((Int(phase) * 13) % 11) - 5
        let rhr = 52 + 4 * sin(phase / 7.0) + Double((Int(phase) * 7) % 5) - 2
        let strain = 45 + 26 * sin(phase / 5.0 + 1.2) + Double((Int(phase) * 5) % 9) - 4
        let gap = Int(phase) % 23 == 0
        seeded.append(DailyMetric(
            day: fmt.string(from: d),
            totalSleepMin: 420, efficiency: 0.9, deepMin: 90, remMin: 110, lightMin: 200,
            disturbances: 6, restingHr: gap ? nil : Int(rhr.rounded()),
            avgHrv: gap ? nil : max(15, hrv), recovery: gap ? nil : max(2, min(99, rec)),
            strain: gap ? nil : max(0, min(100, strain)), exerciseCount: 1
        ))
    }
    repo.days = seeded
    repo.loaded = true
    return repo
}

#Preview("Aurora Trends") {
    AuroraTrendsView()
        .environmentObject(auroraTrendsPreviewRepo())
        .frame(width: 480, height: 900)
        .preferredColorScheme(.dark)
}
#endif
