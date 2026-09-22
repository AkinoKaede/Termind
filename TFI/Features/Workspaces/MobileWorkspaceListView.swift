import SwiftUI
import TermindDomain
import TermindPresentation
import UIKit

private enum MobileWorkspaceListMetrics {
    static let leadingIconSize: CGFloat = 36
    static let rowSpacing: CGFloat = 12
}

/// The registered Workspaces destination.
struct MobileWorkspaceListView: View {
    let app: MobileAppModel
    @Bindable var scene: MobileSceneModel
    @Environment(\.colorScheme) private var colorScheme
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
            if !app.orderedWorkspaceItems.isEmpty || historyRows.isEmpty {
                Section("Workspaces") { workspaceRows }
            }
            if app.orderedWorkspaceItems.isEmpty, !historyRows.isEmpty {
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
                    workspace: workspace, workspaces: app.orderedWorkspaceItems.map(\.descriptor),
                    selectWorkspace: scene.selectWorkspace,
                    renameWorkspace: scene.beginWorkspaceRename,
                    canCloseMultipleWorkspaces: scene.canCloseMultipleWorkspaces,
                    openSameDirectory: scene.openSameDirectory,
                    closeWorkspace: scene.closeWorkspace,
                    closeOtherWorkspaces: scene.closeOtherWorkspaces,
                    closeAllWorkspaces: scene.closeAllWorkspaces
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
        if app.orderedWorkspaceItems.isEmpty {
            ContentUnavailableView(
                "No Workspaces", systemImage: "terminal",
                description: Text("Use Connect to start a workspace.")
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        ForEach(app.orderedWorkspaceItems) { item in
            Button {
                scene.selectWorkspace(item.id)
            } label: {
                HStack(spacing: MobileWorkspaceListMetrics.rowSpacing) {
                    ZStack(alignment: .bottomTrailing) {
                        hostIcon(item.host)
                        if let workspace = item.workspace {
                            Circle()
                                .fill(statusTint(for: workspace))
                                .frame(width: 8, height: 8)
                                .overlay { Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .center, spacing: 12) {
                            Text(item.descriptor.title).foregroundStyle(.primary).lineLimit(1)
                            Spacer(minLength: 12)
                            protocolLabel(item.descriptor.kind)
                        }
                        Text(item.loginAddress)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workspace-\(item.id)")
            .swipeActions {
                Button("Close", systemImage: "xmark", role: .destructive) {
                    scene.closeWorkspace(item.id)
                }
            }
            .contextMenu {
                MobileWorkspaceLifecycleMenuActions(
                    canCloseMultipleWorkspaces: scene.canCloseMultipleWorkspaces,
                    rename: { scene.beginWorkspaceRename(item.descriptor) },
                    close: { scene.closeWorkspace(item.id) },
                    closeOthers: { scene.closeOtherWorkspaces(than: item.id) },
                    closeAll: scene.closeAllWorkspaces
                )
            }
        }
    }

    var historyRows: [MobileRecentHostRow] {
        _ = app.connectionHistory.revision
        return MobileConnectionHistory.recentHostRows(
            entries: app.connectionHistory.localEntries(),
            library: app.library,
            limit: Self.historyLimit
        )
    }

    @ViewBuilder
    private var historyRowsContent: some View {
        ForEach(historyRows) { row in
            historyButton(row)
                .contextMenu {
                    ForEach(MobileConnectionHistoryActionPolicy.menuKinds, id: \.self) { kind in
                        historyConnectionButton(kind, host: row.host)
                    }
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        app.connectionHistory.clear(for: row.host.id)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        app.connectionHistory.clear(for: row.host.id)
                    }
                    ForEach(MobileConnectionHistoryActionPolicy.swipeKinds, id: \.self) { kind in
                        historyConnectionButton(kind, host: row.host)
                            .tint(swipeTint(for: kind))
                    }
                }
        }
    }

    @ViewBuilder
    private func historyButton(_ row: MobileRecentHostRow) -> some View {
        if let preferredKind = row.preferredKind {
            Button {
                scene.open(hostID: row.host.id, kind: preferredKind)
            } label: {
                historyLabel(row)
            }
            .buttonStyle(.plain)
        } else {
            historyLabel(row)
                .opacity(0.55)
        }
    }

    private func historyLabel(_ row: MobileRecentHostRow) -> some View {
        HStack(spacing: MobileWorkspaceListMetrics.rowSpacing) {
            hostIcon(row.host)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.host.name).foregroundStyle(.primary).lineLimit(1)
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

    private func hostIcon(_ host: Host?) -> some View {
        let distribution = host.flatMap { LinuxDistributionIconCatalog.entry(for: $0.detectedDistribution) }
        let tint =
            host?.colorTag.color
            ?? distribution.flatMap {
                LinuxDistributionBrandColor.color(hex: $0.hex, colorScheme: colorScheme)
            }
            ?? .accentColor
        return HostSystemIcon(asset: distribution?.asset, size: MobileWorkspaceListMetrics.leadingIconSize)
            .tint(tint)
    }

    private func protocolLabel(_ kind: ConnectionHistoryEntry.Kind) -> some View {
        Text(kind.label)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityHidden(true)
    }

    private func historyConnectionButton(
        _ kind: ConnectionHistoryEntry.Kind, host: Host
    ) -> some View {
        Button(kind.label, systemImage: kind.symbol) {
            guard MobileConnectionHistoryActionPolicy.isAvailable(kind, for: host) else { return }
            scene.open(hostID: host.id, kind: kind)
        }
        .disabled(!MobileConnectionHistoryActionPolicy.isAvailable(kind, for: host))
    }

    private func swipeTint(for kind: ConnectionHistoryEntry.Kind) -> Color {
        switch kind {
        case .ssh: .blue
        case .telnet: .purple
        case .sftp: .orange
        }
    }

    private func statusTint(for workspace: MobileWorkspace) -> Color {
        if workspace.connected { return .green }
        if workspace.busy || workspace.reconnectState != nil { return .orange }
        return .secondary
    }
}
