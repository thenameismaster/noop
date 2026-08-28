import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - LedgerSleepView — spec §"02 · Sleep"
//
// The Ledger fork of the Sleep tab, transcribed from `data-screen-label="Sleep"` in
// `NOOP Redesign.dc.html` and the design bible's §02 list. ADDITIVE: `SleepView` (classic) and
// `AuroraSleepView` are untouched and keep compiling; this screen is reachable only behind
// `LedgerFlags.ledgerUIEnabledKey`, which defaults to `false`.
//
// PRESENTATION ONLY. Every number drawn here comes from the SAME pure pipeline the classic screen
// reads — `SleepModel.build(_:)` over `SleepModelInputs` — with the same memoization contract
// (`dataKey` fingerprint → rebuild only on a real data change) and the same `.task(id:)` loads. No
// scoring, no repository, no BLE, no persistence is re-derived here.
//
// THE BOARD, TOP TO BOTTOM (spec §02's seven numbered items):
//
//   0. A faint indigo wash over the header + stat strip only —
//      `linear-gradient(180deg, rgba(109,141,247,.09), rgba(10,12,17,0) 70%)`.
//   1. Header: overline `"THU 2 → FRI 3 JUL"` (`Night.spanLabel`), title `"Sleep"`, and a
//      right-aligned 44/700 score in `accent/sleep` under a `SCORE` overline.
//   2. Stat strip: asleep · in bed · efficiency · debt (caution).
//   3. NIGHT TIMELINE: four labelled lanes + the sleeping-HR overlay + a clock axis.
//   4. STAGES ledger: Deep / REM / Light / Awake, each a duration bar with the white@45%
//      "your typical" tick and a `±Xm vs typical` delta.
//   5. RESTORATIVE / CONSISTENCY, 2-up, hairline-divided.
//   6. SLEEP DEBT · 14 NIGHTS: diverging bars around a zero rule.
//   7. RHYTHM · BED & WAKE · 14 NIGHTS: two lines over guides at 23:00 / 07:00.
//
// PERF. Like `SleepView` and `AuroraSleepView`, this screen deliberately does NOT observe
// `LiveState` / `AppModel`: a connected strap publishes at ~1 Hz and would re-evaluate this whole
// body on every tick. Every O(days) / O(sessions) scan happens exactly once per data change, in
// `rebuild()`, and lands in the memoized `render` snapshot — `body` reads pre-formatted strings and
// pre-normalized fractions only.
//
// CARDINAL RULE (spec §Design Tokens): no cards behind data. Every section here draws straight onto
// `Ledger.bgScreen`, separated by a 1px hairline and an overline label.

/// The Ledger Sleep screen. Takes no parameters; reads the same environment the classic Sleep tab
/// declares and rebuilds a memoized snapshot on data change.
@MainActor
struct LedgerSleepView: View {

    // MARK: Data sources (verbatim from `SleepView`'s environment contract)

    @EnvironmentObject var repo: Repository
    /// Held to match `SleepView`'s environment contract. This screen is READ-ONLY: it never calls
    /// `analyzeRecent()` — the mutating affordances (wake-time edit, delete, add nap) stay on the
    /// classic screen, which owns their sheets and their undo state machine.
    @EnvironmentObject var intelligence: IntelligenceEngine

    // MARK: Memoized state

    /// The shared, pure sleep model. Rebuilt only when `dataKey` changes.
    @State private var model: SleepModel?
    /// The repo signature `model` / `render` were built from.
    @State private var modelKey: LedgerSleepInputKey?
    /// Everything the board draws, resolved once per data change: pre-formatted strings,
    /// pre-normalized bar fractions, the smoothed stage timeline, the debt bars, the rhythm points.
    @State private var render: LedgerSleepRender?

    /// Every sleep BLOCK across both sources, un-deduplicated, oldest → newest.
    @State private var allSessions: [CachedSleepSession] = []
    /// The LEARNED habitual midsleep the engine threaded into the daily totals (nil = cold start).
    @State private var habitualMidsleepSec: Int?
    /// Per-epoch motion keyed by each session's detected `startTs`.
    @State private var motionByStart: [Int: [Double]] = [:]

    /// The displayed night's sleeping HR in 1-minute buckets, already mapped into the hypnogram's
    /// own seconds-from-onset domain. Mapped in the `.task`, never in `body`.
    @State private var hrPoints: [LedgerHRPoint] = []

    /// The stage the STAGES ledger is highlighting, or nil. Tapping a stage row toggles it and the
    /// other rows recede — the board's stage-highlight behaviour, display-only selection state.
    @State private var highlightedStage: Ledger.Stage?

    /// Night browsing (the classic tab's ◀/▶, as a swipe): 0 = the latest night, +1 per swipe left.
    @State private var nightOffset = 0
    /// The decoded navigated night (nil at offset 0 — the model's own night is the hero then).
    /// Decoded in the offset handler, never in `body`.
    @State private var navNight: Night?

    init() {}

    // MARK: - Body

    var body: some View {
        // Same memoization contract as `SleepView`: `dataKey` is O(1)-ish, so comparing it every
        // render is cheap; a match reuses the cached model + render untouched.
        let key = dataKey
        // Resolve for THIS frame when the cache is cold, exactly as `AuroraSleepView` does: without
        // it, the first pass after launch or after a sync renders the honest "no data" state for one
        // frame before `onAppear` lands the real snapshot, and the screen visibly flickers through
        // an empty state it is not actually in. The `.onAppear` / `.onChange` handlers below persist
        // the same value, so the rebuild happens once per DATA CHANGE, never per render.
        let resolved: LedgerSleepRender? = (key == modelKey) ? render : buildRender()

        return scroller(resolved)
            .background(Ledger.bgScreen.ignoresSafeArea())
            // Night swipe — the SCREEN, not the ScrollView, for the same recognizer-priority reason
            // the Today day-swipe sits one level out: attached to the scroll view it fights the
            // vertical pan and gentle scrolls lose.
            .simultaneousGesture(nightSwipeGesture)
            .ledgerMotionGate()
            .onChangeCompat(of: key) { newKey in
                modelKey = newKey
                rebuild()
            }
            .onAppear {
                if modelKey != key {
                    modelKey = key
                    rebuild()
                }
            }
            // Load EVERY sleep block across BOTH sources (un-deduplicated) so the merged night
            // matches the one `AnalyticsEngine.analyzeDay` scored, including split-sleep days the
            // dashboard collapses. Re-runs whenever a sync/import bumps `refreshSeq`.
            .task(id: repo.refreshSeq) {
                allSessions = await repo.allSleepSessions()
                habitualMidsleepSec = await repo.habitualMidsleepSec()
                motionByStart = await repo.sessionMotions(starts: allSessions.map { $0.startTs })
                modelKey = dataKey
                rebuild()
            }
            // The night's sleeping HR, loaded once per night change — the same 1-minute buckets the
            // classic chart reads (`bucketSeconds: 60`; the repository default is 300).
            .task(id: hrTaskKey) { await loadNightHR() }
    }

