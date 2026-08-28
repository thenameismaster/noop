import SwiftUI
import CoreText
import Foundation
import os

// MARK: - Ledger Fonts — runtime registration of the two bundled families
//
// The spec bundles two Google-Fonts (OFL) variable faces and asks for them by name:
//
//   • **Space Grotesk** — numerals + screen titles. Weights 600/700, tabular figures.
//   • **Instrument Sans** — row titles + body/labels. Weights 400/600/700.
//
// WHY REGISTER AT RUNTIME RATHER THAN VIA `UIAppFonts` / `ATSApplicationFontsPath`.
// The Info.plist is off-limits for this change (one designated wiring agent owns the shells, and
// the plists are generated from `project.yml`). The `.ttf` files DO reach the bundle — `project.yml`
// globs `Strand/**`, so `Strand/Ledger/Resources/Fonts/*.ttf` is copied into the app's resources
// automatically — they are simply not *declared*. `CTFontManagerRegisterFontsForURL(_:.process:_:)`
// declares them at launch instead, for the process only, on BOTH macOS and iOS. No Info.plist edit,
// no third-party dependency.
//
// WHY NOT `Font.custom("Space Grotesk", size:)`.
// Both files are VARIABLE fonts whose default instance is the LIGHT end of the axis:
//
//   SpaceGrotesk.ttf    family "Space Grotesk Light"  · PostScript "SpaceGrotesk-Light"
//                       fvar: wght 300 … 700, default **300**
//   InstrumentSans.ttf  family "Instrument Sans"      · PostScript "InstrumentSans-Regular"
//                       fvar: wdth 75 … 100 (default 100), wght 400 … 700, default **400**
//
// Asking for the family by name yields the 300-weight default, and `.weight(.bold)` on a custom
// `Font` leaves CoreText to guess a named instance that does not exist as a separate face. So every
// Ledger font is built from a `CTFontDescriptor` that pins the `wght` axis EXPLICITLY
// (`kCTFontVariationAttribute`), which is deterministic for a variable font.
//
// FALLBACK. Every creation path verifies that the font CoreText handed back really is the family we
// asked for (`CTFontCopyFamilyName`). A mismatch — the classic silent failure where a typo'd family
// name renders as Helvetica — returns `nil` and the caller falls back to `Font.system`, i.e. SF Pro,
// which is exactly the fallback the spec sheet names ("custom font or SF Pro Display 700 fallback").
//
// Registration happens exactly once, lazily, on first use: `static let` initialisation carries
// `dispatch_once` semantics in Swift, so no lock or flag of our own is needed for the bootstrap.

/// Resolves and vends the two bundled Ledger typefaces.
///
/// Screens never call this directly — they use `LedgerType`, which layers the spec's type scale on
/// top. This type exists so the *font resolution* is one auditable place.
public enum LedgerFonts {

    // MARK: - Variable-axis tags

    /// The OpenType `wght` axis, as the four-char code CoreText keys variations by.
    private static let wghtAxis: Int = 0x77676874  // 'wght'

    /// The OpenType `wdth` axis. Instrument Sans carries 75…100; the Ledger always uses 100
    /// (normal width) — the spec never asks for a condensed cut.
    private static let wdthAxis: Int = 0x77647468  // 'wdth'

    // MARK: - Faces

    /// The two families the Ledger bundles, keyed by role rather than by name so a call site says
    /// what it MEANS ("this is a numeral") instead of naming a typeface.
    public enum Face: String, CaseIterable, Sendable {
        /// Space Grotesk — display/section numerals and screen titles.
        case numeral
        /// Instrument Sans — row titles, body copy, labels, overlines, captions.
        case label

        /// The file basename in `Strand/Ledger/Resources/Fonts/`.
        var resourceName: String {
            switch self {
            case .numeral: return "SpaceGrotesk"
            case .label:   return "InstrumentSans"
            }
        }

