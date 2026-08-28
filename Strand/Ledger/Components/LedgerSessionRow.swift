import SwiftUI

// MARK: - LedgerSessionRow — the Activity sessions list row
//
// Board: `NOOP Redesign.dc.html` → `data-screen-label="Activity"`, SESSIONS · TODAY.
// Transcribed from the inline CSS/SVG, verbatim:
//
//   row      display:flex; align-items:center; gap:14px; padding:13px 0;
//            border-bottom:1px solid rgba(255,255,255,.05)
//   tile     width:38px; height:38px; border-radius:12px;
//            background:rgba(88,185,255,.08);            ← accent @ 8%
//            border:1px solid rgba(88,185,255,.22);      ← accent @ 22%
//            display:grid; place-items:center
//            <svg width="17" height="17" viewBox="0 0 18 18">
//              stroke="#58B9FF" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"
//   middle   flex:1
//            · name  font-size:14px; font-weight:600            (text/primary)
//            · meta  font-size:11.5px; color:#5C6470; margin-top:2px
//   right    text-align:right
//            · strain   Space Grotesk 16px / 600
//            · caption  font-size:10.5px; color:#5C6470
//
// The tile fill/border are the ONLY tinted surfaces in the Ledger, and they are not a card behind
// data — they are an icon chip. The row's numbers still draw straight on `bg/screen`.
//
// MOTION: none. Rows are instant (spec §Motion).
//
// PURE PRESENTATION. `name`, `meta` and `strain` are pre-formatted strings; the row does not read a
// workout, does not compute a strain and does not know what `EffortScale` the caller displayed on.

/// The line icon drawn inside a session row's 38pt tile.
///
/// The two board icons are reproduced as exact `Path`s from their SVG `d` attributes (viewBox
/// `0 0 18 18`, 1.7pt round strokes). `.symbol` is the escape hatch for a session type the boards
/// do not draw — it renders the nearest SF Symbol at the same weight, per the spec's
/// *"implement as SF Symbols nearest-equivalents or 1.7pt custom Paths"*.
public enum LedgerSessionIcon: Equatable {
    /// The board's running/interval glyph — `M4 15 L8 9 L11 12 L15 4`.
    case cardio
    /// The board's strength glyph — `M3 9 h3 M12 9 h3 M6 6 v6 M12 6 v6 M6 9 h6`.
    case strength
    /// Any other session type, as an SF Symbol name.
    case symbol(String)
}

/// An Activity session row: a tinted 38pt icon tile, a name + meta line, and the session's strain.
///
/// ```swift
/// LedgerSessionRow(
///     icon: .cardio,
///     name: "Interval run",
///     meta: "06:10 · 42m · 6.8 km · avg 158 bpm",
///     strain: "9.8"
/// ) { path.append(TabRoute.workouts) }
/// ```
public struct LedgerSessionRow: View {

    // MARK: Board constants

    /// The icon inside the 38pt tile is drawn at 17pt (`width="17" height="17"`).
    private static let iconSize: CGFloat = 17
    /// The icons' SVG viewBox — `0 0 18 18`. Paths below are authored in this space and scaled.
    private static let iconViewBox: CGFloat = 18
    /// Icon stroke — 1.7pt (`stroke-width="1.7"`), round caps and joins.
    private static let iconStrokeWidth: CGFloat = 1.7
    /// Session name — 14pt / 600 (`font-size:14px;font-weight:600`).
    private static let nameSize: CGFloat = 14
    /// Meta line — 11.5pt (`font-size:11.5px`), and its 2pt gap (`margin-top:2px`).
    private static let metaSize: CGFloat = 11.5
    private static let metaGap: CGFloat = 2
    /// Strain numeral — 16pt / 600 (`font-size:16px;font-weight:600`).
    private static let strainSize: CGFloat = 16
    /// The `strain` caption beneath it — 10.5pt (`font-size:10.5px`).
    private static let captionSize: CGFloat = 10.5
    /// Row vertical padding — 13pt (`padding:13px 0`).
    private static let rowVerticalPadding: CGFloat = 13
    /// Shown for a session whose strain has not been scored. An em-dash, not prose.
    private static let absentValue = "\u{2014}"


    // MARK: Stored

    private let icon: LedgerSessionIcon
    private let name: String
    private let meta: String?
    private let strain: String?
    private let strainCaption: String
    private let accent: Color
    private let showsDivider: Bool
    private let action: (() -> Void)?

    /// - Parameters:
    ///   - icon: the tile glyph. `.cardio` / `.strength` are the board's own paths.
    ///   - name: the session title, e.g. `"Interval run"`. 14/600, `text/primary`.
    ///   - meta: the single meta line, e.g. `"06:10 · 42m · 6.8 km · avg 158 bpm"`. Pre-joined by
    ///     the caller — this row does not decide which facts a session shows.
    ///   - strain: the session's strain, pre-formatted on whatever `EffortScale` the caller
    ///     resolved. `nil` renders an em-dash — a session whose strain has not been scored yet.
    ///   - strainCaption: the caption beneath it. Default `"strain"`, per the board.
    ///   - accent: the tile's tint. `accent/strain` per the board; a domain override is allowed.
    ///   - showsDivider: draws the 1px `white @ 5%` rule beneath. `false` on the last row.
    ///   - action: tap destination (`WorkoutDetailView(row:)`). `nil` renders a static row.
    public init(
        icon: LedgerSessionIcon = .cardio,
        name: String,
        meta: String? = nil,
        strain: String?,
        strainCaption: String = "strain",
        accent: Color = Ledger.accentStrain,
        showsDivider: Bool = true,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.name = name
        self.meta = meta
        self.strain = strain
        self.strainCaption = strainCaption
        self.accent = accent
        self.showsDivider = showsDivider
        self.action = action
    }

