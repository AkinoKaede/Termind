import Foundation
import Observation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure

import struct TermindDomain.Host

private enum MobileWorkspaceStartup {
    case none
    case command(String)
    case directory(String)
}

@MainActor
struct MobileWorkspaceItem: Identifiable {
    let descriptor: MobileWorkspaceDescriptor
    let workspace: MobileWorkspace?
    let host: Host?
    let loginAddress: String

    var id: MobileWorkspaceDescriptor.ID { descriptor.id }
}

/// In-process connection intent and live workspaces belonging to one native scene.
@MainActor
@Observable
final class MobileWorkspaceSessionModel {
    let id: String
    private(set) var workspaces: [MobileWorkspace] = []
    private var manuallyUnreadIDs = Set<UUID>()
    var unreadWorkspaceIDs: Set<UUID> {
        Set(orderedWorkspaceItems.filter { unreadCount(for: $0.id) > 0 }.map(\.id))
    }
    var hasUnreadCompletion: Bool { unreadCompletionCount > 0 }
    var unreadCompletionCount: Int { orderedWorkspaceItems.reduce(0) { $0 + unreadCount(for: $1.id) } }

    func unreadCount(for id: UUID) -> Int {
        max(
            manuallyUnreadIDs.contains(id) ? 1 : 0,
            workspaces.first { $0.id == id }?.commandMonitor.unreadCompletionCount ?? 0)
    }

    func markRead(_ id: UUID) {
        manuallyUnreadIDs.remove(id)
        workspaces.first { $0.id == id }?.commandMonitor.markRead()
    }

    func markUnread(_ id: UUID) {
        guard orderedWorkspaceItems.contains(where: { $0.id == id }) else { return }
        manuallyUnreadIDs.insert(id)
    }
    private(set) var savedWorkspaceDescriptors: [MobileWorkspaceDescriptor] {
        didSet { app.persistWorkspaceDescriptors() }
    }
    private var workspaceDisplayOrder: [MobileWorkspace.ID]
    var canReopen: Bool { !isDiscarded && !app.closedWorkspaceRecords.isEmpty }
    var reopensWindow: Bool { app.closedWorkspaceRecords.first?.isWindow == true }
    var recentlyClosedRecords: [RecentlyClosedRecord<MobileWorkspaceDescriptor>] { app.closedWorkspaceRecords }
    private(set) var isDiscarded = false
    @ObservationIgnored private unowned let app: MobileAppModel

    init(id: String, app: MobileAppModel, descriptors: [MobileWorkspaceDescriptor]) {
        self.id = id
        self.app = app
        savedWorkspaceDescriptors = descriptors
        workspaceDisplayOrder = descriptors.map(\.id)
    }

    struct Recovery {
        var workspaces: [MobileWorkspace]
        var descriptors: [MobileWorkspaceDescriptor]
        var order: [MobileWorkspace.ID]
        var manuallyUnreadIDs: Set<UUID> = []
    }

    var recovery: Recovery {
        Recovery(
            workspaces: workspaces, descriptors: savedWorkspaceDescriptors, order: workspaceDisplayOrder,
            manuallyUnreadIDs: manuallyUnreadIDs)
    }

    func releaseForRecovery() {
        app.persistentClose.cancel()
        manuallyUnreadIDs.removeAll()
        workspaces.removeAll()
        savedWorkspaceDescriptors.removeAll()
        workspaceDisplayOrder.removeAll()
    }

    func acceptRecovery(_ recovery: Recovery) {
        manuallyUnreadIDs.formUnion(recovery.manuallyUnreadIDs)
        workspaces.append(contentsOf: recovery.workspaces)
        savedWorkspaceDescriptors.append(contentsOf: recovery.descriptors)
        workspaceDisplayOrder.append(contentsOf: recovery.order)
        for workspace in recovery.workspaces {
            workspace.didRequestClose = { [weak self] in self?.close($0) }
        }
    }

    func discard(authorized: Bool = false) {
        guard !isDiscarded else { return }
        if !authorized, app.deferPersistentClose(workspaces, action: { [weak self] in self?.discard(authorized: true) })
        {
            return
        }
        let states = orderedWorkspaceItems.map { $0.workspace?.reopenState ?? .init(descriptor: $0.descriptor) }
        app.rememberClosedWorkspaces(states, isWindow: true)
        closeAll(rememberForReopen: false, authorized: true)
        isDiscarded = true
    }