        /// The family name expected from the font's `name` table (name ID 1). Used only to sanity
        /// check the value CoreText reports — the value actually used is the one read back from the
        /// registered descriptor, never this literal.
        var expectedFamilyHint: String {
            switch self {
            case .numeral: return "Space Grotesk"
            case .label:   return "Instrument Sans"
            }
        }

        /// The system fallback when registration or resolution fails. SF Pro, per the spec sheet.
        var fallbackDesign: Font.Design { .default }
    }

    // MARK: - Registration

    /// What the one-shot bootstrap learned. Immutable once built.
    public struct Registration: Sendable {
        /// The resolved family name per face, read back from the registered `CTFontDescriptor`.
        /// `nil` for a face whose file was missing or whose registration failed.
        public let families: [Face: String]
        /// A human-readable line per face, for the diagnostics screen / a bug report.
        public let notes: [String]

        /// Whether both faces registered and resolved.
        public var isComplete: Bool { families[.numeral] != nil && families[.label] != nil }
    }

    private static let log = Logger(subsystem: "com.noop.strand", category: "LedgerFonts")

    /// The one-shot bootstrap. `static let` gives `dispatch_once` semantics: the body runs exactly
    /// once per process, on whichever thread touches it first, and every later read is a plain load.
    public static let registration: Registration = register()

    /// The resolved family name for a face, or `nil` if it is unavailable and the system fallback
    /// is in use.
    public static func familyName(_ face: Face) -> String? {
        registration.families[face]
    }

    /// `true` when both bundled families registered and are being used. `false` means every Ledger
    /// screen is currently drawing in SF Pro — visually degraded but fully functional.
    public static var isUsingBundledFonts: Bool { registration.isComplete }

    /// A multi-line report of what resolved and what did not. Safe to surface in a debug/diagnostics
    /// view; contains no user data.
    public static func diagnostics() -> String {
        registration.notes.joined(separator: "\n")
    }

    private static func register() -> Registration {
        var families: [Face: String] = [:]
        var notes: [String] = []

        for face in Face.allCases {
            guard let url = locate(face) else {
                notes.append("\(face.rawValue): \(face.resourceName).ttf NOT FOUND in bundle — falling back to SF Pro")
                log.error("Ledger font missing from bundle: \(face.resourceName, privacy: .public).ttf")
                continue
            }

            var cfError: Unmanaged<CFError>?
            let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &cfError)
            if !ok {
                let error = cfError?.takeRetainedValue()
                let code = error.map { CFErrorGetCode($0) } ?? -1
                // 105 == kCTFontManagerErrorAlreadyRegistered. Hitting it means another copy of the
                // same file (or a second process-level registration) got there first, which is a
                // success for our purposes: the family IS available.
                if code != CFIndex(CTFontManagerError.alreadyRegistered.rawValue) {
                    notes.append("\(face.rawValue): registration failed (code \(code)) — falling back to SF Pro")
                    log.error("CTFontManagerRegisterFontsForURL failed for \(face.resourceName, privacy: .public): \(code)")
                    continue
                }
            }

            // Read the family name back from the FILE's descriptor rather than trusting a literal.
            // A wrong family name is the silent failure this whole file exists to prevent.
            guard let resolved = familyName(inFileAt: url) else {
                notes.append("\(face.rawValue): registered but family name unreadable — falling back to SF Pro")
                continue
            }

            families[face] = resolved
            let matches = resolved.hasPrefix(face.expectedFamilyHint)
            notes.append("\(face.rawValue): \"\(resolved)\"\(matches ? "" : " (unexpected — hint was \"\(face.expectedFamilyHint)\")")")
        }

        return Registration(families: families, notes: notes)
    }

