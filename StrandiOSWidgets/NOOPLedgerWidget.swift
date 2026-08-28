import WidgetKit
import SwiftUI

// MARK: - NOOP Ledger widget — the Athlete's Ledger charge arc, on the Home Screen
//
// An ADDITIVE second widget kind (the classic NOOPWidget is untouched): the Ledger redesign's
// readiness hero — near-black canvas, a 270° open arc filled `score/100` in the recovery band's
// accent, the score numeral, the band word — as a small/medium widget. Data is the SAME
// `WidgetSnapshot` the classic widget reads; nothing new is published.
//
// The Ledger design kit (`Strand/Ledger`) is app-target code and its bundled fonts are registered
// by the app process, so this file restates the HANDFUL of tokens it needs (colours, arc geometry,
// band cut points) as literals, each traced to its source. The numeral falls back to the system
// face — the widget extension cannot use the app's runtime-registered Space Grotesk.
struct NOOPLedgerWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NOOPEntry

    private var snap: WidgetSnapshot { entry.snapshot }

    // MARK: Ledger tokens (traced to Strand/Ledger/Design/LedgerTokens.swift)

    /// `bg/screen` `#0A0C11`.
    private static let bgScreen = Color(red: 0x0A / 255.0, green: 0x0C / 255.0, blue: 0x11 / 255.0)
    /// `text/primary` `#F2F4F7` / `text/tertiary` `#5C6470`.
    private static let textPrimary = Color(red: 0xF2 / 255.0, green: 0xF4 / 255.0, blue: 0xF7 / 255.0)
    private static let textTertiary = Color(red: 0x5C / 255.0, green: 0x64 / 255.0, blue: 0x70 / 255.0)
    /// `accent/recovery` mint, `accent/caution`, `accent/live-hr` — the recovery band accents.
    private static let mint = Color(red: 0x3E / 255.0, green: 0xE6 / 255.0, blue: 0xA8 / 255.0)
    private static let caution = Color(red: 0xF2 / 255.0, green: 0xC1 / 255.0, blue: 0x4E / 255.0)
    private static let low = Color(red: 0xFF / 255.0, green: 0x6B / 255.0, blue: 0x81 / 255.0)
    /// The arc: 270° sweep from 135° (the symmetrised start), track white @6%.
    private static let arcStart: Double = 135
    private static let arcSweep: Double = 270

    /// The band accent — `Ledger.recoveryAccent`'s cut points (mint ≥ 70, caution 50…69, low < 50).
    private static func accent(_ score: Int?) -> Color {
        guard let score else { return textTertiary }
        if score >= 70 { return mint }
        if score >= 50 { return caution }
        return low
    }

    /// The band word — `LedgerRecoveryBand`'s cut points, restated.
    private static func word(_ score: Int) -> String {
        switch score {
        case ..<25: return String(localized: "DEPLETED")
        case ..<50: return String(localized: "LOW")
        case ..<70: return String(localized: "MODERATE")
        case ..<88: return String(localized: "PRIMED")
        default:    return String(localized: "PEAK")
        }
    }

    var body: some View {
        content
            .containerBackground(for: .widget) { Self.bgScreen }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemMedium: medium
        default: small
        }
    }

    // MARK: Small — the arc alone

    private var small: some View {
        arc(diameter: 116, stroke: 7, numeralSize: 34)
    }

    // MARK: Medium — arc + the WHY pair (HRV / RHR), the Today screen in miniature

    private var medium: some View {
        HStack(spacing: 18) {
            arc(diameter: 110, stroke: 7, numeralSize: 32)
            VStack(alignment: .leading, spacing: 10) {
                sideRow(String(localized: "HRV"), snap.hrv.map { "\($0)" }, String(localized: "ms"))
                divider
                sideRow(String(localized: "REST HR"), snap.restingHr.map { "\($0)" }, String(localized: "bpm"))
                divider
                sideRow(String(localized: "REST"), snap.rest.map { "\($0)" }, nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
    }

    private func sideRow(_ label: String, _ value: String?, _ unit: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .tracking(1.8)
                .foregroundStyle(Self.textTertiary)
            Spacer(minLength: 6)
            Text(value ?? "\u{2014}")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(value == nil ? Self.textTertiary : Self.textPrimary)
                .monospacedDigit()
            if let unit, value != nil {
                Text(unit)
                    .font(.system(size: 9))
                    .foregroundStyle(Self.textTertiary)
            }
        }
    }

    // MARK: The arc

    private func arc(diameter: CGFloat, stroke: CGFloat, numeralSize: CGFloat) -> some View {
        let score = snap.recovery
        let accent = Self.accent(score)
        let fraction = Double(min(max(score ?? 0, 0), 100)) / 100.0

        return ZStack {
            LedgerWidgetArc(startDegrees: Self.arcStart, sweepDegrees: Self.arcSweep)
                .stroke(.white.opacity(0.06), style: StrokeStyle(lineWidth: stroke, lineCap: .round))
            LedgerWidgetArc(startDegrees: Self.arcStart, sweepDegrees: Self.arcSweep * fraction)
                .stroke(accent, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
            VStack(spacing: 2) {
                Text(score.map { "\($0)" } ?? "\u{2014}")
                    .font(.system(size: numeralSize, weight: .bold, design: .rounded))
                    .foregroundStyle(score == nil ? Self.textTertiary : Self.textPrimary)
                    .monospacedDigit()
                Text(score.map(Self.word) ?? String(localized: "NO DATA"))
                    .font(.system(size: 8, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(score == nil ? Self.textTertiary : accent)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

/// The 270° open arc, degrees clockwise from 3 o'clock — the widget-local restatement of
/// `LedgerArcShape` (which lives in the app target).
private struct LedgerWidgetArc: Shape {
    var startDegrees: Double
    var sweepDegrees: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - 5
        guard radius > 0, sweepDegrees > 0 else { return path }
        path.addArc(center: centre, radius: radius,
                    startAngle: .degrees(startDegrees),
                    endAngle: .degrees(startDegrees + sweepDegrees),
                    clockwise: false)
        return path
    }
}

struct NOOPLedgerWidget: Widget {
    let kind = "NOOPLedgerWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NOOPProvider()) { entry in
            NOOPLedgerWidgetView(entry: entry)
        }
        .configurationDisplayName(Text("Charge (Ledger)"))
        .description(Text("Your charge on the Athlete's Ledger arc, with HRV and resting HR beside it."))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
