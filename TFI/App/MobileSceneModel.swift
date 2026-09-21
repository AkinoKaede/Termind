import Foundation
import Observation
import SwiftUI
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

/// Navigation and presentation state owned by one iOS/iPadOS scene.
///
/// App data remains shared through `MobileAppModel`, while commands and deep
/// links act only on the scene that published this model as its focused value.
@MainActor
@Observable
final class MobileSceneModel {
    let id = UUID()
    let assistant: MobileAssistantSceneModel
    var selectedDestination: MobileDestination? = .vault {
        didSet {
            if selectedDestination != .workspaces { pendingWorkspaceID = nil }
        }
    }
    var workspaceID: MobileWorkspace.ID?
    var isConnectionPickerPresented = false
    var isWorkspaceUnavailable = false
    var pendingExternalConnection: RemoteConnectionURL?
    var editingHost: Host?
    var renamingWorkspace: MobileWorkspace?
    var assistantLibraryRoute: MobileAssistantLibraryRoute?
    private(set) var reviewPageID: String?

    @ObservationIgnored private let app: MobileAppModel
    @ObservationIgnored private var pendingWorkspaceID: MobileWorkspace.ID?
    @ObservationIgnored private var recentWorkspaceIDs: [MobileWorkspace.ID] = []

    init(app: MobileAppModel) {
        self.app = app
        assistant = app.assistant.makeSceneModel()
    }

    var activeWorkspace: MobileWorkspace? {
        guard selectedDestination == .workspaces, let workspaceID else { return nil }
        return app.workspaces.first { $0.id == workspaceID }
    }

    var hasWorkspaces: Bool { !app.workspaces.isEmpty }
    var canCloseAllWorkspaces: Bool { !app.savedWorkspaceDescriptors.isEmpty || !app.workspaces.isEmpty }
    var canCloseMultipleWorkspaces: Bool { app.closableWorkspaceCount > 1 }
    var workspaceCount: Int { app.workspaces.count }
    var canCloseWorkspace: Bool { activeWorkspace != nil }
    var canUseTerminalCommands: Bool { activeWorkspace?.descriptor.kind == .ssh }

    func openSettings() {
        selectedDestination = .settings
    }

    func enterReviewPage(_ id: String) {
        reviewPageID = id
    }

    func leaveReviewPage(_ id: String) {
        if reviewPageID == id { reviewPageID = nil }
    }

    func openConnectionPicker() {
        pendingWorkspaceID = nil
        selectedDestination = .workspaces
        workspaceID = nil
        isConnectionPickerPresented = true
    }

    func openNewConversation() {
        assistant.newConversation()
        assistantLibraryRoute = nil
        selectedDestination = .assistant
    }

    func openNewHost() {
        selectedDestination = .vault
        editingHost = Host(name: "", host: "")
    }

    func open(hostID: Host.ID, kind: ConnectionHistoryEntry.Kind) {
        guard let id = app.open(hostID: hostID, kind: kind) else { return }
        selectWorkspace(id)
    }