    @ViewBuilder
    private func scroller(_ resolved: LedgerSleepRender?) -> some View {
        let scroll = ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // §0 + §1 + §2 — the wash covers exactly the header and the stat strip, as the
                // board's gradient wrapper does.
                VStack(alignment: .leading, spacing: 0) {
                    header(resolved)
                    statStrip(resolved)
                }
                .background(topWash)

                if let resolved {
                    nightTimelineSection(resolved)      // §3
                    stagesSection(resolved)             // §4
                    restorativeConsistency(resolved)    // §5
                    debtSection(resolved)               // §6
                    rhythmSection(resolved)             // §7
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // `margin:14px 24px 20px` on the board's last section.
            .padding(.bottom, Self.pageBottomPadding)
        }

        #if os(iOS)
        scroll.refreshable { await repo.refresh() }
        #else
        scroll
        #endif
    }

    // MARK: - §0 · The indigo wash
    //
    // Board: `linear-gradient(180deg, rgba(109,141,247,.09), rgba(10,12,17,0) 70%)`.
    //
    // The literal colour is `rgb(109,141,247)` = `#6D8DF7` = `Ledger.stageLight`, NOT `accent/sleep`
    // `#8F9BFF`. The bible's prose calls it "sleep accent"; the board states the number. The board
    // wins — "where the spec states a number, use THAT number". The second stop is the screen
    // background at zero alpha (rather than `.clear`) so the ramp cannot fringe toward black.

    private var topWash: some View {
        LinearGradient(
            stops: [
                .init(color: Ledger.stageLight.opacity(Ledger.sleepWashOpacity), location: 0),
                .init(color: Ledger.bgScreen.opacity(0), location: 0.7),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - §1 · Header

    private func header(_ render: LedgerSleepRender?) -> some View {
        LedgerHeader(
            overline: render?.spanLabel ?? "",
            title: String(localized: "Sleep"),
            // `align-items:flex-end` on the board's header row.
            alignment: .bottom
        ) {
            LedgerHeaderScore(
                value: render?.scoreText,
                caption: String(localized: "SCORE"),
                accent: Ledger.accentSleep
            )
        }
        .padding(.horizontal, Ledger.pageMargin)
    }

    // MARK: - §2 · Stat strip
    //
    // Board: `margin:18px 24px 0`, rules top and bottom, four `flex:1` cells —
    // `7:09 asleep · 7:52 in bed · 91% efficiency · −1.8h debt · 14n` (the fourth in caution).

    private func statStrip(_ render: LedgerSleepRender?) -> some View {
        LedgerStatStrip(
            [
                .init(value: render?.asleepText ?? Self.absent,
                      label: String(localized: "asleep")),
                .init(value: render?.inBedText ?? Self.absent,
                      label: String(localized: "in bed")),
                .init(value: render?.efficiencyText ?? Self.absent,
                      suffix: render?.efficiencyText == nil ? nil : "%",
                      label: String(localized: "efficiency")),
                .init(value: render?.debtText ?? Self.absent,
                      label: render?.debtCaption ?? String(localized: "debt"),
                      tint: render?.debtText == nil ? Ledger.textPrimary : Ledger.accentCaution),
            ],
            style: .labelBelow
        )
        .padding(.horizontal, Ledger.pageMargin)
        .padding(.top, Self.statStripTopGap)
    }

    // MARK: - §3 · NIGHT TIMELINE
    //
    // Board: `margin:18px 24px 0`; overline `NIGHT TIMELINE` with `— sleeping HR` (11px,
    // `accent/live-hr`) on the right; the 176pt lane chart 12pt beneath.

    private func nightTimelineSection(_ render: LedgerSleepRender) -> some View {
        VStack(alignment: .leading, spacing: 0) {
                sectionHeader(
                    String(localized: "NIGHT TIMELINE"),
                    trailingText: Self.hrLegend,
                    trailingColor: Ledger.accentLiveHR,
                    trailingSize: Self.timelineLegendSize
                )
                LedgerHypnogram(
                    intervals: render.intervals,
                    heartRate: hrPoints,
                    nightStart: render.nightStart,
                    height: Self.timelineHeight,
                    showsTimeAxis: true
                )
                .padding(.top, Self.timelineChartGap)

                // The overlay's headline fact, stated: the sleeping low and when it landed. Only
                // when the overlay itself has data — the caption never claims a floor the chart is
                // not showing. Min-by-bpm over the SAME buckets the line draws; no new query.
                if let low = hrPoints.min(by: { $0.bpm < $1.bpm }) {
                    let start = render.nightStart
                    Text(String(localized:
                        "sleeping low \(Int(low.bpm.rounded())) bpm at \(Self.hrLowClock.string(from: start.addingTimeInterval(low.seconds)))"))
                        .ledgerCaptionStyle(Self.hrLowCaptionSize)
                        .padding(.top, Self.hrLowCaptionGap)
                }
        }
        .padding(.horizontal, Ledger.pageMargin)
        .padding(.top, Ledger.sectionGapWide)
    }

    /// The sleeping-low caption's clock ("2:41 AM" / "02:41", per locale).
    private static let hrLowClock: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("Hm")
        return f
    }()

    // MARK: - §4 · STAGES
    //
    // Board: `margin:16px 24px 0; border-top:1px hairline; padding-top:14px`; overline `STAGES`
    // with `tick = your typical` (11.5px, tertiary) on the right; four rows, the last without a
    // divider.
    //
    // The bar / tick normalization is the SHIPPED rule, lifted from `StagesVsTypicalCard`:
    // `scaleMax = max(last, typical ?? 0) * 1.18`, per row — so the tick is meaningful against its
    // own bar rather than against a night-wide maximum that would flatten Deep and Awake.

    private func stagesSection(_ render: LedgerSleepRender) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(
                String(localized: "STAGES"),
                trailingText: String(localized: "tick = your typical"),
                trailingColor: Ledger.textTertiary,
                trailingSize: Self.stagesLegendSize
            )
            .padding(.top, Ledger.sectionRulePadding)

            ForEach(render.stageRows) { row in
                LedgerStageBar(
                    label: row.label,
                    stage: row.stage,
                    fraction: row.fraction,
                    typicalFraction: row.typicalFraction,
                    value: row.value,
                    delta: row.delta,
                    deltaTone: row.tone,
                    showsDivider: row.showsDivider,
                    action: { toggleHighlight(row.stage) }
                )
                .opacity(highlightedStage == nil || highlightedStage == row.stage ? 1 : Self.recededOpacity)
            }
        }
        .padding(.horizontal, Ledger.pageMargin)
        // The rule is drawn on the CONTENT's top edge, then the section gap is added outside it —
        // the board's `margin-top` sits ABOVE the `border-top`, not below it. Applying the overlay
        // after the padding would float the hairline 16pt clear of the section it opens.
        .overlay(alignment: .top) { sectionRule }
        .padding(.top, Ledger.sectionGap)
    }