    var recentWorkspaces: [MobileWorkspaceDescriptor] {
        let opened = Set(workspaces.map(\.id))
        return savedWorkspaceDescriptors.filter { !opened.contains($0.id) }
    }

    var restorableDescriptors: [MobileWorkspaceDescriptor] {
        savedWorkspaceDescriptors.compactMap { saved in
            let descriptor = workspaces.first { $0.id == saved.id }?.restorationDescriptor ?? saved
            // Tailnet peers can be rediscovered after the scene's descriptors load.
            guard let host = app.library.host(descriptor.hostID) else { return descriptor }
            guard host.isEnabled(descriptor.kind.terminalProtocol ?? .ssh) else { return nil }
            if descriptor.kind.terminalProtocol?.isResumable == true { return descriptor }
            return descriptor.kind == .ssh
                && (host.sessionPersistence.enabled || descriptor.remoteSession != nil) ? descriptor : nil
        }
    }

    var orderedWorkspaceItems: [MobileWorkspaceItem] {
        workspaceDisplayOrder.compactMap { id in
            let workspace = workspaces.first { $0.id == id }
            guard let descriptor = workspace?.descriptor ?? savedWorkspaceDescriptors.first(where: { $0.id == id })
            else { return nil }
            let host = app.library.host(descriptor.hostID) ?? workspace?.presentationHost
            let loginAddress =
                workspace?.temporaryLoginAddress
                ?? host.map {
                    app.library.loginAddress(
                        for: $0,
                        protocol: descriptor.kind == .telnet ? .telnet : .ssh)
                }
                ?? descriptor.title
            return MobileWorkspaceItem(
                descriptor: descriptor,
                workspace: workspace,
                host: host,
                loginAddress: loginAddress)
        }
    }

