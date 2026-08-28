import SwiftUI

// MARK: - LedgerCoachNote — the insight section
//
// Board: `NOOP Redesign.dc.html` — three instances (Today COACH, Body WATCHING, Trends MEANINGFUL
// CHANGE), each a 2px accent left rule beside a 13.5pt paragraph. That treatment is DELIBERATELY
// NOT reproduced: the side-bar was chrome no other section had (it read as decoration, not
// structure), and the paragraph competed with the data above it. The note now speaks the screens'
// own section grammar — a 1px hairline, an overline row (the accent lives in the overline word and
// the action value, where it carries meaning), and quiet 12pt secondary copy written to fit about
// two lines. Still no background fill: a fill would make it a card, which the cardinal rule bans.
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

    /// The gap between the overline row and the body copy — 6pt.
    private static let titleGap: CGFloat = 6

    /// The action's label and value sizes — the value matches a row value, not a hero.
    private static let actionLabelSize: CGFloat = 10.5
    private static let actionValueSize: CGFloat = 13
    /// `padding-top:14px` under the section hairline — the shared section-header rhythm.
    private static let overlineTop: CGFloat = 14
    /// The copy — 12pt caption-weight secondary, tight line spacing: an aside under the data, not a
    /// paragraph competing with it. Written to fit about two lines; the style keeps it quiet.
    private static let bodySize: CGFloat = 12
    private static let bodyLineSpacing: CGFloat = 3.5

    // MARK: Action row

    /// One concrete, tonight-sized instruction under the paragraph — a small accent label and a
    /// numeral-weight value ("TONIGHT · 8:40 in bed"). Optional; the boards' notes carry none, so
    /// nothing changes for a caller that does not pass one.
    public struct Action {
        /// The row's label ("TONIGHT"). Uppercased by the style.
        public let label: String
        /// The row's value ("8:40 in bed"), rendered in the numeral face.
        public let value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    // MARK: Stored

    private let title: String
    private let message: String
    private let accent: Color
    private let action: Action?

    /// - Parameters:
    ///   - title: the accent overline, e.g. `"COACH"` / `"WATCHING"` / `"MEANINGFUL CHANGE"`.
    ///     Uppercased by the style; pass it in whatever case reads best in source.
    ///   - message: one paragraph of deterministic copy. Blank or whitespace-only renders nothing.
    ///   - accent: the domain accent for both the rule and the overline.
    ///   - action: an optional concrete instruction row beneath the paragraph. Default `nil`.
    public init(title: String, message: String, accent: Color = Ledger.accentRecovery,
                action: Action? = nil) {
        self.title = title
        self.message = message
        self.accent = accent
        self.action = action
    }

    // MARK: Body

    public var body: some View {
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // "Renders nothing when quiet" — no rule, no reserved height.
            EmptyView()
        } else {
            // The screens' own section grammar — a 1px hairline over an overline row — instead of
            // the board's 2px accent side-bar, which read as a decoration no other section had.
            // The accent survives where it carries meaning: the overline word and the action value.
            VStack(alignment: .leading, spacing: 0) {
                Rectangle()
                    .fill(Ledger.hairline)
                    .frame(height: Ledger.hairlineWidth)

                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .ledgerOverline(accent)
                    if let action {
                        Spacer(minLength: Ledger.rowGap)
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(action.label)
                                .font(LedgerType.label(Self.actionLabelSize, LedgerType.bold))
                                .tracking(2.4)
                                .textCase(.uppercase)
                                .foregroundStyle(Ledger.textTertiary)
                            Text(action.value)
                                .font(LedgerType.numeral(Self.actionValueSize, LedgerType.semibold))
                                .foregroundStyle(accent)
                                .monospacedDigit()
                        }
                    }
                }
                .padding(.top, Self.overlineTop)

                Text(message)
                    .font(LedgerType.label(Self.bodySize, LedgerType.regular))
                    .foregroundStyle(Ledger.textSecondary)
                    .lineSpacing(Self.bodyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Self.titleGap)
            }
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