    /// Finds a `.ttf` in the main bundle. XcodeGen's resource copy flattens `Strand/Ledger/Resources
    /// /Fonts/` into the bundle's resource root, but the `Fonts` subdirectory is checked too so the
    /// lookup survives a future folder-reference change.
    private static func locate(_ face: Face) -> URL? {
        let bundle = Bundle.main
        if let url = bundle.url(forResource: face.resourceName, withExtension: "ttf") { return url }
        if let url = bundle.url(forResource: face.resourceName, withExtension: "ttf", subdirectory: "Fonts") { return url }
        // Last resort: the SwiftUI-preview / unit-test bundle that hosts this file.
        let here = Bundle(for: LedgerFontBundleToken.self)
        if let url = here.url(forResource: face.resourceName, withExtension: "ttf") { return url }
        return here.url(forResource: face.resourceName, withExtension: "ttf", subdirectory: "Fonts")
    }

    /// The family name (`kCTFontFamilyNameAttribute`) declared by the font file itself.
    private static func familyName(inFileAt url: URL) -> String? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first,
              let name = CTFontDescriptorCopyAttribute(first, kCTFontFamilyNameAttribute) as? String,
              !name.isEmpty
        else { return nil }
        return name
    }

    // MARK: - Font creation

    /// A bundled face at an exact size and variable weight, or `nil` when the family is unavailable
    /// or CoreText substituted a different one.
    ///
    /// - Parameters:
    ///   - face: `.numeral` (Space Grotesk) or `.label` (Instrument Sans).
    ///   - size: the point size the spec states. Fixed by design — the Ledger's numerals are laid
    ///     out to the pixel, so they do not scale with Dynamic Type.
    ///   - weight: the `wght` axis value (400 / 600 / 700), clamped to the face's own axis range.
    public static func font(_ face: Face, size: CGFloat, weight: Double) -> Font? {
        guard let ct = ctFont(face, size: size, weight: weight) else { return nil }
        return Font(ct)
    }

    /// The bundled face if available, otherwise the SF Pro system fallback at the nearest weight.
    /// This is the accessor `LedgerType` uses, and the one that never returns `nil`.
    public static func resolved(_ face: Face, size: CGFloat, weight: Double) -> Font {
        font(face, size: size, weight: weight)
            ?? .system(size: size, weight: systemWeight(weight), design: face.fallbackDesign)
    }

    /// The `CTFont` behind `font(_:size:weight:)`. Exposed because `Canvas`/`CoreText` drawing (the
    /// score arc's numeral) needs the `CTFont`, not the SwiftUI wrapper.
    public static func ctFont(_ face: Face, size: CGFloat, weight: Double) -> CTFont? {
        guard let family = registration.families[face] else { return nil }

        var axes: [NSNumber: NSNumber] = [NSNumber(value: wghtAxis): NSNumber(value: weight)]
        if face == .label {
            // Pin width to normal so a future axis default change cannot silently condense the UI.
            axes[NSNumber(value: wdthAxis)] = NSNumber(value: 100.0)
        }

        let attributes: [CFString: Any] = [
            kCTFontFamilyNameAttribute: family,
            kCTFontVariationAttribute: axes,
        ]
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)

        // Verify. CTFontCreateWithFontDescriptor NEVER fails — an unknown family yields a
        // substituted face — so the only way to detect a bad name is to ask what we got.
        let got = CTFontCopyFamilyName(font) as String
        guard got == family else { return nil }
        return font
    }

    /// Maps a `wght` axis value onto the nearest `Font.Weight` for the SF Pro fallback path.
    private static func systemWeight(_ weight: Double) -> Font.Weight {
        switch weight {
        case ..<350:  return .light
        case ..<450:  return .regular
        case ..<550:  return .medium
        case ..<650:  return .semibold
        case ..<750:  return .bold
        default:      return .heavy
        }
    }
}

/// A bundle anchor for `Bundle(for:)`. Only used by the preview/test lookup path in
/// `LedgerFonts.locate(_:)`; never instantiated at runtime.
private final class LedgerFontBundleToken {}
