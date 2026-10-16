import Foundation
import Observation
import SwiftUI
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

enum MobileVaultRoute: Hashable {
    case history
}

/// Navigation and presentation state owned by one iOS/iPadOS scene.
///
/// App data remains shared through `MobileAppModel`. Focused commands operate on
/// this window's workspaces; workspace links activate their persistent native owner.
@MainActor
@Observable
final class MobileSceneModel {
    enum WorkspaceDestination: Hashable, Identifiable {
        case workspace(UUID)
        case transfers

        var id: Self { self }
    }

    enum WorkspaceSheet: String, Identifiable {
        case connectionPicker, batchStartup

        var id: Self { self }
    }

    let id = UUID()
    let agentForwarding = MobileAgentForwardingInteraction()
    let workspaceSession: MobileWorkspaceSessionModel
    let assistant: MobileAssistantSceneModel
    var selectedDestination: MobileDestination? = .vault {
        didSet {
            if selectedDestination != .workspaces { pendingWorkspaceID = nil }
            app.refreshCommandFocus()
        }
    }
    var workspaceDestination: WorkspaceDestination? { didSet { app.refreshCommandFocus() } }
    var workspaceSheet: WorkspaceSheet?

    var workspaceID: MobileWorkspace.ID? {
        get {
            guard case .workspace(let id) = workspaceDestination else { return nil }
            return id
        }
        set {
            if let newValue {
                workspaceDestination = .workspace(newValue)
            } else if case .workspace = workspaceDestination {
                workspaceDestination = nil
            }
        }
    }
    var isConnectionPickerPresented: Bool { workspaceSheet == .connectionPicker }
    var isBatchStartupPresented: Bool { workspaceSheet == .batchStartup }
    var isWorkspaceUnavailable = false
    var showsTransfers: Bool { workspaceDestination == .transfers }
    var pendingExternalConnection: RemoteConnectionURL?
    var editingHost: Host?
    var renamingWorkspace: MobileWorkspaceDescriptor?
    var assistantLibraryRoute: MobileAssistantLibraryRoute?
    private(set) var vaultNavigationID = UUID()
    var vaultNavigationPath = NavigationPath()
    var confirmsClearConnectionHistory = false

    var historyMenuSnapshot: ConnectionHistoryMenuSnapshot {
        ConnectionHistoryMenuSnapshot(history: app.connectionHistory, library: app.library)
    }
    var hasConnectionHistory: Bool { !app.connectionHistory.entries().isEmpty }

    func showConnectionHistory() {
        let historyPath = NavigationPath([MobileVaultRoute.history])
        if vaultNavigationPath != historyPath {
            // Also remove destination-based pushes that are not represented in the value path.
            vaultNavigationID = UUID()
            vaultNavigationPath = historyPath
        }
        selectedDestination = .vault
    }

    func clearConnectionHistory() {
        app.connectionHistory.clearAll()
        if let error = app.connectionHistory.storageError { app.error = error }
    }

    func reopenClosedWorkspace(_ id: MobileWorkspace.ID) {
        guard let id = workspaceSession.reopenClosedWorkspace(id) else { return }
        selectWorkspace(id)
    }

    @ObservationIgnored private let app: MobileAppModel
    @ObservationIgnored private var pendingWorkspaceID: MobileWorkspace.ID?
    @ObservationIgnored private var pendingBatchStartup:
        (hostIDs: [Host.ID], connectionProtocol: MobileConnectionProtocol)?
    private var recentWorkspaceIDs: [MobileWorkspace.ID] = []

    init(app: MobileAppModel, sessionID: String) {
        workspaceSession = app.workspaceSession(for: sessionID)
        self.app = app
        assistant = app.assistant.makeSceneModel()
        assistant.paneAccess = app.paneAccess(for: self)
        app.registerPaneScene(self)
        app.agentForwardingRouter.register(self)
    }

    var activeWorkspace: MobileWorkspace? {
        guard selectedDestination == .workspaces, let workspaceID else { return nil }
        return workspaceSession.workspaces.first { $0.id == workspaceID }
    }

    var hasWorkspaces: Bool { !workspaceSession.workspaces.isEmpty }
    var canCloseAllWorkspaces: Bool {
        !workspaceSession.savedWorkspaceDescriptors.isEmpty || !workspaceSession.workspaces.isEmpty
    }
    var canCloseMultipleWorkspaces: Bool { workspaceSession.closableWorkspaceCount > 1 }
    var workspaceCount: Int { workspaceSession.workspaces.count }
    var canCloseWorkspace: Bool { activeWorkspace != nil }
    var canUseTerminalCommands: Bool { activeWorkspace?.descriptor.kind.isSSHTerminal == true }