    /// The board's stage-highlight: tap a stage row to light it up and recede the rest; tap again
    /// to clear.
    private func toggleHighlight(_ stage: Ledger.Stage) {
        highlightedStage = (highlightedStage == stage) ? nil : stage
    }

    // MARK: - §5 · RESTORATIVE / CONSISTENCY
    //
    // Board: `margin:16px 24px 0; grid 1fr 1fr; border-top:1px hairline`. Left cell
    // `padding:14px 14px 14px 0` with a `white @ 6%` right rule; right cell `padding:14px 0 14px 14px`.
    // Overlines here carry `letter-spacing:2px` — deliberately tighter than the section overline's
    // +2.4 — so they are drawn locally rather than through `.ledgerOverline()`.

    private func restorativeConsistency(_ render: LedgerSleepRender) -> some View {
        HStack(alignment: .top, spacing: 0) {
                twoUpCell(
                    overline: String(localized: "RESTORATIVE"),
                    value: render.restorativeValue,
                    suffix: render.restorativeValue == nil ? nil : String(localized: "h"),
                    caption: render.restorativeCaption,
                    captionColor: Ledger.textSecondary
                )
                .padding(.trailing, Self.twoUpInnerPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(Ledger.track)
                        .frame(width: Ledger.hairlineWidth)
                }

                // The consistency tile is a tap-through — spec Tap Map:
                // `TabRoute.metric("sleep_consistency")`.
                NavigationLink(value: TabRoute.metric(Self.consistencyKey)) {
                    twoUpCell(
                        overline: String(localized: "CONSISTENCY"),
                        value: render.consistencyValue,
                        suffix: render.consistencyValue == nil ? nil : "%",
                        caption: render.consistencyCaption,
                        captionColor: render.consistencyTone.color
                    )
                    .padding(.leading, Self.twoUpInnerPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Ledger.pageMargin)
        .overlay(alignment: .top) { sectionRule }
        .padding(.top, Ledger.sectionGap)
    }

    /// One half of the 2-up: a tight overline, a 24/700 numeral with a 13pt tertiary suffix, and a
    /// 11pt caption.
    @ViewBuilder
    private func twoUpCell(
        overline: String,
        value: String?,
        suffix: String?,
        caption: String?,
        captionColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(overline)
                .font(LedgerType.overline)
                .tracking(Self.twoUpOverlineTracking)
                .textCase(.uppercase)
                .foregroundStyle(Ledger.textTertiary)

            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(verbatim: value ?? Self.absent)
                    .font(LedgerType.numeral(Self.twoUpValueSize, LedgerType.bold))
                    .foregroundStyle(value == nil ? Ledger.textTertiary : Ledger.textPrimary)
                if let suffix, value != nil {
                    Text(verbatim: suffix)
                        .font(LedgerType.numeral(Self.twoUpSuffixSize, LedgerType.regular))
                        .foregroundStyle(Ledger.textTertiary)
                }
            }
            .padding(.top, Self.twoUpValueGap)

            if let caption {
                Text(caption)
                    .font(LedgerType.caption(Self.twoUpCaptionSize))
                    .lineSpacing(Self.twoUpCaptionSize * (Self.twoUpCaptionLineHeight - 1))
                    .foregroundStyle(captionColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Self.twoUpCaptionGap)
            }
        }
        .padding(.vertical, Ledger.sectionRulePadding)
    }

    // MARK: - §6 · SLEEP DEBT · 14 NIGHTS
    //
    // Board: `margin:14px 24px 0; border-top:1px hairline; padding-top:14px`; overline with
    // `−1.8h owed` (12px, caution) on the right; the 52pt diverging chart; a three-part caption row.
    // Tap → `TabRoute.metric("sleep_debt_min")`.

    private func debtSection(_ render: LedgerSleepRender) -> some View {
        NavigationLink(value: TabRoute.metric(Self.debtKey)) {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(
                    String(localized: "SLEEP DEBT · 14 NIGHTS"),
                    trailingText: render.debtHeadline,
                    trailingColor: render.debtHeadlineTone.color,
                    trailingSize: Self.debtHeadlineSize
                )
                .padding(.top, Ledger.sectionRulePadding)

                LedgerDebtLedger(
                    nights: render.debtNights,
                    leadingCaption: render.debtLeadingCaption,
                    centerCaption: LedgerDebtLedger.repaidMissedCaption,
                    trailingCaption: String(localized: "last night")
                )
                .padding(.top, Self.debtChartGap)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Ledger.pageMargin)
        .overlay(alignment: .top) { sectionRule }
        .padding(.top, Self.tightSectionGap)
    }

