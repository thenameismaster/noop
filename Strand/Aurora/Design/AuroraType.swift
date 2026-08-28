import SwiftUI

// MARK: - Aurora Typography
//
// One voice, two jobs.
//
// NUMERALS are the hero. Every metric screen exists to deliver a number, so the numeric
// styles get the largest sizes, the tightest tracking and — always — TABULAR FIGURES.
// Tabular digits are non-negotiable for live data: a proportional `1` is narrower than a
// `8`, so a heart rate ticking 88 → 91 → 118 visibly jitters and reflows its neighbours.
// `.monospacedDigit()` pins every glyph to one advance width and the number sits still.
//
// PROSE is quiet. Labels, captions and supporting copy step back so the numeral reads
// first. Section headers are the one exception: uppercase and widely tracked, they act
// as structural rules rather than as text.
//
// FAMILY. SF Pro Rounded for numerals and headings (Apple-native, geometric, friendly at
// large sizes without being cute) and SF Pro for body copy at small sizes, where rounded
// terminals cost legibility. SF Mono is reserved for raw values and logs.
//
// TRACKING. Optical, not constant. Large display numerals need negative tracking
// (−4% of point size) or they read as loose; small uppercase labels need generous
// positive tracking (+1.2) or they read as a smear.
//
// DYNAMIC TYPE. Prose styles are declared `relativeTo:` a system text style so they
// scale with the user's setting. Hero numerals are FIXED size on purpose: the ring's
// centre value must never grow past its arc. The app root already caps Dynamic Type at
// `.accessibility1`, so this is a bounded trade, and every fixed-size numeral is paired
// with a scaling label that carries the same information.

/// The Aurora type scale. A screen never writes `.font(.system(size: ...))` — it picks
/// a role from here, so a change to the scale lands everywhere at once.
public enum AuroraType {

    // MARK: - Numerals (tabular, rounded, tight)

    /// **Display** — the hero numeral: a ring's centre value, a screen's single headline
    /// number. ~64pt, heavy, tabular, −4% tracking. Fixed size by design.
    public static func display(_ size: CGFloat = 64) -> Font {
        .system(size: size, weight: .heavy, design: .rounded).monospacedDigit()
    }

    /// Optical tracking for `display(_:)` at a given size (−4% of point size).
    /// Apply alongside the font: `.font(AuroraType.display()).tracking(AuroraType.displayTracking())`
    /// — or just use the `.auroraDisplay()` modifier, which does both.
    public static func displayTracking(_ size: CGFloat = 64) -> CGFloat { -size * 0.04 }

    /// **Metric Large** — 34pt bold tabular. The value in a hero tile or a detail header.
    public static let metricLarge = Font.system(size: 34, weight: .bold, design: .rounded).monospacedDigit()
    /// Tracking for `metricLarge` (−3%).
    public static let metricLargeTracking: CGFloat = -1.0

    /// **Metric Medium** — 24pt semibold tabular. The value in a standard metric tile.
    public static let metricMedium = Font.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit()
    /// Tracking for `metricMedium` (−2%).
    public static let metricMediumTracking: CGFloat = -0.5

    /// **Metric Small** — 17pt semibold tabular. An inline value in a dense row.
    public static let metricSmall = Font.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit()

    /// **Unit** — 13pt medium. The `bpm` / `ms` / `%` that trails a value. Always set in
    /// tertiary text so it reads as an annotation, never as part of the number.
    public static let unit = Font.system(size: 13, weight: .medium, design: .rounded)

    /// A tabular numeral at an arbitrary size — for one-off chart labels and axis ticks.
    public static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    // MARK: - Headings & prose

    /// **Title Large** — 28pt bold. A screen title.
    public static let titleLarge = Font.system(.title, design: .rounded).weight(.bold)

    /// **Title** — 22pt semibold. A card title, a sheet title.
    public static let title = Font.system(.title2, design: .rounded).weight(.semibold)

    /// **Headline** — 17pt semibold. A row's primary line.
    public static let headline = Font.system(.headline, design: .rounded).weight(.semibold)

    /// **Section Header** — 11pt bold, uppercase, +1.2 tracking. A structural rule that
    /// happens to be made of letters. Always tertiary or secondary text; never primary.
    public static let sectionHeader = Font.system(.caption2, design: .rounded).weight(.bold)
    /// Tracking for `sectionHeader`. Wide enough to read as a rule rather than a word.
    public static let sectionHeaderTracking: CGFloat = 1.2

    /// **Body** — 15pt regular. Supporting copy, insight text.
    public static let body = Font.system(.subheadline, design: .default).weight(.regular)

