import SwiftUI

// MARK: - LedgerDebtLedger — the Sleep board's SLEEP DEBT · 14 NIGHTS
//
// Transcribed from `data-screen-label="Sleep"`, `viewBox="0 0 345 52"`, `preserveAspectRatio="none"`:
//
//   <line x1="0" y1="26" x2="345" y2="26" stroke="rgba(255,255,255,.12)"/>
//   <rect x="2"  y="26" width="14" height="13" rx="3"   fill="#F2C14E" opacity=".55"/>   ← missed
//   <rect x="27" y="13" width="14" height="13" rx="3"   fill="#8F9BFF" opacity=".8"/>    ← repaid
//   …
//   <rect x="127" y="21" width="14" height="5"  rx="2.5" fill="#8F9BFF" opacity=".8"/>
//   <rect x="302" y="22" width="14" height="4"  rx="2"   fill="#8F9BFF" opacity=".8"/>
//   caption: <span>Jun 19</span><span>above line = repaid · below = missed</span><span>last night</span>
//
// READING THE GEOMETRY.
//   • The zero hairline sits at y=26 = half of 52, so a night has 26pt of headroom either way.
//   • Bars are `width="14"` on a 25pt pitch (x = 2, 27, 52 … 327) — a 14/25 duty cycle, which is
//     what this view reproduces at any width rather than hard-coding 345.
//   • **The radius is not constant.** `rx` is 3 on tall bars, 2.5 on the 5pt bar, 2 on the 4pt bar:
//     it is `min(3, height/2)`. A short bar therefore stays a lozenge instead of turning into a
//     pill with a flat top. That rule is transcribed, not smoothed.
//   • Above the line is REPAID, in `accent/sleep @ 80%`; below is MISSED, in `accent/caution @ 55%`.
//     Both opacities are the board's.
//
// Pure presentation: it takes signed minutes and normalizes against the window's own largest
// magnitude. It reads no debt ledger and computes no debt.

/// One night of the debt ledger.
public struct LedgerDebtNight: Identifiable, Sendable, Equatable {
    /// Stable identity — the screen's day key or index. Content-derived, never a fresh `UUID()`,
    /// so `ForEach` diffing survives a model rebuild.
    public let id: Int
    /// Signed minutes: **positive = repaid** (drawn above the line, sleep indigo), **negative =
    /// missed** (below, caution amber). Zero draws nothing but keeps the slot.
    public let minutes: Double

    public init(id: Int, minutes: Double) {
        self.id = id
        self.minutes = minutes
    }
}

/// Diverging bars around a zero hairline — the 14-night sleep-debt ledger.
///
/// ```swift
/// LedgerDebtLedger(nights: nights,
///                  leadingCaption: "Jun 19",
///                  centerCaption: LedgerDebtLedger.repaidMissedCaption,
///                  trailingCaption: "last night")
/// ```
public struct LedgerDebtLedger: View {

    // MARK: Board constants

    /// `height="52"` — 26pt either side of the zero line.
    private static let designHeight: CGFloat = 52
    /// `width="14"` on a 25pt pitch — x = 2, 27, 52 … 327.
    private static let barWidthRatio: CGFloat = 14.0 / 25.0
    /// The first bar sits at `x="2"` inside its 25pt slot, not centred in it. Transcribed as a
    /// ratio so the run keeps the board's left bias at any width.
    private static let barInsetRatio: CGFloat = 2.0 / 25.0
    /// The maximum `rx`; a bar shorter than 6pt takes `height/2` instead.
    private static let maxBarRadius: CGFloat = 3
    /// `stroke="rgba(255,255,255,.12)"` on the zero line — one step above `Ledger.trackBand`,
    /// because the zero line is the chart's only structural rule and must out-read the bars' fills.
    private static var zeroLine: Color { Ledger.white(0.12) }
    /// `opacity=".8"` on repaid, `.55"` on missed.
    private static let repaidOpacity: Double = 0.80
    private static let missedOpacity: Double = 0.55
    /// The caption row — `font-size:10px; margin-top:4px`.
    private static let captionSize: CGFloat = 10
    private static let captionTopGap: CGFloat = 4

    /// The board's centre caption, exposed so a screen passes the exact string rather than
    /// re-typing it.
    public static var repaidMissedCaption: String {
        String(localized: "above line = repaid \u{00B7} below = missed")
    }

    // MARK: Input

    private let nights: [LedgerDebtNight]
    private let height: CGFloat
    private let leadingCaption: String?
    private let centerCaption: String?
    private let trailingCaption: String?
    private let animates: Bool
    private let action: (() -> Void)?

