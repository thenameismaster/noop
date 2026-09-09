#if os(iOS)
import SwiftUI
import StrandDesign

/// iOS navigation shell. macOS uses a `NavigationSplitView` sidebar (`RootView`); on iPhone the
/// natural analogue is a `TabView` with the most-used screens as tabs and everything else under a
/// "More" list. Every screen is the same `StrandDesign`-built view the macOS app uses.
struct RootTabView: View {
    /// External entry points must wait until the mandatory first-run gates have completed. The root owns
    /// that state; keeping it explicit here prevents this shell's window-level sheet from covering a gate.
    let homeScreenQuickActionsEnabled: Bool

    @EnvironmentObject private var repo: Repository
    /// Cross-screen navigation requests (e.g. Live → "Manage devices"). Devices isn't a tab — it lives
    /// behind the More list — so a request presents it as a sheet, matching the quick-action screens.
    @EnvironmentObject private var router: NavRouter
    /// The scene-local receiver for actions chosen from NOOP's Home Screen icon menu.
    @EnvironmentObject private var homeScreenQuickActions: HomeScreenQuickActionSceneDelegate

    /// Which quick-action screen the centre FAB is presenting (nil = sheet closed).
    @State private var quickAction: QuickAction?
    /// Presents the Devices manager (pair / switch bands) when a screen asks the shell to open it.
    @State private var showDevices = false
    /// A routed v5 pillar screen (Insights hub / Lab Book / fused record / Rhythm) presented as a sheet
    /// when a hub row deep-links to it via NavRouter. nil = closed.
    @State private var routedPillar: NavRouter.Destination?
    /// Selected tab — bound so tab switches can crossfade (README §Motion: ~240ms opacity swap
    /// between tab roots, calm easing). Defaults to Today.
    @State private var selectedTab: Int = 0
    /// One `NavigationPath` per tab, indexed by tab tag. Re-tapping the already-active tab pops
    /// that tab's stack to its root (#135) by clearing its path — an animated pop that leaves the
    /// root view alive, so an at-root re-tap keeps scroll position and never re-runs `.task`
    /// (#198; the #197 resetID/`.id()` rebuild reset both). Requires the tab roots' first-hop
    /// links to push `TabRoute`/`MoreDestination` VALUES — closure-destination links bypass the path.
    ///
    /// SIZED FOR THE LARGEST SHELL, not the active one. The classic shell has 4 tabs and the Aurora
    /// shell has 5, and the flag can flip at runtime from Settings — so this array is allocated at 5
    /// unconditionally. A conditionally-sized array would make `tabPaths[selectedTab]` (read on every
    /// body pass, in the gesture mask) a crash the instant the user toggled the flag while on the last
    /// tab. The classic path is unaffected: index 4 is simply never addressed while the flag is off.
    @State private var tabPaths: [NavigationPath] = Array(repeating: NavigationPath(), count: 5)
    /// One scroll-to-top token per tab. Bumped when the user re-taps the active tab while it's ALREADY
    /// at its root — the other half of the iOS convention #197/#198 left unserved (an at-root re-tap was
    /// a no-op). Threaded into each tab's root via `\.scrollToTopSignal`; ScreenScaffold / LiquidTodayView
    /// scroll to their top anchor when their tab's token changes.
    /// Sized at 5 for the same reason `tabPaths` is — see the note there.
    @State private var scrollTop: [Int] = Array(repeating: 0, count: 5)
    /// Which More-tab groups are expanded (S2). Insights + Body stay open at rest; Data + App collapse to
    /// just their header until tapped. Persisted (#860 item 2): the user's open/closed choice must SURVIVE
    /// leaving and re-entering the More tab (and relaunch), not reset to the seed every visit. Backed by an
    /// `@AppStorage` CSV string (keyed identically to the Android `MoreSectionPrefs`), bridged to a
    /// `Set<String>` through `MoreSectionPrefs` so the section logic below is unchanged.
    @AppStorage(MoreSectionPrefs.storageKey) private var expandedMoreSectionsCSV = MoreSectionPrefs.defaultCSV
    private var expandedMoreSections: Set<String> { MoreSectionPrefs.decode(expandedMoreSectionsCSV) }

    /// V8 liquid redesign is the default Today; the Settings toggle lets a user fall back to the classic
    /// Today if they prefer it (keyed identically to the SettingsView toggle). Default ON.
    @AppStorage("noop.liquidTodayEnabled") private var liquidTodayEnabled = true

    /// Aurora UI (preview) — an ADDITIVE redesigned shell over the same data. Default OFF, so the
    /// shipped experience is untouched unless the user opts in from Settings. Keyed identically to the
    /// SettingsView toggle and the macOS shell (`RootView`).
    @AppStorage("noop.auroraUIEnabled") private var auroraUIEnabled = false

    /// Ledger UI — the "Athlete's Ledger" redesign (`design_handoff_noop_redesign`). Like Aurora it is
    /// ADDITIVE and toggle-gated, default OFF, so the shipped experience is byte-for-byte unchanged
    /// unless the user opts in from Settings. It takes PRECEDENCE over Aurora when both are on, because
    /// it is the newer fork; the key is shared with `SettingsView` and the macOS shell (`RootView`).
    @AppStorage(LedgerFlags.ledgerUIEnabledKey) private var ledgerUIEnabled = false

    /// The navigation path for the Ledger shell's "…" overflow sheet. The Ledger shell has no More
    /// TAB, so the More hub is presented as a sheet and needs a stack of its own — it cannot borrow a
    /// tab's path without letting a sheet push onto a tab that is still on screen behind it.
    @State private var ledgerOverflowPath = NavigationPath()

    /// The CLASSIC Today tab root: the liquid redesign by default, the classic Today if the user
    /// prefers it. The Aurora preview no longer swaps a root in place — it swaps the whole shell
    /// (`auroraShell`), because its tab STRUCTURE differs, so this property is reached only while the
    /// Aurora flag is off and is byte-for-byte the pre-Aurora behaviour.
    @ViewBuilder private var todayTabRoot: some View {
        if liquidTodayEnabled { LiquidTodayView() } else { TodayView() }
    }

    /// The classic Trends tab root. Aurora has no Trends TAB — Trends lives behind the Aurora More
    /// hub (`AuroraMoreDestination.trends`), which is that hub's own spotlight subject.
    @ViewBuilder private var trendsTabRoot: some View {
        TrendsView()
    }