    /// **Body Strong** — 15pt semibold. An emphasised phrase inside body copy.
    public static let bodyStrong = Font.system(.subheadline, design: .default).weight(.semibold)

    /// **Label** — 13pt medium. A metric tile's name, a chip's text.
    public static let label = Font.system(.footnote, design: .rounded).weight(.medium)

    /// **Caption** — 12pt regular. Timestamps, axis labels, provenance.
    public static let caption = Font.system(.caption, design: .default).weight(.regular)

    /// **Caption Strong** — 12pt semibold. A caption that must be scanned, not read.
    public static let captionStrong = Font.system(.caption, design: .rounded).weight(.semibold)

    /// **Footnote** — 11pt regular. The quietest text Aurora sets.
    public static let footnote = Font.system(.caption2, design: .default).weight(.regular)

    // MARK: - Mono

    /// **Mono** — 13pt SF Mono. Raw values, identifiers, logs. Tabular by nature.
    public static let mono = Font.system(size: 13, weight: .regular, design: .monospaced)

    /// SF Mono at an arbitrary size.
    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// **Tabular Label** — 12pt medium monospaced. Aligned key/value tables, chart
    /// read-outs, anything where columns must line up across rows.
    public static let tabularLabel = Font.system(size: 12, weight: .medium, design: .monospaced)
}

// MARK: - Text role modifiers
//
// Each modifier applies font + tracking + the DEFAULT foreground rank in one step, so a
// screen never has to remember that a section header is also tertiary and also uppercase.
// Colour is applied first, so a call site can still override it:
//
//     Text("Peak").auroraSectionHeader().foregroundStyle(Aurora.statusGood)

/// The set of type roles Aurora exposes as one-call modifiers.
public enum AuroraTextRole: Sendable {
    case display(CGFloat)
    case metricLarge
    case metricMedium
    case metricSmall
    case unit
    case titleLarge
    case title
    case headline
    case sectionHeader
    case body
    case bodyStrong
    case label
    case caption
    case captionStrong
    case footnote
    case mono
    case tabularLabel

    var font: Font {
        switch self {
        case .display(let s):  return AuroraType.display(s)
        case .metricLarge:     return AuroraType.metricLarge
        case .metricMedium:    return AuroraType.metricMedium
        case .metricSmall:     return AuroraType.metricSmall
        case .unit:            return AuroraType.unit
        case .titleLarge:      return AuroraType.titleLarge
        case .title:           return AuroraType.title
        case .headline:        return AuroraType.headline
        case .sectionHeader:   return AuroraType.sectionHeader
        case .body:            return AuroraType.body
        case .bodyStrong:      return AuroraType.bodyStrong
        case .label:           return AuroraType.label
        case .caption:         return AuroraType.caption
        case .captionStrong:   return AuroraType.captionStrong
        case .footnote:        return AuroraType.footnote
        case .mono:            return AuroraType.mono
        case .tabularLabel:    return AuroraType.tabularLabel
        }
    }

    var tracking: CGFloat {
        switch self {
        case .display(let s):  return AuroraType.displayTracking(s)
        case .metricLarge:     return AuroraType.metricLargeTracking
        case .metricMedium:    return AuroraType.metricMediumTracking
        case .sectionHeader:   return AuroraType.sectionHeaderTracking
        case .titleLarge:      return -0.4
        default:               return 0
        }
    }

    var color: Color {
        switch self {
        case .display, .metricLarge, .metricMedium, .metricSmall,
             .titleLarge, .title, .headline, .bodyStrong:
            return Aurora.textPrimary
        case .body, .label, .captionStrong:
            return Aurora.textSecondary
        case .unit, .sectionHeader, .caption, .footnote, .mono, .tabularLabel:
            return Aurora.textTertiary
        }
    }

    var uppercased: Bool {
        if case .sectionHeader = self { return true }
        return false
    }
}

/// Applies an `AuroraTextRole`'s font, tracking, casing and default colour.
public struct AuroraTextStyle: ViewModifier {
    public let role: AuroraTextRole

    public init(role: AuroraTextRole) { self.role = role }

    public func body(content: Content) -> some View {
        let base = content
            .font(role.font)
            .tracking(role.tracking)
            .foregroundStyle(role.color)
        if role.uppercased {
            return AnyView(base.textCase(.uppercase))
        } else {
            return AnyView(base)
        }
    }
}

public extension View {
    /// Apply an Aurora type role (font + tracking + casing + default colour).
    func auroraText(_ role: AuroraTextRole) -> some View {
        modifier(AuroraTextStyle(role: role))
    }

