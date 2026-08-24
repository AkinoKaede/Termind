import SwiftUI

/// One window.
///
/// The tab strip is the window's top-level navigation. Vault and Assistant are pinned
/// first and second; SSH/SFTP Workspaces follow them. One stable left sidebar
/// serves every top-level tab and swaps navigation for contextual tools in place.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @State private var window: WindowModel
    @State private var hostsPageState = HostsPageState()
    /// The last usable width reported by whichever sidebar is mounted.
    ///
    /// Keeping this at the window shell lets the pinned tabs track both the
    /// Vault split view and the shared contextual sidebar. A hidden sidebar can
    /// briefly report zero while it leaves the layout; that value is rejected
    /// by `recordSidebarWidth` so the tab strip keeps the user's last width.
    @State private var sidebarWidth = Metrics.Sidebar.ideal

    init(window: WindowModel = WindowModel()) {
        _window = State(initialValue: window)
    }

    var body: some View {
        @Bindable var window = window
        @Bindable var presentations = window.presentations

        VStack(spacing: 0) {
            TabBarView(pinnedTabStripWidth: sidebarWidth)
            Divider()
            splitContent
            if window.selectedTab != nil {
                StatusBarView()
            }
        }
        .frame(
            minWidth: Metrics.Window.detailMin,
            maxWidth: .infinity,
            minHeight: Metrics.Window.minHeight,
            maxHeight: .infinity
        )
        .toolbarBackground(WindowChrome.background(for: colorScheme), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        // ⌘T and every Connect entry land here. A sheet rather than a page,
        // because "which machine?" is a question with an answer, and the window
        // behind it is what you were looking at when you asked.
        //
        // Must stay *above* `.environment(window)` in this chain. Modifiers
        // apply inside-out, so the environment written last is the outermost and
        // is the only one a sheet's content inherits — attaching `.sheet` after
        // it puts the presentation outside that environment, and the chooser
        // traps on `@Environment(WindowModel.self)` the moment it opens.
        .sheet(item: $presentations.sheet) { route in
            switch route {
            case .hostChooser(let purpose):
                HostChooserView(purpose: purpose)
            case .quickOpen:
                QuickOpenView()
            }
        }
        // Do not put a catch-all `.onDrop` here. On macOS an ancestor accepting
        // the same text payload can win over the pane and tab-strip delegates,
        // clear `dragging`, and turn a valid merge into a cancelled drop. Each
        // real target already completes or rejects the internal drag itself.
        .environment(window)
        // Scene-scoped, not view-scoped. `.focusedValue` resolves only while
        // some view *inside* the window holds keyboard focus, and once you click
        // into a terminal pane nothing here does — so every menu command lost
        // its window and went quietly dead: the ones with a `.disabled` greyed
        // out, and the ones without (Connect, ⌘1…⌘9) returned from their
        // `guard let window` having done nothing at all.
        .focusedSceneValue(\.window, window)
        .onChange(of: window.selectedTabID) {
            window.selectedTab?.refreshConversationContext(in: app.hosts)
            window.reconcileSidebarMode()
        }
        .onAppear {
            window.connectionCoordinator = app.connections
            app.registerWindow(window)
            window.selectedTab?.refreshConversationContext(in: app.hosts)
            window.reconcileSidebarMode()
        }
    }

    @ViewBuilder
    private var splitContent: some View {
        if window.selectedTopLevelTab == .vault {
            // Vault itself always remains the same two-column navigation view.
            // Its detail owns the optional work split so showing New Host does
            // not reconstruct `VaultView` and discard an active query, selected
            // tags, scroll position, or search-field focus.
            NavigationSplitView {
                vaultSidebar
            } detail: {
                vaultWorkspace
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationSplitView(columnVisibility: sidebarVisibility) {
                SidebarView(detailCatalog: .standard(store: app.hosts))
                    .navigationSplitViewColumnWidth(
                        min: Metrics.Sidebar.min,
                        ideal: Metrics.Sidebar.ideal,
                        max: Metrics.Sidebar.max
                    )
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.width
                    } action: {
                        recordSidebarWidth($0)
                    }
            } detail: {
                detail
                    .frame(
                        minWidth: Metrics.Window.detailMin,
                        maxWidth: .infinity,
                        minHeight: Metrics.Window.minHeight,
                        maxHeight: .infinity
                    )
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    private var vaultSidebar: some View {
        VaultSidebarView()
            .navigationSplitViewColumnWidth(
                min: Metrics.Sidebar.min,
                ideal: Metrics.Sidebar.ideal,
                max: Metrics.Sidebar.max
            )
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                recordSidebarWidth($0)
            }
    }

    private func recordSidebarWidth(_ measuredWidth: CGFloat) {
        sidebarWidth = PinnedTopLevelTabSizing.resolvedSidebarWidth(
            current: sidebarWidth,
            measured: measuredWidth
        )
    }

    private var vaultWorkspace: some View {
        let showsWorkDetail = window.vaultWorkRoute != nil

        return HStack(spacing: 0) {
            VaultView(hostsPageState: hostsPageState)
                .frame(
                    minWidth: Metrics.VaultContent.min,
                    idealWidth: Metrics.VaultContent.ideal,
                    maxWidth: .infinity
                )
                .layoutPriority(1)

            Divider()
                .frame(width: showsWorkDetail ? 1 : 0)
                .opacity(showsWorkDetail ? 1 : 0)

            ZStack {
                if let route = window.vaultWorkRoute {
                    VaultWorkDetailView(route: route)
                }
            }
            .frame(
                minWidth: showsWorkDetail ? Metrics.VaultDetail.min : 0,
                idealWidth: showsWorkDetail ? Metrics.VaultDetail.ideal : 0,
                maxWidth: showsWorkDetail ? Metrics.VaultDetail.max : 0
            )
            .clipped()
            .opacity(showsWorkDetail ? 1 : 0)
            .allowsHitTesting(showsWorkDetail)
            .accessibilityHidden(!showsWorkDetail)
        }
        .frame(
            minWidth: Metrics.VaultContent.min,
            maxWidth: .infinity,
            maxHeight: .infinity
        )
    }

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { window.showsSidebar ? .all : .detailOnly },
            set: { window.showsSidebar = $0 != .detailOnly }
        )
    }

    /// Every open tab stays mounted so a Ghostty native view is hidden rather
    /// than destroyed when another tab comes forward. The terminal surface owns
    /// its grid and scrollback, so rebuilding that view on every selection
    /// change would leave a live SSH session attached to a blank terminal.
    ///
    /// `displayedTab`, not `selectedTab`, decides which layer is visible: while
    /// the front tab is being dragged it steps aside so there is something to
    /// merge it *into*. Nothing about the selection moves — see
    /// `WindowModel.displayedTab`.
    @ViewBuilder
    private var detail: some View {
        ZStack {
            PersistentTabDeckLayout {
                ForEach(window.tabs) { tab in
                    // During a selected-tab drag, `displayedTab` deliberately
                    // becomes a neighbouring Workspace so it can receive the
                    // drop. Requiring that neighbour to also be selected makes
                    // every possible merge target transparent and disabled.
                    let isActive = tab.id == window.displayedTab?.id
                    TabContentView(tab: tab, isActive: isActive)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                        .accessibilityHidden(!isActive)
                        .disabled(!isActive)
                        .zIndex(isActive ? 1 : 0)
                        .persistentTabDeckValue(id: tab.id, isActive: isActive)
                }
            }
            .clipped()

            switch window.selectedTopLevelTab {
            case .vault:
                VaultView()
                    .background(Color(nsColor: .windowBackgroundColor))
                    .zIndex(2)
            case .assistant:
                AssistantView()
                    .background(Color(nsColor: .windowBackgroundColor))
                    .zIndex(2)
            case .workspace:
                if window.tabs.isEmpty { VaultView() }
            }
        }
    }

}