    /// The classic Sleep tab root.
    @ViewBuilder private var sleepTabRoot: some View {
        SleepView()
    }

    /// The highest valid tab index for the ACTIVE shell: 3 classic (Today/Trends/Sleep/More), 4 Aurora
    /// (Today/Recovery/Strain/Sleep/More). Every index-clamping site reads this rather than a literal,
    /// so the swipe gesture and the flag-flip clamp can never address a tab the shell does not show.
    private var lastTabIndex: Int { (ledgerUIEnabled || auroraUIEnabled) ? 4 : 3 }

    /// Native tab selection binding. SwiftUI sends taps on the already-selected item through the
    /// setter, which lets the system tab bar retain the app's refresh / pop-to-root / scroll-to-top
    /// convention without placing a custom hit-testing layer over the platform bar.
    private var nativeTabSelection: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { tag in
                if tag == selectedTab {
                    reselectTab(tag)
                } else {
                    selectedTab = tag
                }
            }
        )
    }

    private func reselectTab(_ tag: Int) {
        Task { await repo.refresh() }
        if !tabPaths[tag].isEmpty {
            tabPaths[tag] = NavigationPath()
        } else {
            scrollTop[tag] += 1
        }
    }

    /// The anywhere-swipe tab-switch drag (2026-07-02). Held as a property so the attachment site can
    /// enable or disable it through a `GestureMask` instead of attaching it conditionally: a conditional
    /// attachment changes view identity, and this condition toggles on every push and pop, which would
    /// rebuild the tab roots underneath it. The same class of rebuild is what #197 caused with an
    /// `.id()` reset and #198 had to undo — it lost scroll position and re-ran `.task`.
    ///
    /// Only a decisive horizontal flick switches tabs, and Today is carved out because it uses
    /// horizontal swipe to change DAYS. Both thresholds are unchanged from the original gesture.
    private var tabSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { v in
                // Today (tab 0) uses horizontal swipe to change DAYS, so tab-swipe is off there.
                guard selectedTab != 0 else { return }
                // The Ledger Sleep tab (tab 1) uses horizontal swipe to browse NIGHTS — same carve-out.
                guard !(ledgerUIEnabled && selectedTab == 1) else { return }
                let dx = v.translation.width, dy = v.translation.height
                guard abs(dx) > 60, abs(dx) > abs(dy) * 1.6 else { return }
                // Clamp to the ACTIVE shell's last tab, not a literal 3: the Aurora shell has five
                // tabs, and a hard 3 would make the last tab unreachable by swipe there.
                let next = min(lastTabIndex, max(0, selectedTab + (dx < 0 ? 1 : -1)))
                if next != selectedTab {
                    withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = next }
                }
            }
    }

    /// The tab shell. Two WHOLE TabViews behind one flag rather than conditional children inside a
    /// single TabView: the Aurora fork changes the tab STRUCTURE (five pillars, no Trends tab), not
    /// just what a tab root renders, and position 3 is a different KIND of tab in each (More vs
    /// Sleep). Branching at the TabView itself keeps each configuration statically shaped — no
    /// `_ConditionalContent` children with tags for the platform bar to reconcile — and means the
    /// classic shell below is the pre-Aurora expression verbatim.
    @ViewBuilder private var shell: some View {
        if ledgerUIEnabled { ledgerShell } else if auroraUIEnabled { auroraShell } else { classicShell }
    }

    /// The shipped four-tab shell. UNCHANGED from before the Aurora fork.
    private var classicShell: some View {
        // The platform tab bar is intentionally left fully native. iOS 26 supplies Liquid Glass and
        // its dynamic interaction with scrolling content automatically; older supported releases use
        // the corresponding system material and safe-area behaviour from the same TabView.
        TabView(selection: nativeTabSelection) {
            tab(todayTabRoot, "Today", "square.grid.2x2", path: $tabPaths[0], scrollSignal: scrollTop[0]).tag(0)
            tab(trendsTabRoot, "Trends", "chart.line.uptrend.xyaxis", path: $tabPaths[1], scrollSignal: scrollTop[1]).tag(1)
            tab(sleepTabRoot, "Sleep", "bed.double", path: $tabPaths[2], scrollSignal: scrollTop[2]).tag(2)
            moreTab(path: $tabPaths[3], scrollSignal: scrollTop[3]).tag(3)
        }
    }

    /// The Aurora five-tab shell: one tab per PILLAR. The overview summarises and the three pillar
    /// tabs are the full screens it summarises, so a pillar is one tap away from anywhere rather than
    /// a push buried under Today. Trends is demoted out of the bar (it is the More hub's spotlight),
    /// and Body is deliberately NOT a tab — it is reached from Today's vitals row and from More, so
    /// the bar stays at the five things a wearer checks daily.
    private var auroraShell: some View {
        TabView(selection: nativeTabSelection) {
            tab(AuroraTodayView(), "Today", "square.grid.2x2", path: $tabPaths[0], scrollSignal: scrollTop[0]).tag(0)
            tab(AuroraRecoveryView(), "Recovery", "bolt.heart", path: $tabPaths[1], scrollSignal: scrollTop[1]).tag(1)
            tab(AuroraStrainView(), "Strain", "flame", path: $tabPaths[2], scrollSignal: scrollTop[2]).tag(2)
            tab(AuroraSleepView(), "Sleep", "bed.double", path: $tabPaths[3], scrollSignal: scrollTop[3]).tag(3)
            moreTab(path: $tabPaths[4], scrollSignal: scrollTop[4]).tag(4)
        }
    }

    /// The Ledger five-tab shell: Today · Sleep · Body · Activity · Trends (spec item 7). There is no
    /// More TAB — the old More list moves behind the "…" affordance in the Today header, where all 28
    /// destinations keep their existing routes.
    ///
    /// The system tab bar is HIDDEN and `LedgerTabBar` is supplied through a `safeAreaInset` instead,
    /// because the spec's bar is custom art (line glyphs transcribed from the board's SVGs, a mint dot
    /// on the active item). A `safeAreaInset` — rather than an `overlay` — is what makes every screen's
    /// scroll content inset itself above the bar automatically, so nothing hides underneath it.
    ///
    /// This is still a real `TabView`, which is the point: all five roots stay ALIVE across switches, so
    /// scroll position survives and `.task` does not re-run — the same contract the classic shell has.
    /// Selection stays the shared `Int` `selectedTab`, so the swipe gesture, the pop-to-root/scroll-to-top
    /// conventions (#135/#198) and the flag-flip clamp all keep working untouched.
    private var ledgerShell: some View {
        TabView(selection: nativeTabSelection) {
            ledgerTab(LedgerTodayView(),    tab: .today,    path: $tabPaths[0], scrollSignal: scrollTop[0]).tag(0)
            ledgerTab(LedgerSleepView(),    tab: .sleep,    path: $tabPaths[1], scrollSignal: scrollTop[1]).tag(1)
            ledgerTab(LedgerBodyView(),     tab: .body,     path: $tabPaths[2], scrollSignal: scrollTop[2]).tag(2)
            ledgerTab(LedgerActivityView(), tab: .activity, path: $tabPaths[3], scrollSignal: scrollTop[3]).tag(3)
            ledgerTab(LedgerTrendsView(),   tab: .trends,   path: $tabPaths[4], scrollSignal: scrollTop[4]).tag(4)
        }
        // Spec §01.7 — the old More list moves behind the Today header's "…", with all 28 destinations
        // keeping their EXISTING routes. Injecting `moreTab` itself is what guarantees that: it is the
        // very same list the classic shell's More tab renders, not a copy that could drift out of sync.
        // `ledgerShellActive` is explicitly false: the sheet is presented from inside a Ledger tab
        // stack (whose environment it inherits), but it hosts the CLASSIC hub, so its metric pushes
        // must open the classic detail.
        .environment(\.ledgerOverflowContent, AnyView(
            ledgerOverflowTab()
                .environment(\.ledgerShellActive, false)
        ))
        // Spec §Tap Map routes some Today taps to a TAB ("last-night strip → Sleep tab"); only this
        // shell owns tab selection, so the ability is injected. Runs through `ledgerTabBinding`, the
        // same path the bar's own taps take.
        .environment(\.ledgerSwitchTab) { tab in
            ledgerTabBinding.wrappedValue = tab
        }
    }

    /// Bridges `LedgerTabBar`'s `LedgerTab` selection onto the shared integer `selectedTab`, so the
    /// Ledger bar drives the very same state the classic and Aurora bars do.
    ///
    /// The getter CLAMPS rather than subscripting blind: `selectedTab` can briefly hold a value from a
    /// wider shell while a flag flip settles, and an unclamped `allCases[selectedTab]` would trap. The
    /// setter never has to handle a re-tap — `LedgerTabBar` routes those to `onReselect` itself.
    private var ledgerTabBinding: Binding<LedgerTab> {
        Binding(
            get: { LedgerTab.allCases[max(0, min(selectedTab, LedgerTab.allCases.count - 1))] },
            set: { newTab in
                guard let index = LedgerTab.allCases.firstIndex(of: newTab) else { return }
                if index != selectedTab { selectedTab = index }
            }
        )
    }

    /// A Ledger tab container. Deliberately mirrors `tab(_:_:_:path:scrollSignal:)` — its own
    /// `NavigationStack` bound to the tab's path (so a re-tap pops to root, #135/#198), the shared
    /// `tabRouteDestinations()` registration done ONCE per stack (#38), and the scroll-to-top token —
    /// differing only in that it paints the Ledger canvas and hides the system tab bar.
    private func ledgerTab<V: View>(_ view: V, tab: LedgerTab, path: Binding<NavigationPath>, scrollSignal: Int) -> some View {
        NavigationStack(path: path) {
            view
                .background(Ledger.bgScreen.ignoresSafeArea())
                // Restores the left-edge swipe-back that hiding the navigation bar (below) turns
                // off. The Ledger's pushed screens draw their own "‹ Trends" back link, but the
                // EDGE GESTURE is the way iOS hands actually go back, and UIKit disables its
                // recognizer whenever the bar is hidden. See `LedgerBackSwipeEnabler`.
                .background(LedgerBackSwipeEnabler())
                .toolbar(.hidden, for: .navigationBar)
                .toolbar(.hidden, for: .tabBar)
                .tabRouteDestinations()
        }
        .environment(\.scrollToTopSignal, scrollSignal)
        // The Ledger's tab bar, attached PER TAB rather than once around the `TabView`.
        //
        // WHY NOT ON THE TABVIEW. `safeAreaInset` only insets the view it is applied to. Around the
        // TabView it placed the bar correctly but never shrank the pages inside — each page hides the
        // system tab bar (`.toolbar(.hidden, for: .tabBar)`) and laid itself out over the bar's strip
        // — so a screen's last section (Today's COACH note, the detail's MOVES WITH rows) sat under
        // the bar with no way to scroll it clear: a drag revealed it and the release bounced it back.
        //
        // Applied to the STACK, the inset is the documented case: it reserves the bar's height inside
        // the page, every ScrollView within ends above the bar, and pushed destinations inherit it, so
        // the bar keeps spanning a push exactly as it did before. Each tab therefore renders its own
        // bar, but all of them read and drive the SAME `ledgerTabBinding`, so they are identical and
        // the visible one is always in sync. That also makes the reserve self-correcting: it is the
        // real bar's height, on every device, with no measurement to drift.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LedgerTabBar(selection: ledgerTabBinding, onReselect: { _ in reselectTab(selectedTab) })
        }
        // …and the matching CONTENT margin. The inset above draws the bar, but it does not shorten the
        // scroll views inside the page — the pages hide the system tab bar and lay themselves out over
        // the bar's strip, so a screen's last section (Today's COACH note, the detail's MOVES WITH
        // rows) sat under the bar with no way to scroll it clear: a drag revealed it and the release
        // bounced it straight back. `contentMargins` addresses the scroll CONTENT itself, which is
        // exactly the thing that has to end above the bar, and it reaches every scroll view in the
        // subtree — the tab root and everything pushed on top of it.
        .contentMargins(.bottom, LedgerTabBar.reservedHeight, for: .scrollContent)
        // Marks this stack as the Ledger's, so the shared TabRoute table resolves metric pushes to
        // `LedgerMetricDetailView` (spec §06) instead of the classic detail. Set on the STACK so
        // pushed destinations inherit it; the "…" overflow sheet marks itself back off, because it
        // hosts the classic More list whose pushes must stay classic.
        .environment(\.ledgerShellActive, true)
        // …and names the owning tab, so a pushed detail's back link reads its real origin
        // ("‹ Body" from Body) instead of the spec sheet's Trends-side default.
        .environment(\.ledgerBackTitle, tab.title)
    }

    var body: some View {
        shell
        .tint(StrandPalette.accent)
            // Tab crossfade — README §Motion: ~240ms opacity swap between tab roots, global calm
            // easing cubic-bezier(0.22,1,0.36,1).
            .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24), value: selectedTab)
            // Swipe left/right anywhere to move between tabs (2026-07-02), but ONLY while the current
            // tab is at its root. Attaching this ancestor drag gesture unconditionally defeated the
            // edge-restriction of a pushed NavigationStack screen's native interactive-pop gesture —
            // any More-tab subscreen (Settings, Devices, …) became draggable/rubber-banding from
            // anywhere, not just the left edge (#519). Disabling the recognizer once a push is active,
            // rather than just gating the onEnded action, is what stops the interference: the action
            // never runs early enough, because the recognizer competes during recognition.
            //
            // The mask does that WITHOUT changing view identity. #519 attached the gesture through a
            // conditional ViewModifier, which put the two states in separate _ConditionalContent
            // branches — and since this condition toggles on every push and pop, each navigation
            // rebuilt the whole TabView subtree and could reset @State inside the tab roots (scroll
            // offsets, chart ranges, expanded sections). `including:` keeps one view type in both
            // states, so nothing is torn down.
            //
            // The mask MUST be `.subviews`, not `.none`. `.subviews` means "enable the subview
            // hierarchy's gestures, disable the added one" — exactly this requirement. `.none` disables
            // the subview hierarchy TOO, which on a pushed screen would take out scrolling, taps and the
            // interactive-pop itself: far worse than the bug being fixed.
            .simultaneousGesture(tabSwipeGesture,
                                 including: tabPaths[selectedTab].isEmpty ? .all : .subviews)
        .task {
            await repo.refresh()
            // Backup & Sync: on-launch catch-up (see RootView). Detached + utility priority so a
            // 100MB+ whole-DB ZIP never blocks startup; gated on the auto toggle (default OFF). (Must-fix #4.)
            let backupRepo = repo
            Task.detached(priority: .utility) {
                await FolderBackup.catchUpIfDue(checkpoint: { await backupRepo.checkpointForBackup() })
            }
        }
        // Quick-action sheet presents with the calm easing (~0.42s) per the README sheet spec —
        // the easing is applied where `quickAction` is set (see `presentQuickAction`), keeping the
        // animation scoped to the sheet rather than the whole shell.
        .sheet(item: $quickAction) { action in
            quickActionDestination(action)
        }
        // Live's "Manage devices" affordance (and any future cross-screen link to Devices) routes here:
        // present the Devices manager in its own nav stack, the same way the quick-action screens do.
        .sheet(isPresented: $showDevices) {
            devicesScreen
        }
        // v5 pillar deep-links (Insights hub / Lab Book / fused record / Rhythm) present as a sheet in
        // their own nav stack — the same idiom the quick-action + Devices screens use on iPhone.
        .sheet(item: $routedPillar) { dest in
            pillarScreen(dest)
        }
        // Honour a router request: Devices keeps its dedicated sheet; the v5 pillars route through the
        // shared pillar sheet. Cleared so the same tap can fire again later.
        .onChange(of: router.requestedDestination) { _, dest in
            switch dest {
            case .devices:
                showDevices = true
                router.requestedDestination = nil
            case .insightsHub, .labBook, .fusedRecord, .rhythm:
                routedPillar = dest
                router.requestedDestination = nil
            case .trends:
                if auroraUIEnabled {
                    // The Aurora shell has NO Trends tab (tab 1 is Recovery there, so switching to it
                    // would land the user on the wrong screen). Trends lives behind the More hub, so a
                    // deep-link presents it through the shared pillar sheet instead.
                    routedPillar = .trends
                } else {
                    // Trends is a primary tab on iPhone (not a pillar sheet) — switch to it.
                    withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 1 }
                }
                router.requestedDestination = nil
            case .activeWorkout:
                // The Today active-workout indicator opens Live through the quick-action Live sheet; once
                // it's up, LiveView consumes the one-shot `presentActiveWorkout` flag and presents the
                // in-exercise screen. Calm sheet easing, matching the other quick-action presents.
                withAnimation(Self.sheetEase) { quickAction = .live }
                router.requestedDestination = nil
            case .liveSession:
                // Live Sessions is presented from Today's own Start entry (a cover, not a routed sheet),
                // so a deep-link lands on the Today tab where that entry lives.
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 0 }
                router.requestedDestination = nil
            case .journal:
                // The #627 Today journal widget opens the journal through the quick-action Journal sheet
                // (InsightsView), matching the FAB's "Log journal" action. Calm sheet easing.
                withAnimation(Self.sheetEase) { quickAction = .journal }
                router.requestedDestination = nil
            case nil:
                break
            }
        }
        // A screen's top-bar "+" routes here: open the quick-action sheet, then clear the flag.
        .onChange(of: router.quickActionsRequested) { _, req in
            if req {
                withAnimation(Self.sheetEase) { quickAction = .menu }
                router.quickActionsRequested = false
            }
        }
        // A cold-launch selection is already pending when this shell appears; a warm selection arrives
        // through the change callback. Both route through the same screens as the centre FAB.
        .onAppear {
            presentPendingHomeScreenQuickActionIfPossible()
        }
        .onChange(of: homeScreenQuickActions.pendingAction) { _, _ in
            presentPendingHomeScreenQuickActionIfPossible()
        }
        .onChange(of: homeScreenQuickActionsEnabled) { _, _ in
            presentPendingHomeScreenQuickActionIfPossible()
        }
        // Turning Aurora OFF drops the shell from five tabs to four. If the user was sitting on tab 4
        // (More) the selection would survive with no tab claiming that tag, leaving the bar showing no
        // selected item. Clamp to the new last index and land them on the equivalent screen (More is the
        // last tab in BOTH shells). `tabPaths`/`scrollTop` are sized 5 either way, so no index goes stale.
        .onChange(of: auroraUIEnabled) { _, _ in
            if selectedTab > lastTabIndex { selectedTab = lastTabIndex }
        }
        // Same clamp for the Ledger flag: turning it OFF can drop a five-tab shell to the classic
        // four, and `lastTabIndex` already accounts for both forks.
        .onChange(of: ledgerUIEnabled) { _, _ in
            if selectedTab > lastTabIndex { selectedTab = lastTabIndex }
        }
    }

    /// Mandatory launch gates defer an external action. Once the shell is available, an explicit Home
    /// Screen choice supersedes any ordinary shell sheet; choosing the already-open destination simply
    /// consumes the request and leaves that screen in place.
    private func presentPendingHomeScreenQuickActionIfPossible() {
        guard homeScreenQuickActionsEnabled,
              let action = homeScreenQuickActions.pendingAction else { return }

        let destination: QuickAction = switch action {
        case .liveHeartRate: .live
        case .startWorkout: .workout
        case .logJournal: .journal
        case .breathe: .breathe
        }
        homeScreenQuickActions.consume(action)
        withAnimation(Self.sheetEase) {
            showDevices = false
            routedPillar = nil
            quickAction = destination
        }
    }

    /// A routed v5 pillar screen wrapped in its own nav stack + Done button (mirrors `quickScreen`).
    @ViewBuilder
    private func pillarScreen(_ dest: NavRouter.Destination) -> some View {
        NavigationStack {
            Group {
                switch dest {
                case .insightsHub: InsightsHubView()
                case .labBook: LabBookView()
                case .fusedRecord: FusedRecordHost()
                case .rhythm: RhythmHost(onClose: { routedPillar = nil })
                case .devices: DevicesView()
                // .trends reaches the pillar host only in the Aurora shell, which has no Trends tab
                // (the classic shell switches `selectedTab` instead — see the requestedDestination
                // handler). Render the fork's own Trends screen there; on iOS it supplies no stack of
                // its own, so this host's stack + `tabRouteDestinations()` is exactly what it needs.
                case .trends: if auroraUIEnabled { AuroraTrendsView() } else { TrendsView() }
                // .activeWorkout routes through the quick-action Live sheet (handled above); this keeps the
                // switch exhaustive and falls back to Live if it ever reaches the pillar host.
                case .activeWorkout: LiveView()
                // .liveSession routes to the Today tab (handled above — its Start entry owns the cover);
                // this keeps the switch exhaustive and falls back to Today if it ever reaches the host.
                case .liveSession: LiquidTodayView()
                // .journal opens through the quick-action Journal sheet (handled above); this keeps the
                // switch exhaustive and falls back to the journal's Insights host if it ever reaches here.
                case .journal: InsightsView()
                }
            }
            // The Trends/Today fallbacks above emit TabRoute value pushes (#198), which need a
            // destination registered in THIS sheet's stack to resolve.
            .tabRouteDestinations()
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            // #1027: same fix as quickScreen — the pillar screens draw the full-bleed liquid sky, so a
            // transparent nav bar keeps it edge-to-edge instead of an opaque band clipping the top on scroll.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { routedPillar = nil }
                        .foregroundStyle(StrandPalette.accent)
                }
            }
        }
    }

    /// Calm-easing curve (cubic-bezier(0.22,1,0.36,1)) at the README sheet-present duration.
    private static let sheetEase = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.42)

    // MARK: - Quick-action sheet

    /// Routes a chosen quick action to the existing screen, or shows the action menu itself.
    @ViewBuilder
    private func quickActionDestination(_ action: QuickAction) -> some View {
        switch action {
        case .menu:
            QuickActionSheet { picked in
                // Swap the menu for the chosen destination on the next runloop so the sheet
                // re-presents cleanly (avoids dismiss/re-present races). Calm easing on re-present.
                quickAction = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(Self.sheetEase) { quickAction = picked }
                }
            }
            .presentationDetents([.height(344)])
            .presentationDragIndicator(.hidden)
        case .live:
            quickScreen(LiveView())
        case .workout:
            quickScreen(WorkoutsView())
        case .journal:
            quickScreen(InsightsView())
        case .breathe:
            quickScreen(BreathingView())
        }
    }

    /// Wraps a routed quick-action screen in its own nav stack so it has a title bar + the
    /// shared surface background, matching how the More-tab links present these same views.
    private func quickScreen<V: View>(_ view: V) -> some View {
        NavigationStack {
            view
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                // #1027: these screens draw a full-bleed liquid sky (ScreenScaffold topBackground) that runs
                // edge-to-edge under a transparent bar — exactly how the tab roots present it. An OPAQUE
                // surfaceBase toolbar background sat on top of that sky and, as the content scrolled up, its
                // extended status-bar band CLIPPED the sky + the in-content header ("Live Body Console").
                // Hiding the bar background lets the sky stay continuous under the floating Done button.
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { quickAction = nil }
                            .foregroundStyle(StrandPalette.accent)
                    }
                }
        }
    }

    /// The Devices manager wrapped in its own nav stack + Done button (mirrors `quickScreen`, but
    /// dismisses the dedicated `showDevices` sheet rather than the quick-action item).
    private var devicesScreen: some View {
        NavigationStack {
            DevicesView()
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                // #1027: same fix as quickScreen — Devices draws the full-bleed liquid sky, so a transparent
                // nav bar keeps it edge-to-edge instead of an opaque band clipping the top on scroll.
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showDevices = false }
                            .foregroundStyle(StrandPalette.accent)
                    }
                }
        }
    }

    private func tab<V: View>(_ view: V, _ title: LocalizedStringKey, _ icon: String,
                              path: Binding<NavigationPath>, scrollSignal: Int) -> some View {
        // Each primary tab gets its OWN NavigationStack so the in-content NavigationLinks (e.g. the Today
        // dashboard card rows) both navigate AND render opaque. An ORPHANED NavigationLink (no
        // NavigationStack ancestor) renders its whole label in a disabled/translucent state — that was
        // washing the Today cards over the hero scene and dimming their text to grey (2026-06-23).
        // The root view hides the system nav bar (each screen draws its own in-content header); pushed
        // detail screens get their own nav bar + back button. The stack is bound to the tab's path so a
        // re-tap of the active tab can pop it to the root (#135/#198); the roots' first-hop links push
        // TabRoute values, registered here ONCE per stack (a double registration double-pushes, #38).
        NavigationStack(path: path) {
            view
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .tabRouteDestinations()
        }
        // Drive this tab's root scroll-to-top on an at-root re-tap (#198 follow-up); read by ScreenScaffold
        // / LiquidTodayView inside. Only THIS tab's token changes on its reselect, so the others don't scroll.
        .environment(\.scrollToTopSignal, scrollSignal)
        .tabItem { Label(title, systemImage: icon) }
    }

    // The "More" tab is the app's catch-all index. It was a plain SwiftUI `List` with system large-title
    // + system title-case section headers, so it didn't match any other page (which all use ScreenScaffold
    // + SectionHeader's UPPERCASE overline + the 28pt section rhythm). Rebuilt on the shared page chrome:
    // ScreenScaffold for the title1 "More" + subtitle, a `SectionHeader` overline per group, and the group's
    // rows in a single grouped NoopCard with hairline dividers — the same row idiom Settings/Health use.
    private func moreTab(path: Binding<NavigationPath>, scrollSignal: Int) -> some View {
        NavigationStack(path: path) {
            // Aurora preview: the redesigned hub registers its OWN navigationDestination and pushes
            // VALUES onto this same bound path, so the pop-to-root-on-re-tap contract (#135/#198) and
            // the scroll-to-top signal below are preserved. Default OFF keeps the original index.
            if auroraUIEnabled {
                AuroraMoreView()
            } else {
            ScreenScaffold(title: "More", subtitle: "Everything else, one tap away",
                           onRefresh: { await repo.refresh() },
                           topBackground: liquidScaffoldSky()) {
                moreSection("Insights") {
                    MoreRow("What Moves You", "wand.and.sparkles", .insightsHub)
                    MoreRow("Intelligence", "brain.head.profile", .intelligence)
                    MoreRow("Coach", "sparkles", .coach)
                    MoreRow("Insights", "lightbulb.fill", .insights)
                    MoreRow("Explore", "square.grid.2x2.fill", .explore)
                    MoreRow("Compare", "rectangle.split.2x1.fill", .compare)
                }
                moreSection("Body") {
                    MoreRow("Live", "waveform.path.ecg", .live)
                    MoreRow("Workouts", "figure.run", .workouts)
                    MoreRow("Health", "heart.text.square.fill", .health)
                    MoreRow("Lab Book", "books.vertical.fill", .labBook)
                    MoreRow("Stress", "bolt.heart.fill", .stress)
                    MoreRow("Breathe", "wind", .breathe)
                    MoreRow("Intervals", "timer", .intervals)
                    // Experimental beat-to-beat regularity visualization — self-gates on its own consent.
                    MoreRow("Rhythm", "waveform.path", .rhythm)
                }
                moreSection("Data") {
                    MoreRow("Your Data, Fused", "square.stack.3d.up.fill", .fusedRecord)
                    MoreRow("Apple Health", "heart.fill", .appleHealth)
                    MoreRow("Mi Band", "figure.walk.motion", .miBand)
                    MoreRow("Data Sources", "externaldrive.fill", .dataSources)
                    MoreRow("Backup & Sync", "externaldrive.fill.badge.icloud", .backupSync)
                    // #155: HealthKit-free Apple Health path for sideloaded installs (Siri Shortcut
                    // reads the opt-in Documents/noop_sync.txt drop file).
                    MoreRow("Shortcuts Export", "square.and.arrow.up.fill", .shortcutsExport)
                    // The plain 4.0 vs 5.0/MG capability grid — what NOOP reads live off each strap.
                    MoreRow("NOOP Limitations", "list.bullet.rectangle", .noopLimitations)
                }
                moreSection("App") {
                    // #805/#811: the v7.3.1 #766 alarm consolidation moved Smart Alarm under a single
                    // "Alarms" sidebar entry (RootView .smartAlarm) but the regression dropped the row
                    // from the iPhone More list, leaving Alarms unreachable on iPhone. Restore it here
                    // (route to SmartAlarmView, the cross-platform iOS/macOS surface).
                    //
                    // Notifications (RootView .notifications) is deliberately NOT added: that screen is
                    // macOS-only (it picks which Mac apps tap your wrist via NSWorkspace, imports AppKit,
                    // and project.yml excludes Screens/NotificationSettingsView.swift from the iOS target),
                    // so it can't compile or apply on iPhone. iPhone's wrist-alert controls live on the
                    // Automations screen instead. Its absence from the iPhone More list is correct.
                    MoreRow("Alarms", "alarm.fill", .alarms)
                    MoreRow("Automations", "wand.and.stars", .automations)
                    // The Test Centre (the diagnostics + bug-report hub) gets a first-class home here, not
                    // just buried in Settings, so the feedback loop is one tap from the More tab.
                    MoreRow("Test Centre", "stethoscope", .testCentre)
                    MoreRow("Siri & Shortcuts", "mic.fill", .siriShortcuts)
                    // #477 lives here rather than inside Settings: the strap-battery levers are the
                    // ones people reach for when a strap is running down, so they get their own row.
                    MoreRow("Power saving", "battery.25", .powerSaving)
                    MoreRow("Settings", "gearshape.fill", .settings)
                }
            }
            // The rows push MoreDestination VALUES so a re-tap of the More tab can pop them off the
            // bound path (#135/#198). Each destination keeps the per-screen wrapper the rows used to
            // apply inline (surfaceBase background, inline title bar, hidden bar background):
            // #1027 — a pushed sky-scaffold screen (Live, Workouts, Health, …) draws a full-bleed liquid
            // sky; an opaque surfaceBase nav-bar band sat over it and clipped the top on scroll. A hidden
            // bar background keeps the sky edge-to-edge. On the flat (no-sky) screens this is visually
            // identical at rest — the destination's own surfaceBase background shows through the bar.
            .navigationDestination(for: MoreDestination.self) { route in
                route.destination
                    .background(StrandPalette.surfaceBase.ignoresSafeArea())
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
            }
            }
        }
        // Scroll the More index to the top on an at-root re-tap (#198 follow-up); read by its ScreenScaffold.
        .environment(\.scrollToTopSignal, scrollSignal)
        .tabItem { Label("More", systemImage: "ellipsis") }
    }

    /// The Ledger shell's "…" overflow hub: the SAME 28 destinations as the classic More tab —
    /// mirrored row for row, pushing the same `MoreDestination` VALUES through the same
    /// `navigationDestination` wrapper, so nothing can drift — restyled into the Ledger's section
    /// grammar (dark canvas, overline group headers, hairline rows, no cards). The pushed screens
    /// themselves stay classic; only the index speaks Ledger.
    private func ledgerOverflowTab() -> some View {
        NavigationStack(path: $ledgerOverflowPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    LedgerHeader(overline: String(localized: "Everything else"),
                                 title: String(localized: "More")) { EmptyView() }
                        .padding(.top, 18)

                    ledgerMoreSection(String(localized: "Insights"), first: true) {
                        LedgerMoreRow("What Moves You", "wand.and.sparkles", .insightsHub)
                        LedgerMoreRow("Intelligence", "brain.head.profile", .intelligence)
                        LedgerMoreRow("Coach", "sparkles", .coach)
                        LedgerMoreRow("Insights", "lightbulb", .insights)
                        LedgerMoreRow("Explore", "square.grid.2x2", .explore)
                        LedgerMoreRow("Compare", "rectangle.split.2x1", .compare)
                    }
                    ledgerMoreSection(String(localized: "Body")) {
                        LedgerMoreRow("Live", "waveform.path.ecg", .live)
                        LedgerMoreRow("Workouts", "figure.run", .workouts)
                        LedgerMoreRow("Health", "heart.text.square", .health)
                        LedgerMoreRow("Lab Book", "books.vertical", .labBook)
                        LedgerMoreRow("Stress", "bolt.heart", .stress)
                        LedgerMoreRow("Breathe", "wind", .breathe)
                        LedgerMoreRow("Intervals", "timer", .intervals)
                        LedgerMoreRow("Rhythm", "waveform.path", .rhythm)
                    }
                    ledgerMoreSection(String(localized: "Data")) {
                        LedgerMoreRow("Your Data, Fused", "square.stack.3d.up", .fusedRecord)
                        LedgerMoreRow("Apple Health", "heart", .appleHealth)
                        LedgerMoreRow("Mi Band", "figure.walk.motion", .miBand)
                        LedgerMoreRow("Data Sources", "externaldrive", .dataSources)
                        LedgerMoreRow("Backup & Sync", "externaldrive.badge.icloud", .backupSync)
                        LedgerMoreRow("Shortcuts Export", "square.and.arrow.up", .shortcutsExport)
                        LedgerMoreRow("NOOP Limitations", "list.bullet.rectangle", .noopLimitations)
                    }
                    ledgerMoreSection(String(localized: "App")) {
                        LedgerMoreRow("Alarms", "alarm", .alarms)
                        LedgerMoreRow("Automations", "wand.and.stars", .automations)
                        LedgerMoreRow("Test Centre", "stethoscope", .testCentre)
                        LedgerMoreRow("Siri & Shortcuts", "mic", .siriShortcuts)
                        LedgerMoreRow("Power saving", "battery.25", .powerSaving)
                        LedgerMoreRow("Settings", "gearshape", .settings)
                    }
                }
                .padding(.horizontal, Ledger.pageMargin)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Ledger.bgScreen.ignoresSafeArea())
            // The classic wrapper, verbatim — the pushed screens are the classic ones and keep
            // their own chrome (#1027 sky note in `moreTab`).
            .navigationDestination(for: MoreDestination.self) { route in
                route.destination
                    .background(StrandPalette.surfaceBase.ignoresSafeArea())
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
            }
        }
    }

    /// One Ledger overflow group: hairline rule, overline header, rows.
    private func ledgerMoreSection<Rows: View>(_ title: String, first: Bool = false,
                                               @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Ledger.hairline)
                .frame(height: Ledger.hairlineWidth)
            Text(title).ledgerOverline()
                .padding(.top, 14)
                .padding(.bottom, 4)
            rows()
        }
        .padding(.top, first ? 18 : 16)
    }

    /// One titled, COLLAPSIBLE group in the More index (S2): the app's overline (UPPERCASE) becomes a
    /// tappable header with a disclosure chevron; tapping it expands/collapses the grouped rows card.
    /// Insights + Body default open, Data + App default collapsed (the `expandedMoreSections` seed) so the
    /// list is shorter at rest without dropping a single row. The grouped card is unchanged: a single
    /// `NoopCard` holding a `VStack(spacing: 0)` whose `MoreRow`s draw their own hairlines, clipped to the
    /// card's rounded shape so the last divider is trimmed inside the corners. Same idiom Settings/Health use.
    @ViewBuilder
    private func moreSection<Rows: View>(_ title: String,
                                         @ViewBuilder rows: @escaping () -> Rows) -> some View {
        let isOpen = expandedMoreSections.contains(title)
        VStack(alignment: .leading, spacing: 10) {
            // Tappable overline header: the same ALL-CAPS tracked label as before, now with a trailing
            // chevron that rotates open. A plain Button (not a SwiftUI DisclosureGroup) so the header keeps
            // the exact strandOverline styling and the card layout below stays identical to before.
            Button {
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) {
                    // Persist the toggle via the CSV-backed @AppStorage so the choice survives leaving and
                    // re-entering the More tab and relaunch (#860 item 2). MoreSectionPrefs owns encode/decode.
                    var open = expandedMoreSections
                    if isOpen { open.remove(title) } else { open.insert(title) }
                    expandedMoreSectionsCSV = MoreSectionPrefs.encode(open)
                }
            } label: {
                HStack(spacing: 6) {
                    Text(title).strandOverline()
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .rotationEffect(.degrees(isOpen ? 0 : -90))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(isOpen ? String(localized: "Expanded") : String(localized: "Collapsed")))
            .accessibilityHint(Text(isOpen ? String(localized: "Double tap to collapse") : String(localized: "Double tap to expand")))

            if isOpen {
                // Zero internal padding so each MoreRow owns its own comfortable insets + height; the rows
                // supply their own hairline separators (drawn at the bottom of every row but the last via the
                // divider overlay) so the group reads as one continuous grouped list, matching Settings/Health.
                NoopCard(padding: 0) {
                    VStack(spacing: 0) { rows() }
                        // Clip the rows column to the card's rounded shape so the last row's bottom hairline is
                        // trimmed inside the corners (the card draws its surface in the BACKGROUND and doesn't
                        // clip content itself, so without this the final divider would run past the rounded edge).
                        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
                }
            }
        }
    }
}

