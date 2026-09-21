import SwiftUI
import TermindDomain
import UIKit

/// The registered Workspaces destination.
struct MobileWorkspaceListView: View {
    let app: MobileAppModel
    @Bindable var scene: MobileSceneModel
    @Environment(\.locale) private var locale
    @State private var clearingHistory = false

    static let historyLimit = 5

    var body: some View {
        List {
            Section {
                NavigationLink {
                    MobileTransfersView(transfers: app.transfers, hosts: app.library)
                } label: {
                    Label("Transfers", systemImage: "arrow.up.arrow.down")
                }
            }
            if !app.workspaces.isEmpty || (app.recentWorkspaces.isEmpty && historyRows.isEmpty) {
                Section("Workspaces") { workspaceRows }
            }
            if !app.recentWorkspaces.isEmpty {
                Section("Recent Workspaces") {
                    ForEach(app.recentWorkspaces) { descriptor in
                        if let host = app.library.host(descriptor.hostID) {
                            Button {
                                scene.selectWorkspace(descriptor.id)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: descriptor.kind.symbol)
                                        .foregroundStyle(.tint)
                                        .frame(width: 28, height: 28)
                                        .accessibilityLabel(Text(descriptor.kind.label))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(descriptor.title).foregroundStyle(.primary).lineLimit(1)
                                        Text(
                                            app.library.loginAddress(
                                                for: host,
                                                protocol: descriptor.kind == .telnet ? .telnet : .ssh)
                                        )
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(.rect)
                                .accessibilityElement(children: .combine)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("recent-workspace-\(descriptor.id)")
                            .swipeActions {
                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    scene.closeWorkspace(descriptor.id)
                                }
                            }
                            .contextMenu {
                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    scene.closeWorkspace(descriptor.id)
                                }
                            }
                        }
                    }
                }
            }
            if app.workspaces.isEmpty, app.recentWorkspaces.isEmpty, !historyRows.isEmpty {
                Section("Recents") { historyRowsContent }
            }
        }
        .navigationTitle("Workspaces")
        .toolbar {
            MobileWorkspaceToolbar(
                hasWorkspaces: scene.canCloseAllWorkspaces,
                hasHistory: !app.connectionHistory.entries().isEmpty,
                closeAll: scene.closeAllWorkspaces,
                clearHistory: { clearingHistory = true },
                connect: scene.openConnectionPicker
            )
        }
        .confirmationDialog(
            "Clear connection history?",
            isPresented: $clearingHistory,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                app.connectionHistory.clearAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes all connection history without deleting any Hosts.")
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
                // SFTP's native search state before an SSH detail is mounted.
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
        .task(id: scene.selectedDestination) {
            guard scene.selectedDestination == .workspaces else { return }
            await Task.yield()
            scene.activatePendingWorkspace()
        }
    }

    @ViewBuilder
    private var workspaceRows: some View {
        if app.workspaces.isEmpty {
            ContentUnavailableView(
                "No Workspaces", systemImage: "terminal",
                description: Text("Use Connect to start a workspace.")
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

    var historyRows: [MobileConnectionHistoryRow] {
        _ = app.connectionHistory.revision
        return MobileConnectionHistory.rows(
            entries: app.connectionHistory.entries(),
            library: app.library,
            limit: Self.historyLimit
        )
    }

    @ViewBuilder
    private var historyRowsContent: some View {
        ForEach(historyRows) { row in
            Button {
                scene.open(hostID: row.host.id, kind: row.entry.kind)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: row.entry.kind.symbol)
                        .foregroundStyle(.tint)
                        .frame(width: 28, height: 28)
                        .accessibilityLabel(Text(row.entry.kind.label))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .center, spacing: 12) {
                            Text(row.host.name).foregroundStyle(.primary).lineLimit(1)
                            Spacer(minLength: 12)
                            Text(row.entry.kind.label)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .accessibilityHidden(true)
                        }
                        HStack(alignment: .center, spacing: 12) {
                            Text(row.loginAddress)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 12)
                            Text(row.entry.connectedAt, format: .relative(presentation: .numeric).locale(locale))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .accessibilityElement(children: .combine)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("SSH", systemImage: "terminal") {
                    scene.open(hostID: row.host.id, kind: .ssh)
                }
                Button("SFTP", systemImage: "folder") {
                    scene.open(hostID: row.host.id, kind: .sftp)
                }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    app.connectionHistory.delete(row.entry.id)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    app.connectionHistory.delete(row.entry.id)
                }
                Button("SFTP", systemImage: "folder") {
                    scene.open(hostID: row.host.id, kind: .sftp)
                }
                .tint(.orange)
                Button("SSH", systemImage: "terminal") {
                    scene.open(hostID: row.host.id, kind: .ssh)
                }
                .tint(.blue)
            }
        }
    }

    private func statusTint(for workspace: MobileWorkspace) -> Color {
        if workspace.connected { return .green }
        if workspace.busy || workspace.reconnectState != nil { return .orange }
        return .secondary
    }
}