    func openSettings() {
        selectedDestination = .settings
    }

    func openTransfers() {
        pendingWorkspaceID = nil
        pendingBatchStartup = nil
        workspaceSheet = nil
        selectedDestination = .workspaces
        workspaceDestination = .transfers
    }

    func openConnectionPicker() {
        pendingBatchStartup = nil
        pendingWorkspaceID = nil
        selectedDestination = .workspaces
        workspaceDestination = nil
        workspaceSheet = .connectionPicker
    }

    func openBatchStartup() {
        pendingWorkspaceID = nil
        pendingBatchStartup = nil
        selectedDestination = .workspaces
        workspaceDestination = nil
        workspaceSheet = .batchStartup
    }

    func prepareBatchStartup(hostIDs: [Host.ID], connectionProtocol: MobileConnectionProtocol) {
        guard isBatchStartupPresented, pendingBatchStartup == nil, !hostIDs.isEmpty else { return }
        pendingBatchStartup = (hostIDs, connectionProtocol)
    }

    func completeBatchStartup() {
        guard let request = pendingBatchStartup else { return }
        if workspaceSheet == .batchStartup { workspaceSheet = nil }
        pendingBatchStartup = nil
        pendingWorkspaceID = nil
        selectedDestination = .workspaces
        workspaceID = nil
        workspaceSession.batchStartup(hostIDs: request.hostIDs, connectionProtocol: request.connectionProtocol)
    }

    func isShowingAssistant(_ id: UUID) -> Bool {
        selectedDestination == .assistant && assistantLibraryRoute == nil
            && assistant.library.selectedConversationID == id
    }

    var visibleAssistantConversationID: UUID? {
        guard let id = assistant.library.selectedConversationID, isShowingAssistant(id) else { return nil }
        return id
    }

    func openAssistantNotification(_ id: UUID) {
        assistantLibraryRoute = nil
        selectedDestination = .assistant
        if let conversation = assistant.library.conversation(id: id) {
            assistant.select(conversation)
        } else {
            assistantLibraryRoute = .conversations
        }
    }

    func openNewConversation() {
        assistant.newConversation()
        assistantLibraryRoute = nil
        selectedDestination = .assistant
    }

    func showAssistant() {
        selectedDestination = .assistant
    }

    func openNewHost() {
        selectedDestination = .vault
        editingHost = Host(name: "", host: "")
    }

    func open(hostID: Host.ID, kind: ConnectionHistoryEntry.Kind) {
        guard let id = workspaceSession.open(hostID: hostID, kind: kind) else { return }
        selectWorkspace(id)
    }

    @discardableResult
    func perform(_ quickAction: MobileHomeScreenQuickAction) -> Bool {
        switch quickAction {
        case .connect:
            openConnectionPicker()
            return true
        case .history(let hostID):
            guard let host = app.library.host(hostID),
                let kind = MobileConnectionHistory.preferredKind(for: host)
            else {
                selectedDestination = .workspaces
                workspaceID = nil
                isWorkspaceUnavailable = true
                return false
            }
            open(hostID: hostID, kind: kind)
            return true
        }
    }

    /// Reuses this scene's most recently selected preferred terminal workspace for the Host.
    /// Explicit connection actions continue to call `open(hostID:kind:)` so
    /// users can still create independent SSH and SFTP workspaces.
    func activateHost(_ hostID: Host.ID) {
        guard let host = app.library.host(hostID), let connectionProtocol = host.preferredTerminalProtocol else {
            return
        }
        let kind: ConnectionHistoryEntry.Kind = connectionProtocol == .ssh ? .ssh : .telnet
        guard let workspace = workspaceActivatedByHostRow(for: host) else {
            open(hostID: hostID, kind: kind)
            return
        }
        selectWorkspace(workspace.id)
    }

    /// The connection a Vault Host card will reopen in this window.
    func workspaceActivatedByHostRow(for host: Host) -> MobileWorkspace? {
        guard let connectionProtocol = host.preferredTerminalProtocol else { return nil }
        let kind: ConnectionHistoryEntry.Kind = connectionProtocol == .ssh ? .ssh : .telnet
        let matchingIDs = Set(
            workspaceSession.workspaces.lazy
                .filter { $0.descriptor.hostID == host.id && $0.descriptor.kind == kind }
                .map(\.id)
        )
        let workspaceID =
            recentWorkspaceIDs.first(where: matchingIDs.contains)
            ?? workspaceSession.workspaces.last(where: {
                $0.descriptor.hostID == host.id && $0.descriptor.kind == kind
            })?.id
        return workspaceID.flatMap { id in workspaceSession.workspaces.first { $0.id == id } }
    }

