import SwiftUI

/// One window.
///
/// The tab strip is the window's top-level navigation. Vault and Chat are pinned
/// first and second; SSH/SFTP Workspaces follow them. Vault and Chat own their
/// own internal sidebars, leaving Workspace content full width.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var window: WindowModel

    init(window: WindowModel = WindowModel()) {
        _window = State(initialValue: window)
    }

    var body: some View {
        @Bindable var window = window
        @Bindable var presentations = window.presentations

        VStack(spacing: 0) {
            TabBarView()
            Divider()
            detail
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
        .inspector(
            isPresented: Binding(
                get: { window.selectedTab != nil && window.showsContextPanel },
                set: { window.showsContextPanel = $0 }
            )
        ) {
            ContextPanelView(detailCatalog: .standard(store: app.hosts))
        }
        .toolbar { toolbar }
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
        }
        .onAppear {
            window.connectionCoordinator = app.connections
            app.registerWindow(window)
            window.selectedTab?.refreshConversationContext(in: app.hosts)
        }
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
            case .chat:
                ChatView()
                    .background(Color(nsColor: .windowBackgroundColor))
                    .zIndex(2)
            case .workspace:
                if window.tabs.isEmpty { VaultView() }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button {
                withAnimation(Motion.panel(reduceMotion: reduceMotion)) {
                    window.showsContextPanel.toggle()
                }
            } label: {
                Label("Context Panel", systemImage: "sidebar.right")
            }
            .help(Text("Toggle assistant — ⌥⌘I"))
            .disabled(window.selectedTab == nil)
        }
    }
}
