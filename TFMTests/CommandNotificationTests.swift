import Foundation
import GhosttyTerminal
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@testable import Termind

@Suite @MainActor
struct CommandNotificationTests {
    @Test(arguments: ["hidden", "navigation", "snippets", "history", "peer", "archive", "visible"])
    func assistantNotificationOpensSidebarWithoutReplacingWorkspace(_ state: String) throws {
        let app = AppModel(hosts: HostLibraryModel())
        let window = WindowModel()
        app.registerWindow(window)
        let conversation = ConversationModel()
        conversation.composer.draft = "Target"
        _ = try #require(window.assistantLibrary.startConversation(conversation))
        let workspace = Workspace(pane: Pane(.empty))
        workspace.splitFocusedPane(axis: .horizontal, with: Pane(.empty))
        window.open(workspace)
        let focusedPane = workspace.focusedPane
        window.showAssistant()
        switch state {
        case "hidden": window.showsSidebar = false
        case "navigation": window.sidebarMode = .navigation
        case "snippets": window.sidebarMode = .snippets
        case "history": window.sidebarMode = .history
        case "peer":
            let peer = ConversationModel()
            peer.composer.draft = "Other conversation"
            _ = try #require(window.assistantLibrary.startConversation(peer))
        case "archive": window.showAssistantArchiveInSidebar()
        default: break
        }
        #expect(window.isShowingAssistant(conversation.id) == (state == "visible"))
        #expect(app.isAssistantNotificationFocused(conversation.id) == (state == "visible"))
        window.isQuickOpenPresented = true

        #expect(app.selectAssistantNotificationTarget(conversation.id) === window)

        #expect(window.selectedWorkspace === workspace)
        #expect(workspace.focusedPane === focusedPane)
        #expect(window.showsSidebar && window.sidebarMode == .assistant)
        #expect(window.isShowingAssistant(conversation.id))
        #expect(!window.isAssistantArchivePresented)
        #expect(!window.isQuickOpenPresented && !window.isToolbarFindFocused)
    }

    @Test(arguments: [true, false])
    func assistantNotificationPrefersFocusThenStableOrderWithinMatchingWindows(_ visible: Bool) throws {
        let app = AppModel(hosts: HostLibraryModel())
        let windows = [WindowModel(), WindowModel()].sorted { $0.id.uuidString < $1.id.uuidString }
        for window in windows { app.registerWindow(window) }
        let conversation = ConversationModel()
        conversation.composer.draft = "Target"
        _ = try #require(windows[0].assistantLibrary.startConversation(conversation))
        for window in windows {
            window.openAssistantFullScreen(conversation.id)
            if !visible { window.selectVault() }
        }

        #expect(
            app.selectAssistantNotificationTarget(conversation.id, windowIsFocused: { $0 === windows[1] })
                === windows[1])
        if !visible { windows[1].selectVault() }
        #expect(app.selectAssistantNotificationTarget(conversation.id, windowIsFocused: { _ in false }) === windows[0])

