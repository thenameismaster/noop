import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Ledger Live Workout — the in-exercise screen, in the Ledger's idiom
//
// The handoff has no in-exercise board, so this screen is composed from the kit per the handoff's
// rule for missing screens: data straight on `bg/screen`, hairline-separated sections, the numeral
// face for every figure, colour only where it means something (the zone). It REPLACES nothing —
// `LiveWorkoutView` (classic) still owns the Live tab's presentation; this is what the Ledger
// shell's session sheet presents instead.
//
// ALL machinery is the shipped `AppModel` workout engine, untouched: `activeWorkout` (elapsed clock,
// live strain, avg/peak), `toggleWorkoutPause`, `endWorkout`, `discardWorkout`, and the smoothed
// `bpm`. This view is presentation only.
//
// PERF. This screen observes `AppModel` DELIBERATELY — it is a modal live surface whose whole job
// is the 1 Hz heartbeat, the same trade `LiveWorkoutView` makes. It never renders inside the tab
// shell, so the perf contract for screen roots is not violated. The elapsed clock ticks through a
// 1 s `TimelineView`, not a Timer.
struct LedgerLiveWorkoutView: View {

    let onClose: () -> Void

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var profile: ProfileStore
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue

    @State private var showEndConfirm = false
    @State private var showDiscardConfirm = false

    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }
    private var zoneSet: HRZoneSet { profile.hrZoneSet }
    private var zone: Int { model.bpm.map { zoneSet.zoneNumber(forBPM: Double($0)) } ?? 0 }

    // MARK: Layout constants (kit values)

    private static let hrNumeralSize: CGFloat = 88
    private static let elapsedSize: CGFloat = 31
    private static let railHeight: CGFloat = 34
    private static let railActiveHeight: CGFloat = 44
    private static let controlHeight: CGFloat = 52

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 0)
            hrHero
            Spacer(minLength: 0)
            zoneRail
            statStrip
                .padding(.top, 18)
            controls
                .padding(.top, 22)
        }
        .padding(.horizontal, Ledger.pageMargin)
        .padding(.top, 26)
        .padding(.bottom, 18)
        .background(Ledger.bgScreen.ignoresSafeArea())
        .ledgerMotionGate()
        .confirmationDialog(String(localized: "End workout?"), isPresented: $showEndConfirm) {
            Button(String(localized: "End & save"), role: .destructive) {
                model.endWorkout()
                onClose()
            }
            Button(String(localized: "Keep going"), role: .cancel) {}
        } message: {
            Text(String(localized: "Stops recording and saves what's captured so far."))
        }
        .confirmationDialog(String(localized: "Discard workout?"), isPresented: $showDiscardConfirm) {
            Button(String(localized: "Discard"), role: .destructive) {
                model.discardWorkout()
                onClose()
            }
            Button(String(localized: "Keep going"), role: .cancel) {}
        } message: {
            Text(String(localized: "Throws the session away. Nothing is saved."))
        }
    }

    // MARK: Header — sport + elapsed

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.activeWorkout?.isPaused == true
                     ? String(localized: "Paused")
                     : String(localized: "Live session"))
                    .ledgerOverline(model.activeWorkout?.isPaused == true
                                    ? Ledger.accentCaution : Ledger.accentLiveHR)
                Text(WorkoutSource.displaySport(model.activeWorkout?.sport
                                                ?? WorkoutCatalog.defaultSportName))
                    .font(LedgerType.screenTitle)
                    .foregroundStyle(Ledger.textPrimary)
            }
            Spacer(minLength: Ledger.rowGap)
            // The elapsed clock — 1 s cadence; paused shows the frozen value (elapsed(at:) already
            // excludes paused time, so the display simply stops advancing).
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.clock(model.activeWorkout?.elapsed(at: context.date) ?? 0))
                    .font(LedgerType.numeral(Self.elapsedSize, LedgerType.bold))
                    .tracking(-1)
                    .foregroundStyle(Ledger.textPrimary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: HR hero

    private var hrHero: some View {
        VStack(spacing: 6) {
            Text(model.bpm.map { "\($0)" } ?? "\u{2014}")
                .font(LedgerType.numeral(Self.hrNumeralSize, LedgerType.bold))
                .tracking(-3)
                .foregroundStyle(model.bpm == nil ? Ledger.textTertiary : Ledger.textPrimary)
                .monospacedDigit()
            Text(zone >= 1
                 ? String(localized: "bpm \u{00B7} zone \(zone)")
                 : String(localized: "bpm"))
                .font(LedgerType.label(12, LedgerType.semibold))
                .tracking(2)
                .textCase(.uppercase)
                .foregroundStyle(zone >= 1 ? LedgerZoneRibbon.zoneColors[zone - 1] : Ledger.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Zone rail — the five zones, the current one lit

    private var zoneRail: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { z in
                let active = z == zone
                let color = LedgerZoneRibbon.zoneColors[z - 1]
                RoundedRectangle(cornerRadius: Ledger.barRadiusTight, style: .continuous)
                    .fill(active ? color : color.opacity(0.16))
                    .frame(height: active ? Self.railActiveHeight : Self.railHeight)
                    .overlay(
                        Text(verbatim: "Z\(z)")
                            .font(LedgerType.label(10, active ? LedgerType.bold : LedgerType.regular))
                            .foregroundStyle(active ? Ledger.bgScreen : Ledger.textTertiary)
                            .monospacedDigit()
                    )
            }
        }
        .frame(height: Self.railActiveHeight, alignment: .bottom)
        .animation(LedgerMotion.curve(0.24), value: zone)
    }

    // MARK: Stat strip — live strain · avg · peak

    private var statStrip: some View {
        let w = model.activeWorkout
        return LedgerStatStrip([
            .init(value: w.map { UnitFormatter.effortDisplay($0.liveStrain, scale: effortScale) } ?? "\u{2014}",
                  label: String(localized: "strain"),
                  tint: Ledger.accentStrain),
            .init(value: (w?.avgHr ?? 0) > 0 ? "\(w!.avgHr)" : "\u{2014}",
                  label: String(localized: "avg bpm")),
            .init(value: (w?.peakHr ?? 0) > 0 ? "\(w!.peakHr)" : "\u{2014}",
                  label: String(localized: "peak bpm")),
        ])
    }

    // MARK: Controls — pause/resume · end · discard

    private var controls: some View {
        let paused = model.activeWorkout?.isPaused == true
        return HStack(spacing: 12) {
            controlButton(paused ? String(localized: "Resume") : String(localized: "Pause"),
                          color: Ledger.textPrimary) {
                model.toggleWorkoutPause()
            }
            controlButton(String(localized: "End & save"), color: Ledger.accentLiveHR) {
                showEndConfirm = true
            }
            Button {
                showDiscardConfirm = true
            } label: {
                Text(String(localized: "Discard"))
                    .font(LedgerType.label(12, LedgerType.regular))
                    .foregroundStyle(Ledger.textTertiary)
                    .frame(height: Self.controlHeight)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// The Ledger control: a hairline-bordered raised pill — `bg/raised` is the one fill the token
    /// table allows for CONTROLS, and this is a control.
    private func controlButton(_ label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(LedgerType.label(13.5, LedgerType.semibold))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity)
                .frame(height: Self.controlHeight)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Ledger.bgRaised)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Ledger.white(0.07), lineWidth: 1)
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Formatting

    private static func clock(_ elapsed: TimeInterval) -> String {
        let total = Int(elapsed.rounded(.down))
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
