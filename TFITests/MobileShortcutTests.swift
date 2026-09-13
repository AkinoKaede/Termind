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
        #expect(MobileShortcut.connect == KeyboardShortcut("t", modifiers: .command))
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
                MobileShortcut.connect,
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
        let scene = MobileSceneModel(app: app)

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
        let previousConversationID = app.assistant.conversation.id
        scene.openNewConversation()
        #expect(scene.selectedDestination == .assistant)
        #expect(scene.assistantLibraryRoute == nil)
        #expect(app.assistant.conversation.id != previousConversationID)
    }

    @Test func workspaceCommandsSelectByIndexAndWrapInBothDirections() throws {
        let app = try MobileAppModel(inMemory: true)
        let host = Host(name: "Test", host: "example.invalid")
        app.library.upsert(host)
        let first = try #require(app.open(hostID: host.id, kind: .ssh))
        let second = try #require(app.open(hostID: host.id, kind: .sftp))
        let third = try #require(app.open(hostID: host.id, kind: .ssh))
        defer { app.closeAll() }
        let scene = MobileSceneModel(app: app)

        scene.openSettings()
        scene.selectNextWorkspace()
        #expect(scene.workspaceID == first)
        #expect(scene.selectedDestination == .workspaces)

        scene.openSettings()
        scene.selectPreviousWorkspace()
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

    @Test func closeCommandOnlyClosesAWorkspaceVisibleInThisScene() throws {
        let app = try MobileAppModel(inMemory: true)
        let host = Host(name: "Test", host: "example.invalid")
        app.library.upsert(host)
        let first = try #require(app.open(hostID: host.id, kind: .ssh))
        let second = try #require(app.open(hostID: host.id, kind: .sftp))
        defer { app.closeAll() }
        let scene = MobileSceneModel(app: app)
        let otherScene = MobileSceneModel(app: app)
        otherScene.selectWorkspace(second)

        scene.selectWorkspace(first)
        #expect(scene.canCloseWorkspace)
        scene.openSettings()
        #expect(!scene.canCloseWorkspace)
        scene.closeActiveWorkspace()
        #expect(app.workspaces.map(\.id) == [first, second])

        scene.selectWorkspace(first)
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
