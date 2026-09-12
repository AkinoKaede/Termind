import SwiftUI
import TermindDomain
import UIKit

import struct TermindDomain.Host

/// iPhone has four destinations. iPad retains the sidebar with individual library routes.
struct MobileRootView: View {
    let app: MobileAppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.mobileInterfaceIdiom) private var interfaceIdiom
    @State private var sceneID = UUID()
    @State private var tab: MobileTab = .vault
    @State private var selection: MobileDestination? = .vault
    @State private var workspaceID: UUID?
    @State private var selectingConnection = false
    @State private var unavailable = false
    @State private var renamingWorkspace: MobileWorkspace?

    var body: some View {
        Group {
            if interfaceIdiom != .pad {
                TabView(selection: $tab) {
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
                    List(selection: $selection) {
                        ForEach(MobileDestination.allCases) { destination in
                            NavigationLink(value: destination) {
                                Label(destination.title, systemImage: destination.symbol)
                            }
                        }
                    }
                } detail: {
                    NavigationStack {
                        switch selection {
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
        .sheet(item: $renamingWorkspace) { workspace in
            MobileWorkspaceRenameView(workspace: workspace) { title in
                app.renameWorkspace(workspace.id, to: title)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in app.sceneChanged(sceneID, phase: phase) }
        .onChange(of: app.pro.hasProAccess) { _, _ in app.reconcileSync() }
        .onChange(of: app.workspaces.map(\.id)) { _, workspaceIDs in
            guard let workspaceID, !workspaceIDs.contains(workspaceID) else { return }
            self.workspaceID = nil
        }
        .onDisappear { app.removeScene(sceneID) }
        .onOpenURL { url in
            if WorkspaceActivityAttributes.accepts(url) {
                tab = .workspaces
                selection = .workspaces
                workspaceID = nil
                return
            }
            guard let id = WorkspaceActivityAttributes.workspaceID(from: url) else { return }
            tab = .workspaces
            selection = .workspaces
            if let workspace = app.workspaces.first(where: { $0.id == id }) {
                workspace.activateWhenOpened()
                workspaceID = id
                app.focusWorkspaceActivity(id)
                workspace.terminal.requestFocus()
            } else {
                unavailable = true
            }
        }
        .alert(
            unavailable ? String(localized: "Workspace Unavailable") : String(localized: "Operation Failed"),
            isPresented: Binding(
                get: { unavailable || app.error != nil },
                set: {
                    if !$0 {
                        unavailable = false
                        app.error = nil
                    }
                })
        ) {
            Button("OK", role: .cancel) {
                unavailable = false
                app.error = nil
            }
        } message: {
            Text(
                unavailable
                    ? String(localized: "This workspace was closed or its host was removed.") : app.error ?? "")
        }

    }

    private var vault: some View {
        MobileVaultView(app: app, open: open, executeSnippet: executeSnippet)
    }

    private var sidebarVault: some View {
        MobileVaultView(
            app: app, open: open, showsMetrics: false,
            executeSnippet: executeSnippet)
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
                closeAll: closeAllWorkspaces,
                connect: { selectingConnection = true })
        }
        .navigationDestination(item: $workspaceID) { id in
            if let workspace = app.workspaces.first(where: { $0.id == id }) {
                MobileWorkspaceView(
                    library: app.library, pro: app.pro, commandGenerator: app.commandGenerator,
                    workspace: workspace, workspaces: app.workspaces,
                    selectWorkspace: selectWorkspace,
                    renameWorkspace: beginWorkspaceRename,
                    openSameDirectory: openSameDirectory,
                    closeWorkspace: closeWorkspace
                )
                .onAppear { workspace.activateWhenOpened() }
            }
        }
        .sheet(isPresented: $selectingConnection) {
            NavigationStack {
                MobileConnectionPicker(
                    library: app.library,
                    connect: { hostID, kind in
                        selectingConnection = false
                        open(hostID, kind)
                    },
                    cancel: { selectingConnection = false })
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
                selectWorkspace(workspace.id)
            } label: {
                HStack(spacing: 12) {
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: workspace.descriptor.kind.symbol)
                            .foregroundStyle(.secondary)
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
                Button("Close", systemImage: "xmark", role: .destructive) { closeWorkspace(workspace.id) }
            }
            .contextMenu {
                Button("Rename", systemImage: "pencil") { beginWorkspaceRename(workspace) }
                Divider()
                Button("Close", systemImage: "xmark", role: .destructive) { closeWorkspace(workspace.id) }
            }
        }
    }

    private func workspaceStatusTint(_ workspace: MobileWorkspace) -> Color {
        if workspace.connected { return .green }
        if workspace.busy || workspace.reconnectState != nil { return .orange }
        return .secondary
    }

    private var assistant: some View {
        MobileAssistantView(app: app, model: app.assistant)
    }

    private var metrics: some View {
        MobileMetricsView(app: app)
    }

    private var settings: some View {
        MobileSettingsView(app: app)
    }

    private func open(_ hostID: UUID, _ kind: MobileWorkspaceDescriptor.Kind) {
        workspaceID = app.open(hostID: hostID, kind: kind)
        tab = .workspaces
        selection = .workspaces
    }

    private func executeSnippet(_ snippet: Snippet, on hostIDs: [Host.ID]) {
        guard let first = app.execute(snippet, on: hostIDs).first else { return }
        workspaceID = first
        tab = .workspaces
        selection = .workspaces
        app.focusWorkspaceActivity(first)
    }

    private func selectWorkspace(_ id: UUID) {
        guard let workspace = app.workspaces.first(where: { $0.id == id }) else { return }
        workspace.activateWhenOpened()
        workspaceID = id
        app.focusWorkspaceActivity(id)
    }

    private func beginWorkspaceRename(_ workspace: MobileWorkspace) {
        renamingWorkspace = workspace
    }

    private func openSameDirectory(_ launch: MobileWorkspaceDirectoryLaunch) {
        guard let id = app.open(hostID: launch.hostID, kind: launch.kind, initialPath: launch.path) else { return }
        workspaceID = id
        tab = .workspaces
        selection = .workspaces
        app.focusWorkspaceActivity(id)
    }

    private func closeWorkspace(_ id: UUID) {
        app.close(id)
        if workspaceID == id { workspaceID = nil }
    }

    private func closeAllWorkspaces() {
        app.closeAll()
        workspaceID = nil
    }
}
