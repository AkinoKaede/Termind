import SwiftUI
import UIKit

/// iPhone has four destinations. iPad retains the sidebar with individual library routes.
struct MobileRootView: View {
    let app: MobileAppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var sceneID = UUID()
    @State private var tab: MobileTab = .vault
    @State private var selection: MobileDestination? = .vault
    @State private var workspaceID: UUID?
    @State private var unavailable = false

    var body: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom != .pad {
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
                    }.navigationTitle("Termind")
                } detail: {
                    NavigationStack {
                        switch selection {
                        case .vault: vault
                        case .assistant: assistant
                        case .settings: settings
                        case .metrics: metrics
                        case .workspaces: workspaceList
                        default: vault
                        }
                    }
                }
            }
        }
        .sheet(isPresented: Binding(get: { app.pro.isPaywallPresented }, set: { app.pro.isPaywallPresented = $0 })) {
            MobileProView(pro: app.pro)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in app.sceneChanged(sceneID, phase: phase) }
        .onChange(of: app.pro.hasProAccess) { _, _ in app.reconcileSync() }
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
                workspaceID = id
                app.liveActivities.focus(id, in: app.workspaces)
                workspace.connect()
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
                unavailable ? String(localized: "This workspace was closed or its host was removed.") : app.error ?? "")
        }

    }

    private var vault: some View {
        MobileVaultView(app: app, open: open)
    }

    private var workspaceList: some View {
        List {
            Section {
                NavigationLink("Transfers") { MobileTransfersView(transfers: app.transfers) }
            }
            Section("Workspaces") { workspaceRows }
        }
        .navigationTitle("Workspaces")
        .navigationDestination(item: $workspaceID) { id in
            if let workspace = app.workspaces.first(where: { $0.id == id }) {
                MobileWorkspaceView(library: app.library, workspace: workspace)
            }
        }
    }

    @ViewBuilder private var workspaceRows: some View {
        if app.workspaces.isEmpty {
            Text("Open a host from Vault to start a workspace.").foregroundStyle(.secondary)
        }
        ForEach(app.workspaces) { workspace in
            Button {
                workspaceID = workspace.id
                app.liveActivities.focus(workspace.id, in: app.workspaces)
            } label: {
                Label {
                    VStack(alignment: .leading) {
                        Text(workspace.descriptor.title)
                        Text(workspace.status).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: workspace.descriptor.kind.symbol)
                }
            }
            .swipeActions { Button("Close", role: .destructive) { app.close(workspace.id) } }
        }
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
}

nonisolated enum MobileTab: String, CaseIterable {
    case vault, workspaces, assistant, settings
}
