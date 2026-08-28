import SwiftUI

// MARK: - LedgerZoneRibbon — the Activity board's TIME IN ZONES
//
// Transcribed from `data-screen-label="Activity"`:
//
//   <span style="font-size:10.5px;font-weight:700;letter-spacing:2.4px;color:#5C6470">TIME IN ZONES</span>
//   <div style="display:flex;gap:3px;margin-top:12px;height:10px;border-radius:5px;overflow:hidden">
//     <div style="width:34%;background:#39414E"></div>
//     <div style="width:26%;background:#2E7FD4"></div>
//     <div style="width:20%;background:#58B9FF"></div>
//     <div style="width:13%;background:#F2C14E"></div>
//     <div style="width:7%; background:#FF6B81"></div>
//   </div>
//   <div style="display:flex;justify-content:space-between;font-size:10px;color:#5C6470;margin-top:6px">
//     <span>Z1 33m</span><span>Z2 25m</span><span>Z3 19m</span><span>Z4 13m</span><span>Z5 7m</span>
//   </div>
//
// READING THE RIBBON.
//   • `border-radius:5px` + `overflow:hidden` on the FLEX CONTAINER, not on the segments: only the
//     ribbon's two outer ends are round; every internal edge is square. Reproduced with a single
//     `.clipShape` on the `HStack`, never with rounded children.
//   • `gap:3px` — 3pt of `bg/screen` between segments, so the ramp reads as five discrete zones.
//   • The ramp is grey → two blues → amber → red: `#39414E`, `#2E7FD4`, `#58B9FF` (`accent/strain`),
//     `#F2C14E` (`accent/caution`), `#FF6B81` (`accent/live-hr`). The first two are ramp-only steps
//     that exist nowhere else in the token table, so they are declared here rather than smuggled
//     into `Ledger` as if they were semantic accents.
//   • Labels use `justify-content:space-between` — evenly spread, NOT aligned under their segments.
//     A 7-minute Z5 still gets a readable label at the right edge.
//
// Pure presentation: minutes in, ribbon out. It computes no zones and reads no HR.

/// The proportional Z1–Z5 time-in-zones ribbon.
///
/// ```swift
/// LedgerZoneRibbon(minutes: [33, 25, 19, 13, 7]) { route(.fullDayChart) }
/// ```
public struct LedgerZoneRibbon: View {

    // MARK: Board constants

    /// `height:10px`.
    private static let ribbonHeight: CGFloat = 10
    /// `gap:3px`.
    private static let segmentGap: CGFloat = 3
    /// `border-radius:5px` on the container.
    private static let ribbonRadius: CGFloat = Ledger.barRadius
    /// `margin-top:6px` above the labels.
    private static let labelTopGap: CGFloat = 6
    /// `font-size:10px` on the labels.
    private static let labelSize: CGFloat = 10

    /// The five zone fills, Z1 → Z5. `#39414E` and `#2E7FD4` are ramp steps local to this
    /// component; the last three are the shared strain / caution / live-HR accents.
    public static let zoneColors: [Color] = [
        Ledger.hex(0x39414E),
        Ledger.hex(0x2E7FD4),
        Ledger.accentStrain,
        Ledger.accentCaution,
        Ledger.accentLiveHR
    ]

    // MARK: Input

    private let minutes: [Double]
    private let labels: [String]?
    private let height: CGFloat
    private let showsLabels: Bool
    private let animates: Bool
    private let action: (() -> Void)?

