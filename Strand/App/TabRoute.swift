import SwiftUI

// MARK: - TabRoute
//
// Value-based routes for every push that leaves a primary tab's ROOT (#198, Path A). The iOS tab
// shell binds each tab's `NavigationStack` to a `NavigationPath`, and a path only tracks pushes
// made through it — a closure-destination `NavigationLink` bypasses the path entirely. So the
// root-level links in the tab roots must push a VALUE for "re-tap the active tab" to pop back to
// the root (#135) without the #197 rebuild. Deeper links stay closure-based on purpose: popping a
// route off the path also pops everything pushed above it, so only the first hop needs a value.
//
// Shared with macOS because the tab roots (TodayView / LiquidTodayView / TrendsView) are the SAME
// views the sidebar shell hosts — every `NavigationStack` that hosts one must register
// `tabRouteDestinations()`, and must register it exactly ONCE: the same value type resolving
// against two registrations in one stack double-pushes (see MetricExplorerView, #38).

/// One first-hop destination reachable from a tab root. `Hashable` so it can ride a `NavigationPath`.
enum TabRoute: Hashable {
    /// The whole-day, full-resolution HR timeline (Liquid Today's live-HR card tap, #979).
    case fullDayChart
    /// One metric's detail page by `MetricCatalog` key — the same tap-through Today's cards and
    /// Trends' small-multiples share. Each card opens ITS metric (2026-07-02: not the shared
    /// Health screen).
    case metric(String)
    /// One metric's detail by BOTH key and source. `steps` exists under several sources (my-whoop,
    /// apple-health, xiaomi-band); routing by bare key alone resolves whichever catalog entry is
    /// declared first, so a card's tap-through would silently depend on declaration order. This pins
    /// the exact source, so the catalog's ordering can never decide where a card taps through.
    case metricSourced(key: String, source: String)
    case metricExplorer
    case workouts
    case dataSources
    case stress
    case sleep
    case health
    case hydration
    case coupled
}

extension View {
    /// Maps every `TabRoute` push to its screen. Apply once to the ROOT content of each
    /// `NavigationStack` that hosts a tab-root view (the iOS tab shell's stacks; the macOS
    /// Today detail pane and TrendsView's own macOS wrap).
    func tabRouteDestinations() -> some View {
        navigationDestination(for: TabRoute.self) { route in
            switch route {
            case .fullDayChart: FullDayChartView()
            case .metric(let key):
                MetricRouteHost(key: key, source: nil)
            case .metricSourced(let key, let source):
                MetricRouteHost(key: key, source: source)
            case .metricExplorer: MetricExplorerView()
            case .workouts: WorkoutsView()
            case .dataSources: DataSourcesView()
            case .stress: StressView()
            case .sleep: SleepView()
            case .health: HealthView()
            case .hydration: HydrationView()
            case .coupled: CoupledView()
            }
        }
    }
}

/// Resolves a `.metric` / `.metricSourced` push to the ACTIVE shell's detail screen.
///
/// The Ledger shell marks its tab stacks with `\.ledgerShellActive` (its "…" overflow sheet, which
/// hosts the classic More list, marks itself back off), so a metric tap inside the Ledger opens
/// `LedgerMetricDetailView` while every other stack — the classic iOS tabs, the macOS panes, the
/// Aurora shell — keeps the classic `MetricDetailView`, byte-for-byte as before. Resolution when
/// classic: exact (key, source) first, then the bare-key entry, then Health, so a stale route can
/// never dead-end (the pre-host behaviour, unchanged). The Ledger detail does its own resolution
/// from the same catalog and renders its own honest unknown-metric state.
private struct MetricRouteHost: View {
    @Environment(\.ledgerShellActive) private var ledgerShellActive
    /// The owning Ledger tab's name (spec §06 puts the origin after the back chevron).
    @Environment(\.ledgerBackTitle) private var ledgerBackTitle

    let key: String
    let source: String?

    var body: some View {
        if ledgerShellActive {
            LedgerMetricDetailView(metricKey: key, source: source,
                                   backTitle: ledgerBackTitle
                                       ?? LedgerMetricDetailView.defaultBackTitle)
        } else if let m = classicMetric {
            MetricDetailView(metric: m)
        } else {
            HealthView()
        }
    }

    private var classicMetric: MetricDescriptor? {
        if let source, let m = MetricCatalog.metric(key: key, source: source) { return m }
        return MetricCatalog.all.first { $0.key == key }
    }
}