    // MARK: - §7 · RHYTHM · BED & WAKE · 14 NIGHTS
    //
    // Board: `margin:14px 24px 20px; border-top:1px hairline; padding-top:14px`; a 72pt chart with
    // `white @ 6%` guides at y=18 and y=54 and the labels `bed 23:00` / `wake 07:00`, plus two
    // 1.6pt polylines — bed in `accent/sleep` @ 90%, wake in `stage/awake`.
    //
    // THE VERTICAL AXIS is read straight off those two guides: 23:00 sits at 18/72 = 0.25 and 07:00
    // at 54/72 = 0.75, so one quarter of the box spans four hours and the full box spans sixteen —
    // 19:00 at the top edge to 11:00 at the bottom. Clock times are wrapped onto that scale and
    // clamped to it.

    private func rhythmSection(_ render: LedgerSleepRender) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(String(localized: "RHYTHM · BED & WAKE · 14 NIGHTS"))
                .padding(.top, Ledger.sectionRulePadding)
            rhythmChart(render)
                .padding(.top, Self.rhythmChartGap)
        }
        .padding(.horizontal, Ledger.pageMargin)
        .overlay(alignment: .top) { sectionRule }
        .padding(.top, Self.tightSectionGap)
    }

    @ViewBuilder
    private func rhythmChart(_ render: LedgerSleepRender) -> some View {
        ZStack(alignment: .topLeading) {
            // The two guides, at the board's exact fractions.
            ForEach(Array(Self.rhythmGuideFractions.enumerated()), id: \.offset) { _, fraction in
                Rectangle()
                    .fill(Ledger.track)
                    .frame(height: Ledger.hairlineWidth)
                    .offset(y: Self.rhythmHeight * fraction - Ledger.hairlineWidth / 2)
            }

            if render.rhythmBed.count >= 2 || render.rhythmWake.count >= 2 {
                LedgerDrawIn(.chart) { progress in
                    ZStack(alignment: .topLeading) {
                        LedgerPolyline(points: render.rhythmWake)
                            .trim(from: 0, to: progress)
                            .stroke(Ledger.stageAwake,
                                    style: StrokeStyle(lineWidth: Self.rhythmStroke,
                                                       lineCap: .round, lineJoin: .round))
                        LedgerPolyline(points: render.rhythmBed)
                            .trim(from: 0, to: progress)
                            .stroke(Ledger.accentSleep.opacity(Self.rhythmBedOpacity),
                                    style: StrokeStyle(lineWidth: Self.rhythmStroke,
                                                       lineCap: .round, lineJoin: .round))
                    }
                }
            }

            // `text x="0" y="12"` and `y="68"`, 9pt tertiary.
            Text(render.bedGuideLabel)
                .font(LedgerType.caption(Self.rhythmLabelSize))
                .foregroundStyle(Ledger.textTertiary)
            Text(render.wakeGuideLabel)
                .font(LedgerType.caption(Self.rhythmLabelSize))
                .foregroundStyle(Ledger.textTertiary)
                .frame(height: Self.rhythmHeight, alignment: .bottom)
        }
        .frame(height: Self.rhythmHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(String(localized: "Bed and wake times over the last 14 nights")))
    }

    // MARK: - Empty state
    //
    // No usable night ⇒ the sections that would be fabricated are simply not drawn. The header and
    // the stat strip stay (with em-dashes), so the screen still says what it is.

    private var emptyState: some View {
        // Existing catalog copy, reused verbatim rather than reworded, so the Ledger's empty state
        // is already translated everywhere the classic screens are.
        Text(String(localized: "No metrics yet. Import your Whoop export or wear the strap to begin."))
            .ledgerBody()
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Ledger.pageMargin)
            .padding(.top, Ledger.sectionGapWide * 2)
    }

    // MARK: - Shared chrome

    /// The 1px `white @ 7%` rule that opens a section. Drawn as a top overlay so it spans the
    /// section's own padded width, exactly like the board's `border-top` on the section div.
    private var sectionRule: some View {
        Rectangle()
            .fill(Ledger.hairline)
            .frame(height: Ledger.hairlineWidth)
            .padding(.horizontal, Ledger.pageMargin)
    }

    /// An overline with an optional right-aligned caption — the board's
    /// `display:flex; justify-content:space-between` section head.
    @ViewBuilder
    private func sectionHeader(
        _ title: String,
        trailingText: String? = nil,
        trailingColor: Color = Ledger.textTertiary,
        trailingSize: CGFloat = 11
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Ledger.rowGap) {
            Text(title).ledgerOverline()
            Spacer(minLength: 0)
            if let trailingText {
                Text(verbatim: trailingText)
                    .font(LedgerType.label(trailingSize, LedgerType.regular))
                    .foregroundStyle(trailingColor)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Loading & memoization

    /// An O(1)-ish fingerprint of the repository inputs this screen reads. Byte-identical in shape
    /// to `SleepView.dataKey` / `AuroraSleepView.dataKey`.
    private var dataKey: LedgerSleepInputKey {
        LedgerSleepInputKey(
            loaded: repo.loaded,
            daysCount: repo.days.count,
            sleepsCount: repo.sleeps.count,
            firstDay: repo.days.first?.day,
            lastDay: repo.days.last?.day,
            lastDayUpdated: repo.days.last,
            lastSleep: repo.sleeps.last,
            refreshSeq: repo.refreshSeq)
    }

    /// Snapshot the view's state into `SleepModelInputs` and hand off to the SAME pure builder the
    /// classic screen uses. Every full pass over `repo.days` / `repo.sleeps` runs here — once per
    /// DATA CHANGE, never once per render.
    private func buildModel() -> SleepModel? {
        SleepModel.build(SleepModelInputs(
            days: repo.days,
            sleeps: repo.sleeps,
            allSessions: allSessions,
            importedSleep: repo.importedSleep,
            habitualMidsleepSec: habitualMidsleepSec,
            motionByStart: motionByStart))
    }

    /// Resolve the board's snapshot: every string formatted, every bar fraction normalized, every
    /// chart's points laid out. `body` then reads finished values and does no arithmetic.
    private func buildRender(_ built: SleepModel? = nil) -> LedgerSleepRender? {
        (built ?? buildModel()).map {
            LedgerSleepRender.build(model: $0,
                                    days: repo.days,
                                    sleeps: repo.sleeps,
                                    importedSleep: repo.importedSleep,
                                    todayEfficiency: repo.today?.efficiency,
                                    nightOverride: navNight)
        }
    }

    /// Persist a fresh model + snapshot into `@State`. Called only from `onAppear` / `onChange` /
    /// the load `.task` — the three places the data actually changed.
    private func rebuild() {
        let built = buildModel()
        model = built
        nightOffset = 0
        navNight = nil
        render = buildRender(built)
        highlightedStage = nil
    }

    /// The night the screen is currently showing — the navigated one, else the model's latest.
    private var displayedNight: Night? { navNight ?? model?.night }

    /// Swipe left = one night OLDER, swipe right = newer, clamped to the browsable groups. The same
    /// thresholds as the Today day-swipe, so the two gestures feel identical.
    private var nightSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.5, abs(dx) > 50 else { return }
                step(dx < 0 ? 1 : -1)
            }
    }

    private func step(_ delta: Int) {
        let navSessions = allSessions.isEmpty ? repo.sleeps : allSessions
        let groups = SleepModel.navDays(navSessions: navSessions)
        let next = min(max(0, nightOffset + delta), max(0, groups.count - 1))
        guard next != nightOffset else { return }
        nightOffset = next
        navNight = next == 0 ? nil : SleepModel.decodedNight(at: next, navDays: groups,
                                                             habitualMidsleepSec: habitualMidsleepSec,
                                                             motionByStart: motionByStart)
        render = buildRender()
        highlightedStage = nil
    }

    /// The night the HR overlay belongs to. `0` while there is no night, which keeps the `.task`
    /// from firing against a half-built model.
    private var hrTaskKey: Int { displayedNight?.session.startTs ?? 0 }

    /// Load the displayed night's 1-minute sleeping-HR buckets and map them into the hypnogram's
    /// seconds-from-onset domain. The window filter is the classic chart's, verbatim
    /// (`rel >= origin − 60 … rel <= origin + span + 60`); the samples are then clamped into the
    /// stage timeline's own span so the HR trace can never stretch the chart past the night.
    ///
    /// No confidence filtering: with the shipped acceptance floor no stored PPG sample carries
    /// `conf < 0.3`, so every bucket in the store is a measured reading.
    private func loadNightHR() async {
        guard let night = displayedNight,
              night.session.endTs > night.session.effectiveStartTs else {
            hrPoints = []
            return
        }
        let buckets = await repo.hrBuckets(from: night.session.effectiveStartTs,
                                           to: night.session.endTs,
                                           bucketSeconds: 60)
        let intervals = render?.intervals ?? LedgerSleepRender.smoothed(night.intervals)
        guard let span = intervals.map(\.end).max(), span > 0 else {
            hrPoints = []
            return
        }
        let nightStartTs = night.onsetDate.timeIntervalSince1970
        hrPoints = buckets.compactMap { bucket in
            let rel = TimeInterval(bucket.ts) - nightStartTs
            guard rel >= -60, rel <= span + 60 else { return nil }
            return LedgerHRPoint(seconds: min(max(rel, 0), span), bpm: bucket.bpm)
        }
    }

    // MARK: - Board constants
    //
    // Every value below is the board's own number.

    /// `margin:18px …` between the header block and the stat strip.
    private static let statStripTopGap: CGFloat = 18
    /// `margin:14px 24px 20px` — the bottom gutter under the last section.
    private static let pageBottomPadding: CGFloat = 20
    /// `margin:14px …` on the debt + rhythm sections, tighter than `Ledger.sectionGap`.
    private static let tightSectionGap: CGFloat = 14

    /// `height="176"` on the timeline SVG, and `margin-top:12px` above it.
    private static let timelineHeight: CGFloat = 176
    private static let timelineChartGap: CGFloat = 12
    /// `font-size:11px` on `— sleeping HR`.
    private static let timelineLegendSize: CGFloat = 11
    /// The sleeping-low caption beneath the timeline — 10.5pt, 6pt under the axis.
    private static let hrLowCaptionSize: CGFloat = 10.5
    private static let hrLowCaptionGap: CGFloat = 6
    /// `font-size:11.5px` on `tick = your typical`.
    private static let stagesLegendSize: CGFloat = 11.5

    /// `font-size:24px; font-weight:700` on the 2-up numerals, `13px` on their suffix.
    private static let twoUpValueSize: CGFloat = 24
    private static let twoUpSuffixSize: CGFloat = 13
    /// `letter-spacing:2px` — the 2-up overlines are tighter than the section overline's +2.4.
    private static let twoUpOverlineTracking: CGFloat = 2
    /// `margin-top:6px` above the numeral, `margin-top:4px` above the caption.
    private static let twoUpValueGap: CGFloat = 6
    private static let twoUpCaptionGap: CGFloat = 4
    /// `font-size:11px; line-height:1.45` on the 2-up captions.
    private static let twoUpCaptionSize: CGFloat = 11
    private static let twoUpCaptionLineHeight: CGFloat = 1.45
    /// `padding:14px 14px 14px 0` / `padding:14px 0 14px 14px` — the inner gutter either side of the
    /// vertical rule.
    private static let twoUpInnerPadding: CGFloat = 14

    /// `font-size:12px` on `−1.8h owed`, and `margin-top:10px` above the debt chart.
    private static let debtHeadlineSize: CGFloat = 12
    private static let debtChartGap: CGFloat = 10

    /// `height="72"` on the rhythm SVG, `margin-top:10px` above it, `stroke-width="1.6"`,
    /// `opacity=".9"` on the bed line, `font-size="9"` on the guide labels.
    private static let rhythmHeight: CGFloat = 72
    private static let rhythmChartGap: CGFloat = 10
    private static let rhythmStroke: CGFloat = 1.6
    private static let rhythmBedOpacity: Double = 0.9
    private static let rhythmLabelSize: CGFloat = 9
    /// `y1="18"` and `y1="54"` over a 72pt box.
    private static let rhythmGuideFractions: [CGFloat] = [18.0 / 72.0, 54.0 / 72.0]

    /// How far a non-highlighted stage row recedes when one stage is selected.
    private static let recededOpacity: Double = 0.35

    /// The em-dash every absent value renders as — never prose, never a zero.
    private static let absent = "\u{2014}"
    /// `— sleeping HR`: the board's em-dash rule glyph plus the legend.
    private static var hrLegend: String { "\u{2014} " + String(localized: "sleeping HR") }

    /// Spec Tap Map keys — existing `MetricCatalog` entries, not new ones.
    private static let debtKey = "sleep_debt_min"
    private static let consistencyKey = "sleep_consistency"
}

