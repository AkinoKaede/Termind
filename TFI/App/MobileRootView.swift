import SwiftUI
import UIKit

/// iPhone has four destinations. iPad retains the sidebar with individual library routes.
struct MobileRootView: View {
    let app: MobileAppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.mobileInterfaceIdiom) private var interfaceIdiom
    @State private var scene: MobileSceneModel

    init(app: MobileAppModel) {
        self.app = app
        _scene = State(initialValue: MobileSceneModel(app: app))
    }

    var body: some View {
        Group {
            if interfaceIdiom != .pad {
                TabView(selection: $scene.selectedTab) {
                    NavigationStack { vault }
                        .tabItem { Label("Vault", systemImage: "server.rack") }.tag(MobileTab.vault)
                    NavigationStack { workspaceList }
                        .tabItem { Label("Workspaces", systemImage: "terminal") }.tag(MobileTab.workspaces)
                    NavigationStack { assistant }
                        .tabItem { Label("Assistant", systemImage: "sparkles") }.tag(MobileTab.assistant)
                    NavigationStack { settings }
                        .tabItem { Label("Settings", systemImage: "gearshape") }.tag(MobileTab.settings)
                }
            } else {
                NavigationSplitView {
                    List(selection: $scene.selectedDestination) {
                        ForEach(MobileDestination.allCases) { destination in
                            NavigationLink(value: destination) {
                                Label(destination.title, systemImage: destination.symbol)
                            }
                        }
                    }
                } detail: {
                    NavigationStack {
                        switch scene.selectedDestination {
                        case .vault: sidebarVault
                        case .assistant: assistant
                        case .settings: settings
                        case .metrics: metrics
                        case .workspaces: workspaceList
                        default: sidebarVault
                        }
                    }
                }
            }
        }
        .sheet(isPresented: Binding(get: { app.pro.isPaywallPresented }, set: { app.pro.isPaywallPresented = $0 })) {
            MobileProView(pro: app.pro)
        }
        .sheet(item: $scene.renamingWorkspace) { workspace in
            MobileWorkspaceRenameView(workspace: workspace) { title in
                app.renameWorkspace(workspace.id, to: title)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in app.sceneChanged(scene.id, phase: phase) }
        .onChange(of: app.pro.hasProAccess) { _, _ in app.reconcileSync() }
        .onChange(of: app.workspaces.map(\.id)) { _, workspaceIDs in
            scene.reconcileWorkspaceIDs(workspaceIDs)
        }
        .onDisappear { app.removeScene(scene.id) }
        .onOpenURL(perform: scene.open)
        .focusedSceneValue(\.mobileScene, scene)
        .alert(
            scene.isWorkspaceUnavailable
                ? String(localized: "Workspace Unavailable") : String(localized: "Operation Failed"),
            isPresented: Binding(
                get: { scene.isWorkspaceUnavailable || app.error != nil },
                set: {
                    if !$0 {
                        scene.isWorkspaceUnavailable = false
                        app.error = nil
                    }
                })
        ) {
            Button("OK", role: .cancel) {
                scene.isWorkspaceUnavailable = false
                app.error = nil
            }
        } message: {
            Text(
                scene.isWorkspaceUnavailable
                    ? String(localized: "This workspace was closed or its host was removed.") : app.error ?? "")
        }

    }

    private var vault: some View {
        MobileVaultView(
            app: app, editingHost: $scene.editingHost,
            open: scene.open, executeSnippet: scene.execute)
    }

    private var sidebarVault: some View {
        MobileVaultView(
            app: app, editingHost: $scene.editingHost,
            open: scene.open, showsMetrics: false,
            executeSnippet: scene.execute)
    }

    private var workspaceList: some View {
        List {
            Section {
                NavigationLink {
                    MobileTransfersView(transfers: app.transfers, hosts: app.library)
                } label: {
                    Label("Transfers", systemImage: "arrow.up.arrow.down")
                }
            }
            Section("Workspaces") { workspaceRows }
        }
        .navigationTitle("Workspaces")
        .toolbar {
            MobileWorkspaceToolbar(
                hasWorkspaces: !app.workspaces.isEmpty,
                closeAll: scene.closeAllWorkspaces,
                connect: scene.openConnectionPicker)
        }
        .navigationDestination(item: $scene.workspaceID) { id in
            if let workspace = app.workspaces.first(where: { $0.id == id }) {
                MobileWorkspaceView(
                    library: app.library, pro: app.pro, commandGenerator: app.commandGenerator,
                    workspace: workspace, workspaces: app.workspaces,
                    selectWorkspace: scene.selectWorkspace,
                    renameWorkspace: scene.beginWorkspaceRename,
                    openSameDirectory: scene.openSameDirectory,
                    closeWorkspace: scene.closeWorkspace
                )
            }
        }
        .sheet(isPresented: $scene.isConnectionPickerPresented) {
            NavigationStack {
                MobileConnectionPicker(
                    library: app.library,
                    connect: { hostID, kind in
                        scene.isConnectionPickerPresented = false
                        scene.open(hostID: hostID, kind: kind)
                    },
                    cancel: { scene.isConnectionPickerPresented = false })
            }
            .mobileSheetPresentation(compact: true)
        }
    }

    @ViewBuilder private var workspaceRows: some View {
        if app.workspaces.isEmpty {
            ContentUnavailableView(
                "No Workspaces", systemImage: "terminal",
                description: Text("Open a host from Vault to start a workspace.")
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        ForEach(app.workspaces) { workspace in
            Button {
                scene.selectWorkspace(workspace.id)
            } label: {
                HStack(spacing: 12) {
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: workspace.descriptor.kind.symbol)
                            .foregroundStyle(.tint)
                            .frame(width: 28, height: 28)
                        Circle()
                            .fill(workspaceStatusTint(workspace))
                            .frame(width: 8, height: 8)
                            .overlay { Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5) }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workspace.descriptor.title).foregroundStyle(.primary).lineLimit(1)
                        Text(workspace.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .swipeActions {
                Button("Close", systemImage: "xmark", role: .destructive) { scene.closeWorkspace(workspace.id) }
            }
            .contextMenu {
                Button("Rename", systemImage: "pencil") { scene.beginWorkspaceRename(workspace) }
                Divider()
                Button("Close", systemImage: "xmark", role: .destructive) { scene.closeWorkspace(workspace.id) }
            }
        }
    }

    private func workspaceStatusTint(_ workspace: MobileWorkspace) -> Color {
        if workspace.connected { return .green }
        if workspace.busy || workspace.reconnectState != nil { return .orange }
        return .secondary
    }

    private var assistant: some View {
        MobileAssistantView(
            app: app, model: app.assistant,
            libraryRoute: $scene.assistantLibraryRoute)
    }

    private var metrics: some View {
        MobileMetricsView(app: app)
    }

    private var settings: some View {
        MobileSettingsView(app: app)
    }

}
