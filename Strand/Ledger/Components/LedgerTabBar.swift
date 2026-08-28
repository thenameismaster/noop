import SwiftUI

// MARK: - LedgerTabBar — five line-icon tabs
//
// Board: `NOOP Redesign.dc.html` → `data-screen-label="Today"`, the bottom bar.
// Transcribed verbatim:
//
//   bar      display:flex; justify-content:space-around;
//            padding:12px 8px 26px;
//            border-top:1px solid rgba(255,255,255,.06)
//   item     text-align:center; min-width:52px
//            <svg width="20" height="20" viewBox="0 0 22 22"> stroke-width="1.8"
//   label    font-size:10px; margin-top:3px
//            active   font-weight:600, inherits #F2F4F7
//            inactive color:#5C6470
//
// The five icons, transcribed from their SVG `d` attributes (viewBox `0 0 22 22`):
//
//   Today     <circle r="7.5" stroke="…" stroke-width="1.8">  +  <circle r="2.4" fill="#3EE6A8">
//   Sleep     M4 14 Q8 6 11 11 T18 8      +  M11 19 A 8.5 8.5 0 1 1 19.5 11
//   Body      M3 12 h4 l2-5 3 9 2-4 h5
//   Activity  M4 18 V10  M11 18 V4  M18 18 V13
//   Trends    M4 16 L9 10 L13 13 L18 6    +  <circle cx="18" cy="6" r="1.6" fill="…">
//
// THE MINT DOT. Two of the five glyphs carry a filled dot as part of the drawing — Today's inner
// pip and Trends' terminal point. The board paints Today's pip `#3EE6A8` while Today is the active
// tab; that IS the spec's *"Active = white icon + a mint dot detail"*. So: a tab's strokes go
// `text/primary` when active and `text/tertiary` when not, and a glyph's dot (where the SVG has
// one) goes `accent/recovery` when active and `text/tertiary` when not. Sleep, Body and Activity
// have no dot in the board and therefore do not grow one — the boards are the source of truth.
//
// MOTION: none. Chrome is instant (spec §Motion). The 240 ms tab crossfade belongs to the content
// the shell swaps, not to this bar; the shell applies `LedgerMotion.tabCrossfade` there.
//
// PURE PRESENTATION. It renders a `[LedgerTab]` and reports taps. It owns no `TabRoute`, no
// `NavigationPath` and no selection state.

/// One of the Ledger's five tabs.
///
/// The order of `allCases` is the board's order — Today · Sleep · Body · Activity · Trends.
public enum LedgerTab: String, CaseIterable, Hashable, Sendable {
    case today, sleep, body, activity, trends

    /// The bar's caption, per the board.
    public var title: String {
        switch self {
        case .today:    return "Today"
        case .sleep:    return "Sleep"
        case .body:     return "Body"
        case .activity: return "Activity"
        case .trends:   return "Trends"
        }
    }
}

/// The Ledger's five-tab bar: a 1px top rule, five 20pt line icons, and 10pt captions.
///
/// ```swift
/// LedgerTabBar(selection: $tab)
/// ```
public struct LedgerTabBar: View {

    // MARK: Board constants

    /// Icon box — 20pt (`width="20" height="20"`), drawn from a 22-unit viewBox.
    private static let iconSize: CGFloat = 20
    /// Icon stroke — 1.8pt (`stroke-width="1.8"`), authored in the 22-unit viewBox.
    private static let iconStrokeWidth: CGFloat = 1.8
    /// Caption — 10pt (`font-size:10px`), 3pt beneath the icon (`margin-top:3px`).
    private static let captionSize: CGFloat = 10
    private static let captionGap: CGFloat = 3
    /// Each tab's minimum width — 52pt (`min-width:52px`).
    private static let tabMinWidth: CGFloat = 52
    /// Bar padding — `padding:12px 8px 26px`. The 26pt bottom is the board's home-indicator gutter;
    /// a real device supplies its own safe-area inset, so it is exposed as `bottomPadding`.
    private static let barTopPadding: CGFloat = 12
    private static let barHorizontalPadding: CGFloat = 8

    /// The board's bottom gutter — **26pt**. `public` because it is the default value of a public
    /// initializer parameter, and a host that supplies its own safe-area inset needs to name it.
    public static let barBottomPadding: CGFloat = 26
    /// The bar's top rule — `rgba(255,255,255,.06)`, one step softer than a section hairline.
    private static let barRuleColor = Ledger.white(0.06)

