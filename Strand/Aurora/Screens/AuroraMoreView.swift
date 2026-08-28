import SwiftUI
import StrandDesign

// MARK: - Aurora More — the navigation hub
//
// An ADDITIVE fork of the iPhone "More" tab (StrandiOS/App/RootTabView.swift `moreTab`). Nothing in
// the original is modified: this file re-presents the SAME destinations on the Aurora design system.
//
// The INFORMATION ARCHITECTURE is deliberately different from the original index, which was a
// scrolling stack of four collapsible accordions — a shape that makes finding a screen a game of
// "which drawer was it in?":
//
//   • SEARCH IS CHROME, NOT CONTENT. The title and the filter live in a fixed band above the scroll
//     view, so the fastest route to any of the 26 screens is always on screen, never scrolled away.
//   • ONE DOMINANT STATEMENT. Trends is no longer a tab, so it opens the hub as a full-width
//     spotlight: the 14-day recovery average as a rolling hero numeral in its own band colour, the
//     house coaching line for that band, a 14-night sparkline, and the change against the prior
//     fortnight. Colour is the datum. Everything else on the screen is a list.
//   • JUMP BACK IN. A row of four compact tiles ordered by what this user actually opened last
//     (recency, persisted), not by a hard-coded editor's pick.
//   • NO ACCORDIONS. Every group is open, always. The four section headers become scannable
//     landmarks rather than doors, and the filter — not a disclosure chevron — is how the list gets
//     short. Rows gained a tinted glyph plate and a one-line subtitle naming the job, so the index
//     tells you what a screen is for instead of only what it is called.
//
// What did NOT change: every `MoreDestination` case is still reachable (the two iOS-only ones stay
// behind `#if os(iOS)` because their views live in StrandiOS/ and do not compile into the macOS
// target), the rows still push VALUES onto the enclosing `NavigationStack`'s path so an at-root tab
// re-tap can pop them (#135/#198), the pushed screen still gets the original per-screen chrome, and
// pull-to-refresh still calls `Repository.refresh()`. No score, series or persisted metric is
// computed or altered here — the spotlight reads `Repository.days` and formats it.

// MARK: - Destinations

/// Every screen the Aurora More hub links to, as a `Hashable` value the enclosing tab's
/// `NavigationPath` can carry — the same contract the original `MoreDestination` has (#198): a
/// closure-destination push bypasses the path and is un-poppable on a tab re-tap.
///
/// One case per row of the original More index, plus `.trends`: the Aurora shell drops Trends as a
/// primary tab, so the hub is now its home. `shortcutsExport` and `siriShortcuts` are iOS-only
/// because `ShortcutExportSettingsView` / `SiriShortcutsSettingsView` live under `StrandiOS/` and
/// are not compiled into the macOS target.
enum AuroraMoreDestination: Hashable, Identifiable, CaseIterable {
    case trends
    case insightsHub, intelligence, coach, insights, explore, compare
    case live, workouts, health, labBook, stress, breathe, intervals, rhythm
    case fusedRecord, appleHealth, miBand, dataSources, backupSync, noopLimitations
    #if os(iOS)
    case shortcutsExport
    #endif
    case alarms, automations, testCentre, powerSaving, settings
    #if os(iOS)
    case siriShortcuts
    #endif

    var id: Self { self }

    /// Stable token for the persisted "jump back in" order. Deliberately NOT the localized title:
    /// a stored order must survive a copy edit and a language change.
    var key: String {
        switch self {
        case .trends:          return "trends"
        case .insightsHub:     return "insightsHub"
        case .intelligence:    return "intelligence"
        case .coach:           return "coach"
        case .insights:        return "insights"
        case .explore:         return "explore"
        case .compare:         return "compare"
        case .live:            return "live"
        case .workouts:        return "workouts"
        case .health:          return "health"
        case .labBook:         return "labBook"
        case .stress:          return "stress"
        case .breathe:         return "breathe"
        case .intervals:       return "intervals"
        case .rhythm:          return "rhythm"
        case .fusedRecord:     return "fusedRecord"
        case .appleHealth:     return "appleHealth"
        case .miBand:          return "miBand"
        case .dataSources:     return "dataSources"
        case .backupSync:      return "backupSync"
        case .noopLimitations: return "noopLimitations"
        case .alarms:          return "alarms"
        case .automations:     return "automations"
        case .testCentre:      return "testCentre"
        case .powerSaving:     return "powerSaving"
        case .settings:        return "settings"
        #if os(iOS)
        case .shortcutsExport: return "shortcutsExport"
        case .siriShortcuts:   return "siriShortcuts"
        #endif
        }
    }

