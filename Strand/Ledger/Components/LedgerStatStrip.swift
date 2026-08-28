import SwiftUI

// MARK: - LedgerStatStrip — 2–4 numerals divided by vertical hairlines
//
// Board: `NOOP Redesign.dc.html`. Two treatments, both transcribed verbatim.
//
// A · LABEL BELOW — `data-screen-label="Sleep"` (asleep / in bed / efficiency / debt) and
//                   `data-screen-label="Activity"` (kcal / steps / workout time / peak bpm):
//
//   strip    display:flex;
//            border-top:1px solid rgba(255,255,255,.07);
//            border-bottom:1px solid rgba(255,255,255,.07)
//   cell     flex:1; padding:12px 0
//   cell 2+  border-left:1px solid rgba(255,255,255,.06); padding-left:14px
//   value    Space Grotesk 20px / 600     (+ optional suffix 12–13px #5C6470)
//   label    font-size:10.5px; color:#5C6470; margin-top:2px
//
// B · LABEL ABOVE — `data-screen-label="Metric detail"` (MIN / AVG / MAX / Δ 30D / LATEST):
//
//   strip    display:flex; justify-content:space-between;
//            border-top:1px solid rgba(255,255,255,.07); padding-top:14px
//   label    font-size:10.5px; font-weight:700; letter-spacing:1.8px; color:#5C6470
//            ← note: +1.8 tracking, NOT the section overline's +2.4
//   value    Space Grotesk 20px / 600; margin-top:4px
//
// The `.labelAbove` strip has NO vertical hairlines in the board — the five cells are spread by
// `justify-content:space-between` — so `showsCellRules` defaults per style and can be overridden.
//
// MOTION: none. Spec §Motion — rows and text are instant.
//
// PURE PRESENTATION. Every `value` is a pre-formatted string the caller produced from a number
// NOOP already computes; the strip does no formatting, no unit conversion and no arithmetic.

/// A row of 2–4 (the detail strip takes 5) numerals separated by 1px vertical hairlines.
///
/// ```swift
/// LedgerStatStrip([
///     .init(value: "7:09", label: "asleep"),
///     .init(value: "7:52", label: "in bed"),
///     .init(value: "91", suffix: "%", label: "efficiency"),
///     .init(value: "−1.8h", label: "debt · 14n", tint: Ledger.accentCaution),
/// ])
/// ```
public struct LedgerStatStrip: View {

    // MARK: Style

    /// Which of the board's two strip treatments to draw.
    public enum Style: Sendable {
        /// Sleep header / Activity totals — value on top, 10.5pt caption beneath, cells divided by
        /// vertical hairlines, ruled top **and** bottom.
        case labelBelow
        /// Metric-detail stats — a +1.8-tracked overline above the numeral, cells spread edge to
        /// edge with no vertical rules, ruled on top only.
        case labelAbove
    }

    // MARK: Item

    /// One cell of the strip.
    public struct Item {
        /// The numeral, pre-formatted. Rendered Space Grotesk 20/600, tabular.
        public var value: String
        /// An optional small suffix drawn immediately after the numeral — the board's `%` and `h`,
        /// 12pt in `text/tertiary`. Keep unit words in `label`; this is for a single glyph.
        public var suffix: String?
        /// The cell's caption (`.labelBelow`) or overline (`.labelAbove`).
        public var label: String
        /// The numeral's colour. `text/primary` by default; the Sleep debt cell passes
        /// `Ledger.accentCaution` and the detail Δ cell passes `Ledger.accentRecovery`.
        public var tint: Color

        /// - Parameters:
        ///   - value: pre-formatted numeral, e.g. `"7:09"`, `"1,860"`, `"−1.8h"`.
        ///   - suffix: a single trailing glyph in tertiary, e.g. `"%"`. Default `nil`.
        ///   - label: the caption, e.g. `"asleep"`, `"peak bpm"`, `"MIN"`.
        ///   - tint: the numeral's colour. Default `Ledger.textPrimary`.
        public init(value: String, suffix: String? = nil, label: String, tint: Color = Ledger.textPrimary) {
            self.value = value
            self.suffix = suffix
            self.label = label
            self.tint = tint
        }
    }

    // MARK: Board constants

    /// Cell vertical padding — 12pt (`padding:12px 0`), `.labelBelow`.
    private static let cellVerticalPadding: CGFloat = 12
    /// The inset a divided cell gets after its vertical rule — 14pt (`padding-left:14px`).
    private static let cellRuleInset: CGFloat = 14
    /// Vertical cell rule — `rgba(255,255,255,.06)`.
    private static let cellRuleColor = Ledger.white(0.06)
    /// Caption size — 10.5pt, and the gap above it — 2pt (`margin-top:2px`), `.labelBelow`.
    private static let captionSize: CGFloat = 10.5
    private static let captionGap: CGFloat = 2
    /// The suffix glyph — 12pt (the board uses 12 for `%` and 13 for `h`; 12 is the common value).
    private static let suffixSize: CGFloat = 12
    /// `.labelAbove` overline tracking — **1.8**, deliberately tighter than the section overline's
    /// +2.4 (`letter-spacing:1.8px` in the metric-detail board).
    private static let statOverlineTracking: CGFloat = 1.8
    /// `.labelAbove` gap between the overline and its numeral — 4pt (`margin-top:4px`).
    private static let overlineGap: CGFloat = 4
    /// `.labelAbove` padding beneath the top rule — 14pt (`padding-top:14px`).
    private static let topRulePadding: CGFloat = 14
    /// The smallest gap `justify-content:space-between` may collapse to before two `.labelAbove`
    /// cells touch. The boards never get this tight; it exists so a narrow window degrades legibly.
    private static let spreadMinimumGap: CGFloat = 8