    // MARK: Body

    public var body: some View {
        if let action {
            Button(action: action) { rowContent }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: Ledger.rowGap) {
                tile

                VStack(alignment: .leading, spacing: Self.metaGap) {
                    Text(name)
                        .font(LedgerType.label(Self.nameSize, LedgerType.semibold))
                        .foregroundStyle(Ledger.textPrimary)
                        .lineLimit(1)
                    if let meta, !meta.isEmpty {
                        Text(meta)
                            .font(LedgerType.label(Self.metaSize, LedgerType.regular))
                            .foregroundStyle(Ledger.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 0) {
                    Text(strain ?? Self.absentValue)
                        .ledgerRowValue(Self.strainSize)
                        .foregroundStyle(strain == nil ? Ledger.textTertiary : Ledger.textPrimary)
                    Text(strainCaption)
                        .font(LedgerType.caption(Self.captionSize))
                        .foregroundStyle(Ledger.textTertiary)
                }
                .lineLimit(1)
            }
            .padding(.vertical, Self.rowVerticalPadding)
            .frame(minHeight: Ledger.rowMinHeight)

            if showsDivider {
                Rectangle()
                    .fill(Ledger.hairlineSoft)
                    .frame(height: Ledger.hairlineWidth)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Icon tile

    private var tile: some View {
        RoundedRectangle(cornerRadius: Ledger.iconTileRadius, style: .continuous)
            .fill(accent.opacity(Ledger.iconTileFillOpacity))
            .overlay(
                RoundedRectangle(cornerRadius: Ledger.iconTileRadius, style: .continuous)
                    .strokeBorder(accent.opacity(Ledger.iconTileBorderOpacity), lineWidth: Ledger.hairlineWidth)
            )
            .overlay(glyph)
            .frame(width: Ledger.iconTileSize, height: Ledger.iconTileSize)
    }

    @ViewBuilder
    private var glyph: some View {
        switch icon {
        case .cardio:
            LedgerSessionGlyph.cardio
                .stroke(accent, style: strokeStyle)
                .frame(width: Self.iconSize, height: Self.iconSize)
        case .strength:
            LedgerSessionGlyph.strength
                .stroke(accent, style: strokeStyle)
                .frame(width: Self.iconSize, height: Self.iconSize)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: Self.iconSize * 0.82, weight: .medium))
                .foregroundStyle(accent)
        }
    }

    private var strokeStyle: StrokeStyle {
        // The 1.7pt stroke is authored in the 18-unit viewBox and drawn at 17pt, so it scales by
        // 17/18 exactly as the SVG's own stroke does.
        StrokeStyle(
            lineWidth: Self.iconStrokeWidth * (Self.iconSize / Self.iconViewBox),
            lineCap: .round,
            lineJoin: .round
        )
    }
}

// MARK: - The two board glyphs

/// The session-tile line icons, transcribed from the board's SVG `d` attributes.
///
/// Both are authored in the SVG's `0 0 18 18` viewBox and scaled into whatever rect they are given,
/// so the shapes stay exact at any size.
struct LedgerSessionGlyph: Shape {
    /// The SVG path commands, already resolved to absolute points in the 18×18 viewBox.
    private let subpaths: [[CGPoint]]

    private init(_ subpaths: [[CGPoint]]) {
        self.subpaths = subpaths
    }

    /// `M4 15 L8 9 L11 12 L15 4` — the interval/run zigzag.
    static let cardio = LedgerSessionGlyph([[
        CGPoint(x: 4, y: 15), CGPoint(x: 8, y: 9), CGPoint(x: 11, y: 12), CGPoint(x: 15, y: 4),
    ]])

    /// `M3 9 h3  M12 9 h3  M6 6 v6  M12 6 v6  M6 9 h6` — the dumbbell.
    static let strength = LedgerSessionGlyph([
        [CGPoint(x: 3, y: 9), CGPoint(x: 6, y: 9)],
        [CGPoint(x: 12, y: 9), CGPoint(x: 15, y: 9)],
        [CGPoint(x: 6, y: 6), CGPoint(x: 6, y: 12)],
        [CGPoint(x: 12, y: 6), CGPoint(x: 12, y: 12)],
        [CGPoint(x: 6, y: 9), CGPoint(x: 12, y: 9)],
    ])

    /// The viewBox the points above are authored in — `0 0 18 18`.
    private static let viewBox: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        let scaleX = rect.width / Self.viewBox
        let scaleY = rect.height / Self.viewBox
        var path = Path()
        for points in subpaths {
            guard let first = points.first else { continue }
            path.move(to: CGPoint(x: rect.minX + first.x * scaleX, y: rect.minY + first.y * scaleY))
            for point in points.dropFirst() {
                path.addLine(to: CGPoint(x: rect.minX + point.x * scaleX, y: rect.minY + point.y * scaleY))
            }
        }
        return path
    }
}

// MARK: - Preview

#if DEBUG
#Preview("LedgerSessionRow") {
    VStack(spacing: 0) {
        LedgerSessionRow(
            icon: .cardio,
            name: "Interval run",
            meta: "06:10 · 42m · 6.8 km · avg 158 bpm",
            strain: "9.8"
        ) {}

        LedgerSessionRow(
            icon: .strength,
            name: "Strength · upper",
            meta: "17:05 · 55m · avg 121 bpm",
            strain: "3.4"
        ) {}

        LedgerSessionRow(
            icon: .symbol("figure.pool.swim"),
            name: "Swim",
            meta: "12:40 · 30m",
            strain: nil,
            showsDivider: false
        ) {}
    }
    .padding(.horizontal, Ledger.pageMargin)
    .frame(width: 393)
    .background(Ledger.bgScreen)
    .preferredColorScheme(.dark)
}
#endif