    /// The caption's reserved line box. Pinned rather than left to the font's own line height so the
    /// bar's total height is EXACTLY computable — see `reservedHeight`, which a host relies on to keep
    /// scroll content clear of the bar. 13pt comfortably fits the 10pt caption.
    private static let captionLineHeight: CGFloat = 13

    /// The vertical space the bar occupies above the host's bottom safe area.
    ///
    /// A host that draws this bar OVER its content (the iOS Ledger shell does — the pages hide the
    /// system tab bar and extend beneath it) must reserve this much at the bottom of its scroll
    /// content, or the last section of a screen is unreachable underneath the bar. Derived from the
    /// same constants the body lays out with, so the two cannot drift apart.
    public static let reservedHeight: CGFloat =
        Ledger.hairlineWidth + barTopPadding + iconSize + captionGap + captionLineHeight + barBottomPadding

    // MARK: Stored

    private let tabs: [LedgerTab]
    @Binding private var selection: LedgerTab
    private let bottomPadding: CGFloat
    private let onReselect: ((LedgerTab) -> Void)?

    /// - Parameters:
    ///   - tabs: the tabs to show. Defaults to all five, in the board's order.
    ///   - selection: the bound active tab.
    ///   - bottomPadding: the gutter beneath the captions. The board's 26pt by default; pass `0`
    ///     when the host already applies a safe-area inset.
    ///   - onReselect: called when the already-selected tab is tapped again — the shell's
    ///     pop-to-root / scroll-to-top hook. `nil` makes a re-tap inert.
    public init(
        tabs: [LedgerTab] = LedgerTab.allCases,
        selection: Binding<LedgerTab>,
        bottomPadding: CGFloat = LedgerTabBar.barBottomPadding,
        onReselect: ((LedgerTab) -> Void)? = nil
    ) {
        self.tabs = tabs
        self._selection = selection
        self.bottomPadding = bottomPadding
        self.onReselect = onReselect
    }

    // MARK: Body

