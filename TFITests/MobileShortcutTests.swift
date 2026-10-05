import SwiftUI
import TermindApplication
import TermindDomain
import Testing
import UIKit

import struct TermindDomain.Host

@testable import TermindIOS

@Suite @MainActor
struct MobileShortcutTests {
    @Test func shortcutMapMatchesDesktopAndHasNoDuplicates() {
        #expect(MobileShortcut.settings == KeyboardShortcut(",", modifiers: .command))
        #expect(MobileShortcut.newWindow == KeyboardShortcut("n", modifiers: .command))
        #expect(MobileShortcut.connect == KeyboardShortcut("t", modifiers: .command))
        #expect(MobileShortcut.batchStartup == KeyboardShortcut("b", modifiers: [.command, .shift]))
        #expect(MobileShortcut.newChat == KeyboardShortcut("t", modifiers: [.command, .option]))
        #expect(MobileShortcut.newHost == KeyboardShortcut("n", modifiers: [.command, .shift]))
        #expect(MobileShortcut.generateCommand == KeyboardShortcut("i", modifiers: .command))
        #expect(MobileShortcut.find == KeyboardShortcut("f", modifiers: .command))
        #expect(MobileShortcut.findNext == KeyboardShortcut("g", modifiers: .command))
        #expect(MobileShortcut.findPrevious == KeyboardShortcut("g", modifiers: [.command, .shift]))
        #expect(MobileShortcut.closeWorkspace == KeyboardShortcut("w", modifiers: .command))
        #expect(MobileShortcut.nextWorkspace == KeyboardShortcut("]", modifiers: [.command, .shift]))
        #expect(MobileShortcut.previousWorkspace == KeyboardShortcut("[", modifiers: [.command, .shift]))
        #expect(MobileShortcut.send == KeyboardShortcut(.return, modifiers: .command))
        #expect(MobileShortcut.stop == KeyboardShortcut(".", modifiers: .command))
        #expect(MobileShortcut.formDefault == KeyboardShortcut(.return, modifiers: []))
        #expect(MobileShortcut.formCancel == KeyboardShortcut(.escape, modifiers: []))

        let shortcuts =
            [
                MobileShortcut.settings,
                MobileShortcut.newWindow,
                MobileShortcut.connect,
                MobileShortcut.batchStartup,
                MobileShortcut.newChat,
                MobileShortcut.newHost,
                MobileShortcut.generateCommand,
                MobileShortcut.find,
                MobileShortcut.findNext,
                MobileShortcut.findPrevious,
                MobileShortcut.closeWorkspace,
                MobileShortcut.nextWorkspace,
                MobileShortcut.previousWorkspace,
                MobileShortcut.send,
                MobileShortcut.stop,
                MobileShortcut.formDefault,
                MobileShortcut.formCancel,
            ] + (1...9).map(MobileShortcut.workspace)
        #expect(Set(shortcuts).count == shortcuts.count)
    }

    @Test func sceneCommandsNavigateToTheirMobileDestinations() throws {
        let app = try MobileAppModel(inMemory: true)
        let scene = MobileSceneModel(app: app, sessionID: "test")

        scene.openSettings()
        #expect(scene.selectedDestination == .settings)

        scene.openConnectionPicker()
        #expect(scene.selectedDestination == .workspaces)
        #expect(scene.workspaceID == nil)
        #expect(scene.isConnectionPickerPresented)

        scene.openNewHost()
        #expect(scene.selectedDestination == .vault)
        #expect(scene.editingHost != nil)

        scene.assistantLibraryRoute = .archived
        let previousConversationID = scene.assistant.conversation.id
        scene.openNewConversation()
        #expect(scene.selectedDestination == .assistant)
        #expect(scene.assistantLibraryRoute == nil)
        #expect(scene.assistant.conversation.id != previousConversationID)
    }

    @Test func homeScreenConnectActionUsesTheWorkspaceConnectionPicker() throws {
        let app = try MobileAppModel(inMemory: true)
        let scene = MobileSceneModel(app: app, sessionID: "test")

        #expect(scene.perform(.connect))
        #expect(scene.selectedDestination == .workspaces)
        #expect(scene.workspaceID == nil)
        #expect(scene.isConnectionPickerPresented)
    }