    /// - Parameters:
    ///   - minutes: minutes per zone, Z1 first. Five values in the boards; any count is laid out
    ///     proportionally against the same ramp (a sixth zone would reuse the last colour). All
    ///     zeros, or empty, renders the designed empty state — an untouched `white @ 6%` track with
    ///     a caption, not a blank strip.
    ///   - labels: pre-formatted labels (`"Z1 33m"`). Default `nil` ⇒ `Z<n> <m>m`, built here.
    ///     Pass your own to localize the unit or to use the app's duration formatter.
    ///   - height: ribbon height. Default `10`, the board's.
    ///   - showsLabels: the minute row beneath. Default `true`.
    ///   - animates: `false` renders at final width. Default `true` ⇒ a left-to-right reveal over
    ///     1.2 s on appear, collapsing to a 150 ms fade under Reduce Motion.
    ///   - action: the board routes the ribbon to `TabRoute.fullDayChart`. `nil` = inert.
    public init(
        minutes: [Double],
        labels: [String]? = nil,
        height: CGFloat = 10,
        showsLabels: Bool = true,
        animates: Bool = true,
        action: (() -> Void)? = nil
    ) {
        self.minutes = minutes.map { max(0, $0) }
        self.labels = labels
        self.height = height
        self.showsLabels = showsLabels
        self.animates = animates
        self.action = action
    }

    // MARK: Derived

    private var total: Double { minutes.reduce(0, +) }
    private var hasData: Bool { total > 0 }

    private func color(_ index: Int) -> Color {
        Self.zoneColors[min(index, Self.zoneColors.count - 1)]
    }

    private var resolvedLabels: [String] {
        if let labels { return labels }
        return minutes.enumerated().map { index, value in
            "Z\(index + 1) \(Int(value.rounded()))m"
        }
    }

    public var body: some View {
        Group {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Self.labelTopGap) {
            ribbon
            if showsLabels && hasData {
                labelRow
            } else if showsLabels {
                Text("No heart-rate zones recorded today")
                    .ledgerCaptionStyle(11)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: Ribbon

    @ViewBuilder
    private var ribbon: some View {
        if hasData {
            if animates {
                LedgerDrawIn(.chart) { progress in segments(progress: progress) }
            } else {
                segments(progress: 1)
            }
        } else {
            // Empty state: the ribbon keeps its 10pt of vertical space so nothing reflows when the
            // day fills in, and reads as an untouched track rather than as "all Z1".
            RoundedRectangle(cornerRadius: Self.ribbonRadius, style: .continuous)
                .fill(Ledger.track)
                .frame(height: height)
        }
    }

    private func segments(progress: Double) -> some View {
        GeometryReader { geo in
            // `gap:3px` is real space, so the segments share the width that is left after the gaps.
            let gaps = Self.segmentGap * CGFloat(max(0, minutes.count - 1))
            let usable = max(0, geo.size.width - gaps)
            HStack(spacing: Self.segmentGap) {
                ForEach(Array(minutes.enumerated()), id: \.offset) { index, value in
                    Rectangle()
                        .fill(color(index))
                        .frame(width: usable * CGFloat(value / total))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            // Round only the ribbon's two outer ends — the board clips the CONTAINER.
            .clipShape(RoundedRectangle(cornerRadius: Self.ribbonRadius, style: .continuous))
            .mask(alignment: .leading) {
                Rectangle().frame(width: geo.size.width * CGFloat(progress))
            }
        }
        .frame(height: height)
    }

    // MARK: Labels

    private var labelRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(resolvedLabels.enumerated()), id: \.offset) { index, text in
                if index > 0 { Spacer(minLength: 4) }
                Text(verbatim: text)
            }
        }
        .font(LedgerType.caption(Self.labelSize))
        .foregroundStyle(Ledger.textTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
#Preview("LedgerZoneRibbon") {
    VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 12) {
            Text("Time in zones").ledgerOverline()
            LedgerZoneRibbon(minutes: [33, 25, 19, 13, 7]) {}
        }
        VStack(alignment: .leading, spacing: 12) {
            Text("Zero Z5").ledgerOverline()
            LedgerZoneRibbon(minutes: [48, 21, 9, 2, 0])
        }
        VStack(alignment: .leading, spacing: 12) {
            Text("Empty").ledgerOverline()
            LedgerZoneRibbon(minutes: [0, 0, 0, 0, 0])
        }
    }
    .padding(Ledger.pageMargin)
    .frame(width: 393)
    .background(Ledger.bgScreen)
    .preferredColorScheme(.dark)
}
#endif