    /// The row label. Deliberately the SAME literal the original More list uses, so each one resolves
    /// against the String Catalog entry that already exists rather than minting a new key.
    var title: String {
        switch self {
        case .trends:          return String(localized: "Trends")
        case .insightsHub:     return String(localized: "What Moves You")
        case .intelligence:    return String(localized: "Intelligence")
        case .coach:           return String(localized: "Coach")
        case .insights:        return String(localized: "Insights")
        case .explore:         return String(localized: "Explore")
        case .compare:         return String(localized: "Compare")
        case .live:            return String(localized: "Live")
        case .workouts:        return String(localized: "Workouts")
        case .health:          return String(localized: "Health")
        case .labBook:         return String(localized: "Lab Book")
        case .stress:          return String(localized: "Stress")
        case .breathe:         return String(localized: "Breathe")
        case .intervals:       return String(localized: "Intervals")
        case .rhythm:          return String(localized: "Rhythm")
        case .fusedRecord:     return String(localized: "Your Data, Fused")
        case .appleHealth:     return String(localized: "Apple Health")
        case .miBand:          return String(localized: "Mi Band")
        case .dataSources:     return String(localized: "Data Sources")
        case .backupSync:      return String(localized: "Backup & Sync")
        case .noopLimitations: return String(localized: "NOOP Limitations")
        case .alarms:          return String(localized: "Alarms")
        case .automations:     return String(localized: "Automations")
        case .testCentre:      return String(localized: "Test Centre")
        case .powerSaving:     return String(localized: "Power saving")
        case .settings:        return String(localized: "Settings")
        #if os(iOS)
        case .shortcutsExport: return String(localized: "Shortcuts Export")
        case .siriShortcuts:   return String(localized: "Siri & Shortcuts")
        #endif
        }
    }

    /// A one- or two-word label for the compact shortcut tiles, where a full title would shrink to
    /// unreadable. Everything else falls back to the row title.
    var shortTitle: String {
        switch self {
        case .insightsHub:     return String(localized: "Moves You")
        case .fusedRecord:     return String(localized: "Fused")
        case .noopLimitations: return String(localized: "Limits")
        case .backupSync:      return String(localized: "Backup")
        case .testCentre:      return String(localized: "Tests")
        case .powerSaving:     return String(localized: "Power")
        case .dataSources:     return String(localized: "Sources")
        #if os(iOS)
        case .shortcutsExport: return String(localized: "Export")
        case .siriShortcuts:   return String(localized: "Siri")
        #endif
        default:               return title
        }
    }

    /// One short clarifier under the title. A hub that only lists names makes the reader open a screen
    /// to find out what it is; naming the job is what turns an index into navigation.
    var subtitle: String {
        switch self {
        case .trends:          return String(localized: "Every metric over weeks and months")
        case .insightsHub:     return String(localized: "What actually moves your recovery")
        case .intelligence:    return String(localized: "How every score was computed")
        case .coach:           return String(localized: "Ask about your own data")
        case .insights:        return String(localized: "Journal, behaviours and correlations")
        case .explore:         return String(localized: "Chart any metric, any range")
        case .compare:         return String(localized: "Put two periods side by side")
        case .live:            return String(localized: "Real-time heart rate and sensors")
        case .workouts:        return String(localized: "History, strain and routes")
        case .health:          return String(localized: "Vitals, temperature and blood oxygen")
        case .labBook:         return String(localized: "Raw captures and experiments")
        case .stress:          return String(localized: "Daytime load and check-ins")
        case .breathe:         return String(localized: "Guided breathing sessions")
        case .intervals:       return String(localized: "Build and run interval timers")
        case .rhythm:          return String(localized: "Beat-to-beat regularity")
        case .fusedRecord:     return String(localized: "Every source, one timeline")
        case .appleHealth:     return String(localized: "Read from and write to Health")
        case .miBand:          return String(localized: "Xiaomi band pairing and sync")
        case .dataSources:     return String(localized: "Imports, exports and priority")
        case .backupSync:      return String(localized: "Back up and restore your database")
        case .noopLimitations: return String(localized: "What each strap can and cannot do")
        case .alarms:          return String(localized: "Smart alarm and wake window")
        case .automations:     return String(localized: "Triggers, alerts and wrist taps")
        case .testCentre:      return String(localized: "Diagnostics and bug reports")
        case .powerSaving:     return String(localized: "Stretch your strap's battery")
        case .settings:        return String(localized: "Units, appearance and account")
        #if os(iOS)
        case .shortcutsExport: return String(localized: "HealthKit-free export drop file")
        case .siriShortcuts:   return String(localized: "Voice shortcuts and App Intents")
        #endif
        }
    }

