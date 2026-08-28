import SwiftUI

// MARK: - LedgerHeader — overline date + screen title + a trailing slot
//
// Board: `NOOP Redesign.dc.html` — every one of the six screens opens with this block.
// Transcribed verbatim:
//
//   header    padding:22px 24px 0; display:flex; justify-content:space-between
//             align-items:baseline   (Today)  ·  align-items:flex-end  (Sleep/Body/Trends)
//   overline  font-size:11px; font-weight:600; letter-spacing:2.6px; color:#5C6470
//   title     font-family:'Space Grotesk'; font-size:27px; font-weight:700;
//             letter-spacing:-.5px; margin-top:4px
//
// ⚠️ THE HEADER OVERLINE IS NOT THE SECTION OVERLINE. The boards give the section label
// 10.5/700/+2.4 (`LedgerType.overline` → `.ledgerOverline()`) but the *header* label 11/600/+2.6.
// Two different styles that look alike; both are transcribed, neither is rounded into the other.
//
// The trailing slot is whatever the screen puts there, and the boards use three shapes:
//   Today   `SyncStatus`  — 6px mint dot + "synced · 68%" at 12px #5C6470, gap 7px
//   Sleep   `Score`       — Space Grotesk 44/700 −1.5 in accent/sleep + "SCORE" 10.5 / +2 tertiary
//   Body    a 56pt recovery mini-ring (the screen builder's own `ScoreArc`)
//   Trends  a `LedgerRangePill`
// plus the spec's overflow affordance — `Overflow` — which is where the old 28-destination "More"
// list now lives (spec §01.7).
//
// MOTION: none. Header text is instant (spec §Motion).
//
// PURE PRESENTATION. Strings in, taps out.

/// A Ledger screen header: an overline, a Space Grotesk 27/700 title, and a trailing slot.
///
/// ```swift
/// LedgerHeader(overline: "FRI · JUL 3", title: "Today") {
///     LedgerHeaderSyncStatus(text: "synced · 68%", isConnected: true)
/// }
/// ```
public struct LedgerHeader<Trailing: View>: View {

    // MARK: Board constants

    /// Header overline — 11pt / 600 (`font-size:11px;font-weight:600`).
    private static var overlineSize: CGFloat { 11 }
    /// Header overline tracking — +2.6 (`letter-spacing:2.6px`).
    private static var overlineTracking: CGFloat { 2.6 }
    /// Gap between the overline and the title — 4pt (`margin-top:4px`).
    private static var titleGap: CGFloat { 4 }

    /// The board's top padding above the header — **22pt** (`padding:22px 24px 0`). The 24pt is the
    /// page margin, which the screen owns; this view stays horizontally neutral.
    public static var defaultTopPadding: CGFloat { 22 }

    // MARK: Stored

    private let overline: String
    private let title: String
    private let alignment: VerticalAlignment
    private let topPadding: CGFloat
    private let trailing: Trailing

    /// - Parameters:
    ///   - overline: the small tracked label above the title, e.g. `"FRI · JUL 3"`,
    ///     `"THU 2 → FRI 3 JUL"`, `"RECOVERY"`, `"LOAD & TRAINING"`, `"LONG VIEW"`.
    ///   - title: the screen title, e.g. `"Today"`. Space Grotesk 27/700, −0.5 tracking.
    ///   - alignment: how the trailing slot lines up with the title block. `.lastTextBaseline`
    ///     matches the Today board's `align-items:baseline`; `.bottom` matches the Sleep / Body /
    ///     Trends boards' `align-items:flex-end`.
    ///   - topPadding: the board's 22pt gutter above the header. Pass `0` when the host already
    ///     provides it.
    ///   - trailing: the trailing slot — a sync status, a score, a mini-ring, a range pill, or the
    ///     overflow affordance.
    public init(
        overline: String,
        title: String,
        alignment: VerticalAlignment = .lastTextBaseline,
        topPadding: CGFloat = LedgerHeader.defaultTopPadding,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.overline = overline
        self.title = title
        self.alignment = alignment
        self.topPadding = topPadding
        self.trailing = trailing()
    }