    func openSameDirectory(_ launch: MobileWorkspaceDirectoryLaunch) {
        guard let id = workspaceSession.open(hostID: launch.hostID, kind: launch.kind, initialPath: launch.path) else {
            return
        }
        selectWorkspace(id)
    }

    func execute(_ snippet: Snippet, on hostIDs: [Host.ID]) {
        guard let first = workspaceSession.execute(snippet, on: hostIDs).first else { return }
        selectWorkspace(first)
    }

    func selectWorkspace(_ id: MobileWorkspace.ID) {
        guard workspaceSession.openWorkspace(id) != nil else {
            pendingWorkspaceID = nil
            selectedDestination = .workspaces
            workspaceID = nil
            isWorkspaceUnavailable = true
            return
        }
        isWorkspaceUnavailable = false
        if selectedDestination != .workspaces {
            workspaceID = nil
            pendingWorkspaceID = id
            selectedDestination = .workspaces
            return
        }
        presentWorkspace(id)
    }

    func activatePendingWorkspace() {
        guard selectedDestination == .workspaces, let id = pendingWorkspaceID else { return }
        pendingWorkspaceID = nil
        presentWorkspace(id)
    }

    private func presentWorkspace(_ id: MobileWorkspace.ID) {
        guard workspaceSession.workspaces.contains(where: { $0.id == id }) else { return }
        pendingWorkspaceID = nil
        selectedDestination = .workspaces
        workspaceID = id
        recentWorkspaceIDs.removeAll { $0 == id }
        recentWorkspaceIDs.insert(id, at: 0)
        app.focusWorkspaceActivity(id)
    }

    func selectWorkspace(at index: Int) {
        guard workspaceSession.workspaces.indices.contains(index) else { return }
        selectWorkspace(workspaceSession.workspaces[index].id)
    }

    func selectNextWorkspace() {
        guard !workspaceSession.workspaces.isEmpty else { return }
        guard let activeWorkspace,
            let index = workspaceSession.workspaces.firstIndex(where: { $0.id == activeWorkspace.id })
        else {
            selectWorkspace(at: 0)
            return
        }
        selectWorkspace(at: (index + 1) % workspaceSession.workspaces.count)
    }

    func selectPreviousWorkspace() {
        guard !workspaceSession.workspaces.isEmpty else { return }
        guard let activeWorkspace,
            let index = workspaceSession.workspaces.firstIndex(where: { $0.id == activeWorkspace.id })
        else {
            selectWorkspace(at: workspaceSession.workspaces.count - 1)
            return
        }
        selectWorkspace(at: (index - 1 + workspaceSession.workspaces.count) % workspaceSession.workspaces.count)
    }

    func selectLastWorkspace() {
        guard !workspaceSession.workspaces.isEmpty else { return }
        selectWorkspace(at: workspaceSession.workspaces.count - 1)
    }

    func generateTerminalCommand() {
        guard let workspace = activeWorkspace, workspace.descriptor.kind.isSSHTerminal else { return }
        workspace.generateCommand(using: app.commandGenerator)
    }

    func presentTerminalFind() {
        guard let workspace = activeWorkspace, workspace.descriptor.kind.isSSHTerminal else { return }
        workspace.find.present()
    }

    func navigateTerminalFind(_ direction: TerminalFindDirection) {
        guard let workspace = activeWorkspace, workspace.descriptor.kind.isSSHTerminal else { return }
        workspace.find.presentAndNavigate(direction)
    }

    func beginWorkspaceRename(_ descriptor: MobileWorkspaceDescriptor) {
        guard workspaceSession.orderedWorkspaceItems.contains(where: { $0.id == descriptor.id }) else { return }
        renamingWorkspace = descriptor
    }

    func closeWorkspace(_ id: MobileWorkspace.ID) {
        workspaceSession.close(id)
        recentWorkspaceIDs.removeAll { $0 == id }
        if pendingWorkspaceID == id { pendingWorkspaceID = nil }
        if workspaceID == id { workspaceID = nil }
    }

    func closeActiveWorkspace() {
        guard let activeWorkspace else { return }
        closeWorkspace(activeWorkspace.id)
    }

    func reopenLastClosedWorkspace() {
        guard let id = workspaceSession.reopenLastClosed() else { return }
        selectWorkspace(id)
    }

    func closeSelectionOrWindow() {
        guard !workspaceSession.isDiscarded else { return }
        if activeWorkspace != nil {
            closeActiveWorkspace()
        } else {
            closeWindow()
        }
    }

