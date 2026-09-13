import Foundation
import Observation
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
    var selectedDestination: MobileDestination? = .vault
    var workspaceID: MobileWorkspace.ID?
    var isConnectionPickerPresented = false
    var isWorkspaceUnavailable = false
    var editingHost: Host?
    var renamingWorkspace: MobileWorkspace?
    var assistantLibraryRoute: MobileAssistantLibraryRoute?

    @ObservationIgnored private let app: MobileAppModel

    init(app: MobileAppModel) {
        self.app = app
        assistant = app.assistant.makeSceneModel()
    }

    var selectedTab: MobileDestination {
        get {
            switch selectedDestination {
            case .workspaces, .assistant, .settings:
                selectedDestination ?? .vault
            case .vault, .metrics, nil: .vault
            }
        }
        set { selectedDestination = newValue }
    }

    var activeWorkspace: MobileWorkspace? {
        guard selectedDestination == .workspaces, let workspaceID else { return nil }
        return app.workspaces.first { $0.id == workspaceID }
    }

    var hasWorkspaces: Bool { !app.workspaces.isEmpty }
    var workspaceCount: Int { app.workspaces.count }
    var canCloseWorkspace: Bool { activeWorkspace != nil }
    var canUseTerminalCommands: Bool { activeWorkspace?.descriptor.kind == .ssh }

    func openSettings() {
        selectedDestination = .settings
    }

    func openConnectionPicker() {
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

    func openSameDirectory(_ launch: MobileWorkspaceDirectoryLaunch) {
        guard let id = app.open(hostID: launch.hostID, kind: launch.kind, initialPath: launch.path) else { return }
        selectWorkspace(id)
    }

    func execute(_ snippet: Snippet, on hostIDs: [Host.ID]) {
        guard let first = app.execute(snippet, on: hostIDs).first else { return }
        selectWorkspace(first)
    }

    func selectWorkspace(_ id: MobileWorkspace.ID) {
        guard app.workspaces.contains(where: { $0.id == id }) else { return }
        selectedDestination = .workspaces
        workspaceID = id
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
        if workspaceID == id { workspaceID = nil }
    }

    func closeActiveWorkspace() {
        guard let activeWorkspace else { return }
        closeWorkspace(activeWorkspace.id)
    }

    func closeAllWorkspaces() {
        app.closeAll()
        workspaceID = nil
    }

    func reconcileWorkspaceIDs(_ workspaceIDs: [MobileWorkspace.ID]) {
        guard let workspaceID, !workspaceIDs.contains(workspaceID) else { return }
        self.workspaceID = nil
    }

    func open(_ url: URL) {
        if WorkspaceActivityAttributes.accepts(url) {
            selectedDestination = .workspaces
            workspaceID = nil
            return
        }
        guard let id = WorkspaceActivityAttributes.workspaceID(from: url) else { return }
        guard let workspace = app.workspaces.first(where: { $0.id == id }) else {
            isWorkspaceUnavailable = true
            return
        }
        selectWorkspace(id)
        workspace.terminal.requestFocus()
    }
}
