import SwiftUI

// MARK: - LedgerCoachNote — the left-ruled insight block
//
// Board: `NOOP Redesign.dc.html` — three instances, identical apart from the accent:
//   Today   COACH             `border-left:2px solid #3EE6A8`
//   Body    WATCHING          `border-left:2px solid #F2C14E`
//   Trends  MEANINGFUL CHANGE `border-left:2px solid #3EE6A8`
//
// Transcribed verbatim:
//
//   block    border-left:2px solid <accent>; padding:2px 0 2px 14px
//            (margin:16–18px 24px 22px — the screen owns those; this view owns the inner box)
//   title    font-size:10.5px; font-weight:700; letter-spacing:2.4px; color:<accent>
//   body     font-size:13.5px; line-height:1.55; color:#C9CFD8; margin-top:6px
//
// **NO BACKGROUND FILL.** Spec §Layout: *"Coach/insight blocks: 2px left rule in the domain accent,
// no background fill, one per screen max."* A fill here would make it a card, which the cardinal
// rule bans. The 2px rule is the entire chrome.
//
// ONE PER SCREEN, MAXIMUM — that is a screen-builder rule this view cannot enforce; it is stated
// here so nobody stacks two.
//
// EMPTY = ABSENT. An empty (or whitespace-only) message renders nothing at all, which is exactly
// what the Body screen's WATCHING block needs: spec §03 — *"renders nothing when quiet"*. It does
// not draw an empty rule, and it does not reserve height.
//
// MOTION: none. Text is instant (spec §Motion).

/// A left-ruled coach/insight note: an accent overline over one paragraph of copy, with a 2px rule
/// in the domain accent and no fill.
///
/// ```swift
/// LedgerCoachNote(
///     title: "COACH",
///     message: "Green light for intensity. Recovery 74 puts today's optimal strain at 11.6–15.2.",
///     accent: Ledger.accentRecovery
/// )
/// ```
public struct LedgerCoachNote: View {

    // MARK: Board constants

    /// The gap between the rule and the copy — 14pt (`padding-left:14px`).
    private static let rulePadding: CGFloat = 14
    /// The block's own vertical padding — 2pt top and bottom (`padding:2px 0 2px 14px`).
    private static let verticalPadding: CGFloat = 2
    /// The gap between the overline and the body copy — 6pt (`margin-top:6px`).
    private static let titleGap: CGFloat = 6

    // MARK: Stored

    private let title: String
    private let message: String
    private let accent: Color

    /// - Parameters:
    ///   - title: the accent overline, e.g. `"COACH"` / `"WATCHING"` / `"MEANINGFUL CHANGE"`.
    ///     Uppercased by the style; pass it in whatever case reads best in source.
    ///   - message: one paragraph of deterministic copy. Blank or whitespace-only renders nothing.
    ///   - accent: the domain accent for both the rule and the overline.
    public init(title: String, message: String, accent: Color = Ledger.accentRecovery) {
        self.title = title
        self.message = message
        self.accent = accent
    }

    // MARK: Body

    public var body: some View {
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // "Renders nothing when quiet" — no rule, no reserved height.
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: Self.rulePadding) {
                // The 2px left rule, matched to the content's height.
                Rectangle()
                    .fill(accent)
                    .frame(width: Ledger.coachRuleWidth)

                VStack(alignment: .leading, spacing: Self.titleGap) {
                    Text(title)
                        .ledgerOverline(accent)
                    Text(message)
                        .ledgerCoachBody()
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, Self.verticalPadding)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("LedgerCoachNote") {
    VStack(alignment: .leading, spacing: 28) {
        LedgerCoachNote(
            title: "Coach",
            message: "Green light for intensity. Recovery 74 puts today's optimal strain at 11.6–15.2. In bed by 23:00 keeps your sleep-debt trend falling.",
            accent: Ledger.accentRecovery
        )

        LedgerCoachNote(
            title: "Watching",
            message: "Monday's dip followed two short nights. Fully recovered since — no illness signature in temp or respiratory.",
            accent: Ledger.accentCaution
        )

        LedgerCoachNote(
            title: "Meaningful change",
            message: "HRV baseline is up +6 ms over 90 days while resting HR fell 2 bpm. Aerobic base is building.",
            accent: Ledger.accentRecovery
        )

        // Quiet: renders nothing.
        LedgerCoachNote(title: "Watching", message: "   ", accent: Ledger.accentCaution)
    }
    .padding(.horizontal, Ledger.pageMargin)
    .padding(.vertical, 24)
    .frame(width: 393)
    .background(Ledger.bgScreen)
    .preferredColorScheme(.dark)
}
#endif