    func closeWindow() {
        guard !workspaceSession.isDiscarded else { return }
        requestWindowClose(sessionID: workspaceSession.id)
    }

    func closeAllWindows(authorized: Bool = false) {
        guard !workspaceSession.isDiscarded else { return }
        let sessionIDs = app.openWorkspaceSessionIDs()
        if !authorized,
            app.deferPersistentClose(
                sessionIDs.flatMap { app.workspaceSession(for: $0).workspaces },
                action: { [weak self] in self?.closeAllWindows(authorized: true) })
        {
            return
        }
        for id in sessionIDs.sorted() where id != workspaceSession.id {
            requestWindowClose(sessionID: id, authorized: true)
        }
        if sessionIDs.contains(workspaceSession.id) {
            requestWindowClose(sessionID: workspaceSession.id, authorized: true)
        }
    }

    private func requestWindowClose(sessionID: String, authorized: Bool = false) {
        if !authorized,
            app.deferPersistentClose(
                app.workspaceSession(for: sessionID).workspaces,
                action: { [weak self] in
                    self?.requestWindowClose(sessionID: sessionID, authorized: true)
                })
        {
            return
        }
        // UIKit's discard callback owns cleanup; a rejected request must preserve this session.
        let logger = app.logging.makeLogger(label: "termind.window")
        app.closeWorkspaceSession(sessionID) { error in
            let error = error as NSError
            logger.warning(
                "Window close request failed",
                metadata: ["domain": .string(error.domain), "code": .stringConvertible(error.code)])
        }
    }

    func closeOtherWorkspaces(than id: MobileWorkspace.ID) {
        guard workspaceSession.orderedWorkspaceItems.contains(where: { $0.id == id }) else { return }
        workspaceSession.closeOtherWorkspaces(than: id)
        recentWorkspaceIDs.removeAll { $0 != id }
        if pendingWorkspaceID != id { pendingWorkspaceID = nil }
        if workspaceID != id { workspaceID = nil }
    }

    func closeAllWorkspaces() {
        workspaceSession.closeAll()
        recentWorkspaceIDs.removeAll()
        pendingWorkspaceID = nil
        workspaceID = nil
    }

    func reconcileWorkspaceIDs(_ workspaceIDs: [MobileWorkspace.ID]) {
        let existingIDs = Set(workspaceIDs)
        recentWorkspaceIDs.removeAll { !existingIDs.contains($0) }
        if let pendingWorkspaceID, !workspaceIDs.contains(pendingWorkspaceID) {
            self.pendingWorkspaceID = nil
        }
        guard let workspaceID, !workspaceIDs.contains(workspaceID) else { return }
        self.workspaceID = nil
    }

    func open(_ url: URL) {
        if let scheme = url.scheme?.lowercased(), ["ssh", "sftp", "telnet"].contains(scheme) {
            do {
                let request = try RemoteConnectionURLParser.parse(url)
                if request.kind == .telnet, request.advisoryPassword != nil {
                    pendingExternalConnection = request
                } else {
                    if let id = workspaceSession.openExternalConnection(request) { selectWorkspace(id) }
                }
            } catch {
                app.error = error.localizedDescription
            }
            return
        }
        if WorkspaceActivityAttributes.accepts(url) {
            isWorkspaceUnavailable = false
            pendingWorkspaceID = nil
            selectedDestination = .workspaces
            workspaceID = nil
            return
        }
        guard let sourceID = WorkspaceActivityAttributes.workspaceID(from: url) else {
            if url.scheme == "termind", url.host == "workspace" {
                pendingWorkspaceID = nil
                selectedDestination = .workspaces
                workspaceID = nil
                isWorkspaceUnavailable = true
            }
            return
        }
        isWorkspaceUnavailable = false
        let id =
            app.containsWorkspace(sourceID) ? sourceID : app.rebuildActivityWorkspace(from: url, into: workspaceSession)
        guard let id, let owner = app.workspaceOwner(id) else {
            pendingWorkspaceID = nil
            selectedDestination = .workspaces
            workspaceID = nil
            isWorkspaceUnavailable = true
            return
        }
        if owner != workspaceSession.id {
            app.activateWorkspaceSession(owner, id) { [weak self] in self?.isWorkspaceUnavailable = true }
            return
        }
        selectWorkspace(id)
        workspaceSession.workspaces.first(where: { $0.id == id })?.terminal.requestFocus()
    }

    func confirmExternalConnection() {
        guard let request = pendingExternalConnection else { return }
        pendingExternalConnection = nil
        if let id = workspaceSession.openExternalConnection(request) { selectWorkspace(id) }
    }
}