    /// Extra words the filter should match but the row does not print — the vocabulary a user is as
    /// likely to type as the official name ("battery", "HRV", "CSV"). Search that only matches the
    /// visible label fails exactly when it matters, on the screen whose name you cannot remember.
    var searchTerms: String {
        switch self {
        case .trends:          return "graph chart history week month average"
        case .insightsHub:     return "drivers what moves you factors"
        case .intelligence:    return "how it works method algorithm explain"
        case .coach:           return "ask chat assistant question"
        case .insights:        return "journal behaviour behavior correlation habits"
        case .explore:         return "metric explorer graph any chart"
        case .compare:         return "period versus vs side by side"
        case .live:            return "heart rate hr sensor now realtime bpm"
        case .workouts:        return "training exercise run activity route strain"
        case .health:          return "vitals hrv spo2 oxygen temperature respiratory"
        case .labBook:         return "raw capture experiment packets debug"
        case .stress:          return "load tension calm check in"
        case .breathe:         return "breathing box relax meditate"
        case .intervals:       return "timer hiit rounds tabata"
        case .rhythm:          return "afib arrhythmia irregular beat rr"
        case .fusedRecord:     return "merge sources timeline record fused"
        case .appleHealth:     return "healthkit apple ios sync"
        case .miBand:          return "xiaomi band smart pairing"
        case .dataSources:     return "import export csv priority sources"
        case .backupSync:      return "restore icloud database file backup"
        case .noopLimitations: return "capability strap 4.0 5.0 mg support"
        case .alarms:          return "alarm wake smart clock"
        case .automations:     return "trigger alert wrist tap rules notification"
        case .testCentre:      return "diagnostic bug report logs support"
        case .powerSaving:     return "battery power drain charge"
        case .settings:        return "preferences units appearance account theme"
        #if os(iOS)
        case .shortcutsExport: return "shortcut drop file sideload export"
        case .siriShortcuts:   return "voice siri intent shortcut"
        #endif
        }
    }

    /// SF Symbol for the glyph plate. Same symbol the original row used, so a returning user's
    /// visual memory of the list survives the redesign.
    var icon: String {
        switch self {
        case .trends:          return "chart.line.uptrend.xyaxis"
        case .insightsHub:     return "wand.and.sparkles"
        case .intelligence:    return "brain.head.profile"
        case .coach:           return "sparkles"
        case .insights:        return "lightbulb.fill"
        case .explore:         return "square.grid.2x2.fill"
        case .compare:         return "rectangle.split.2x1.fill"
        case .live:            return "waveform.path.ecg"
        case .workouts:        return "figure.run"
        case .health:          return "heart.text.square.fill"
        case .labBook:         return "books.vertical.fill"
        case .stress:          return "bolt.heart.fill"
        case .breathe:         return "wind"
        case .intervals:       return "timer"
        case .rhythm:          return "waveform.path"
        case .fusedRecord:     return "square.stack.3d.up.fill"
        case .appleHealth:     return "heart.fill"
        case .miBand:          return "figure.walk.motion"
        case .dataSources:     return "externaldrive.fill"
        case .backupSync:      return "externaldrive.fill.badge.icloud"
        case .noopLimitations: return "list.bullet.rectangle"
        case .alarms:          return "alarm.fill"
        case .automations:     return "wand.and.stars"
        case .testCentre:      return "stethoscope"
        case .powerSaving:     return "battery.25"
        case .settings:        return "gearshape.fill"
        #if os(iOS)
        case .shortcutsExport: return "square.and.arrow.up.fill"
        case .siriShortcuts:   return "mic.fill"
        #endif
        }
    }

    /// The glyph plate's tint. Colour carries MEANING here, not decoration: the interpretation
    /// screens take the accent, the body screens take their own physiological ramp colour (the same
    /// hue that screen's data is drawn in), and the plumbing screens stay neutral so they recede.
    /// `powerSaving` is the one deliberate exception — a battery lever is a caution-coloured concern.
    var accent: Color {
        switch self {
        case .trends, .insightsHub, .intelligence, .coach, .insights, .explore, .compare:
            return Aurora.accent
        case .live:        return Aurora.statusAlert
        case .workouts:    return Aurora.strainColor(16)
        case .health:      return Aurora.recoveryColor(78)
        case .labBook:     return Aurora.strainColor(6)
        case .stress:      return Aurora.stressColor(72)
        case .breathe:     return Aurora.sleepColor(84)
        case .intervals:   return Aurora.strainColor(11)
        case .rhythm:      return Aurora.recoveryColor(52)
        case .powerSaving: return Aurora.statusCaution
        default:           return Aurora.statusNeutral
        }
    }

    /// The destination screen, with the SAME view for the SAME case as the original `MoreDestination`.
    /// Per-screen chrome is applied once at the `navigationDestination(for:)` registration below,
    /// exactly as the original does. `.trends` resolves to the Aurora trends screen because this hub
    /// only ever renders inside the Aurora shell.
    /// `@MainActor` because `AuroraTrendsView` is a main-actor view; the only caller is the hub's
    /// `navigationDestination(for:)` builder, which is already on the main actor.
    @MainActor @ViewBuilder var screen: some View {
        switch self {
        case .trends:          AuroraTrendsView()
        case .insightsHub:     InsightsHubView()
        case .intelligence:    IntelligenceView()
        case .coach:           CoachView()
        case .insights:        InsightsView()
        case .explore:         MetricExplorerView()
        case .compare:         CompareView()
        case .live:            LiveView()
        case .workouts:        WorkoutsView()
        case .health:          HealthView()
        case .labBook:         LabBookView()
        case .stress:          StressView()
        case .breathe:         BreathingView()
        case .intervals:       IntervalTimerView()
        case .rhythm:          RhythmHost()
        case .fusedRecord:     FusedRecordHost()
        case .appleHealth:     AppleHealthView()
        case .miBand:          XiaomiBandView()
        case .dataSources:     DataSourcesView()
        case .noopLimitations: NoopLimitationsView()
        case .backupSync:      BackupSyncView()
        case .alarms:          SmartAlarmView()
        case .automations:     AutomationsView()
        case .testCentre:      TestCentreView()
        case .powerSaving:     PowerSavingView()
        case .settings:        SettingsView()
        #if os(iOS)
        case .shortcutsExport: ShortcutExportSettingsView()
        case .siriShortcuts:   SiriShortcutsSettingsView()
        #endif
        }
    }
}