// MARK: - Input fingerprint

/// The repository signature `LedgerSleepView`'s memoized model was built from. Same shape as
/// `SleepView.SleepInputKey` — cheap to compute every render, so a hover/animation/1 Hz re-render
/// never triggers a rebuild.
private struct LedgerSleepInputKey: Equatable {
    let loaded: Bool
    let daysCount: Int
    let sleepsCount: Int
    let firstDay: String?
    let lastDay: String?
    let lastDayUpdated: DailyMetric?
    let lastSleep: CachedSleepSession?
    let refreshSeq: Int
}

// MARK: - One STAGES row, resolved

/// A single STAGES-ledger row, fully resolved: the bar and tick fractions are already normalized and
/// the value/delta are already formatted, so `body` does no arithmetic.
private struct LedgerSleepStageRow: Identifiable {
    let id: Int
    let label: String
    let stage: Ledger.Stage
    let fraction: Double?
    let typicalFraction: Double?
    let value: String
    let delta: String?
    let tone: LedgerTone
    let showsDivider: Bool
}

// MARK: - The board's snapshot

/// Everything §02 draws, resolved once per data change. Pure presentation: it formats and normalizes
/// values that `SleepModel` / `Repository` / `SleepDebt` already computed, and derives nothing new
/// about the user's physiology.
private struct LedgerSleepRender {

