import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopProtocol
import WhoopStore

// MARK: - Ledger Workout Detail — the session sheet, in the Ledger's own idiom
//
// The handoff has no workout-detail board (the Tap Map routes session rows to the EXISTING
// `WorkoutDetailView`), so this screen is composed from the kit per the handoff's rule for missing
// screens: data drawn straight on `bg/screen`, hairline-separated sections with overlines, a stat
// strip, the zone ribbon, and the one calm draw-in — no cards, no fills behind data.
//
// It deliberately does NOT replace the classic detail. The classic screen owns the session's
// workflows (edit, delete, splits, export) and keeps them; this screen is the Ledger-styled READ of
// the session, with "All details & edit ›" pushing the classic detail for everything else. That is
// the same absorb-don't-remove pattern the shell uses for the More list.
//
// Data: the `WorkoutRow` the Activity screen already holds, plus one `repo.hrSamples` read over the
// session's own window for the trace and the zone split — the same accessor the Activity screen's
// day-wide zones use. Nothing is computed that the app does not already compute.
struct LedgerWorkoutDetailView: View {

    let row: WorkoutRow

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.whoop.rawValue

    /// The session's own HR trace, loaded once in `.task`. Empty ⇒ the trace section renders its
    /// honest empty line (an imported session without raw HR is normal, not an error).
    @State private var samples: [HRSample] = []
    /// Per-zone minutes from `samples` through the user's OWN zone set; nil until loaded (or when
    /// the session carries no raw HR and no imported split).
    @State private var zoneMinutes: [Double]?
    @State private var loaded = false

    // MARK: Board constants (kit values — this screen has no board of its own)