// MARK: - Groups

/// One titled group of the hub. `title` is display copy only — the hub no longer collapses, so no
/// group needs a persistence token.
private struct AuroraMoreGroup: Identifiable {
    let title: String
    let caption: String
    let items: [AuroraMoreDestination]
    var id: String { title }
}

private enum AuroraMoreCatalog {

    /// The four groups, in the original order, with the original membership. `.trends` joins
    /// Insights: it is the long-range interpretation screen, and it must be findable by the filter
    /// as well as reachable from the spotlight.
    static var groups: [AuroraMoreGroup] {
        var data: [AuroraMoreDestination] = [
            .fusedRecord, .appleHealth, .miBand, .dataSources, .backupSync,
        ]
        var app: [AuroraMoreDestination] = [
            .alarms, .automations, .testCentre,
        ]
        #if os(iOS)
        // #155: HealthKit-free Apple Health path for sideloaded installs.
        data.append(.shortcutsExport)
        app.append(.siriShortcuts)
        #endif
        // The plain 4.0 vs 5.0/MG capability grid — what NOOP reads live off each strap.
        data.append(.noopLimitations)
        // #477: the strap-battery levers are what people reach for when a strap is running down.
        app.append(.powerSaving)
        app.append(.settings)

        return [
            AuroraMoreGroup(title: String(localized: "Insights"),
                            caption: String(localized: "Make sense of the numbers"),
                            items: [.trends, .insightsHub, .intelligence, .coach,
                                    .insights, .explore, .compare]),
            AuroraMoreGroup(title: String(localized: "Body"),
                            caption: String(localized: "Live signals and sessions"),
                            items: [.live, .workouts, .health, .labBook,
                                    .stress, .breathe, .intervals, .rhythm]),
            AuroraMoreGroup(title: String(localized: "Data"),
                            caption: String(localized: "Where your numbers come from"),
                            items: data),
            AuroraMoreGroup(title: String(localized: "App"),
                            caption: String(localized: "Set NOOP up the way you want it"),
                            items: app),
        ]
    }

    /// Flat list for the filter, in group order.
    static var all: [AuroraMoreDestination] { groups.flatMap(\.items) }

    /// What "Jump back in" falls back to before this user has opened anything — the four screens a
    /// new NOOP user reaches for first. Every one of them ALSO keeps its row in its own group below:
    /// the tiles are a shortcut, not a relocation, so nothing is dropped from the index.
    static let seedShortcuts: [AuroraMoreDestination] = [.trends, .live, .workouts, .settings]

    /// Resolve a persisted shortcut token. Unknown tokens (a removed case, a downgrade) drop out.
    static func destination(forKey key: String) -> AuroraMoreDestination? {
        all.first { $0.key == key }
    }
}

// MARK: - Screen

/// The Aurora More hub: fixed title + filter chrome, the Trends spotlight, recency shortcuts, and
/// the four always-open groups.
///
/// Drop-in for the body of the original `moreTab`'s `NavigationStack` — it registers its own
/// `navigationDestination(for:)`, so the rows push onto whichever path the enclosing stack is bound
/// to. Pass `embedsNavigationStack: true` to use it standalone (a sheet, a macOS detail pane, a
/// preview) where no stack ancestor exists.
@MainActor
struct AuroraMoreView: View {

    /// Wrap the hub in its own `NavigationStack`. Default `false`: the iOS tab shell already owns a
    /// stack bound to the More tab's `NavigationPath`, and a nested stack there would break the
    /// pop-to-root-on-re-tap contract (#135/#198).
    private let embedsNavigationStack: Bool

    /// Register `tabRouteDestinations()` on this stack. Trends now lives BEHIND this hub, and Trends
    /// is a tab root: its metric cards push `TabRoute` VALUES (#198), which need a registration in
    /// the stack they land in. The original `moreTab` has none, so the default is `true`.
    ///
    /// Pass `false` if — and only if — the enclosing shell already calls `tabRouteDestinations()` on
    /// the same stack: the same value type resolving against two registrations double-pushes (#38).
    private let registersTabRoutes: Bool

    /// - Parameters:
    ///   - embedsNavigationStack: `true` only when this view has no `NavigationStack` ancestor.
    ///   - registersTabRoutes: `false` only when the enclosing stack already registers `TabRoute`.
    init(embedsNavigationStack: Bool = false, registersTabRoutes: Bool = true) {
        self.embedsNavigationStack = embedsNavigationStack
        self.registersTabRoutes = registersTabRoutes
    }