        windows[0].closeForWindow()
        #expect(app.selectAssistantNotificationTarget(conversation.id) === windows[1])
    }

    @Test func assistantNotificationReusesHiddenSelectionBeforeAnUnrelatedFocusedWindow() throws {
        let app = AppModel(hosts: HostLibraryModel())
        let owner = WindowModel()
        let other = WindowModel()
        app.registerWindow(owner)
        app.registerWindow(other)
        let conversation = ConversationModel()
        conversation.composer.draft = "Target"
        _ = try #require(owner.assistantLibrary.startConversation(conversation))
        owner.openAssistantFullScreen(conversation.id)
        let workspace = Workspace(pane: Pane(.empty))
        owner.open(workspace)
        owner.showsSidebar = false
        #expect(!app.isAssistantNotificationFocused(conversation.id))

        #expect(app.selectAssistantNotificationTarget(conversation.id, windowIsFocused: { $0 === other }) === owner)
        #expect(owner.selectedWorkspace === workspace)
        #expect(owner.isShowingAssistant(conversation.id))
        #expect(other.assistantLibrary.selectedConversationID == nil)

        other.openAssistantFullScreen(conversation.id)
        owner.showsSidebar = false
        #expect(app.selectAssistantNotificationTarget(conversation.id, windowIsFocused: { $0 === owner }) === other)
        #expect(!owner.showsSidebar)
    }

    @Test func notificationRouterUsesTheLatestClickAndConsumesItOnce() async throws {
        let app = AppModel(hosts: HostLibraryModel())
        let window = WindowModel()
        app.registerWindow(window)
        let first = ConversationModel()
        let second = ConversationModel()
        first.composer.draft = "First"
        second.composer.draft = "Second"
        _ = try #require(window.assistantLibrary.startConversation(first))
        _ = try #require(window.assistantLibrary.startConversation(second))
        let activations = AsyncStream<Void>.makeStream()
        var count = 0
        let router = DesktopNotificationRouter(app: app) { _ in
            count += 1
            activations.continuation.yield(())
        }
        router.open(.assistant(first.id))
        router.open(.assistant(second.id))
        var iterator = activations.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(window.assistantLibrary.selectedConversationID == second.id)
        router.resume()
        #expect(count == 1)
        router.stop()
        router.open(.assistant(first.id))
        router.resume()
        #expect(window.assistantLibrary.selectedConversationID == second.id)
    }

    @Test func manuallyUnreadWorkspacesCountOnceWithoutRequiringATerminal() {
        let app = AppModel(hosts: HostLibraryModel())
        let window = WindowModel()
        app.registerWindow(window)
        let workspace = Workspace(pane: Pane(.empty))
        window.open(workspace, select: false)
        workspace.markCommandsUnread()
        workspace.markCommandsUnread()
        #expect(workspace.hasUnreadCommandCompletion)
        #expect(window.unreadCompletionCount == 1)
        #expect(app.unreadNotificationCount == 1)
        workspace.markCommandsRead()
        #expect(app.unreadNotificationCount == 0)
        #expect(!Workspace(pane: Pane(.empty)).hasUnreadCommandCompletion)
    }

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
        var preferences = NotificationPreferences()
        preferences.isEnabled = true
        preferences.terminalMode = .always
        preferences.terminalMinimumSeconds = 0
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
        #expect(window.unreadCompletionCount == 1)
        #expect(other.unreadCompletionCount == 0)
        let moved = try #require(window.takePaneForMove(first.id))
        other.open(moved)
        #expect(!workspace.hasUnreadCommandCompletion)
        #expect(moved.hasUnreadCommandCompletion)
        #expect(window.unreadCompletionCount == 0)
        #expect(other.unreadCompletionCount == 1)
        #expect(app.commandNotificationTarget(firstID)?.0 === other)
        other.selectVault()
        #expect(app.selectCommandNotificationTarget(firstID) === other)
        #expect(other.selectedWorkspace === moved)
        #expect(moved.focusedPane === first)
        moved.markCommandsRead()
        #expect(!moved.hasUnreadCommandCompletion)
        #expect(other.unreadCompletionCount == 0)
        other.close(moved.id)
        #expect(app.commandNotificationTarget(firstID) == nil)
        #expect(app.selectCommandNotificationTarget(firstID) == nil)
        other.reopenLastClosed()
        #expect(app.commandNotificationTarget(firstID) == nil)
        #expect(first.commandSessionID != firstID)
    }

    @Test func assistantFocusIncludesVisibleSidebarAndNotificationTargetsReuseTheConversation() throws {
        let app = AppModel(hosts: HostLibraryModel())
        let window = WindowModel()
        let other = WindowModel()
        app.registerWindow(window)
        app.registerWindow(other)
        let conversation = ConversationModel()
        conversation.composer.draft = "Test"
        _ = try #require(window.assistantLibrary.startConversation(conversation))
        window.openAssistantFullScreen(conversation.id)
        #expect(app.isAssistantNotificationFocused(conversation.id))
        #expect(app.isAssistantNotificationFocused(UUID()))
        window.open(Workspace(pane: Pane(.empty)))
        window.sidebarMode = .assistant
        window.showsSidebar = true
        #expect(window.isShowingAssistant(conversation.id))
        window.showsSidebar = false
        #expect(!window.isShowingAssistant(conversation.id))
        #expect(!app.isAssistantNotificationFocused(conversation.id))
        other.openAssistantFullScreen(conversation.id)
        #expect(app.selectAssistantNotificationTarget(conversation.id) === other)
        #expect(other.assistantLibrary.selectedConversation === conversation)
        let peer = ConversationModel()
        peer.composer.draft = "Second conversation"
        _ = try #require(window.assistantLibrary.startConversation(peer))
        window.openAssistantInSidebar(peer.id)
        window.showsSidebar = true
        other.open(Workspace(pane: Pane(.empty)))
        other.sidebarMode = .assistant
        other.showsSidebar = true
        #expect(app.isAssistantNotificationFocused(peer.id))
        #expect(app.isAssistantNotificationFocused(conversation.id))
        #expect(!app.isAssistantNotificationFocused(UUID()))
        #expect(other.assistantLibrary.conversation(id: peer.id) === peer)
        other.isAssistantArchivePresented = true
        #expect(!other.isShowingAssistant(conversation.id))
        let target = try #require(app.selectAssistantNotificationTarget(UUID()))
        #expect(target.selectedDestination == .assistant)
        #expect(target.assistantLibrary.selectedConversation == nil)
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