    /// - Parameters:
    ///   - nights: the window, oldest first. Signed minutes; see `LedgerDebtNight.minutes`. Empty
    ///     renders the designed empty state — the zero line stays, with a caption over it.
    ///   - height: total bar height. Default `52`, the board's.
    ///   - leadingCaption: the left caption (`"Jun 19"`). `nil` omits it.
    ///   - centerCaption: the middle caption. Pass `LedgerDebtLedger.repaidMissedCaption` for the
    ///     board's legend. `nil` omits it.
    ///   - trailingCaption: the right caption (`"last night"`). `nil` omits it.
    ///   - animates: `false` renders at final height. Default `true` ⇒ the bars grow out of the
    ///     zero line over 1.2 s on appear, collapsing to a 150 ms fade under Reduce Motion.
    ///   - action: makes the block tappable — the Sleep board routes it to
    ///     `TabRoute.metric("sleep_debt_min")`. `nil` = inert.
    public init(
        nights: [LedgerDebtNight],
        height: CGFloat = 52,
        leadingCaption: String? = nil,
        centerCaption: String? = nil,
        trailingCaption: String? = nil,
        animates: Bool = true,
        action: (() -> Void)? = nil
    ) {
        self.nights = nights
        self.height = height
        self.leadingCaption = leadingCaption
        self.centerCaption = centerCaption
        self.trailingCaption = trailingCaption
        self.animates = animates
        self.action = action
    }

    // MARK: Derived

    private var scale: CGFloat { height / Self.designHeight }
    /// The window's own largest magnitude — the bars are relative to the worst/best night shown,
    /// which is what makes a quiet fortnight legible instead of flat.
    private var peak: Double { nights.map { abs($0.minutes) }.max() ?? 0 }
    private var hasBars: Bool { !nights.isEmpty && peak > 0 }

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
        VStack(spacing: Self.captionTopGap) {
            chart
            if leadingCaption != nil || centerCaption != nil || trailingCaption != nil {
                HStack(spacing: 0) {
                    Text(leadingCaption ?? "")
                    Spacer(minLength: 0)
                    Text(centerCaption ?? "")
                    Spacer(minLength: 0)
                    Text(trailingCaption ?? "")
                }
                .font(LedgerType.caption(Self.captionSize))
                .foregroundStyle(Ledger.textTertiary)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: Chart

    private var chart: some View {
        GeometryReader { geo in
            let half = geo.size.height / 2
            let pitch = nights.isEmpty ? 0 : geo.size.width / CGFloat(nights.count)
            let barWidth = pitch * Self.barWidthRatio

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Self.zeroLine)
                    .frame(width: geo.size.width, height: Ledger.hairlineWidth)
                    .offset(y: half - Ledger.hairlineWidth / 2)

                if hasBars {
                    if animates {
                        LedgerDrawIn(.chart) { progress in
                            bars(pitch: pitch, barWidth: barWidth, half: half, progress: progress)
                        }
                    } else {
                        bars(pitch: pitch, barWidth: barWidth, half: half, progress: 1)
                    }
                } else {
                    Text("No sleep-debt history yet")
                        .ledgerCaptionStyle(11)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                }
            }
        }
        .frame(height: height)
    }

    @ViewBuilder
    private func bars(pitch: CGFloat, barWidth: CGFloat, half: CGFloat, progress: Double) -> some View {
        ForEach(Array(nights.enumerated()), id: \.element.id) { index, night in
            let magnitude = CGFloat(abs(night.minutes) / peak) * half * CGFloat(progress)
            let repaid = night.minutes > 0
            // `rx` is min(3, height/2) — the board's own short-bar behaviour, scaled with `height`.
            let radius = min(Self.maxBarRadius * scale, magnitude / 2)

            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(repaid
                      ? Ledger.accentSleep.opacity(Self.repaidOpacity)
                      : Ledger.accentCaution.opacity(Self.missedOpacity))
                .frame(width: max(0, barWidth), height: max(0, magnitude))
                .offset(x: CGFloat(index) * pitch + pitch * Self.barInsetRatio,
                        y: repaid ? half - magnitude : half)
        }
    }
}

#if DEBUG
#Preview("LedgerDebtLedger") {
    let sample: [Double] = [-52, 34, -32, 27, -68, 15, -40, -24, 68, -44, 21, -60, 12, 18]
    return VStack(alignment: .leading, spacing: 18) {
        Text("Sleep debt \u{00B7} 14 nights").ledgerOverline()
        LedgerDebtLedger(
            nights: sample.enumerated().map { LedgerDebtNight(id: $0.offset, minutes: $0.element) },
            leadingCaption: "Jun 19",
            centerCaption: LedgerDebtLedger.repaidMissedCaption,
            trailingCaption: "last night")
        Text("Empty").ledgerOverline()
        LedgerDebtLedger(nights: [], centerCaption: LedgerDebtLedger.repaidMissedCaption)
    }
    .padding(Ledger.pageMargin)
    .frame(width: 393)
    .background(Ledger.bgScreen)
    .preferredColorScheme(.dark)
}
#endif