    /// The read model every More destination binds to. The hub itself uses it for pull-to-refresh —
    /// exactly as the original `moreTab` did via `ScreenScaffold(onRefresh:)` — and to read the
    /// recovery series the Trends spotlight graphs.
    @EnvironmentObject private var repo: Repository

    /// The "Jump back in" order: destination keys, most recently opened first, capped at
    /// `recentsMemory`. Presentation state only, in its own Aurora-namespaced key so nothing the
    /// original app persists is touched.
    @AppStorage("noop.aurora.moreRecents") private var recentsCSV = ""

    /// Bumped by the tab shell when the user re-taps the already-at-root More tab (#198 follow-up).
    @Environment(\.scrollToTopSignal) private var scrollToTopSignal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    #if os(iOS)
    /// iPad runs this screen full-width; cap the readable column exactly as `ScreenScaffold` does.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif

    /// The live filter over every row. Empty string = the full hub.
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// Drives the one-shot entrance sweep. Flipped in `onAppear`.
    @State private var appeared = false
    /// Points scrolled up, from `AuroraScrollOffsetProbe` — drives the chrome's separator only.
    @State private var scrollOffset: CGFloat = 0

    /// Zero-height scroll-to-top target.
    private let topAnchor = "aurora.more.top"
    /// Coordinate space for the scroll-offset probe.
    private static let space = "aurora.more.scroll"
    /// How many visited screens the shortcut row remembers behind the four it shows.
    private static let recentsMemory = 8
    /// How many shortcut tiles the row draws.
    private static let shortcutCount = 4

    var body: some View {
        if embedsNavigationStack {
            NavigationStack { routed }
        } else {
            routed
        }
    }

    /// The hub plus its route registrations. The rows push VALUES so an at-root re-tap of the More
    /// tab pops them off the enclosing stack's bound path (#135/#198).
    @ViewBuilder
    private var routed: some View {
        if registersTabRoutes {
            hub
                .navigationDestination(for: AuroraMoreDestination.self) { destinationChrome($0) }
                .tabRouteDestinations()
        } else {
            hub
                .navigationDestination(for: AuroraMoreDestination.self) { destinationChrome($0) }
        }
    }

    // MARK: Layout

    /// Fixed chrome over a scrolling index. The split is the point: the filter is the fastest route
    /// to any of these screens, so it never scrolls away.
    private var hub: some View {
        VStack(spacing: 0) {
            chrome
            index
        }
        .auroraCanvas()
        .onAppear { appeared = true }
    }

    private var index: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    AuroraScrollOffsetProbe(space: Self.space)
                    Color.clear.frame(height: 0).id(topAnchor)