    // §1
    let spanLabel: String
    let scoreText: String?
    // §2
    let asleepText: String
    let inBedText: String
    let efficiencyText: String?
    let debtText: String?
    let debtCaption: String
    // §3
    let intervals: [SleepInterval]
    let nightStart: Date
    // §4
    let stageRows: [LedgerSleepStageRow]
    // §5
    let restorativeValue: String?
    let restorativeCaption: String?
    let consistencyValue: String?
    let consistencyCaption: String?
    let consistencyTone: LedgerTone
    // §6
    let debtNights: [LedgerDebtNight]
    let debtHeadline: String?
    let debtHeadlineTone: LedgerTone
    let debtLeadingCaption: String?
    // §7
    let rhythmBed: [CGPoint]
    let rhythmWake: [CGPoint]
    let bedGuideLabel: String
    let wakeGuideLabel: String

    // MARK: Build

    static func build(
        model: SleepModel,
        days: [DailyMetric],
        sleeps: [CachedSleepSession],
        importedSleep: [String: ImportedSleepFigures],
        todayEfficiency: Double?,
        nightOverride: Night? = nil
    ) -> LedgerSleepRender {
        // Night browsing (the ◀/▶ the classic tab has): an override swaps every NIGHT-SCOPED
        // section — header span, score, stat strip, timeline, stages — onto the navigated night,
        // while the whole-history sections (debt, rhythm, consistency) stay put. nil = latest.
        let night = nightOverride ?? model.night
        let stages = night.stages
        let ledger = model.sleepDebtLedger

        // §1 — the score for THIS night: the imported WHOOP figure for its local wake-day when the
        // export carried one, else the resolved Rest composite for that day. Byte-identical to the
        // rule `AuroraSleepView.performanceScore(for:)` uses.
        let wakeDay = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(night.session.endTs)))
        let score: Double? = {
            if let p = importedSleep[wakeDay]?.performancePct { return p }
            guard let daily = days.last(where: { $0.day == wakeDay }) else { return nil }
            return AnalyticsEngine.Rest.composite(daily: daily)
        }()

        // §2 — efficiency. `SleepView.efficiencyPct` is private to that file, so its exact rule is
        // re-stated here rather than approximated: a stored fraction/percent wins, else asleep over
        // time-in-bed, capped at 100.
        let efficiency: Double? = {
            if let stored = night.session.efficiency ?? todayEfficiency {
                return stored <= 1.0 ? stored * 100 : stored
            }
            let bed = night.timeInBed
            guard bed > 0 else { return nil }
            return min(100, stages.asleep / bed * 100)
        }()

        // §4 — the four stage rows, in the board's order. Deep and REM read "more is better", Awake
        // reads "less is better", and Light has no polarity at all (the board paints its `+6m vs
        // typical` in tertiary). The component never infers a tone from the sign; the screen, which
        // knows the polarity, supplies it.
        let hasStages = stages.total > 0
        let rows: [LedgerSleepStageRow] = [
            stageRow(id: 0, label: String(localized: "Deep"), stage: .deep,
                     minutes: hasStages ? stages.deep : nil, typical: model.typicalDeepMin,
                     polarity: .moreIsBetter, showsDivider: true),
            stageRow(id: 1, label: String(localized: "REM"), stage: .rem,
                     minutes: hasStages ? stages.rem : nil, typical: model.typicalRemMin,
                     polarity: .moreIsBetter, showsDivider: true),
            stageRow(id: 2, label: String(localized: "Light"), stage: .light,
                     minutes: hasStages ? stages.light : nil, typical: model.typicalLightMin,
                     polarity: .neutral, showsDivider: true),
            stageRow(id: 3, label: String(localized: "Awake"), stage: .awake,
                     minutes: hasStages ? stages.awake : nil, typical: nil,
                     polarity: .lessIsBetter, showsDivider: false),
        ]

        // §5a — restorative: deep + REM, and its share of the night's asleep time.
        let restorativeMin = stages.deep + stages.rem
        let restorativeValue: String? = (hasStages && restorativeMin > 0) ? clockDuration(restorativeMin) : nil
        let restorativeCaption: String? = {
            guard hasStages, restorativeMin > 0, stages.asleep > 0 else { return nil }
            let share = Int((restorativeMin / stages.asleep * 100).rounded())
            return String(localized: "deep + REM · \(share)% of the night")
        }()

        // §5b — consistency, with the board's bedtime-drift caption beneath it.
        let consistency = model.consistency.latest
        let drift = bedtimeDriftMinutes(sleeps)
        let consistencyCaption: String? = {
            if let drift {
                let magnitude = Int(abs(drift).rounded())
                if magnitude < driftSteadyBandMin { return String(localized: "bedtime steady this week") }
                return drift > 0
                    ? String(localized: "bedtime drifted \(magnitude)m later this week")
                    : String(localized: "bedtime drifted \(magnitude)m earlier this week")
            }
            guard let typical = model.consistency.typical else { return nil }
            return String(localized: "typical \(Int(typical.rounded()))%")
        }()
        // Tone comes from two numbers NOOP already computes: this week's consistency against the
        // user's own typical. Less consistent than usual reads caution; otherwise tertiary.
        let consistencyTone: LedgerTone = {
            guard let consistency, let typical = model.consistency.typical else { return .neutral }
            return consistency < typical ? .caution : .neutral
        }()

        // §6 — the 14-night ledger. Already computed on the model; never rebuilt here.
        let debtNights = ledger.nights.enumerated().map {
            LedgerDebtNight(id: $0.offset, minutes: $0.element.deltaMin)
        }
        let debtHeadline: String? = {
            guard ledger.nightCount > 0 else { return nil }
            if ledger.magnitudeMin < SleepDebt.onTargetBandMin { return String(localized: "on target") }
            let magnitude = signedHours(ledger.balanceMin)
            return ledger.isDebt
                ? String(localized: "\(magnitude) owed")
                : String(localized: "\(magnitude) ahead")
        }()
        let debtHeadlineTone: LedgerTone = {
            guard ledger.nightCount > 0, ledger.magnitudeMin >= SleepDebt.onTargetBandMin else { return .neutral }
            return ledger.isDebt ? .caution : .sleep
        }()

        // §7 — bed / wake over the same 14-night window the ledger uses.
        let rhythmSessions = Array(sleeps.suffix(SleepDebt.defaultWindowNights))
        let bedPoints = rhythmPoints(rhythmSessions) { TimeInterval($0.effectiveStartTs) }
        let wakePoints = rhythmPoints(rhythmSessions) { TimeInterval($0.endTs) }

        return LedgerSleepRender(
            spanLabel: night.spanLabel,
            scoreText: score.map { "\(Int($0.rounded()))" },
            asleepText: hasStages ? clockDuration(stages.asleep) : "\u{2014}",
            inBedText: hasStages ? clockDuration(night.timeInBed) : "\u{2014}",
            efficiencyText: efficiency.map { "\(Int($0.rounded()))" },
            debtText: ledger.nightCount > 0 ? signedHours(ledger.balanceMin) : nil,
            debtCaption: ledger.nightCount > 0
                ? String(localized: "debt · \(ledger.nightCount)n")
                : String(localized: "debt"),
            intervals: smoothed(nightOverride?.intervals ?? model.intervals),
            nightStart: night.onsetDate,
            stageRows: rows,
            restorativeValue: restorativeValue,
            restorativeCaption: restorativeCaption,
            consistencyValue: consistency.map { "\(Int($0.rounded()))" },
            consistencyCaption: consistencyCaption,
            consistencyTone: consistencyTone,
            debtNights: debtNights,
            debtHeadline: debtHeadline,
            debtHeadlineTone: debtHeadlineTone,
            debtLeadingCaption: ledger.nights.first.map { shortDate(dayKey: $0.day) },
            rhythmBed: bedPoints,
            rhythmWake: wakePoints,
            bedGuideLabel: String(localized: "bed \(clockLabel(hour: bedGuideHour))"),
            wakeGuideLabel: String(localized: "wake \(clockLabel(hour: wakeGuideHour))")
        )
    }

    // MARK: Stage rows

    /// Whether a bigger number is better for this stage — the polarity the board encodes in its
    /// delta colours (Deep short = caution, Awake short = mint).
    private enum StagePolarity { case moreIsBetter, lessIsBetter, neutral }

    /// One resolved STAGES row. The bar/tick normalization is the shipped `StagesVsTypicalCard`
    /// rule: `scaleMax = max(last, typical ?? 0) * 1.18`, per row.
    private static func stageRow(
        id: Int,
        label: String,
        stage: Ledger.Stage,
        minutes: Double?,
        typical: Double?,
        polarity: StagePolarity,
        showsDivider: Bool
    ) -> LedgerSleepStageRow {
        guard let minutes else {
            return LedgerSleepStageRow(id: id, label: label, stage: stage, fraction: nil,
                                       typicalFraction: nil, value: "\u{2014}", delta: nil,
                                       tone: .neutral, showsDivider: showsDivider)
        }
        let scaleMax = max(minutes, typical ?? 0) * stageScaleHeadroom
        let fraction = scaleMax > 0 ? min(1, minutes / scaleMax) : nil
        let tickFraction: Double? = {
            guard let typical, typical > 0, scaleMax > 0 else { return nil }
            return min(1, typical / scaleMax)
        }()
        let delta: String? = typical.map { signedMinutesVsTypical(minutes - $0) }
        let tone: LedgerTone = {
            guard let typical else { return .neutral }
            let difference = minutes - typical
            switch polarity {
            case .neutral: return .neutral
            case .moreIsBetter: return difference >= 0 ? .good : .caution
            case .lessIsBetter: return difference <= 0 ? .good : .caution
            }
        }()
        return LedgerSleepStageRow(id: id, label: label, stage: stage, fraction: fraction,
                                   typicalFraction: tickFraction, value: clockDuration(minutes),
                                   delta: delta, tone: tone, showsDivider: showsDivider)
    }

    /// `* 1.18` — the headroom `StagesVsTypicalCard` gives every stage bar so a bar at its own
    /// typical does not run to the end of its track.
    private static let stageScaleHeadroom: Double = 1.18

    // MARK: Timeline

    /// The display smoothing the shipped chart applies. Render-only: totals are computed from the
    /// raw segments elsewhere and are untouched. A raw night arrives as 60–100 sub-minute fragments
    /// and would render as an unreadable comb without it.
    static func smoothed(_ intervals: [SleepInterval]) -> [SleepInterval] {
        Hypnogram.displaySmoothed(intervals.sorted { $0.start < $1.start },
                                  minDuration: displaySmoothingSeconds)
    }

    /// `smoothingSeconds: 300` — the default the shipped chart uses.
    private static let displaySmoothingSeconds: TimeInterval = 300

    // MARK: Rhythm

    /// The board's vertical clock axis: 19:00 at the top edge, 11:00 at the bottom, read off the two
    /// guides (23:00 at 18/72, 07:00 at 54/72).
    private static let rhythmAxisStartMinutes: Double = 19 * 60
    private static let rhythmAxisSpanMinutes: Double = 16 * 60
    private static let bedGuideHour = 23
    private static let wakeGuideHour = 7

    /// `x="8"` for the first point and `x="336"` for the last, over the board's 345-wide viewBox.
    private static let rhythmLeadingInset: CGFloat = 8.0 / 345.0
    private static let rhythmTrailingInset: CGFloat = 336.0 / 345.0

    /// Normalized polyline points for one clock series over the rhythm window.
    private static func rhythmPoints(
        _ sessions: [CachedSleepSession],
        _ timestamp: (CachedSleepSession) -> TimeInterval
    ) -> [CGPoint] {
        guard sessions.count >= 2 else { return [] }
        let span = rhythmTrailingInset - rhythmLeadingInset
        return sessions.enumerated().map { index, session in
            let t = CGFloat(index) / CGFloat(sessions.count - 1)
            let date = Date(timeIntervalSince1970: timestamp(session))
            return CGPoint(x: rhythmLeadingInset + t * span, y: rhythmFraction(date))
        }
    }

    /// A wall-clock time as a 0…1 position down the rhythm box, wrapped onto the 19:00 → 11:00 axis
    /// and clamped to it.
    private static func rhythmFraction(_ date: Date) -> CGFloat {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let minutes = Double((components.hour ?? 0) * 60 + (components.minute ?? 0))
        let relative = (minutes - rhythmAxisStartMinutes).truncatingRemainder(dividingBy: 1440)
        let wrapped = relative < 0 ? relative + 1440 : relative
        return CGFloat(min(max(wrapped / rhythmAxisSpanMinutes, 0), 1))
    }

    // MARK: Formatting

    /// `"7:09"` — hours and zero-padded minutes, the board's duration form.
    private static func clockDuration(_ minutes: Double) -> String {
        let total = max(0, Int(minutes.rounded()))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    /// `"−1.8h"` — a signed balance in hours to one decimal, with the board's true minus sign.
    private static func signedHours(_ minutes: Double) -> String {
        let hours = abs(minutes) / 60
        let sign = minutes < 0 ? "\u{2212}" : "+"
        return sign + String(format: "%.1f", hours) + "h"
    }

    /// `"−9m vs typical"` / `"+11m vs typical"`.
    private static func signedMinutesVsTypical(_ minutes: Double) -> String {
        let magnitude = Int(abs(minutes).rounded())
        let sign = minutes < 0 ? "\u{2212}" : "+"
        return String(localized: "\(sign)\(magnitude)m vs typical")
    }

    /// `"Jun 19"` from a stored `yyyy-MM-dd` day key. Fixed POSIX parsing, locale-aware display; an
    /// unparseable key yields no caption rather than a wrong date.
    private static func shortDate(dayKey: String) -> String {
        guard let date = dayKeyParser.date(from: dayKey) else { return "" }
        return shortDateFormatter.string(from: date)
    }

    /// `"23:00"` / `"11:00 PM"` — a fixed guide hour in the device's own 12-/24-hour setting.
    private static func clockLabel(hour: Int) -> String {
        var components = DateComponents()
        components.year = 2000; components.month = 1; components.day = 1
        components.hour = hour; components.minute = 0
        guard let date = Calendar.current.date(from: components) else { return "" }
        return clockFormatter.string(from: date)
    }

    /// A drift under half an hour reads as "steady" rather than as a direction — the same deadband
    /// `SleepDebt.onTargetBandMin` uses so a few stray minutes never flip the sentence.
    private static var driftSteadyBandMin: Int { Int(SleepDebt.onTargetBandMin) }

    /// This week's mean bedtime minus last week's, in minutes (positive = later).
    ///
    /// PRESENTATION ARITHMETIC, not a new metric: it reads the SAME session onsets
    /// `SleepModel.consistencySeries` folds into the consistency score, on the same wrapped
    /// evening-continuous scale, and simply states the week-over-week difference the board's caption
    /// asks for. Returns nil under a full fortnight of onsets, in which case the caption falls back
    /// to the consistency score's own typical.
    private static func bedtimeDriftMinutes(_ sleeps: [CachedSleepSession]) -> Double? {
        LedgerSleepSignals.bedtimeDriftMinutes(sleeps)
    }

    private static let dayKeyParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.activeLocale
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.activeLocale
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter
    }()
}