    public var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Self.barRuleColor)
                .frame(height: Ledger.hairlineWidth)

            HStack(spacing: 0) {
                ForEach(tabs, id: \.self) { tab in
                    item(tab)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, Self.barTopPadding)
            .padding(.horizontal, Self.barHorizontalPadding)
            .padding(.bottom, bottomPadding)
        }
        .background(Ledger.bgScreen)
    }

    @ViewBuilder
    private func item(_ tab: LedgerTab) -> some View {
        let active = tab == selection

        Button {
            if active {
                onReselect?(tab)
            } else {
                selection = tab
            }
        } label: {
            VStack(spacing: Self.captionGap) {
                LedgerTabGlyph(tab: tab)
                    .stroked(
                        color: active ? Ledger.textPrimary : Ledger.textTertiary,
                        dotColor: active ? Ledger.accentRecovery : Ledger.textTertiary,
                        lineWidth: Self.iconStrokeWidth * (Self.iconSize / LedgerTabGlyph.viewBox)
                    )
                    .frame(width: Self.iconSize, height: Self.iconSize)

                Text(tab.title)
                    .font(LedgerType.label(Self.captionSize, active ? LedgerType.semibold : LedgerType.regular))
                    .foregroundStyle(active ? Ledger.textPrimary : Ledger.textTertiary)
                    .lineLimit(1)
                    // Pinned so the bar's height is exactly `reservedHeight` — the value the shell
                    // reserves beneath its scroll content. Also keeps the bar from changing height
                    // between the regular and semibold captions of the active item.
                    .frame(height: Self.captionLineHeight)
            }
            .frame(minWidth: Self.tabMinWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(tab.title))
        .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - The five board glyphs

/// The tab-bar line icons, transcribed from the board's SVG `d` attributes and authored in its
/// `0 0 22 22` viewBox.
///
/// A glyph is drawn as two layers, because that is how the SVGs are built: a **stroked** path
/// (1.8pt, round caps and joins) and an optional **filled dot**. Rendering them separately is what
/// lets the active state paint the strokes white and the dot mint without a second copy of the art.
struct LedgerTabGlyph {
    /// The viewBox the geometry below is authored in — `0 0 22 22`.
    static let viewBox: CGFloat = 22

    let tab: LedgerTab

    /// The stroked outline layer.
    var strokeShape: LedgerTabStrokeShape { LedgerTabStrokeShape(tab: tab) }

    /// The filled dot layer, when the glyph has one (Today's pip, Trends' terminal point).
    var dotShape: LedgerTabDotShape? {
        switch tab {
        // `<circle cx="11" cy="11" r="2.4">` inside the Today ring.
        case .today:  return LedgerTabDotShape(center: CGPoint(x: 11, y: 11), radius: 2.4)
        // `<circle cx="18" cy="6" r="1.6">` at the end of the Trends line.
        case .trends: return LedgerTabDotShape(center: CGPoint(x: 18, y: 6), radius: 1.6)
        case .sleep, .body, .activity: return nil
        }
    }

    /// Draws the glyph: strokes in `color`, dot (if any) in `dotColor`.
    @ViewBuilder
    func stroked(color: Color, dotColor: Color, lineWidth: CGFloat) -> some View {
        ZStack {
            strokeShape
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            if let dotShape {
                dotShape.fill(dotColor)
            }
        }
    }
}

/// The stroked layer of a tab glyph.
struct LedgerTabStrokeShape: Shape {
    let tab: LedgerTab

    func path(in rect: CGRect) -> Path {
        let s = rect.width / LedgerTabGlyph.viewBox
        let t = rect.height / LedgerTabGlyph.viewBox
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * s, y: rect.minY + y * t)
        }

        var path = Path()
        switch tab {
        case .today:
            // `<circle cx="11" cy="11" r="7.5">`
            path.addEllipse(in: CGRect(
                x: rect.minX + (11 - 7.5) * s,
                y: rect.minY + (11 - 7.5) * t,
                width: 15 * s,
                height: 15 * t
            ))

        case .sleep:
            // `M4 14 Q8 6 11 11 T18 8` — the second segment's control point is the reflection of
            // (8,6) about (11,11), i.e. (14,16).
            path.move(to: point(4, 14))
            path.addQuadCurve(to: point(11, 11), control: point(8, 6))
            path.addQuadCurve(to: point(18, 8), control: point(14, 16))

            // `M11 19 A 8.5 8.5 0 1 1 19.5 11` — the SVG endpoint arc, converted to centre form:
            // centre (11.015, 10.5), r 8.5, sweeping 90.10° → 363.37° (large-arc, positive sweep).
            path.move(to: point(11, 19))
            path.addArc(
                center: point(11.015, 10.5),
                radius: 8.5 * s,
                startAngle: .degrees(90.10),
                endAngle: .degrees(363.37),
                clockwise: false
            )

        case .body:
            // `M3 12 h4 l2-5 3 9 2-4 h5`
            path.move(to: point(3, 12))
            path.addLine(to: point(7, 12))
            path.addLine(to: point(9, 7))
            path.addLine(to: point(12, 16))
            path.addLine(to: point(14, 12))
            path.addLine(to: point(19, 12))

        case .activity:
            // `M4 18 V10  M11 18 V4  M18 18 V13`
            path.move(to: point(4, 18));  path.addLine(to: point(4, 10))
            path.move(to: point(11, 18)); path.addLine(to: point(11, 4))
            path.move(to: point(18, 18)); path.addLine(to: point(18, 13))

        case .trends:
            // `M4 16 L9 10 L13 13 L18 6`
            path.move(to: point(4, 16))
            path.addLine(to: point(9, 10))
            path.addLine(to: point(13, 13))
            path.addLine(to: point(18, 6))
        }
        return path
    }
}

/// The filled-dot layer of a tab glyph — the "mint dot detail" when its tab is active.
struct LedgerTabDotShape: Shape {
    /// Centre, in the 22-unit viewBox.
    let center: CGPoint
    /// Radius, in the 22-unit viewBox.
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let s = rect.width / LedgerTabGlyph.viewBox
        let t = rect.height / LedgerTabGlyph.viewBox
        return Path(ellipseIn: CGRect(
            x: rect.minX + (center.x - radius) * s,
            y: rect.minY + (center.y - radius) * t,
            width: radius * 2 * s,
            height: radius * 2 * t
        ))
    }
}

// MARK: - Preview

#if DEBUG
private struct LedgerTabBarPreviewHost: View {
    @State private var tab: LedgerTab = .today

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Text(tab.title)
                .ledgerScreenTitle()
                .foregroundStyle(Ledger.textPrimary)
            Spacer()
            LedgerTabBar(selection: $tab) { _ in }
        }
        .frame(width: 393, height: 320)
        .background(Ledger.bgScreen)
    }
}

#Preview("LedgerTabBar") {
    LedgerTabBarPreviewHost()
        .preferredColorScheme(.dark)
}
#endif
