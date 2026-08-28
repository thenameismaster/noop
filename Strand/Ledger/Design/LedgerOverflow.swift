//
//  LedgerOverflow.swift
//  Strand
//
//  The seam that lets the Ledger Today header's "…" affordance present the host shell's OWN
//  navigation hub.
//
//  Spec §01 item 7 is explicit: "The old 'More' list moves behind a '…'/profile affordance in the
//  Today header (all 28 destinations keep existing routes)." The Ledger shell therefore has no More
//  TAB — but those 28 destinations must stay reachable, and their routes must be the EXISTING ones,
//  not re-declared copies that could drift.
//
//  That list lives in `RootTabView.swift` and is built from types that are `private` to it and
//  iOS-only (`MoreDestination`, `MoreRow`). `LedgerTodayView` is cross-platform — it compiles into
//  the macOS `Strand` target too, where `RootTabView` does not exist — so it cannot name them.
//
//  An environment value inverts the dependency instead. The Today screen asks for overflow content
//  and renders whatever the host injected; the iOS shell injects its real More list; the Mac shell
//  injects nothing and the screen falls back to Settings. No shipped type changes visibility, and
//  nothing about the classic More tab is touched.
//

import SwiftUI

/// Host-injected content for the Ledger Today header's "…" affordance.
///
/// `nil` means "no host supplied one", and the screen falls back to presenting Settings — which is
/// what keeps the toggle itself reachable from inside the Ledger shell on every platform. That
/// fallback is a safety property, not a nicety: without it a user who enabled Ledger on a shell that
/// injects nothing would have no route back to the switch that turns it off.
public struct LedgerOverflowContentKey: EnvironmentKey {
    public static let defaultValue: AnyView? = nil
}

public extension EnvironmentValues {
    /// The navigation hub the Ledger Today header's "…" presents, supplied by the host shell.
    var ledgerOverflowContent: AnyView? {
        get { self[LedgerOverflowContentKey.self] }
        set { self[LedgerOverflowContentKey.self] = newValue }
    }
}

/// A host-supplied "switch to this Ledger tab" action.
///
/// Spec §Tap Map sends some Today taps to a TAB, not a push ("Today last-night strip → Sleep tab",
/// "Today load strip → Activity tab"). Only the host shell owns tab selection, so — like
/// `ledgerOverflowContent` — the action is injected. `nil` (the default, and the macOS case, which
/// has no Ledger tab bar) makes the screen fall back to pushing the matching screen instead, so the
/// tap never dead-ends.
public struct LedgerTabSwitchKey: EnvironmentKey {
    public static let defaultValue: (@MainActor (LedgerTab) -> Void)? = nil
}

public extension EnvironmentValues {
    /// Switches the Ledger shell to a tab, when a host injected the ability. `nil` ⇒ push instead.
    var ledgerSwitchTab: (@MainActor (LedgerTab) -> Void)? {
        get { self[LedgerTabSwitchKey.self] }
        set { self[LedgerTabSwitchKey.self] = newValue }
    }
}

/// The name of the Ledger tab that owns the enclosing stack, for detail back links.
///
/// Spec §06 puts the ORIGIN after the back chevron ("‹ Trends" on the board, which is pushed from
/// Trends). A `TabRoute` value cannot carry its origin, so the owning tab publishes its name and
/// the metric route host reads it. `nil` (the default) leaves the detail's own default.
public struct LedgerBackTitleKey: EnvironmentKey {
    public static let defaultValue: String? = nil
}

public extension EnvironmentValues {
    /// The back-chevron word for detail screens pushed in this stack. `nil` ⇒ the screen's default.
    var ledgerBackTitle: String? {
        get { self[LedgerBackTitleKey.self] }
        set { self[LedgerBackTitleKey.self] = newValue }
    }
}

/// Whether the enclosing navigation stack belongs to the Ledger shell.
///
/// The same seam-inversion as `ledgerOverflowContent`, for ROUTES instead of content: the shared
/// `TabRoute` table (`tabRouteDestinations()`) is registered once per stack by every shell, and its
/// `.metric` / `.metricSourced` cases must resolve to `LedgerMetricDetailView` inside the Ledger
/// shell but to the classic `MetricDetailView` everywhere else — including the Ledger's own "…"
/// overflow sheet, which hosts the CLASSIC More list and marks itself `false` explicitly. An
/// environment value keeps `TabRoute` free of any flag read of its own: default `false` means every
/// shipped stack behaves byte-for-byte as before, and only the stacks the Ledger shell marks opt in.
public struct LedgerShellActiveKey: EnvironmentKey {
    public static let defaultValue: Bool = false
}

public extension EnvironmentValues {
    /// `true` inside the Ledger shell's tab stacks; `false` everywhere else (the default).
    var ledgerShellActive: Bool {
        get { self[LedgerShellActiveKey.self] }
        set { self[LedgerShellActiveKey.self] = newValue }
    }
}