    /// Hero numeral. ~64pt heavy tabular with optical negative tracking.
    func auroraDisplay(_ size: CGFloat = 64) -> some View { auroraText(.display(size)) }

    /// 34pt bold tabular — a hero tile's value.
    func auroraMetricLarge() -> some View { auroraText(.metricLarge) }

    /// 24pt semibold tabular — a standard tile's value.
    func auroraMetricMedium() -> some View { auroraText(.metricMedium) }

    /// 17pt semibold tabular — an inline value in a dense row.
    func auroraMetricSmall() -> some View { auroraText(.metricSmall) }

    /// 13pt medium tertiary — the unit trailing a value.
    func auroraUnit() -> some View { auroraText(.unit) }

    /// 28pt bold — a screen title.
    func auroraTitleLarge() -> some View { auroraText(.titleLarge) }

    /// 22pt semibold — a card or sheet title.
    func auroraTitle() -> some View { auroraText(.title) }

    /// 17pt semibold — a row's primary line.
    func auroraHeadline() -> some View { auroraText(.headline) }

    /// 11pt bold UPPERCASE +1.2 tracking — a structural section rule.
    func auroraSectionHeader() -> some View { auroraText(.sectionHeader) }

    /// 15pt regular secondary — supporting copy.
    func auroraBody() -> some View { auroraText(.body) }

    /// 15pt semibold primary — an emphasised phrase.
    func auroraBodyStrong() -> some View { auroraText(.bodyStrong) }

    /// 13pt medium secondary — a metric's name, a chip's text.
    func auroraLabel() -> some View { auroraText(.label) }

    /// 12pt regular tertiary — timestamps, axis labels, provenance.
    func auroraCaption() -> some View { auroraText(.caption) }

    /// 12pt semibold secondary — a caption meant to be scanned.
    func auroraCaptionStrong() -> some View { auroraText(.captionStrong) }

    /// 11pt regular tertiary — the quietest text in the system.
    func auroraFootnote() -> some View { auroraText(.footnote) }

    /// 13pt SF Mono tertiary — raw values and logs.
    func auroraMono() -> some View { auroraText(.mono) }

    /// 12pt medium monospaced tertiary — aligned columns and chart read-outs.
    func auroraTabularLabel() -> some View { auroraText(.tabularLabel) }
}

// MARK: - Composed value + unit

/// A value and its unit set as one optically-balanced pair: a tabular numeral with the
/// unit trailing it on the numeral's baseline, one rank quieter and one size smaller.
///
/// Screens use this instead of hand-assembling an `HStack` so the baseline relationship
/// and the spacing between number and unit are identical everywhere in the app.
public struct AuroraValueUnit: View {

    private let value: String
    private let unit: String?
    private let role: AuroraTextRole
    private let valueColor: Color?

    /// - Parameters:
    ///   - value: the already-formatted numeral (e.g. `"128"`, `"7:42"`, `"—"`).
    ///   - unit: the trailing unit, or `nil` for a unitless value.
    ///   - role: the numeral's type role. Defaults to `.metricMedium`.
    ///   - valueColor: overrides the numeral's colour (e.g. a sampled ramp colour).
    public init(
        value: String,
        unit: String? = nil,
        role: AuroraTextRole = .metricMedium,
        valueColor: Color? = nil
    ) {
        self.value = value
        self.unit = unit
        self.role = role
        self.valueColor = valueColor
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Aurora.Space.xxs) {
            Text(value)
                .auroraText(role)
                .foregroundStyle(valueColor ?? role.color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let unit, !unit.isEmpty {
                Text(unit)
                    .auroraUnit()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Aurora Type") {
    ScrollView {
        VStack(alignment: .leading, spacing: Aurora.Space.m) {
            Text("88").auroraDisplay()
            AuroraValueUnit(value: "128", unit: "bpm", role: .metricLarge)
            AuroraValueUnit(value: "62", unit: "ms")
            Text("Recovery").auroraTitleLarge()
            Text("Last night").auroraTitle()
            Text("Sleep debt").auroraHeadline()
            Text("Today").auroraSectionHeader()
            Text("Your baseline shifted up 4 ms this week, which usually follows a lighter training block.")
                .auroraBody()
            Text("Resting heart rate").auroraLabel()
            Text("Updated 4 minutes ago").auroraCaption()
            Text("crc32=f3a1  0xAA 41 00 1c").auroraMono()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Aurora.Space.l)
    }
    .background(Aurora.canvas)
}
#endif
