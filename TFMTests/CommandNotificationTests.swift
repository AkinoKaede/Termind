import Foundation
import GhosttyTerminal
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@testable import Termind

@Suite @MainActor
struct CommandNotificationTests {
    @Test func appOwnsCommandNotificationsWithoutChangingThemeOrFontPrecedence() {
        let state = TerminalViewState(configSource: .none)
        let preferences = TerminalPreferences(
            darkCustomEnabled: true,
            darkCustomConfiguration: "notify-on-command-finish = always\nbackground = 010203")
        state.applyPreferences(preferences)
        #expect(state.controller.terminalConfiguration.rendered.contains("notify-on-command-finish = never"))
        #expect(!state.theme.dark.rendered.contains("notify-on-command-finish = always"))
        #expect(state.theme.dark.rendered.hasSuffix("background = 010203"))
    }

    @Test func ghosttyPublishesEveryCompletionAndPairsItsExitCode() async {
        let state = TerminalViewState(configSource: .none)
        let monitor = TerminalCommandMonitor()
        var preferences = CommandNotificationPreferences()
        preferences.mode = .always
        preferences.after = 0
        monitor.preferences = { preferences }
        var received: [TerminalCommandCompletion] = []
        monitor.alert = { completion, _ in received.append(completion) }
        monitor.beginConnection()
        let observation = TerminalCommandObservation(state: state, monitor: monitor)
        state.terminalDidFinishCommand(exitCode: 0, durationNanos: 1_000_000_000)
        state.terminalDidFinishCommand(exitCode: 7, durationNanos: 1_000_000_000)
        state.terminalDidFinishCommand(exitCode: nil, durationNanos: 1_000_000_000)
        for _ in 0..<100 where received.count < 3 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(received.map(\.exitCode) == [0, 7, nil])
        #expect(received.map(\.duration) == [1, 1, 1])
        withExtendedLifetime(observation) {}
    }

    @Test func workspaceFocusIncludesEveryPaneAndTargetsFollowMoves() throws {
        let host = Host(name: "Build", host: "test.invalid")
        let app = AppModel(hosts: HostLibraryModel(hosts: [host]))
        let window = WindowModel()
        let other = WindowModel()
        app.registerWindow(window)
        app.registerWindow(other)
        let first = Pane.sshSession(host: host)
        let second = Pane.sshSession(host: host)
        let workspace = Workspace(pane: first)
        workspace.splitFocusedPane(axis: .horizontal, with: second)
        window.open(workspace)
        let firstID = try #require(first.commandSessionID)
        let secondID = try #require(second.commandSessionID)
        #expect(workspace.focusedPane === second)
        #expect(app.isCommandWorkspaceFocused(firstID, windowIsFocused: { $0 === window }))
        #expect(app.isCommandWorkspaceFocused(secondID, windowIsFocused: { $0 === window }))
        #expect(!app.isCommandWorkspaceFocused(firstID, windowIsFocused: { _ in false }))
        window.selectVault()
        #expect(app.selectCommandNotificationTarget(firstID) === window)
        #expect(window.selectedWorkspace === workspace)
        #expect(workspace.focusedPane === first)
        window.selectVault()
        #expect(!app.isCommandWorkspaceFocused(firstID, windowIsFocused: { _ in true }))
        let monitor = try #require(first.commandMonitor)
        monitor.beginConnection()
        monitor.receiveOSC133(exitCode: 0, durationNanos: 0)
        #expect(workspace.hasUnreadCommandCompletion)
        let moved = try #require(window.takePaneForMove(first.id))
        other.open(moved)
        #expect(!workspace.hasUnreadCommandCompletion)
        #expect(moved.hasUnreadCommandCompletion)
        #expect(app.commandNotificationTarget(firstID)?.0 === other)
        other.selectVault()
        #expect(app.selectCommandNotificationTarget(firstID) === other)
        #expect(other.selectedWorkspace === moved)
        #expect(moved.focusedPane === first)
        moved.markCommandsRead()
        #expect(!moved.hasUnreadCommandCompletion)
        other.close(moved.id)
        #expect(app.commandNotificationTarget(firstID) == nil)
        #expect(app.selectCommandNotificationTarget(firstID) == nil)
        other.reopenLastClosed()
        #expect(app.commandNotificationTarget(firstID) == nil)
        #expect(first.commandSessionID != firstID)
    }

    @Test func ghosttyValuesAlreadyPublishedAreNotReplayedWhenObserving() async {
        let state = TerminalViewState(configSource: .none)
        state.terminalDidFinishCommand(exitCode: 0, durationNanos: 1)
        try? await Task.sleep(for: .milliseconds(30))
        let monitor = TerminalCommandMonitor()
        monitor.beginConnection()
        let observation = TerminalCommandObservation(state: state, monitor: monitor)
        #expect(!monitor.hasUnreadCompletion)
        monitor.endConnection()
        state.terminalDidFinishCommand(exitCode: 0, durationNanos: 1)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(!monitor.hasUnreadCompletion)
        withExtendedLifetime(observation) {}
    }
}