    // MARK: Stored

    private let items: [Item]
    private let style: Style
    private let showsTopRule: Bool
    private let showsBottomRule: Bool
    private let showsCellRules: Bool

    /// - Parameters:
    ///   - items: 2–5 cells, left to right. An empty array renders nothing.
    ///   - style: `.labelBelow` (Sleep / Activity) or `.labelAbove` (Metric detail).
    ///   - showsTopRule: the 1px `white @ 7%` section rule above. Default `true` — both boards
    ///     have one.
    ///   - showsBottomRule: the matching rule beneath. Defaults to `true` for `.labelBelow` and
    ///     `false` for `.labelAbove`, matching the boards. Pass explicitly to override.
    ///   - showsCellRules: the 1px `white @ 6%` vertical rules between cells. Defaults to `true`
    ///     for `.labelBelow` and `false` for `.labelAbove`.
    public init(
        _ items: [Item],
        style: Style = .labelBelow,
        showsTopRule: Bool = true,
        showsBottomRule: Bool? = nil,
        showsCellRules: Bool? = nil
    ) {
        self.items = items
        self.style = style
        self.showsTopRule = showsTopRule
        self.showsBottomRule = showsBottomRule ?? (style == .labelBelow)
        self.showsCellRules = showsCellRules ?? (style == .labelBelow)
    }

    // MARK: Body

    public var body: some View {
        if items.isEmpty {
            // Designed empty state: a strip with nothing to say draws nothing at all — an empty
            // ruled band would read as missing data rather than as absent sections.
            EmptyView()
        } else {
            VStack(spacing: 0) {
                if showsTopRule {
                    Rectangle()
                        .fill(Ledger.hairline)
                        .frame(height: Ledger.hairlineWidth)
                }

                cells
                    .padding(.top, style == .labelAbove ? Self.topRulePadding : 0)

                if showsBottomRule {
                    Rectangle()
                        .fill(Ledger.hairline)
                        .frame(height: Ledger.hairlineWidth)
                }
            }
        }
    }

    @ViewBuilder
    private var cells: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let ruled = index > 0 && showsCellRules

                // `.labelBelow` is the board's `flex:1` — every cell takes an equal share.
                // `.labelAbove` is `justify-content:space-between` — cells stay at their intrinsic
                // width and the free space goes into the gaps, so the last cell sits flush right.
                if style == .labelBelow {
                    ruledCell(item, ruled: ruled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ruledCell(item, ruled: ruled)
                    if index < items.count - 1 {
                        Spacer(minLength: Self.spreadMinimumGap)
                    }
                }
            }
        }
    }

    /// The board's `border-left` + `padding-left:14px`, drawn as an **overlay** rather than as a
    /// sibling in the `HStack`. An overlay is sized to the cell it sits on, so the 1px rule spans
    /// exactly the cell's height — a sibling `Rectangle` with `maxHeight: .infinity` would instead
    /// inherit whatever height the enclosing scroll view proposed.
    private func ruledCell(_ item: Item, ruled: Bool) -> some View {
        cell(item)
            .padding(.leading, ruled ? Self.cellRuleInset : 0)
            .overlay(alignment: .leading) {
                if ruled {
                    Rectangle()
                        .fill(Self.cellRuleColor)
                        .frame(width: Ledger.hairlineWidth)
                }
            }
    }

    @ViewBuilder
    private func cell(_ item: Item) -> some View {
        switch style {
        case .labelBelow:
            VStack(alignment: .leading, spacing: Self.captionGap) {
                numeral(item)
                Text(item.label)
                    .font(LedgerType.caption(Self.captionSize))
                    .foregroundStyle(Ledger.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.vertical, Self.cellVerticalPadding)

        case .labelAbove:
            VStack(alignment: .leading, spacing: Self.overlineGap) {
                Text(item.label)
                    .font(LedgerType.overline)
                    .tracking(Self.statOverlineTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(Ledger.textTertiary)
                    .lineLimit(1)
                numeral(item)
            }
        }
    }

    private func numeral(_ item: Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(item.value)
                .ledgerStripNumeral()
                .foregroundStyle(item.tint)
            if let suffix = item.suffix, !suffix.isEmpty {
                Text(suffix)
                    .font(LedgerType.label(Self.suffixSize, LedgerType.regular))
                    .foregroundStyle(Ledger.textTertiary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("LedgerStatStrip") {
    VStack(alignment: .leading, spacing: 28) {
        // Sleep header — the board's four cells, debt in caution.
        LedgerStatStrip([
            .init(value: "7:09", label: "asleep"),
            .init(value: "7:52", label: "in bed"),
            .init(value: "91", suffix: "%", label: "efficiency"),
            .init(value: "−1.8h", label: "debt · 14n", tint: Ledger.accentCaution),
        ])

        // Activity totals.
        LedgerStatStrip([
            .init(value: "1,860", label: "kcal"),
            .init(value: "7,412", label: "steps"),
            .init(value: "1:37", label: "workout time"),
            .init(value: "172", label: "peak bpm"),
        ])

        // Metric detail — label above, no vertical rules.
        LedgerStatStrip([
            .init(value: "44", label: "MIN"),
            .init(value: "58", label: "AVG"),
            .init(value: "71", label: "MAX"),
            .init(value: "+6", label: "Δ 30D", tint: Ledger.accentRecovery),
            .init(value: "62", label: "LATEST"),
        ], style: .labelAbove)
    }
    .padding(.horizontal, Ledger.pageMargin)
    .padding(.vertical, 24)
    .frame(width: 393)
    .background(Ledger.bgScreen)
    .preferredColorScheme(.dark)
}
#endif