    @discardableResult
    func perform(_ quickAction: MobileHomeScreenQuickAction) -> Bool {
        switch quickAction {
        case .connect:
            openConnectionPicker()
            return true
        case .history(let hostID, let kind):
            guard app.library.host(hostID) != nil else {
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
        let matchingIDs = Set(
            app.workspaces.lazy
                .filter { $0.descriptor.hostID == hostID && $0.descriptor.kind == kind }
                .map(\.id)
        )
        let workspaceID =
            recentWorkspaceIDs.first(where: matchingIDs.contains)
            ?? app.workspaces.last(where: {
                $0.descriptor.hostID == hostID && $0.descriptor.kind == kind
            })?.id
        guard let workspaceID else {
            open(hostID: hostID, kind: kind)
            return
        }
        selectWorkspace(workspaceID)
    }

    func openSameDirectory(_ launch: MobileWorkspaceDirectoryLaunch) {
        guard let id = app.open(hostID: launch.hostID, kind: launch.kind, initialPath: launch.path) else { return }
        selectWorkspace(id)
    }

    func execute(_ snippet: Snippet, on hostIDs: [Host.ID]) {
        guard let first = app.execute(snippet, on: hostIDs).first else { return }
        selectWorkspace(first)
    }

    func selectWorkspace(_ id: MobileWorkspace.ID) {
        guard app.openWorkspace(id) != nil else {
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
        guard app.workspaces.contains(where: { $0.id == id }) else { return }
        pendingWorkspaceID = nil
        selectedDestination = .workspaces
        workspaceID = id
        recentWorkspaceIDs.removeAll { $0 == id }
        recentWorkspaceIDs.insert(id, at: 0)
        app.focusWorkspaceActivity(id)
    }

    func selectWorkspace(at index: Int) {
        guard app.workspaces.indices.contains(index) else { return }
        selectWorkspace(app.workspaces[index].id)
    }

    func selectNextWorkspace() {
        guard !app.workspaces.isEmpty else { return }
        guard let activeWorkspace,
            let index = app.workspaces.firstIndex(where: { $0.id == activeWorkspace.id })
        else {
            selectWorkspace(at: 0)
            return
        }
        selectWorkspace(at: (index + 1) % app.workspaces.count)
    }

    func selectPreviousWorkspace() {
        guard !app.workspaces.isEmpty else { return }
        guard let activeWorkspace,
            let index = app.workspaces.firstIndex(where: { $0.id == activeWorkspace.id })
        else {
            selectWorkspace(at: app.workspaces.count - 1)
            return
        }
        selectWorkspace(at: (index - 1 + app.workspaces.count) % app.workspaces.count)
    }

    func selectLastWorkspace() {
        guard !app.workspaces.isEmpty else { return }
        selectWorkspace(at: app.workspaces.count - 1)
    }

    func generateTerminalCommand() {
        guard let workspace = activeWorkspace, workspace.descriptor.kind == .ssh else { return }
        workspace.generateCommand(using: app.commandGenerator)
    }

    func presentTerminalFind() {
        guard let workspace = activeWorkspace, workspace.descriptor.kind == .ssh else { return }
        workspace.find.present()
    }

    func navigateTerminalFind(_ direction: TerminalFindDirection) {
        guard let workspace = activeWorkspace, workspace.descriptor.kind == .ssh else { return }
        workspace.find.presentAndNavigate(direction)
    }

    func beginWorkspaceRename(_ workspace: MobileWorkspace) {
        renamingWorkspace = workspace
    }

    func closeWorkspace(_ id: MobileWorkspace.ID) {
        app.close(id)
        recentWorkspaceIDs.removeAll { $0 == id }
        if pendingWorkspaceID == id { pendingWorkspaceID = nil }
        if workspaceID == id { workspaceID = nil }
    }

    func closeActiveWorkspace() {
        guard let activeWorkspace else { return }
        closeWorkspace(activeWorkspace.id)
    }

    func closeOtherWorkspaces(than id: MobileWorkspace.ID) {
        app.closeOtherWorkspaces(than: id)
        recentWorkspaceIDs.removeAll { $0 != id }
        if pendingWorkspaceID != id { pendingWorkspaceID = nil }
        if workspaceID != id { workspaceID = nil }
    }

    func closeAllWorkspaces() {
        app.closeAll()
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
                    selectWorkspace(app.openExternalConnection(request))
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
        guard let id = WorkspaceActivityAttributes.workspaceID(from: url) else { return }
        selectWorkspace(id)
        app.workspaces.first(where: { $0.id == id })?.terminal.requestFocus()
    }

    func confirmExternalConnection() {
        guard let request = pendingExternalConnection else { return }
        pendingExternalConnection = nil
        selectWorkspace(app.openExternalConnection(request))
    }
}