    private static let heroTopGap: CGFloat = 18
    private static let sectionGap: CGFloat = 16
    private static let traceHeight: CGFloat = 120
    private static let traceLineWidth: CGFloat = 1.7
    private static let axisCaptionSize: CGFloat = 10
    private static let metaSize: CGFloat = 12
    private static let pageBottomGap: CGFloat = 22

    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var effortScale: EffortScale { EffortScale(rawValue: effortScaleRaw) ?? .whoop }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                metaLine
                statStrip
                traceSection
                zonesSection
                notesSection
                classicLink
            }
            .padding(.horizontal, Ledger.pageMargin)
            .padding(.bottom, Self.pageBottomGap)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Ledger.bgScreen.ignoresSafeArea())
        .ledgerMotionGate()
        .task { await load() }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    // MARK: Header

    private var header: some View {
        LedgerHeader(overline: Self.overlineFormatter.string(from: startDate),
                     title: WorkoutSource.displaySport(row.sport),
                     alignment: .bottom) {
            if let strain = row.strain {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(UnitFormatter.effortDisplay(strain, scale: effortScale))
                        .font(LedgerType.numeral(31, LedgerType.bold))
                        .tracking(-1)
                        .foregroundStyle(Ledger.accentStrain)
                        .monospacedDigit()
                    Text(String(localized: "Strain")).ledgerOverline()
                }
            }
        }
        .padding(.top, Self.heroTopGap)
    }

    /// "06:10 – 06:52 · 42m · 6.8 km · 4,120 steps" — every part only when the row carries it.
    private var metaLine: some View {
        var parts: [String] = ["\(Self.clockFormatter.string(from: startDate)) \u{2013} \(Self.clockFormatter.string(from: endDate))"]
        let seconds = row.durationS ?? Double(row.endTs - row.startTs)
        if seconds > 0 {
            let minutes = Int((seconds / 60).rounded())
            parts.append(minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m")
        }
        if let metres = row.distanceM, metres > 0 {
            parts.append(UnitFormatter.distanceFromMeters(metres, system: unitSystem))
        }
        if let steps = row.steps, steps > 0 {
            parts.append(String(localized: "\(steps) steps"))
        }
        return Text(parts.joined(separator: " \u{00B7} "))
            .font(LedgerType.label(Self.metaSize, LedgerType.regular))
            .foregroundStyle(Ledger.textSecondary)
            .monospacedDigit()
            .padding(.top, 6)
    }

    // MARK: Stat strip

    private var statStrip: some View {
        var items: [LedgerStatStrip.Item] = []
        if let kcal = row.energyKcal, kcal > 0 {
            items.append(.init(value: "\(Int(kcal.rounded()))", label: String(localized: "kcal")))
        }
        if let avg = row.avgHr, avg > 0 {
            items.append(.init(value: "\(avg)", label: String(localized: "avg bpm")))
        }
        if let peak = peakBpm {
            items.append(.init(value: "\(peak)", label: String(localized: "peak bpm")))
        }
        if let source = sourceLabel {
            items.append(.init(value: source, label: String(localized: "source")))
        }
        return Group {
            if !items.isEmpty {
                LedgerStatStrip(items)
                    .padding(.top, Self.sectionGap)
            }
        }
    }

    /// The stored max when the row carries one, else the trace's own max — never both disagree,
    /// because the stored value wins whenever it exists.
    private var peakBpm: Int? {
        if let max = row.maxHr, max > 0 { return max }
        return samples.map { Int($0.bpm) }.max()
    }

    /// A short provenance word ("strap", "import", "manual") for the strip. nil hides the cell
    /// rather than guessing.
    private var sourceLabel: String? {
        switch row.source {
        case "manual": return String(localized: "manual")
        case Repository.whoopSource: return String(localized: "strap")
        case "apple-health": return String(localized: "Health")
        case "": return nil
        default: return row.source
        }
    }

    // MARK: Heart-rate trace

    @ViewBuilder
    private var traceSection: some View {
        sectionRule(String(localized: "Heart rate"),
                    trailing: samples.isEmpty ? nil : String(localized: "\u{2014} bpm"))

        if samples.count >= 2 {
            LedgerDrawIn(.chart) { progress in
                LedgerPolyline(points: tracePoints)
                    .trim(from: 0, to: progress)
                    .stroke(Ledger.accentLiveHR.opacity(0.85),
                            style: StrokeStyle(lineWidth: Self.traceLineWidth,
                                               lineCap: .round, lineJoin: .round))
            }
            .frame(height: Self.traceHeight)
            .padding(.top, 10)

            HStack(spacing: Ledger.rowGap) {
                Text(Self.clockFormatter.string(from: startDate))
                Spacer(minLength: 4)
                if let domain = traceDomain {
                    Text(String(localized: "\(Int(domain.lowerBound))\u{2013}\(Int(domain.upperBound)) bpm"))
                }
                Spacer(minLength: 4)
                Text(Self.clockFormatter.string(from: endDate))
            }
            .ledgerCaptionStyle(Self.axisCaptionSize)
            .padding(.top, 6)
        } else if loaded {
            Text(String(localized: "No raw heart-rate samples stored for this session."))
                .ledgerCaptionStyle(11)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
    }

    private var traceDomain: ClosedRange<Double>? {
        LedgerScale.domain(values: samples.map { Double($0.bpm) }, pad: 0.1)
    }

    private var tracePoints: [CGPoint] {
        guard let domain = traceDomain, samples.count >= 2,
              let first = samples.first, let last = samples.last, last.ts > first.ts else { return [] }
        let span = Double(last.ts - first.ts)
        return samples.map { s in
            CGPoint(x: Double(s.ts - first.ts) / span,
                    y: LedgerScale.normalizedY(Double(s.bpm), in: domain))
        }
    }

    // MARK: Zones

    @ViewBuilder
    private var zonesSection: some View {
        if let minutes = zoneMinutes, minutes.reduce(0, +) > 0 {
            sectionRule(String(localized: "Time in zones"), trailing: nil)
            LedgerZoneRibbon(minutes: minutes,
                             labels: minutes.enumerated().map { "Z\($0.offset + 1) \(Int($0.element.rounded()))m" })
                .padding(.top, 12)
        }
    }

    // MARK: Notes

    @ViewBuilder
    private var notesSection: some View {
        if let notes = row.notes, !notes.isEmpty {
            sectionRule(String(localized: "Notes"), trailing: nil)
            Text(notes)
                .ledgerBody()
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
    }

    // MARK: Classic hand-off

    /// Everything this read omits — splits, editing, deletion, export — stays one push away in the
    /// classic detail, so no workflow is lost to the restyle.
    private var classicLink: some View {
        NavigationLink {
            WorkoutDetailView(row: row)
        } label: {
            Text(String(localized: "All details & edit \u{203A}"))
                .font(LedgerType.label(13, LedgerType.semibold))
                .foregroundStyle(Ledger.accentStrain)
        }
        .buttonStyle(.plain)
        .padding(.top, Self.sectionGap + 4)
    }

    // MARK: Chrome

    @ViewBuilder
    private func sectionRule(_ overline: String, trailing: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Ledger.hairline)
                .frame(height: Ledger.hairlineWidth)
            HStack {
                Text(overline).ledgerOverline()
                if let trailing {
                    Spacer(minLength: Ledger.rowGap)
                    Text(trailing)
                        .font(LedgerType.label(11, LedgerType.regular))
                        .foregroundStyle(Ledger.accentLiveHR)
                }
            }
            .padding(.top, 14)
        }
        .padding(.top, Self.sectionGap)
    }

    // MARK: Load

    private func load() async {
        guard row.endTs > row.startTs else { loaded = true; return }
        let raw = await repo.hrSamples(from: row.startTs, to: row.endTs, limit: 20_000)
        samples = raw
        if !raw.isEmpty {
            let tiz = HRZones.timeInZone(raw, zoneSet: profile.hrZoneSet)
            if tiz.seconds.reduce(0, +) > 0 {
                zoneMinutes = tiz.seconds.map { $0 / 60.0 }
            }
        }
        // Fallback: the imported per-session split, exactly as the Activity screen falls back.
        if zoneMinutes == nil, let summary = WorkoutZones.summary(from: [row]) {
            zoneMinutes = summary.minutes
        }
        loaded = true
    }

    // MARK: Formatting

    private var startDate: Date { Date(timeIntervalSince1970: TimeInterval(row.startTs)) }
    private var endDate: Date { Date(timeIntervalSince1970: TimeInterval(row.endTs)) }

    /// "SESSION · FRI 3 JUL" — the header overline (uppercased by `LedgerHeader`).
    private static let overlineFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f
    }()

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("Hm")
        return f
    }()
}