    func open(
        hostID: UUID, kind: ConnectionHistoryEntry.Kind,
        initialPath: String? = nil
    ) -> UUID? {
        guard !isDiscarded, let host = app.library.host(hostID) else { return nil }
        do { try app.library.requireHostAccess(host) } catch {
            if case HostAccessError.verifyingEntitlement = error {
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await app.library.resolveHostAccess(host)
                        guard !isDiscarded else { return }
                        _ = open(hostID: hostID, kind: kind, initialPath: initialPath)
                    } catch {
                        if case HostAccessError.lockedHost = error {
                            app.pro.presentPaywall()
                        } else if !(error is CancellationError) {
                            app.error = HostAccessError.presentationDescription(of: error)
                        }
                    }
                }
            } else if case HostAccessError.lockedHost = error {
                app.pro.presentPaywall()
            } else {
                app.error = HostAccessError.presentationDescription(of: error)
            }
            return nil
        }
        let startup: MobileWorkspaceStartup
        if let initialPath,
            !initialPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            startup = .directory(RemotePath.normalized(initialPath))
        } else {
            startup = .none
        }
        let workspace = makeWorkspace(host: host, kind: kind, startup: startup)
        addWorkspaces([workspace])
        return workspace.id
    }

    func rebuild(_ recovery: WorkspaceActivityAttributes.Recovery) -> UUID? {
        guard !isDiscarded, let host = app.library.host(recovery.hostID),
            let kind = ConnectionHistoryEntry.Kind(rawValue: recovery.kind),
            MobileConnectionHistoryActionPolicy.isAvailable(kind, for: host)
        else { return nil }
        if kind.terminalProtocol?.isResumable == true {
            // A stale activity cannot recreate an explicitly closed resumable session.
            return nil
        }
        let workspace = makeWorkspace(host: host, kind: kind)
        if let data = recovery.remoteSession,
            let reference = try? JSONDecoder().decode(RemoteSessionReference.self, from: data),
            reference.hostID == host.id, kind == .ssh
        {
            workspace.restoreRemoteSession(reference)
        }
        workspace.sessionPersistence.requiresSelection = true
        addWorkspaces([workspace])
        return workspace.id
    }

    @discardableResult
    func batchStartup(
        hostIDs: [Host.ID], connectionProtocol: MobileConnectionProtocol
    ) -> [MobileWorkspace.ID] {
        let wanted = Set(hostIDs)
        return app.library.hosts(matching: "", for: connectionProtocol.useCase)
            .filter { wanted.contains($0.id) }
            .compactMap { host in
                guard let kind = connectionProtocol.kind(for: host) else { return nil }
                return open(hostID: host.id, kind: kind)
            }
    }

    func openExternalConnection(_ request: RemoteConnectionURL) -> MobileWorkspace.ID? {
        guard !isDiscarded else { return nil }
        let host: Host
        let kind: ConnectionHistoryEntry.Kind
        switch request.kind {
        case .ssh:
            host = Host(name: request.host, host: request.host, port: request.port)
            kind = .ssh
        case .sftp:
            host = Host(name: request.host, host: request.host, port: request.port)
            kind = .sftp
        case .telnet:
            host = Host(
                name: request.host, host: request.host,
                sshEnabled: false, telnetEnabled: true, telnetPort: request.port)
            kind = .telnet
        }
        let route = SSHConnectionRoute(
            hosts: [host], usernames: request.username.map { [host.id: $0] } ?? [:])
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(
                hostID: host.id, title: host.name, kind: kind),
            hosts: app.library, transfers: app.transfers, sftpEdits: app.sftpEdits,
            terminalSettings: app.terminalSettings, connectionServices: app.workspaceConnectionServices,
            transientHost: host,
            connectionRoute: request.kind == .telnet ? nil : route,
            usernameHint: request.username,
            connectionOrigin: .externalLink(
                hostKeyConstraints: request.hostKeyFingerprint.map { [host.id: $0] } ?? [:]),
            advisoryTelnetPassword: request.advisoryPassword.map(SSHSecret.init),
            externalSFTPResourcePath: request.kind == .sftp ? request.path : nil,
            externalSFTPMustBeDirectory: request.sftpType == .directory)
        addWorkspaces([workspace], persists: false)
        return workspace.id
    }

    /// Opens one workspace per target using its default terminal transport. The command is intentionally
    /// carried only by the live workspace and never enters its restoration descriptor.
    func execute(_ snippet: Snippet, on hostIDs: [Host.ID]) -> [MobileWorkspace.ID] {
        guard !isDiscarded else { return [] }
        let wanted = Set(hostIDs)
        let targets = app.library.hosts(matching: "", for: .snippetExecution)
            .filter { wanted.contains($0.id) }
        let opened = targets.map { host in
            makeWorkspace(
                host: host,
                kind: .terminal(host.terminalTransports.preferred(isTailscaleManaged: host.isTailscaleManaged)),
                startup: .command(snippet.body))
        }
        addWorkspaces(opened)
        return opened.map(\.id)
    }

    @discardableResult
    func renameWorkspace(_ id: MobileWorkspace.ID, to title: String) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        guard !isDiscarded else { return false }
        let workspace = workspaces.first { $0.id == id }
        let savedIndex = savedWorkspaceDescriptors.firstIndex { $0.id == id }
        guard workspace != nil || savedIndex != nil else { return false }
        if let workspace {
            guard workspace.rename(to: title) else { return false }
        } else {
            guard let savedIndex, savedWorkspaceDescriptors[savedIndex].title != title else { return false }
            savedWorkspaceDescriptors[savedIndex].title = title
        }
        if let savedIndex, let workspace {
            savedWorkspaceDescriptors[savedIndex] = workspace.descriptor
        }
        return true
    }

    func close(_ id: UUID, rememberForReopen: Bool = true, authorized: Bool = false) {
        if !authorized,
            app.deferPersistentClose(
                workspaces.filter { $0.id == id },
                action: { [weak self] in
                    self?.close(id, rememberForReopen: rememberForReopen, authorized: true)
                })
        {
            return
        }
        manuallyUnreadIDs.remove(id)
        let wasSaved = savedWorkspaceDescriptors.contains(where: { $0.id == id })
        guard wasSaved || workspaces.contains(where: { $0.id == id }) else { return }
        if rememberForReopen { rememberClosedWorkspaces([id]) }
        app.workspaceDidClose(id)
        if let workspace = workspaces.first(where: { $0.id == id }) {
            workspace.didChangeState = nil
            workspace.didRequestClose = nil
            workspace.close()
        }
        workspaces.removeAll { $0.id == id }
        savedWorkspaceDescriptors.removeAll { $0.id == id }
        workspaceDisplayOrder.removeAll { $0 == id }
    }

    var closableWorkspaceCount: Int {
        Set(savedWorkspaceDescriptors.map(\.id)).union(workspaces.map(\.id)).count
    }

    func closeOtherWorkspaces(than id: MobileWorkspace.ID, authorized: Bool = false) {
        if !authorized,
            app.deferPersistentClose(
                workspaces.filter { $0.id != id },
                action: { [weak self] in
                    self?.closeOtherWorkspaces(than: id, authorized: true)
                })
        {
            return
        }
        let knownIDs = Set(savedWorkspaceDescriptors.map(\.id)).union(workspaces.map(\.id))
        guard knownIDs.contains(id), knownIDs.count > 1 else { return }
        rememberClosedWorkspaces(knownIDs.subtracting([id]))

        let closing = workspaces.filter { $0.id != id }
        for closedID in knownIDs where closedID != id { app.workspaceDidClose(closedID) }
        manuallyUnreadIDs = manuallyUnreadIDs.intersection([id])
        workspaces.removeAll { $0.id != id }
        savedWorkspaceDescriptors.removeAll { $0.id != id }
        workspaceDisplayOrder.removeAll { $0 != id }
        for workspace in closing {
            workspace.didChangeState = nil
            workspace.didRequestClose = nil
            workspace.close()
        }
    }

    func closeAll(rememberForReopen: Bool = true, authorized: Bool = false) {
        if !authorized,
            app.deferPersistentClose(
                workspaces,
                action: { [weak self] in
                    self?.closeAll(rememberForReopen: rememberForReopen, authorized: true)
                })
        {
            return
        }
        manuallyUnreadIDs.removeAll()
        guard !savedWorkspaceDescriptors.isEmpty || !workspaces.isEmpty else { return }
        if rememberForReopen { rememberClosedWorkspaces(Set(workspaceDisplayOrder)) }
        let closing = workspaces
        for id in Set(savedWorkspaceDescriptors.map(\.id)).union(workspaces.map(\.id)) {
            app.workspaceDidClose(id)
        }
        workspaces.removeAll()
        savedWorkspaceDescriptors.removeAll()
        workspaceDisplayOrder.removeAll()
        for workspace in closing {
            workspace.didChangeState = nil
            workspace.didRequestClose = nil
            workspace.close()
        }
    }

    private func rememberClosedWorkspaces(_ ids: Set<UUID>) {
        for item in orderedWorkspaceItems where ids.contains(item.id) {
            app.rememberClosedWorkspaces([item.workspace?.reopenState ?? .init(descriptor: item.descriptor)])
        }
    }

    func reopenLastClosed() -> MobileWorkspace.ID? {
        guard !isDiscarded, let record = app.closedWorkspaceRecords.first else { return nil }
        if record.isWindow {
            app.requestClosedWindow(record.id)
            return nil
        }
        return reopenClosedWorkspace(record.id)
    }

    func reopenClosedWorkspace(_ id: MobileWorkspace.ID) -> MobileWorkspace.ID? {
        guard !isDiscarded else { return nil }
        return app.restoreClosedRecord(id, into: self)
    }

    func reopenClosedItem(_ itemID: UUID, in recordID: UUID) -> UUID? {
        guard !isDiscarded else { return nil }
        return app.restoreClosedRecord(recordID, into: self, itemID: itemID)
    }

    func requestClosedWindow(_ id: UUID) { app.requestClosedWindow(id) }

    func restoreClosedStates(_ states: [MobileWorkspace.ReopenState]) {
        for state in states {
            let workspace = MobileWorkspace(
                descriptor: state.descriptor, hosts: app.library, transfers: app.transfers, sftpEdits: app.sftpEdits,
                terminalSettings: app.terminalSettings, connectionServices: app.workspaceConnectionServices,
                transientHost: state.transientHost, connectionRoute: state.connectionRoute,
                usernameHint: state.usernameHint, connectionOrigin: state.connectionOrigin,
                externalSFTPResourcePath: state.externalSFTPResourcePath,
                externalSFTPMustBeDirectory: state.externalSFTPMustBeDirectory)
            workspace.restoreRemoteSession(state.remoteSession)
            addWorkspaces([workspace], persists: state.connectionOrigin.allowsPersistence)
        }
    }

    /// Publish before connecting so repeated selection in this window shares one initial attempt.
    @discardableResult
    func openWorkspace(_ id: UUID) -> MobileWorkspace? {
        guard !isDiscarded else { return nil }
        if let workspace = workspaces.first(where: { $0.id == id }) { return workspace }
        guard let descriptor = savedWorkspaceDescriptors.first(where: { $0.id == id }) else { return nil }
        guard app.library.host(descriptor.hostID) != nil else {
            return nil
        }
        let workspace = MobileWorkspace(
            descriptor: descriptor, hosts: app.library, transfers: app.transfers, sftpEdits: app.sftpEdits,
            terminalSettings: app.terminalSettings, connectionServices: app.workspaceConnectionServices)
        workspace.requiresTransportRecovery = descriptor.kind.terminalProtocol?.isResumable == true
        if descriptor.kind.isSSHTerminal {
            workspace.restoreRemoteSession(descriptor.remoteSession)
            workspace.sessionPersistence.requiresSelection = descriptor.kind == .ssh
        }
        addWorkspaces([workspace])
        return workspace
    }

    private func makeWorkspace(
        host: Host, kind: ConnectionHistoryEntry.Kind, startup: MobileWorkspaceStartup = .none
    ) -> MobileWorkspace {
        let initialCommand: String?
        let recordsInitialCommandInHistory: Bool
        let initialSFTPPath: String?
        switch (kind, startup) {
        case (.ssh, .command(let command)), (.mosh, .command(let command)), (.eternalTerminal, .command(let command)):
            initialCommand = command
            recordsInitialCommandInHistory = true
            initialSFTPPath = nil
        case (.ssh, .directory(let path)), (.mosh, .directory(let path)), (.eternalTerminal, .directory(let path)):
            initialCommand = RemoteShellCommand.changeDirectory(to: path)
            recordsInitialCommandInHistory = false
            initialSFTPPath = nil
        case (.sftp, .directory(let path)):
            initialCommand = nil
            recordsInitialCommandInHistory = true
            initialSFTPPath = path
        case (.ssh, .none), (.mosh, .none), (.eternalTerminal, .none), (.sftp, .none), (.sftp, .command),
            (.telnet, .none), (.telnet, .command), (.telnet, .directory):
            initialCommand = nil
            recordsInitialCommandInHistory = true
            initialSFTPPath = nil
        }
        let title = WorkspaceNameAllocator.nextName(
            prefix: host.name,
            occupiedNames: savedWorkspaceDescriptors.map(\.title),
            automaticallyRenames: app.workspaceSettings.preferences.automaticallyRenamesWorkspaces)
        return MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(
                hostID: host.id, title: title, kind: kind),
            hosts: app.library, transfers: app.transfers, sftpEdits: app.sftpEdits,
            terminalSettings: app.terminalSettings,
            connectionServices: app.workspaceConnectionServices,
            initialCommand: initialCommand,
            recordsInitialCommandInHistory: recordsInitialCommandInHistory,
            initialSFTPPath: initialSFTPPath)
    }

    private func addWorkspaces(_ added: [MobileWorkspace], persists: Bool = true) {
        guard !added.isEmpty else { return }
        var orderedIDs = Set(workspaceDisplayOrder)
        for id in added.map(\.id) where orderedIDs.insert(id).inserted {
            workspaceDisplayOrder.append(id)
        }
        for workspace in added {
            workspace.terminalRecoveryStore = app.terminalRecoveryStore
            app.workspaceWillOpen(workspace, close: { [weak self] in self?.close($0) })
        }
        workspaces.append(contentsOf: added)
        if persists {
            let savedIDs = Set(savedWorkspaceDescriptors.map(\.id))
            savedWorkspaceDescriptors.append(contentsOf: added.map(\.descriptor).filter { !savedIDs.contains($0.id) })
        }
        app.workspacesDidOpen(added)
        for workspace in added { workspace.connect() }
        app.persistWorkspaceDescriptors()
    }

}