                    LazyVStack(alignment: .leading, spacing: Aurora.Space.sectionGap) {
                        if trimmedQuery.isEmpty {
                            trendsSpotlight.entrance(appeared, index: 0, reduced: reduceMotion)
                            shortcutSection.entrance(appeared, index: 1, reduced: reduceMotion)

                            let groups = AuroraMoreCatalog.groups
                            ForEach(groups.indices, id: \.self) { i in
                                groupSection(groups[i])
                                    .entrance(appeared, index: 2 + i, reduced: reduceMotion)
                            }

                            footer.entrance(appeared, index: 2 + groups.count, reduced: reduceMotion)
                        } else {
                            resultsSection
                        }
                    }
                    .auroraGutter()
                    .padding(.top, Aurora.Space.l)
                    #if os(iOS)
                    // The tab bar floats over the scroll content; reserve room so the last card clears it.
                    .padding(.bottom, Aurora.Space.tabBarClearance)
                    .frame(maxWidth: hSizeClass == .regular ? 700 : .infinity,
                           alignment: hSizeClass == .regular ? .center : .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    #else
                    .padding(.bottom, Aurora.Space.xxl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    #endif
                }
            }
            .auroraScrollSpace(Self.space)
            .onAuroraScrollOffset { scrollOffset = $0 }
            #if os(iOS)
            // Keep a vertical scroll from rubber-banding sideways (the column never overflows the width).
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif
            .refreshable { await repo.refresh() }
            .onChangeCompat(of: scrollToTopSignal) { _ in
                withAnimation(Aurora.Motion.respecting(Aurora.Motion.slow, reduced: reduceMotion)) {
                    proxy.scrollTo(topAnchor, anchor: .top)
                }
            }
        }
    }

    @ViewBuilder
    private func destinationChrome(_ route: AuroraMoreDestination) -> some View {
        #if os(iOS)
        route.screen
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        #else
        route.screen
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
        #endif
    }

    // MARK: Chrome

    /// Title, screen count and the filter — pinned above the scroll view, with a separator that
    /// fades in only once content has moved under it.
    private var chrome: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Aurora.Space.s) {
                Text("More").auroraTitleLarge()
                Spacer(minLength: Aurora.Space.xs)
                Text(verbatim: "\(AuroraMoreCatalog.all.count)")
                    .auroraTabularLabel()
                    .padding(.horizontal, Aurora.Space.xs)
                    .padding(.vertical, 2)
                    .background(Capsule(style: .continuous).fill(Aurora.surfaceSubtle))
                    .accessibilityLabel(Text("\(AuroraMoreCatalog.all.count) screens"))
            }
            searchField
        }
        .auroraGutter()
        .padding(.top, Aurora.Space.xs)
        .padding(.bottom, Aurora.Space.s)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Aurora.hairline)
                .frame(height: Aurora.Stroke.hairline)
                .opacity(Double(min(max(scrollOffset, 0) / 14, 1)))
                .accessibilityHidden(true)
        }
    }

    // MARK: Filter

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matches(_ item: AuroraMoreDestination) -> Bool {
        let q = trimmedQuery
        guard !q.isEmpty else { return true }
        return item.title.localizedCaseInsensitiveContains(q)
            || item.subtitle.localizedCaseInsensitiveContains(q)
            || item.searchTerms.localizedCaseInsensitiveContains(q)
    }

    private var searchField: some View {
        HStack(spacing: Aurora.Space.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(searchFocused ? Aurora.accent : Aurora.textTertiary)

            TextField(String(localized: "Search every screen"), text: $query)
                .textFieldStyle(.plain)
                .font(AuroraType.body)
                .foregroundStyle(Aurora.textPrimary)
                .focused($searchFocused)
                .autocorrectionDisabled(true)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif

            if !query.isEmpty {
                Button {
                    withAnimation(Aurora.Motion.respecting(Aurora.Motion.fast, reduced: reduceMotion)) {
                        query = ""
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Aurora.textTertiary)
                }
                .buttonStyle(.auroraPress)
                .accessibilityLabel(Text("Clear"))
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Aurora.Space.s + 2)
        .frame(height: Aurora.Layout.controlHeight)
        .background(
            RoundedRectangle(cornerRadius: Aurora.Radius.m, style: .continuous)
                .fill(Aurora.surfaceInset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Aurora.Radius.m, style: .continuous)
                .strokeBorder(searchFocused ? Aurora.accentFocus : Aurora.hairline,
                              lineWidth: searchFocused ? Aurora.Stroke.emphasis : Aurora.Stroke.border)
        )
        .animation(Aurora.Motion.respecting(Aurora.Motion.fast, reduced: reduceMotion), value: searchFocused)
        .animation(Aurora.Motion.respecting(Aurora.Motion.fast, reduced: reduceMotion), value: query.isEmpty)
    }

    // MARK: Trends spotlight

    /// Trends lost its tab in the Aurora shell, so it opens the hub as the one dominant statement on
    /// the screen: the 14-night recovery average as a hero numeral in its own band colour, the house
    /// coaching line for that band, the change against the previous fortnight, and the shape itself.
    ///
    /// Every number here is read straight off `Repository.days` and averaged for display. No score is
    /// recomputed, and a missing series gets a named empty state rather than a zero.
    private var trendsSpotlight: some View {
        let window = recoveryWindow
        let tint = window.average.map { Aurora.recoveryColor($0) } ?? Aurora.statusNeutral

        return NavigationLink(value: AuroraMoreDestination.trends) {
            AuroraCard(elevation: .raised,
                       padding: Aurora.Space.l,
                       radius: Aurora.Radius.hero,
                       tint: tint) {
                VStack(alignment: .leading, spacing: Aurora.Space.m) {
                    HStack(spacing: Aurora.Space.s) {
                        AuroraMoreGlyph(icon: AuroraMoreDestination.trends.icon, tint: tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Trends").auroraHeadline()
                            Text("14-night recovery average").auroraFootnote()
                        }
                        Spacer(minLength: Aurora.Space.xs)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Aurora.textTertiary)
                    }

                    if window.values.isEmpty {
                        AuroraEmptyState(
                            icon: "chart.xyaxis.line",
                            headline: String(localized: "No recovery readings yet"),
                            message: String(localized: "Wear the strap overnight. Once NOOP has scored a night, your rolling average and its shape appear here."),
                            tint: Aurora.statusNeutral
                        )
                        .padding(.vertical, Aurora.Space.xs)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: Aurora.Space.s) {
                            AuroraRollingNumber(value: window.average,
                                                unit: "%",
                                                size: 60,
                                                color: tint)
                            if let change = window.change {
                                AuroraDeltaChip(value: change, unit: "%", higherIsBetter: true)
                            }
                        }

                        AuroraCoachLine.forRecovery(window.average)

                        if window.values.count > 1 {
                            AuroraSparkline(values: window.values,
                                            ramp: .recovery,
                                            range: 0...100,
                                            showsArea: true,
                                            showsHead: true)
                                .frame(height: 52)
                        }

                        Text(window.footnote).auroraFootnote()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.auroraPress)
        .simultaneousGesture(TapGesture().onEnded { remember(.trends) })
        .accessibilityLabel(Text(AuroraMoreDestination.trends.title))
        .accessibilityValue(Text(window.accessibilityValue))
        .accessibilityHint(Text(AuroraMoreDestination.trends.subtitle))
    }

    /// The recovery figures behind the spotlight. Pure formatting over `Repository.days`.
    private struct RecoveryWindow {
        /// The trailing 14 nights that have a recovery score, oldest first.
        var values: [Double] = []
        /// Mean of `values`, or `nil` when there are none.
        var average: Double?
        /// Change against the mean of the 14 nights before those, or `nil` when that is unavailable.
        var change: Double?
        var footnote = ""
        var accessibilityValue = ""
    }

    private var recoveryWindow: RecoveryWindow {
        let cal = Calendar.current
        let today = Date()
        // Two adjacent fortnights, keyed the same way every other Aurora screen keys a day.
        let recentCutoff = Repository.localDayKey(cal.date(byAdding: .day, value: -13, to: today) ?? today)
        let priorCutoff = Repository.localDayKey(cal.date(byAdding: .day, value: -27, to: today) ?? today)

        let rows = repo.days
            .compactMap { row -> (day: String, value: Double)? in
                row.recovery.map { (row.day, $0) }
            }
            .sorted { $0.day < $1.day }

        let recent = rows.filter { $0.day >= recentCutoff }
        let prior = rows.filter { $0.day >= priorCutoff && $0.day < recentCutoff }

        var window = RecoveryWindow()
        window.values = recent.map(\.value)

        guard !recent.isEmpty else {
            window.accessibilityValue = String(localized: "No recovery readings yet")
            return window
        }

        let mean = recent.reduce(0) { $0 + $1.value } / Double(recent.count)
        window.average = mean

        if !prior.isEmpty {
            let priorMean = prior.reduce(0) { $0 + $1.value } / Double(prior.count)
            window.change = mean - priorMean
        }

        let nights = recent.count
        window.footnote = window.change == nil
            ? String(localized: "\(nights) scored nights in the last fortnight")
            : String(localized: "\(nights) scored nights, versus the fortnight before")
        window.accessibilityValue = String(localized: "\(Int(mean.rounded())) percent average recovery over \(nights) nights")
        return window
    }

    // MARK: Jump back in

    /// The four screens this user opened most recently, seeded with sensible defaults until they
    /// have opened anything. Recency, not an editor's pick — the row is only worth its space if it
    /// is right most of the time.
    private var shortcuts: [AuroraMoreDestination] {
        var out: [AuroraMoreDestination] = []
        for key in recentsCSV.split(separator: ",").map(String.init) {
            guard let item = AuroraMoreCatalog.destination(forKey: key), !out.contains(item) else { continue }
            out.append(item)
        }
        for item in AuroraMoreCatalog.seedShortcuts where !out.contains(item) {
            out.append(item)
        }
        return Array(out.prefix(Self.shortcutCount))
    }

    /// Move a destination to the front of the shortcut order. Called from a tap gesture that runs
    /// ALONGSIDE the navigation link, so it can never swallow the push.
    private func remember(_ item: AuroraMoreDestination) {
        var keys = recentsCSV.split(separator: ",").map(String.init).filter { $0 != item.key }
        keys.insert(item.key, at: 0)
        recentsCSV = keys.prefix(Self.recentsMemory).joined(separator: ",")
    }

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.s) {
            AuroraSectionHeader(String(localized: "Jump back in"),
                                subtitle: String(localized: "Where you were last"))

            HStack(spacing: Aurora.Space.xs) {
                ForEach(shortcuts) { item in
                    NavigationLink(value: item) {
                        AuroraMoreShortcutTile(item: item)
                    }
                    .buttonStyle(.auroraPress)
                    .simultaneousGesture(TapGesture().onEnded { remember(item) })
                    .accessibilityLabel(Text(item.title))
                    .accessibilityHint(Text(item.subtitle))
                }
            }
        }
    }

    // MARK: Groups

    private func groupSection(_ group: AuroraMoreGroup) -> some View {
        VStack(alignment: .leading, spacing: Aurora.Space.s) {
            AuroraSectionHeader(group.title, subtitle: group.caption)
            rowsCard(group.items)
        }
    }

    /// One grouped card of rows: zero card padding so each row owns its own insets, hairlines between
    /// rows only, clipped to the card shape so no divider runs past a rounded corner.
    private func rowsCard(_ items: [AuroraMoreDestination]) -> some View {
        AuroraCard(padding: 0) {
            VStack(spacing: 0) {
                ForEach(items.indices, id: \.self) { index in
                    NavigationLink(value: items[index]) {
                        AuroraMoreRow(item: items[index])
                    }
                    .buttonStyle(.auroraPress)
                    .simultaneousGesture(TapGesture().onEnded { remember(items[index]) })
                    .accessibilityLabel(Text(items[index].title))
                    .accessibilityHint(Text(items[index].subtitle))

                    if index < items.count - 1 {
                        AuroraDivider(inset: AuroraMoreRow.textInset)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Aurora.Radius.card, style: .continuous))
        }
    }

    // MARK: Results

    /// The filtered view. Groups collapse away entirely while a query is active — a filter that still
    /// shows four headers has not filtered anything — and a query that matches nothing gets a designed
    /// state rather than a blank page.
    @ViewBuilder
    private var resultsSection: some View {
        let hits = AuroraMoreCatalog.all.filter(matches)

        if hits.isEmpty {
            AuroraCard {
                AuroraEmptyState(
                    icon: "magnifyingglass",
                    headline: String(localized: "Nothing matches that"),
                    message: String(localized: "Try a shorter word, or clear the filter to see every screen."),
                    actionTitle: String(localized: "Clear filter"),
                    action: {
                        withAnimation(Aurora.Motion.respecting(Aurora.Motion.fast, reduced: reduceMotion)) {
                            query = ""
                        }
                    }
                )
            }
        } else {
            VStack(alignment: .leading, spacing: Aurora.Space.s) {
                AuroraSectionHeader(String(localized: "Results"),
                                    subtitle: hits.count == 1
                                        ? String(localized: "1 screen")
                                        : String(localized: "\(hits.count) screens"))
                rowsCard(hits)
            }
        }
    }

    // MARK: Footer

    /// Build identity, set quietly at the foot of the index — the single most-asked-for fact in a bug
    /// report, and the natural place for it is the screen that also holds the Test Centre.
    private var footer: some View {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return VStack(spacing: 2) {
            Text(verbatim: "NOOP \(short) (\(build))").auroraFootnote()
            Text("Aurora preview").auroraFootnote()
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "NOOP \(short), build \(build), Aurora preview"))
    }
}