    // MARK: Body

    public var body: some View {
        HStack(alignment: alignment, spacing: Ledger.rowGap) {
            VStack(alignment: .leading, spacing: Self.titleGap) {
                if !overline.isEmpty {
                    Text(overline)
                        .font(LedgerType.label(Self.overlineSize, LedgerType.semibold))
                        .tracking(Self.overlineTracking)
                        .textCase(.uppercase)
                        .foregroundStyle(Ledger.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Text(title)
                    .ledgerScreenTitle()
                    .foregroundStyle(Ledger.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .padding(.top, topPadding)
    }
}

// MARK: - Header with no trailing slot

public extension LedgerHeader where Trailing == EmptyView {
    /// A header with nothing in the trailing slot — the Activity board's own header.
    init(
        overline: String,
        title: String,
        alignment: VerticalAlignment = .lastTextBaseline,
        topPadding: CGFloat = LedgerHeader.defaultTopPadding
    ) {
        self.init(
            overline: overline,
            title: title,
            alignment: alignment,
            topPadding: topPadding,
            trailing: { EmptyView() }
        )
    }
}

// MARK: - Trailing slot · sync status dot + battery

/// The Today board's trailing slot: a 6pt status dot and a caption.
///
/// Board: `display:flex; align-items:center; gap:7px; font-size:12px; color:#5C6470` with
/// `<span style="width:6px;height:6px;border-radius:50%;background:#3EE6A8">`.
///
/// The dot's colour carries the meaning: mint when the strap is connected, `accent/caution` when it
/// is not. The caption ("synced · 68%") is composed by the screen from `BLEManager`/`LiveState` —
/// this view formats nothing.
public struct LedgerHeaderSyncStatus: View {
    /// Dot diameter — 6pt (`width:6px;height:6px`).
    private static let dotDiameter: CGFloat = 6
    /// Gap between the dot and the caption — 7pt (`gap:7px`).
    private static let gap: CGFloat = 7
    /// Caption — 12pt (`font-size:12px`), `text/tertiary`.
    private static let captionSize: CGFloat = 12

    private let text: String
    private let isConnected: Bool
    private let action: (() -> Void)?

    /// - Parameters:
    ///   - text: the pre-composed caption, e.g. `"synced · 68%"`.
    ///   - isConnected: `true` paints the dot `accent/recovery`; `false` paints it `accent/caution`.
    ///   - action: optional tap (the boards do not route this; a screen may).
    public init(text: String, isConnected: Bool, action: (() -> Void)? = nil) {
        self.text = text
        self.isConnected = isConnected
        self.action = action
    }

    public var body: some View {
        let content = HStack(spacing: Self.gap) {
            Circle()
                .fill(isConnected ? Ledger.accentRecovery : Ledger.accentCaution)
                .frame(width: Self.dotDiameter, height: Self.dotDiameter)
            Text(text)
                .font(LedgerType.label(Self.captionSize, LedgerType.regular))
                .foregroundStyle(Ledger.textTertiary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)

        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
        } else {
            content
        }
    }
}

// MARK: - Trailing slot · score

/// The Sleep board's trailing slot: a large accent numeral over a tracked caption.
///
/// Board: `font-family:'Space Grotesk'; font-size:44px; font-weight:700; letter-spacing:-1.5px;
/// line-height:1; color:#8F9BFF` over `font-size:10.5px; letter-spacing:2px; color:#5C6470;
/// margin-top:3px`.
public struct LedgerHeaderScore: View {
    /// Score numeral — 44pt / 700 (`font-size:44px;font-weight:700`).
    private static let scoreSize: CGFloat = 44
    /// Score tracking — −1.5 (`letter-spacing:-1.5px`).
    private static let scoreTracking: CGFloat = -1.5
    /// Caption — 10.5pt, +2 tracking (`letter-spacing:2px`), 3pt beneath (`margin-top:3px`).
    private static let captionTracking: CGFloat = 2
    private static let captionGap: CGFloat = 3
    /// Shown when there is no score for this night. An em-dash, not prose.
    private static let absentValue = "\u{2014}"

    private let value: String?
    private let caption: String
    private let accent: Color
    private let action: (() -> Void)?

    /// - Parameters:
    ///   - value: the pre-formatted score, e.g. `"82"`. `nil` renders an em-dash in tertiary.
    ///   - caption: the caption beneath it. Default `"SCORE"`, per the board.
    ///   - accent: the domain accent for the numeral — `accent/sleep` on the Sleep board.
    ///   - action: optional tap.
    public init(
        value: String?,
        caption: String = "SCORE",
        accent: Color = Ledger.accentSleep,
        action: (() -> Void)? = nil
    ) {
        self.value = value
        self.caption = caption
        self.accent = accent
        self.action = action
    }

    public var body: some View {
        let content = VStack(alignment: .trailing, spacing: Self.captionGap) {
            Text(value ?? Self.absentValue)
                .font(LedgerType.numeral(Self.scoreSize, LedgerType.bold))
                .tracking(Self.scoreTracking)
                .foregroundStyle(value == nil ? Ledger.textTertiary : accent)
                .lineLimit(1)
            Text(caption)
                .font(LedgerType.overline)
                .tracking(Self.captionTracking)
                .textCase(.uppercase)
                .foregroundStyle(Ledger.textTertiary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)

        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
        } else {
            content
        }
    }
}

// MARK: - Trailing slot · overflow

/// The overflow affordance — the spec's `"…"`, behind which the old 28-destination "More" list now
/// lives (spec §01.7 and §02/§05's "naps, edits, smart alarm / Explorer, Compare, Lab Book").
///
/// Drawn at the header caption's own weight in `text/tertiary`, with a 44pt hit target.
public struct LedgerHeaderOverflow: View {
    /// The glyph size — matched to the header's 12pt caption rank, one weight up so three dots read.
    private static let glyphSize: CGFloat = 17

    private let label: String
    private let action: () -> Void

    /// - Parameters:
    ///   - label: the accessibility label for the affordance. Default `"More"`.
    ///   - action: presents the overflow menu / sheet.
    public init(label: String = "More", action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text("…")
                .font(LedgerType.label(Self.glyphSize, LedgerType.bold))
                .foregroundStyle(Ledger.textTertiary)
                .frame(minWidth: Ledger.rowMinHeight, minHeight: Ledger.rowMinHeight, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

// MARK: - Preview

#if DEBUG
private struct LedgerHeaderPreviewHost: View {
    @State private var range = "90D"

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            // Today — baseline-aligned, sync status trailing.
            LedgerHeader(overline: "FRI · JUL 3", title: "Today") {
                LedgerHeaderSyncStatus(text: "synced · 68%", isConnected: true)
            }

            // Sleep — bottom-aligned, score trailing.
            LedgerHeader(
                overline: "THU 2 → FRI 3 JUL",
                title: "Sleep",
                alignment: .bottom,
                topPadding: 0
            ) {
                LedgerHeaderScore(value: "82", accent: Ledger.accentSleep)
            }

            // Trends — bottom-aligned, range pill trailing.
            LedgerHeader(overline: "LONG VIEW", title: "Trends", alignment: .bottom, topPadding: 0) {
                LedgerRangePill(options: ["7D", "30D", "90D"], selection: $range, label: { $0 })
            }

            // Today with the overflow affordance.
            LedgerHeader(overline: "RECOVERY", title: "Body", alignment: .bottom, topPadding: 0) {
                LedgerHeaderOverflow {}
            }

            // Activity — no trailing slot.
            LedgerHeader(overline: "LOAD & TRAINING", title: "Activity", topPadding: 0)
        }
        .padding(.horizontal, Ledger.pageMargin)
        .padding(.bottom, 24)
        .frame(width: 393)
        .background(Ledger.bgScreen)
    }
}

#Preview("LedgerHeader") {
    LedgerHeaderPreviewHost()
        .preferredColorScheme(.dark)
}
#endif