/// Every screen the More index links to, as a `Hashable` value the tab's `NavigationPath` can carry
/// (#198): a closure-destination push would bypass the path and be un-poppable on tab re-tap. The
/// per-screen chrome the old inline links applied lives at the single `navigationDestination(for:)`
/// registration in `moreTab`.
private enum MoreDestination: Hashable {
    case insightsHub, intelligence, coach, insights, explore, compare
    case live, workouts, health, labBook, stress, breathe, intervals, rhythm
    case fusedRecord, appleHealth, miBand, dataSources, backupSync, shortcutsExport, noopLimitations
    case alarms, automations, testCentre, siriShortcuts, powerSaving, settings

    @ViewBuilder var destination: some View {
        switch self {
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
        case .shortcutsExport: ShortcutExportSettingsView()
        case .alarms:          SmartAlarmView()
        case .automations:     AutomationsView()
        case .testCentre:      TestCentreView()
        case .siriShortcuts:   SiriShortcutsSettingsView()
        case .powerSaving:     PowerSavingView()
        case .settings:        SettingsView()
        }
    }
}


/// One tappable destination row in the More index. A `NavigationLink` whose label is the standard app row:
/// the SF Symbol icon tinted `StrandPalette.accent`, the title in the body text colour, a `Spacer`, and a
/// trailing `chevron.right` in `textTertiary`. ~44pt min height + the card's row insets keep the whole row a
/// comfortable tap target.
/// One Ledger overflow row: a tertiary line icon in a fixed column, the title, a chevron — a
/// value-pushing `NavigationLink` like `MoreRow`, drawn in the Ledger row idiom (44pt min height,
/// hairline beneath, no card).
private struct LedgerMoreRow: View {
    let title: LocalizedStringKey
    let icon: String
    let destination: MoreDestination

