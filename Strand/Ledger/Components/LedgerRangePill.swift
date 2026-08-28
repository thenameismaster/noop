import SwiftUI

// MARK: - LedgerRangePill — the ONLY raised control in the Ledger
//
// Board: `NOOP Redesign.dc.html` → `data-screen-label="Trends"` (7D/30D/90D) and
// `data-screen-label="Metric detail"` (7D/30D/90D/1Y/ALL). Transcribed verbatim:
//
//   pill      display:flex; gap:2px;
//             background:#10131A;                        ← bg/raised
//             border:1px solid rgba(255,255,255,.07);     ← hairline
//             border-radius:999px; padding:3px
//   segment   padding:5px 12px  (Trends) / 5px 13px (Metric detail);
//             border-radius:999px; font-size:11.5px; font-weight:600; color:#5C6470
//   selected  font-weight:700; color:#0A0C11; background:#F2F4F7
//
// THE INVERSION IS THE POINT. Spec §05: *"selected segment inverts to paper-on-ink (`#F2F4F7` bg,
// `#0A0C11` text)"* — the selected chip is the only place in the whole design where `bg/screen`
// is used as a *foreground* colour.
//
// AND IT IS THE ONE PLACE `bg/raised` MAY APPEAR. Cardinal rule: `#10131A` is for CONTROLS ONLY.
// This is that control. Nothing else in `Strand/Ledger/**` should fill with `Ledger.bgRaised`.
//
// MOTION: none. Spec §Motion — *"Rows/text: no entrance animation — content is instant; only
// data-viz animates."* A segmented control is chrome, so the selection swaps instantly; there is
// deliberately no sliding `matchedGeometryEffect` thumb.
//
// PURE PRESENTATION. Generic over any `Hashable` option, so a screen binds its own
// `ExploreRange` (or a `String`) without this component importing anything from the data layer.
// `isEnabled` is how `ExploreRangeGating` reaches the UI: a gated range dims and stops taking taps,
// but the component itself knows nothing about why.

/// A segmented capsule control. The selected segment inverts to paper-on-ink.
///
/// ```swift
/// LedgerRangePill(
///     options: ExploreRange.allCases,
///     selection: $range,
///     label: \.shortTitle,
///     isEnabled: { gating.allows($0) }
/// )
/// ```
public struct LedgerRangePill<Option: Hashable>: View {

    // MARK: Board constants

    /// Gap between segments — 2pt (`gap:2px`).
    private static var segmentGap: CGFloat { 2 }
    /// The pill's inner padding around its segments — 3pt (`padding:3px`).
    private static var pillPadding: CGFloat { 3 }
    /// Segment vertical padding — 5pt (`padding:5px …`).
    private static var segmentVerticalPadding: CGFloat { 5 }
    /// Segment label — 11.5pt, 600 unselected / 700 selected.
    private static var segmentFontSize: CGFloat { 11.5 }
    /// A disabled (data-gated) segment's opacity. Nothing in the boards is gated, so this is the
    /// one value here the boards do not state; it is the standard SwiftUI disabled step.
    private static var disabledOpacity: Double { 0.4 }

    // MARK: Stored

    private let options: [Option]
    @Binding private var selection: Option
    private let label: (Option) -> String
    private let isEnabled: (Option) -> Bool
    private let horizontalPadding: CGFloat

    /// - Parameters:
    ///   - options: the segments, left to right. An empty array renders nothing.
    ///   - selection: the bound selection. Tapping a segment writes it directly.
    ///   - label: the segment's text, e.g. `"7D"`, `"30D"`, `"90D"`, `"1Y"`, `"ALL"`.
    ///   - isEnabled: `false` dims a segment and makes it untappable — the hook for
    ///     `ExploreRangeGating`, which hides ranges a user has no history for. Default: all enabled.
    ///   - horizontalPadding: segment horizontal padding. **12** is the board's three-segment
    ///     Trends pill; the five-segment metric-detail pill uses **13**.
    public init(
        options: [Option],
        selection: Binding<Option>,
        label: @escaping (Option) -> String,
        isEnabled: @escaping (Option) -> Bool = { _ in true },
        horizontalPadding: CGFloat = 12
    ) {
        self.options = options
        self._selection = selection
        self.label = label
        self.isEnabled = isEnabled
        self.horizontalPadding = horizontalPadding
    }

    // MARK: Body

    public var body: some View {
        if options.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: Self.segmentGap) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    segment(option)
                }
            }
            .padding(Self.pillPadding)
            .background(
                Capsule(style: .continuous)
                    .fill(Ledger.bgRaised)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Ledger.hairline, lineWidth: Ledger.hairlineWidth)
            )
            .fixedSize()
        }
    }

    @ViewBuilder
    private func segment(_ option: Option) -> some View {
        let selected = option == selection
        let enabled = isEnabled(option)

        Button {
            guard enabled else { return }
            selection = option
        } label: {
            Text(label(option))
                .font(LedgerType.label(Self.segmentFontSize, selected ? LedgerType.bold : LedgerType.semibold))
                .foregroundStyle(selected ? Ledger.bgScreen : Ledger.textTertiary)
                .lineLimit(1)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, Self.segmentVerticalPadding)
                .background(
                    Capsule(style: .continuous)
                        // Paper-on-ink: the selected chip is filled with `text/primary`.
                        .fill(selected ? Ledger.textPrimary : Color.clear)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : Self.disabledOpacity)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Preview

#if DEBUG
private struct LedgerRangePillPreviewHost: View {
    @State private var trends = "90D"
    @State private var detail = "30D"

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            // Trends — three segments, 12pt segment padding.
            LedgerRangePill(
                options: ["7D", "30D", "90D"],
                selection: $trends,
                label: { $0 }
            )

            // Metric detail — five segments, 13pt segment padding, ALL gated off.
            LedgerRangePill(
                options: ["7D", "30D", "90D", "1Y", "ALL"],
                selection: $detail,
                label: { $0 },
                isEnabled: { $0 != "ALL" },
                horizontalPadding: 13
            )
        }
        .padding(.horizontal, Ledger.pageMargin)
        .padding(.vertical, 24)
        .frame(width: 393, alignment: .leading)
        .background(Ledger.bgScreen)
    }
}

#Preview("LedgerRangePill") {
    LedgerRangePillPreviewHost()
        .preferredColorScheme(.dark)
}
#endif