// MARK: - Row

/// One destination row: a tinted glyph plate, the title, one line of subtitle, and the single
/// chevron every row in the hub shares. ~56pt tall, so the whole row is a comfortable tap target.
private struct AuroraMoreRow: View {
    let item: AuroraMoreDestination

    /// Leading inset for the divider between rows, so hairlines start under the TEXT, not under the
    /// glyph — the alignment that makes a grouped list read as one column instead of two.
    static let textInset: CGFloat = Aurora.Space.m + AuroraMoreGlyph.size + Aurora.Space.s

    var body: some View {
        HStack(spacing: Aurora.Space.s) {
            AuroraMoreGlyph(icon: item.icon, tint: item.accent)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).auroraBodyStrong()
                Text(item.subtitle)
                    .auroraFootnote()
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: Aurora.Space.xs)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Aurora.textTertiary)
        }
        .padding(.horizontal, Aurora.Space.m)
        .padding(.vertical, Aurora.Space.s - 2)
        .frame(minHeight: Aurora.Layout.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Shortcut tile

/// One compact "Jump back in" tile. Same glyph and same tint as its row below, so the shortcut and
/// the index entry read as the same object seen twice, not two different things.
private struct AuroraMoreShortcutTile: View {
    let item: AuroraMoreDestination

    var body: some View {
        AuroraCard(elevation: .raised,
                   padding: Aurora.Space.s,
                   radius: Aurora.Radius.tile,
                   tint: item.accent) {
            VStack(spacing: Aurora.Space.xs) {
                AuroraMoreGlyph(icon: item.icon, tint: item.accent)
                Text(item.shortTitle)
                    .auroraCaptionStrong()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(minHeight: Aurora.Layout.minTapTarget + Aurora.Space.xl)
    }
}

// MARK: - Glyph plate

/// The tinted icon container shared by rows, tiles and the spotlight: a soft wash of the
/// destination's own colour, a hairline of the same hue, and the symbol at full strength on top.
private struct AuroraMoreGlyph: View {
    let icon: String
    let tint: Color

    static let size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: Aurora.Radius.s, style: .continuous)
            .fill(tint.opacity(0.14))
            .overlay(
                RoundedRectangle(cornerRadius: Aurora.Radius.s, style: .continuous)
                    .strokeBorder(tint.opacity(0.22), lineWidth: Aurora.Stroke.hairline)
            )
            .overlay(
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            )
            .frame(width: Self.size, height: Self.size)
            .accessibilityHidden(true)
    }
}

// MARK: - Entrance

private extension View {
    /// The hub's one-shot entrance: each band fades up 10pt, staggered ~35ms apart and capped well
    /// under a quarter second in total. Suppressed entirely under Reduce Motion.
    func entrance(_ appeared: Bool, index: Int, reduced: Bool) -> some View {
        self
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
            .animation(
                Aurora.Motion.respecting(
                    Aurora.Motion.standard.delay(min(Double(index) * 0.035, 0.21)),
                    reduced: reduced
                ),
                value: appeared
            )
    }
}

#if DEBUG
#Preview("Aurora More") {
    AuroraMoreView(embedsNavigationStack: true)
        .environmentObject(Repository(deviceId: "preview"))
        .frame(width: 420, height: 900)
        .preferredColorScheme(.dark)
}
#endif