    @Test func batchStartupCommandPresentsThePickerOnlyInItsScene() throws {
        let app = try MobileAppModel(inMemory: true)
        let scene = MobileSceneModel(app: app, sessionID: "first")
        let otherScene = MobileSceneModel(app: app, sessionID: "second")
        scene.openTransfers()
        otherScene.openConnectionPicker()

        scene.openBatchStartup()

        #expect(scene.selectedDestination == .workspaces)
        #expect(scene.workspaceDestination == nil)
        #expect(scene.workspaceSheet == .batchStartup)
        #expect(otherScene.selectedDestination == .workspaces)
        #expect(otherScene.workspaceSheet == .connectionPicker)
        #expect(app.workspaces.isEmpty)
    }

    @Test func homeScreenHistoryActionOpensThePreferredTerminalAndReportsAMissingHost() throws {
        let app = try MobileAppModel(inMemory: true)
        let host = Host(name: "Files", host: "files.example.invalid")
        app.library.upsert(host)
        let scene = MobileSceneModel(app: app, sessionID: "test")
        defer { app.testWorkspaceSession.closeAll() }

        #expect(scene.perform(.history(hostID: host.id)))
        scene.activatePendingWorkspace()
        #expect(scene.activeWorkspace?.descriptor.hostID == host.id)
        #expect(scene.activeWorkspace?.descriptor.kind == .ssh)
        #expect(app.connectionHistory.entries(for: host.id).map(\.kind) == [.ssh])

        let historyCount = app.connectionHistory.entries().count
        #expect(!scene.perform(.history(hostID: UUID())))
        #expect(scene.isWorkspaceUnavailable)
        #expect(app.connectionHistory.entries().count == historyCount)
    }

    @Test func hostCardActivationReusesOnlyTheScenesMostRecentSSHWorkspace() throws {
        let app = try MobileAppModel(inMemory: true)
        let host = Host(name: "Test", host: "example.invalid")
        app.library.upsert(host)
        let firstScene = MobileSceneModel(app: app, sessionID: "first")
        let secondScene = MobileSceneModel(app: app, sessionID: "second")
        defer {
            firstScene.closeAllWorkspaces()
            secondScene.closeAllWorkspaces()
        }
        firstScene.open(hostID: host.id, kind: .ssh)
        firstScene.activatePendingWorkspace()
        let first = firstScene.workspaceID
        firstScene.open(hostID: host.id, kind: .ssh)
        let mostRecent = firstScene.workspaceID
        secondScene.activateHost(host.id)
        secondScene.activatePendingWorkspace()
        let second = secondScene.workspaceID
        #expect(second != first && second != mostRecent)

        firstScene.openSettings()
        firstScene.activateHost(host.id)
        firstScene.activatePendingWorkspace()
        secondScene.openSettings()
        secondScene.activateHost(host.id)
        secondScene.activatePendingWorkspace()
        #expect(firstScene.workspaceID == mostRecent)
        #expect(secondScene.workspaceID == second)
        #expect(app.workspaces.count == 3)
    }

