import SwiftUI
import TermindDomain
import TermindPresentation
import UIKit

private enum MobileWorkspaceListMetrics {
    static let leadingIconSize: CGFloat = 36
    static let rowSpacing: CGFloat = 12
}

enum MobileWorkspaceConnectionIndicator: Equatable {
    case connected
    case busy

    static func resolve(connected: Bool, busy: Bool, reconnecting: Bool) -> Self? {
        if connected { return .connected }
        if busy || reconnecting { return .busy }
        return nil
    }

    var status: ConnectionStatus {
        switch self {
        case .connected: .connected
        case .busy: .connecting
        }
    }
}

/// The registered Workspaces destination.
struct MobileWorkspaceListView: View {
    let app: MobileAppModel
    @Bindable var scene: MobileSceneModel
    @Environment(\.locale) private var locale
    @State private var clearingRecentHost: Host?

    static let historyLimit = 5

    var body: some View {
        List {
            Section {
                Button(action: scene.openTransfers) {
                    Label(AppStrings.SFTP.transfers.swiftUIKey, systemImage: "arrow.up.arrow.down")
                }
            }
            if !scene.workspaceSession.orderedWorkspaceItems.isEmpty || historyRows.isEmpty {
                Section(AppStrings.Navigation.workspaces.swiftUIKey) { workspaceRows }
            }
            if scene.workspaceSession.orderedWorkspaceItems.isEmpty, !historyRows.isEmpty {
                Section(AppStrings.Workspace.recents.swiftUIKey) { historyRowsContent }
            }
        }
        .navigationTitle(AppStrings.Navigation.workspaces.swiftUIKey)
        .navigationDestination(isPresented: $scene.showsTransfers) {
            MobileTransfersView(transfers: app.transfers, hosts: app.library)
        }
        .toolbar {
            MobileWorkspaceToolbar(
                hasWorkspaces: scene.canCloseAllWorkspaces,
                closeAll: scene.closeAllWorkspaces,
                connect: scene.openConnectionPicker,
                batchStartup: scene.openBatchStartup
            )
        }
        .navigationDestination(item: $scene.workspaceID) { id in
            if let workspace = scene.workspaceSession.workspaces.first(where: { $0.id == id }) {
                MobileWorkspaceView(
                    library: app.library, commandGenerator: app.commandGenerator,
                    workspace: workspace, workspaces: scene.workspaceSession.orderedWorkspaceItems.map(\.descriptor),
                    unreadWorkspaceIDs: scene.workspaceSession.unreadWorkspaceIDs,
                    selectWorkspace: scene.selectWorkspace,
                    renameWorkspace: scene.beginWorkspaceRename,
                    canCloseMultipleWorkspaces: scene.canCloseMultipleWorkspaces,
                    openSameDirectory: scene.openSameDirectory,
                    closeWorkspace: scene.closeWorkspace,
                    closeOtherWorkspaces: scene.closeOtherWorkspaces
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
        .sheet(isPresented: $scene.isBatchStartupPresented, onDismiss: scene.completeBatchStartup) {
            MobileBatchStartupPicker(library: app.library, connect: scene.prepareBatchStartup)
        }
        .task(id: scene.selectedDestination) {
            guard scene.selectedDestination == .workspaces else { return }
            await Task.yield()
            scene.activatePendingWorkspace()
        }
        .confirmationDialog(
            AppStrings.Workspace.clearRecentConnectionsConfirmation,
            isPresented: Binding(
                get: { clearingRecentHost != nil },
                set: { if !$0 { clearingRecentHost = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(AppStrings.Common.clearHistory.swiftUIKey, role: .destructive) {
                if let host = clearingRecentHost {
                    app.connectionHistory.clear(for: host.id)
                }
                clearingRecentHost = nil
            }
            Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) { clearingRecentHost = nil }
        } message: {
            Text(AppStrings.Workspace.clearHostHistoryWarning)
        }
    }

    @ViewBuilder
    private var workspaceRows: some View {
        if scene.workspaceSession.orderedWorkspaceItems.isEmpty {
            ContentUnavailableView(
                AppStrings.Workspace.noWorkspaces.swiftUIKey, systemImage: "terminal",
                description: Text(AppStrings.Workspace.useConnectToStartAWorkspace)
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        ForEach(scene.workspaceSession.orderedWorkspaceItems) { item in
            Button {
                scene.selectWorkspace(item.id)
            } label: {
                HStack(spacing: MobileWorkspaceListMetrics.rowSpacing) {
                    HostConnectionIcon(
                        host: item.host, size: MobileWorkspaceListMetrics.leadingIconSize,
                        status: item.workspace.flatMap {
                            MobileWorkspaceConnectionIndicator.resolve(
                                connected: $0.connected, busy: $0.busy, reconnecting: $0.reconnectState != nil
                            )?.status
                        },
                        badgeStyle: .card(background: Color(uiColor: .systemBackground), pulses: false)
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: MobileWorkspaceListMetrics.rowSpacing) {
                            Text(item.descriptor.title)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if scene.workspaceSession.unreadCount(for: item.id) > 0 {
                                NotificationUnreadDot()
                            }
                        }
                        HStack(alignment: .center, spacing: 12) {
                            Text(item.loginAddress)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 12)
                            protocolLabel(item.descriptor.kind)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(
                scene.workspaceSession.unreadCount(for: item.id) > 0
                    ? String(
                        localized: AppStrings.Notifications.unread(
                            scene.workspaceSession.unreadCount(for: item.id))) : ""
            )
            .accessibilityIdentifier("workspace-\(item.id)")
            .swipeActions {
                Button(AppStrings.Common.close.swiftUIKey, systemImage: "xmark", role: .destructive) {
                    scene.closeWorkspace(item.id)
                }
            }
            .contextMenu {
                let hasUnread = scene.workspaceSession.unreadCount(for: item.id) > 0
                MobileWorkspaceLifecycleMenuActions(
                    canCloseMultipleWorkspaces: scene.canCloseMultipleWorkspaces,
                    rename: { scene.beginWorkspaceRename(item.descriptor) },
                    close: { scene.closeWorkspace(item.id) },
                    closeOthers: { scene.closeOtherWorkspaces(than: item.id) },
                    hasUnread: hasUnread,
                    toggleRead: {
                        if hasUnread {
                            scene.workspaceSession.markRead(item.id)
                        } else {
                            scene.workspaceSession.markUnread(item.id)
                        }
                    }
                )
            }
        }
    }

    var historyRows: [MobileRecentHostRow] {
        _ = app.connectionHistory.revision
        return MobileConnectionHistory.recentHostRows(
            history: app.connectionHistory,
            library: app.library,
            limit: Self.historyLimit
        )
    }

    @ViewBuilder
    private var historyRowsContent: some View {
        ForEach(historyRows) { row in
            historyButton(row)
                .contextMenu {
                    let kinds = MobileConnectionHistoryActionPolicy.availableMenuKinds(for: row.host)
                    ForEach(kinds, id: \.self) { kind in
                        historyConnectionButton(kind, host: row.host)
                    }
                    if !kinds.isEmpty { Divider() }
                    Button(AppStrings.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) {
                        requestHistoryClear(for: row.host)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(AppStrings.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) {
                        requestHistoryClear(for: row.host)
                    }
                    ForEach(
                        MobileConnectionHistoryActionPolicy.availableSwipeKinds(for: row.host), id: \.self
                    ) { kind in
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

    private func requestHistoryClear(for host: Host) {
        if DeletionContentCategory.recordedContent.requiresConfirmation(for: .clearCollection) {
            clearingRecentHost = host
        } else {
            app.connectionHistory.clear(for: host.id)
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
        HostDistributionIcon(host: host, size: MobileWorkspaceListMetrics.leadingIconSize)
    }

    private func protocolLabel(_ kind: ConnectionHistoryEntry.Kind) -> some View {
        Text(kind.label)
            .font(.caption2)
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
        case .ssh: .accentColor
        case .telnet: .purple
        case .sftp: .orange
        }
    }

}
