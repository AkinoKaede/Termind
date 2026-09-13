import SwiftUI
import TermindDomain
import UIKit

struct MobileConnectionHistoryRow: Identifiable {
    let entry: ConnectionHistoryEntry
    let host: Host

    var id: ConnectionHistoryEntry.ID { entry.id }
}

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
            if app.workspaces.isEmpty, !historyRows.isEmpty {
                Section("History") { historyRowsContent }
            } else {
                Section("Workspaces") { workspaceRows }
            }
        }
        .navigationTitle("Workspaces")
        .toolbar {
            MobileWorkspaceToolbar(
                hasWorkspaces: !app.workspaces.isEmpty,
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
        return Array(
            app.connectionHistory.entries().lazy.compactMap { entry in
                app.library.host(entry.hostID).map { MobileConnectionHistoryRow(entry: entry, host: $0) }
            }.prefix(Self.historyLimit)
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
                            Text(app.library.loginAddress(for: row.host))
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
            }
        }
    }

    private func statusTint(for workspace: MobileWorkspace) -> Color {
        if workspace.connected { return .green }
        if workspace.busy || workspace.reconnectState != nil { return .orange }
        return .secondary
    }
}