// MARK: - Shared sleep signals

/// Sleep-rhythm reads shared between the Sleep screen (the consistency caption) and the Today
/// coach (the bedtime-drift verdict). One canonical implementation so the two can never disagree
/// about whether a bedtime is drifting.
enum LedgerSleepSignals {

    /// Recent-half mean bedtime minus earlier-half mean, in minutes, over the debt window's nights.
    /// Positive = drifting LATER. `nil` below a full window — a short history claims no drift.
    /// Evening onsets wrap past midnight into one scale so 23:30 and 00:30 compare sanely.
    static func bedtimeDriftMinutes(_ sleeps: [CachedSleepSession]) -> Double? {
        let window = SleepDebt.defaultWindowNights
        guard sleeps.count >= window else { return nil }
        let calendar = Calendar.current
        func bedMinutes(_ session: CachedSleepSession) -> Double {
            let date = Date(timeIntervalSince1970: TimeInterval(session.effectiveStartTs))
            let components = calendar.dateComponents([.hour, .minute], from: date)
            var minutes = Double((components.hour ?? 0) * 60 + (components.minute ?? 0))
            if minutes < 12 * 60 { minutes += 24 * 60 }   // wrap evening onsets into one scale
            return minutes
        }
        let recent = sleeps.suffix(window).map(bedMinutes)
        let half = recent.count / 2
        let previous = Array(recent.prefix(half))
        let latest = Array(recent.suffix(recent.count - half))
        guard !previous.isEmpty, !latest.isEmpty else { return nil }
        let previousMean = previous.reduce(0, +) / Double(previous.count)
        let latestMean = latest.reduce(0, +) / Double(latest.count)
        return latestMean - previousMean
    }

    /// The steady band — below this magnitude a drift is noise, not a signal. The same cut the
    /// Sleep screen's caption uses.
    static var driftSteadyBandMin: Double { SleepDebt.onTargetBandMin }
}