    @Test func hostCardActivationFallsBackToTheNewestMatchingSSHWorkspace() throws {
        let app = try MobileAppModel(inMemory: true)
        let host = Host(name: "Test", host: "example.invalid")
        app.library.upsert(host)
        _ = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .ssh))
        let newestSSH = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .ssh))
        _ = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .sftp))
        defer { app.testWorkspaceSession.closeAll() }
        let scene = MobileSceneModel(app: app, sessionID: "test")

        scene.activateHost(host.id)
        scene.activatePendingWorkspace()

        #expect(scene.workspaceID == newestSSH)
        #expect(app.workspaces.count == 3)
    }

    @Test func hostCardActivationCreatesSSHWhenOnlySFTPExists() throws {
        let app = try MobileAppModel(inMemory: true)
        let host = Host(name: "Test", host: "example.invalid")
        app.library.upsert(host)
        let sftp = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .sftp))
        defer { app.testWorkspaceSession.closeAll() }
        let scene = MobileSceneModel(app: app, sessionID: "test")

        scene.activateHost(host.id)
        scene.activatePendingWorkspace()

        #expect(app.workspaces.count == 2)
        #expect(scene.workspaceID != sftp)
        #expect(scene.activeWorkspace?.descriptor.hostID == host.id)
        #expect(scene.activeWorkspace?.descriptor.kind == .ssh)
    }

    @Test func hostCardActivationForgetsAClosedRecentWorkspace() throws {
        let app = try MobileAppModel(inMemory: true)
        let host = Host(name: "Test", host: "example.invalid")
        app.library.upsert(host)
        let first = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .ssh))
        let second = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .ssh))
        defer { app.testWorkspaceSession.closeAll() }
        let scene = MobileSceneModel(app: app, sessionID: "test")
        scene.selectWorkspace(first)
        scene.activatePendingWorkspace()
        scene.selectWorkspace(second)

        scene.closeWorkspace(second)
        scene.activateHost(host.id)

        #expect(scene.workspaceID == first)
        #expect(app.workspaces.map(\.id) == [first])
    }

    @Test func workspaceCommandsSelectByIndexAndWrapInBothDirections() throws {
        let app = try MobileAppModel(inMemory: true)
        let host = Host(name: "Test", host: "example.invalid")
        app.library.upsert(host)
        let first = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .ssh))
        let second = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .sftp))
        let third = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .ssh))
        defer { app.testWorkspaceSession.closeAll() }
        let scene = MobileSceneModel(app: app, sessionID: "test")

        scene.openSettings()
        scene.selectNextWorkspace()
        #expect(scene.workspaceID == nil)
        scene.activatePendingWorkspace()
        #expect(scene.workspaceID == first)
        #expect(scene.selectedDestination == .workspaces)

        scene.openSettings()
        scene.selectPreviousWorkspace()
        scene.activatePendingWorkspace()
        #expect(scene.workspaceID == third)

        scene.selectNextWorkspace()
        #expect(scene.workspaceID == first)

        scene.selectWorkspace(at: 1)
        #expect(scene.workspaceID == second)
        #expect(!scene.canUseTerminalCommands)

        scene.selectLastWorkspace()
        #expect(scene.workspaceID == third)
        #expect(scene.canUseTerminalCommands)
        scene.presentTerminalFind()
        #expect(scene.activeWorkspace?.find.isPresented == true)
        scene.activeWorkspace?.find.dismiss()

        scene.selectWorkspace(at: 99)
        #expect(scene.workspaceID == third)
    }

    @Test func closeCommandClosesTheLastWorkspaceBeforeRequestingWindowClosure() throws {
        var requestedSessions: [String] = []
        var dependencies = MobileAppDependencies.testing()
        dependencies.closeWorkspaceSession = { id, _ in requestedSessions.append(id) }
        let app = try MobileAppModel(dependencies: dependencies)
        let host = Host(name: "Test", host: "example.invalid")
        app.library.upsert(host)
        let scene = MobileSceneModel(app: app, sessionID: "owner")
        let other = MobileSceneModel(app: app, sessionID: "other")
        defer { app.discardWorkspaceSessions(["owner", "other"]) }
        let first = try #require(scene.workspaceSession.open(hostID: host.id, kind: .ssh))
        let second = try #require(other.workspaceSession.open(hostID: host.id, kind: .sftp))
        scene.selectWorkspace(first)
        scene.activatePendingWorkspace()
        other.selectWorkspace(second)
        other.activatePendingWorkspace()

        scene.closeSelectionOrWindow()

        #expect(scene.workspaceSession.orderedWorkspaceItems.isEmpty)
        #expect(scene.workspaceID == nil)
        #expect(requestedSessions.isEmpty)
        #expect(other.activeWorkspace?.id == second)

        scene.closeSelectionOrWindow()

        #expect(requestedSessions == ["owner"])
        #expect(other.activeWorkspace?.id == second)
    }

    @Test(arguments: MobileDestination.allCases)
    func closeCommandWithoutSelectionRequestsOnlyItsOwnWindow(destination: MobileDestination) throws {
        let app = try MobileAppModel(inMemory: true)
        let scene = MobileSceneModel(app: app, sessionID: "owner")
        let other = MobileSceneModel(app: app, sessionID: "other")
        defer { app.discardWorkspaceSessions(["owner", "other"]) }
        var requestedSessions: [String] = []
        app.closeWorkspaceSession = { id, _ in requestedSessions.append(id) }
        scene.selectedDestination = destination

        scene.closeSelectionOrWindow()

        #expect(requestedSessions == [scene.workspaceSession.id])
        #expect(!other.workspaceSession.isDiscarded)
        #expect(app.error == nil)
        #expect(!scene.isWorkspaceUnavailable)
    }

    @Test func closeCommandOnlyClosesAWorkspaceVisibleInThisScene() throws {
        let app = try MobileAppModel(inMemory: true)
        let host = Host(name: "Test", host: "example.invalid")
        app.library.upsert(host)
        let first = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .ssh))
        let second = try #require(app.workspaceSession(for: "other").open(hostID: host.id, kind: .sftp))
        defer { app.discardWorkspaceSessions(["test", "other"]) }
        let scene = MobileSceneModel(app: app, sessionID: "test")
        let otherScene = MobileSceneModel(app: app, sessionID: "other")
        otherScene.selectWorkspace(second)
        otherScene.activatePendingWorkspace()

        scene.selectWorkspace(first)
        scene.activatePendingWorkspace()
        #expect(scene.canCloseWorkspace)
        scene.openSettings()
        #expect(!scene.canCloseWorkspace)
        scene.closeActiveWorkspace()
        #expect(app.workspaces.map(\.id) == [first, second])

        scene.selectWorkspace(first)
        scene.activatePendingWorkspace()
        scene.closeActiveWorkspace()
        #expect(app.workspaces.map(\.id) == [second])
        #expect(scene.workspaceID == nil)
        #expect(otherScene.workspaceID == second)
        #expect(otherScene.activeWorkspace?.id == second)
    }

    @Test func terminalFunctionKeysFollowDesktopFindDirection() throws {
        var actions: [String] = []
        let find = TerminalFindController(perform: { actions.append($0) }, focus: {})
        let view = MobileTerminalView(frame: .zero)
        view.findController = find
        find.updateQuery("needle")
        actions.removeAll()

        let next = try keyCommand(in: view, input: UIKeyCommand.f3, modifiers: [])
        #expect(UIApplication.shared.sendAction(try #require(next.action), to: view, from: next, for: nil))
        #expect(
            actions == [
                TerminalFindBinding.search("needle"),
                TerminalFindBinding.navigate(.previous),
            ])

        actions.removeAll()
        let previous = try keyCommand(in: view, input: UIKeyCommand.f3, modifiers: .shift)
        #expect(UIApplication.shared.sendAction(try #require(previous.action), to: view, from: previous, for: nil))
        #expect(actions == [TerminalFindBinding.navigate(.next)])
    }

    @Test func terminalEscapeReturnsToGhosttyUnlessFindIsPresented() throws {
        var actions: [String] = []
        var focusCount = 0
        let find = TerminalFindController(
            perform: { actions.append($0) },
            focus: { focusCount += 1 }
        )
        let view = MobileTerminalView(frame: .zero)
        view.findController = find

        let terminalEscape = try keyCommand(in: view, input: UIKeyCommand.inputEscape, modifiers: [])
        #expect(!NSStringFromSelector(try #require(terminalEscape.action)).contains("handleDismissFindCommand"))

        find.present()
        let dismiss = try keyCommand(in: view, input: UIKeyCommand.inputEscape, modifiers: [])
        #expect(NSStringFromSelector(try #require(dismiss.action)).contains("handleDismissFindCommand"))
        #expect(UIApplication.shared.sendAction(try #require(dismiss.action), to: view, from: dismiss, for: nil))
        #expect(!find.isPresented)
        #expect(actions == [TerminalFindBinding.end])
        #expect(focusCount == 1)

        let shifted = try keyCommand(in: view, input: UIKeyCommand.inputEscape, modifiers: .shift)
        #expect(!NSStringFromSelector(try #require(shifted.action)).contains("handleDismissFindCommand"))
    }

    private func keyCommand(
        in view: MobileTerminalView,
        input: String,
        modifiers: UIKeyModifierFlags
    ) throws -> UIKeyCommand {
        try #require(
            view.keyCommands?.first {
                $0.input == input
                    && $0.modifierFlags.intersection([.command, .control, .alternate, .shift]) == modifiers
            }
        )
    }
}