    init(_ title: LocalizedStringKey, _ icon: String, _ destination: MoreDestination) {
        self.title = title
        self.icon = icon
        self.destination = destination
    }

    var body: some View {
        NavigationLink(value: destination) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Ledger.textTertiary)
                    .frame(width: 22, alignment: .center)
                Text(title)
                    .font(LedgerType.label(14, LedgerType.semibold))
                    .foregroundStyle(Ledger.textPrimary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Ledger.textTertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct MoreRow: View {
    let title: LocalizedStringKey
    let icon: String
    let route: MoreDestination

    init(_ title: LocalizedStringKey, _ icon: String, _ route: MoreDestination) {
        self.title = title; self.icon = icon; self.route = route
    }

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 14) {
                // Pin the icon to the accent explicitly. A plain inherited tint gets re-resolved by iOS to
                // its default blue a beat after first render — so the icons flashed green→blue (#184). The
                // explicit foregroundStyle on the image overrides that; the title keeps the primary colour.
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(StrandPalette.accent)
                    .frame(width: 26, alignment: .center)
                Text(title)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Hairline under every row; the grouped container clips the last one's overflow so the bottom
            // edge stays clean (the divider sits inside the card's rounded corners).
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(StrandPalette.hairline)
                    .frame(height: 1)
                    .padding(.leading, 16)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Quick actions (centre FAB)

/// The destinations the centre FAB can present. `.menu` is the action sheet itself; the rest
/// route to existing screens. `Identifiable` so it drives `.sheet(item:)`.
private enum QuickAction: Int, Identifiable {
    case menu, live, workout, journal, breathe
    var id: Int { rawValue }
}

/// The bottom sheet of quick actions presented by the centre FAB. Spec bottom sheet: surfaceOverlay
/// fill, gold hairline top edge, grab handle, three flat action rows that route to existing screens.
private struct QuickActionSheet: View {
    /// Called with the picked destination (the host swaps the menu for that screen).
    let onPick: (QuickAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Grab handle (36×4) in the slate hairline tone.
            Capsule()
                .fill(StrandPalette.hairlineStrong)
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 14)

            Text("QUICK ACTIONS")
                .font(StrandFont.overline)
                .tracking(1.6)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            VStack(spacing: 8) {
                row("Live HR", icon: "waveform.path.ecg", tint: StrandPalette.metricRose) { onPick(.live) }
                row("Start workout", icon: "figure.run", tint: StrandPalette.effortColor) { onPick(.workout) }
                row("Log journal", icon: "square.and.pencil", tint: StrandPalette.accent) { onPick(.journal) }
                row("Breathe", icon: "wind", tint: StrandPalette.restColor) { onPick(.breathe) }
            }
            .padding(.horizontal, 16)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            NoopChromeSurface()
                .overlay(alignment: .top) {
                    // Gold hairline top edge per the bottom-sheet spec.
                    Rectangle()
                        .fill(StrandPalette.gold.opacity(0.35))
                        .frame(height: 1)
                }
                .ignoresSafeArea()
        )
    }

    /// One flat action row: hued line-icon tile + title, inset surface, hairline border.
    private func row(_ title: LocalizedStringKey, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(StrandPalette.surfaceInset))
                Text(title)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(NoopPanelSurface(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Re-arms `UINavigationController`'s interactive pop (the left-edge swipe-back) inside a
/// `NavigationStack` whose navigation bar is hidden — UIKit disables the recognizer with the bar,
/// which left the Ledger's pushed screens reachable but only backable via their "‹" link.
///
/// Installed as a zero-size `background` on each Ledger tab's ROOT view, so it lives exactly as
/// long as that tab's stack and finds its `navigationController` through the responder chain. It
/// takes over as the recognizer's delegate and allows the gesture ONLY while something is pushed:
/// the classic footgun with the bare `delegate = nil` re-enable is that an edge swipe at the ROOT
/// begins a pop with nowhere to go and freezes the navigation controller — `viewControllers.count
/// > 1` is the guard that keeps the root's day-swipe (and sanity) intact.
private struct LedgerBackSwipeEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Proxy { Proxy() }
    func updateUIViewController(_ controller: Proxy, context: Context) {}

    final class Proxy: UIViewController, UIGestureRecognizerDelegate {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            arm()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // The navigation controller may not be reachable yet in `didMove` on first layout;
            // re-arming here is idempotent and catches that case.
            arm()
        }

        private func arm() {
            guard let recognizer = navigationController?.interactivePopGestureRecognizer else { return }
            recognizer.delegate = self
            recognizer.isEnabled = true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}

#endif
