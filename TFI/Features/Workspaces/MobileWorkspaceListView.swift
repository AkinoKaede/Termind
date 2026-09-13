import SwiftUI
import UIKit

/// The registered Workspaces destination.
struct MobileWorkspaceListView: View {
    let app: MobileAppModel
    @Bindable var scene: MobileSceneModel

    var body: some View {
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
                connect: scene.openConnectionPicker
            )
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
                // The title menu replaces this pushed detail in place. A new identity tears down
                // SFTP's native search and back-gesture state before an SSH detail is mounted.
                .id(workspace.id)
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
                    cancel: { scene.isConnectionPickerPresented = false }
                )
            }
            .mobileSheetPresentation(compact: true)
        }
    }

    @ViewBuilder
    private var workspaceRows: some View {
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
                            .fill(statusTint(for: workspace))
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
                Button("Close", systemImage: "xmark", role: .destructive) {
                    scene.closeWorkspace(workspace.id)
                }
            }
            .contextMenu {
                Button("Rename", systemImage: "pencil") {
                    scene.beginWorkspaceRename(workspace)
                }
                Divider()
                Button("Close", systemImage: "xmark", role: .destructive) {
                    scene.closeWorkspace(workspace.id)
                }
            }
        }
    }

    private func statusTint(for workspace: MobileWorkspace) -> Color {
        if workspace.connected { return .green }
        if workspace.busy || workspace.reconnectState != nil { return .orange }
        return .secondary
    }
}
