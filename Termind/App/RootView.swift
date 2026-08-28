import AppKit
import SwiftUI

/// One window with one native Navigator column and one persistent detail deck.
///
/// Vault pages, dynamic Workspaces, and Assistant conversations are destinations
/// in the Navigator rather than a second horizontal workspace system. Workspace native
/// views stay mounted while another destination is in front, preserving terminal
/// grids, scrollback, and SFTP state.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var window: WindowModel
    @State private var layoutWidth = Metrics.Window.defaultWidth

    init(window: WindowModel = WindowModel()) {
        _window = State(initialValue: window)
    }

    var body: some View {
        @Bindable var window = window
        @Bindable var presentations = window.presentations

        NavigationSplitView(columnVisibility: sidebarVisibility) {
            ZStack {
                SidebarMaterialBackground()
                    .ignoresSafeArea()
                SidebarView(detailCatalog: .standard(store: app.hostLibrary))
            }
            .navigationSplitViewColumnWidth(
                min: Metrics.Sidebar.min,
                ideal: min(Metrics.Sidebar.ideal, sidebarMaxWidth),
                max: sidebarMaxWidth
            )
        } detail: {
            detail
            // Floating over the pane rather than docked under it, so switching
            // to a Workspace no longer resizes the content area — and so the
            // bar reads as belonging to the session it describes.
            .overlay(alignment: .bottomTrailing) {
                if case .workspace = window.selectedDestination {
                    StatusBarView()
                        .padding(Metrics.StatusBar.floatingInset)
                }
            }
            .frame(
                minWidth: Metrics.Window.detailMin,
                maxWidth: .infinity,
                minHeight: Metrics.Window.detailMinHeight,
                maxHeight: .infinity
            )
        }
        .navigationSplitViewStyle(.balanced)
        .overlay { ExternalAuthWindowPresenter() }
        .frame(
            minWidth: Metrics.Window.minWidth,
            maxWidth: .infinity,
            minHeight: Metrics.Window.minHeight,
            maxHeight: .infinity
        )
        .background { FullHeightWindowContent() }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { layoutWidth = $0 }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .navigationTitle(WindowTitleCatalog.standard(hosts: app.hostLibrary).title(in: window))
        // The window's only toolbar. Creation on the left, one Find on the
        // right, both following the content in front rather than the sidebar —
        // see `WindowToolbarLeadingActions` and `WindowModel.findKind`.
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                WindowToolbarLeadingActions()
            }
            ToolbarItem(placement: .primaryAction) {
                WindowToolbarFindField()
            }
        }
        .sheet(item: $presentations.sheet) { route in
            switch route {
            case .hostChooser(let purpose):
                HostChooserView(purpose: purpose)
            case .quickOpen:
                QuickOpenView()
            }
        }
        .alert(
            "Conversation Operation Failed",
            isPresented: Binding(
                get: { window.assistantOperationError != nil },
                set: { if !$0 { window.assistantOperationError = nil } }
            )
        ) {
            Button("OK") { window.assistantOperationError = nil }
        } message: {
            Text(window.assistantOperationError ?? "")
        }
        // No ancestor drop target: pane and Navigator targets must own internal
        // layout drops without competing for the same text payload.
        .environment(window)
        .focusedSceneValue(\.window, window)
        .onChange(of: window.selectedDestination) {
            window.refreshSessionContext()
            window.reconcileSidebarMode()
        }
        .onAppear {
            window.connectionCoordinator = app.connections
            window.hostStore = app.hostLibrary
            app.registerWindow(window)
            window.refreshSessionContext()
            window.reconcileSidebarMode()
        }
    }

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { window.showsSidebar ? .all : .detailOnly },
            set: { window.showsSidebar = $0 != .detailOnly }
        )
    }

    private var sidebarMaxWidth: CGFloat {
        Metrics.Window.sidebarMaxWidth(for: layoutWidth)
    }

    private var vaultWorkspace: some View {
        let showsWorkDetail = window.vaultWorkRoute != nil

        return HStack(spacing: 0) {
            VaultView(pages: window.vaultPages)
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
                        .id(route)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
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
        .animation(
            Motion.panel(reduceMotion: reduceMotion),
            value: window.vaultWorkRoute
        )
        .frame(
            minWidth: Metrics.VaultContent.min,
            maxWidth: .infinity,
            maxHeight: .infinity
        )
    }

    @ViewBuilder
    private var detail: some View {
        ZStack {
            PersistentWorkspaceDeckLayout {
                ForEach(window.workspaces) { workspace in
                    let isActive = workspace.id == window.displayedWorkspace?.id
                    WorkspaceContentView(workspace: workspace, isActive: isActive)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                        .accessibilityHidden(!isActive)
                        .disabled(!isActive)
                        .zIndex(isActive ? 1 : 0)
                        .persistentWorkspaceDeckValue(id: workspace.id, isActive: isActive)
                }
            }
            .clipped()

            switch window.selectedDestination {
            case .vault:
                vaultWorkspace
                    .background(Color(nsColor: .windowBackgroundColor))
                    .zIndex(2)
            case .assistant:
                AssistantView()
                    .background(Color(nsColor: .windowBackgroundColor))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(2)
            case .workspace:
                if window.workspaces.isEmpty {
                    VaultView(pages: window.vaultPages)
                }
            }
        }
        .animation(
            Motion.panel(reduceMotion: reduceMotion),
            value: isAssistantFullScreen
        )
        .clipped()
    }

    private var isAssistantFullScreen: Bool {
        window.selectedDestination == .assistant
    }
}

/// Extends the split view's material behind the titlebar while retaining the
/// native toolbar chrome.
private struct FullHeightWindowContent: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowContentBridgeView {
        WindowContentBridgeView()
    }

    func updateNSView(_ view: WindowContentBridgeView, context: Context) {
        view.configureWindow()
    }
}

private final class WindowContentBridgeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow()
    }

    func configureWindow() {
        guard let window else { return }
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        if !window.titlebarAppearsTransparent {
            window.titlebarAppearsTransparent = true
        }
    }
}
