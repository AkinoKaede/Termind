import Foundation
import SwiftData
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing
import UIKit

import struct TermindDomain.Host

@testable import TermindIOS

@Suite @MainActor
struct MobileWorkspaceSessionTests {
    @Test func artworkRefreshesForOpenWorkspacesWithoutReconnecting() async throws {
        let app = try MobileAppModel(inMemory: true)
        let host = Host(name: "Mac", host: "example.invalid", shellIntegrationMode: .enabled)
        app.library.upsert(host)
        let session = app.testWorkspaceSession
        defer { session.closeAll() }
        let id = try #require(session.open(hostID: host.id, kind: .ssh))
        let workspace = try #require(session.openWorkspace(id))
        let originalStatus = workspace.status
        workspace.receiveShellEvent(
            .available(
                shell: "zsh", systemInfo: RemoteSystemInfo(kernelName: "Darwin"), homeDirectory: "/Users/test"))
        #expect(workspace.activitySession.iconAsset == "HostOS-macos")
        var draft = try #require(app.library.host(host.id))
        draft.iconOverrideID = "windows"
        #expect(app.library.saveHost(draft))
        for _ in 0..<50 where workspace.activitySession.iconAsset != "HostOS-windows" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(workspace.activitySession.iconAsset == "HostOS-windows")
        workspace.receiveShellEvent(
            .systemInfo(
                RemoteSystemInfo(distributionID: "ubuntu", kernelName: "Linux")))
        #expect(workspace.activitySession.iconAsset == "HostOS-windows")
        for (choice, symbol) in [("cloud", "cloud"), ("database", "cylinder")] {
            draft = try #require(app.library.host(host.id))
            draft.iconOverrideID = choice
            #expect(app.library.saveHost(draft))
            for _ in 0..<50 where workspace.activitySession.iconSystemName != symbol {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(workspace.activitySession.iconAsset == nil)
            #expect(workspace.activitySession.iconSystemName == symbol)
        }
        draft = try #require(app.library.host(host.id))
        draft.iconOverrideID = nil
        app.applyRemoteVault(.init(hosts: [draft]), keys: [.init(kind: .host, id: host.id)])
        for _ in 0..<50 where workspace.activitySession.iconAsset != "LinuxDistro-ubuntu" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(workspace.activitySession.iconAsset == "LinuxDistro-ubuntu")
        #expect(workspace.activitySession.iconSystemName == nil)
        workspace.receiveShellEvent(.systemInfo(RemoteSystemInfo(kernelName: "DragonFly")))
        #expect(workspace.activitySession.iconAsset == "HostOS-bsd")
        #expect(app.library.host(host.id)?.detectedDistribution?.id == "dragonfly")
        workspace.receiveShellEvent(.systemInfo(RemoteSystemInfo(distributionID: "custom-linux", kernelName: "Linux")))
        #expect(workspace.activitySession.iconAsset == "HostOS-linux")
        #expect(workspace.status == originalStatus)
        #expect(session.openWorkspace(id) === workspace)
    }

    @Test func recentlyClosedIsSharedOnlyWithinOneProcess() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let first = app.workspaceSession(for: "first")
        let other = app.workspaceSession(for: "other")
        let id = try #require(first.open(hostID: fixture.host.id, kind: .ssh))
        first.close(id)
        #expect(other.canReopen)
        #expect(other.reopenLastClosed() == id)
        #expect(!first.canReopen)
        other.close(id)
        #expect(try fixture.makeApp().closedWorkspaceRecords.isEmpty)
    }

    @Test func discardedWindowsAreGroupedAndReopenedInANewSession() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let source = MobileSceneModel(app: app, sessionID: "source")
        source.open(hostID: fixture.host.id, kind: .ssh)
        source.open(hostID: fixture.host.id, kind: .sftp)
        let ids = source.workspaceSession.orderedWorkspaceItems.map(\.id)
        app.discardWorkspaceSessions(["source"])
        let record = try #require(app.closedWorkspaceRecords.first)
        #expect(record.isWindow)
        #expect(record.items.map(\.id) == ids)
        #expect(app.closedWorkspaceRecords.count == 1)
        let current = MobileSceneModel(app: app, sessionID: "current")
        var requests: [UUID] = []
        app.createWorkspaceWindow = { id, _ in requests.append(id) }
        current.reopenLastClosedWorkspace()
        current.reopenLastClosedWorkspace()
        #expect(requests == [record.id])
        #expect(current.workspaceSession.orderedWorkspaceItems.isEmpty)
        #expect(app.closedWorkspaceRecords.count == 1)
        let destination = MobileSceneModel(app: app, sessionID: "destination")
        let selected = app.restoreClosedWindow(record.id, into: destination.workspaceSession)
        #expect(selected == ids.first)
        #expect(destination.workspaceSession.orderedWorkspaceItems.map(\.id) == ids)
        #expect(app.closedWorkspaceRecords.isEmpty)
        #expect(app.restoreClosedWindow(record.id, into: destination.workspaceSession) == nil)
    }

    @Test func windowChildRestoreAndFailedNewWindowRequestsPreserveRemainingRecords() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let source = MobileSceneModel(app: app, sessionID: "source")
        source.open(hostID: fixture.host.id, kind: .ssh)
        source.open(hostID: fixture.host.id, kind: .sftp)
        app.discardWorkspaceSessions(["source"])
        let record = try #require(app.closedWorkspaceRecords.first)
        let current = MobileSceneModel(app: app, sessionID: "current")
        let first = try #require(record.items.first)
        #expect(current.workspaceSession.reopenClosedItem(first.id, in: record.id) == first.id)
        #expect(app.closedWorkspaceRecords.first?.items.count == 1)
        app.createWorkspaceWindow = { _, failed in failed() }
        current.reopenLastClosedWorkspace()
        #expect(app.closedWorkspaceRecords.first?.items.count == 1)
        #expect(app.pendingClosedWindows.isEmpty)
    }

    @Test func recentClosedCanRestoreAnOlderItemWithoutConsumingTheNewest() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let records = (0..<3).map {
            MobileWorkspaceDescriptor(hostID: fixture.host.id, title: "Workspace \($0)", kind: .ssh)
        }
        let app = try fixture.makeApp()
        let session = app.workspaceSession(for: "owner")
        session.restoreClosedStates(records.map { .init(descriptor: $0) })
        session.closeAll()
        #expect(session.recentlyClosedRecords.flatMap(\.items).map(\.id) == records.reversed().map(\.id))
        #expect(session.reopenClosedWorkspace(records[0].id) == records[0].id)
        #expect(session.recentlyClosedRecords.flatMap(\.items).map(\.id) == [records[2].id, records[1].id])
        #expect(session.reopenClosedWorkspace(records[0].id) == nil)
        #expect(session.reopenLastClosed() == records[2].id)
    }

    @Test func reopenRestoresTheOwningWindowsWorkspaceWithFreshHistoryAndRouting() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let owner = MobileSceneModel(app: app, sessionID: "owner")
        let other = MobileSceneModel(app: app, sessionID: "other")
        owner.open(hostID: fixture.host.id, kind: .sftp)
        owner.activatePendingWorkspace()
        let original = try #require(owner.activeWorkspace)
        #expect(owner.workspaceSession.renameWorkspace(original.id, to: "Files"))
        other.open(hostID: fixture.host.id, kind: .ssh)
        other.activatePendingWorkspace()
        let otherWorkspace = try #require(other.activeWorkspace)

        owner.closeActiveWorkspace()
        #expect(owner.workspaceSession.canReopen)
        #expect(other.workspaceSession.canReopen)
        #expect(fixture.defaults.object(forKey: MobileWorkspaceStore.key) == nil)
        owner.openSettings()
        owner.reopenLastClosedWorkspace()
        owner.activatePendingWorkspace()

        let reopened = try #require(owner.activeWorkspace)
        #expect(reopened !== original)
        #expect(reopened.descriptor == original.descriptor)
        #expect(owner.selectedDestination == .workspaces)
        reopened.sftpHistory.record(kind: .directory, path: "/srv")
        #expect(reopened.sftpHistory.entries().first?.path == "/srv")
        #expect(other.activeWorkspace === otherWorkspace)
        #expect(!owner.workspaceSession.canReopen)
        #expect(fixture.defaults.object(forKey: MobileWorkspaceStore.key) == nil)
        owner.reopenLastClosedWorkspace()
        #expect(owner.workspaceSession.workspaces.count == 1)
    }

    @Test func reopenUsesLastClosedOrderForDormantAndBulkClosedWorkspaces() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let records = (0..<3).map {
            MobileWorkspaceDescriptor(hostID: fixture.host.id, title: "Workspace \($0)", kind: .ssh)
        }
        let app = try fixture.makeApp()
        let session = app.workspaceSession(for: "owner")
        session.restoreClosedStates(records.map { .init(descriptor: $0) })

        session.closeOtherWorkspaces(than: records[0].id)
        #expect(session.reopenLastClosed() == records[2].id)
        #expect(session.reopenLastClosed() == records[1].id)
        #expect(!session.canReopen)
        session.closeAll()
        #expect(session.reopenLastClosed() == records[1].id)
        #expect(session.reopenLastClosed() == records[2].id)
        #expect(session.reopenLastClosed() == records[0].id)
        #expect(session.reopenLastClosed() == nil)
    }

    @Test func reopenKeepsExternalConnectionsTransientAndDoesNotReplayOneShotCommands() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let scene = MobileSceneModel(app: app, sessionID: "owner")
        scene.open(try #require(URL(string: "ssh://tester@external.invalid:2222")))
        scene.activatePendingWorkspace()
        let external = try #require(scene.activeWorkspace)
        scene.closeActiveWorkspace()
        scene.reopenLastClosedWorkspace()
        let reopened = try #require(scene.activeWorkspace)
        #expect(reopened.id == external.id)
        #expect(reopened.isExternalTemporaryConnection)
        #expect(reopened.temporaryLoginAddress == external.temporaryLoginAddress)
        #expect(reopened.presentationHost?.port == 2222)
        #expect(scene.workspaceSession.savedWorkspaceDescriptors.isEmpty)
        #expect(app.library.host(external.descriptor.hostID) == nil)

        scene.execute(Snippet(title: "One shot", body: "echo one-shot"), on: [fixture.host.id])
        #expect(scene.activeWorkspace?.pendingInitialCommand == "echo one-shot")
        scene.closeActiveWorkspace()
        scene.reopenLastClosedWorkspace()
        #expect(scene.activeWorkspace?.descriptor.hostID == fixture.host.id)
        #expect(scene.activeWorkspace?.pendingInitialCommand == nil)
        #expect(scene.activeWorkspace?.commandHistory.record("echo after-reopen") != nil)
    }

    @Test func reopenHistoryIsBoundedAndClearedWhenTheWindowIsDiscarded() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let session = app.workspaceSession(for: "owner")
        var closed: [UUID] = []
        for _ in 0..<17 {
            let id = try #require(session.open(hostID: fixture.host.id, kind: .ssh))
            session.close(id)
            closed.append(id)
        }
        var reopened: [UUID] = []
        while let id = session.reopenLastClosed() { reopened.append(id) }
        #expect(reopened == Array(closed.suffix(15).reversed()))
        session.closeAll()
        #expect(session.canReopen)
        app.discardWorkspaceSessions(["owner"])
        #expect(!session.canReopen)
        #expect(session.reopenLastClosed() == nil)
    }

    @Test func deletingAHostForgetsClosedWorkspacesAndDoesNotCreateNewReopenEntries() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let session = app.workspaceSession(for: "owner")
        let id = try #require(session.open(hostID: fixture.host.id, kind: .ssh))
        session.close(id)
        _ = session.open(hostID: fixture.host.id, kind: .sftp)
        #expect(session.canReopen)

        #expect(app.deleteHost(fixture.host.id))

        #expect(!session.canReopen)
        #expect(session.reopenLastClosed() == nil)
        #expect(session.workspaces.isEmpty)
    }

    @Test func deletingAHostBeforeBindingAWindowRemovesPersistedClosedWorkspaces() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let firstApp = try fixture.makeApp()
        let session = firstApp.workspaceSession(for: "owner")
        let id = try #require(session.open(hostID: fixture.host.id, kind: .ssh))
        session.close(id)

        let nextApp = try fixture.makeApp()
        #expect(nextApp.recentlyClosedStore.entries.isEmpty)
        #expect(firstApp.closedWorkspaceRecords.flatMap(\.items).map(\.id) == [id])
        #expect(nextApp.deleteHost(fixture.host.id))
        #expect(nextApp.recentlyClosedStore.entries.isEmpty)
        let thirdApp = try fixture.makeApp()
        #expect(thirdApp.recentlyClosedStore.entries.isEmpty)
    }

    @Test func agentForwardingStaysWithTheConversationScene() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let owner = MobileSceneModel(app: app, sessionID: "agent-owner")
        let other = MobileSceneModel(app: app, sessionID: "agent-other")
        owner.agentForwarding.isActive = true
        other.agentForwarding.isActive = true
        let conversation = ConversationModel()
        conversation.composer.draft = "Agent forwarding"
        conversation.sendDraft()
        owner.assistant.library.insertAndSelect(conversation)
        owner.openAssistantNotification(conversation.id)
        let hostID = UUID()
        let request = SSHConnectionRequest(
            configuration: .init(
                hostID: hostID, host: "fixture", port: 22, username: "user", credentials: [], expectedHostKeys: []),
            agentForwardingContextID: conversation.id)
        let context = app.agentForwardingRouter.context(for: request)
        #expect(context.canInteract())
        let handler = try #require(context.unlock)
        let pending = Task {
            try await handler(
                .init(
                    connectionID: UUID(), hostID: hostID,
                    hostname: "fixture", port: 22, username: "user", round: 0, name: "Agent Forwarding",
                    instruction: "Fixture", prompts: [.init(text: "Passphrase", echo: false)]))
        }
        for _ in 0..<100 where owner.agentForwarding.current == nil { await Task.yield() }
        #expect(owner.agentForwarding.current != nil)
        #expect(other.agentForwarding.current == nil)
        owner.agentForwarding.isActive = false
        #expect(!context.canInteract())
        await #expect(throws: CancellationError.self) { try await pending.value }
    }

    @Test(arguments: [true, false])
    func assistantNotificationPrefersActiveThenStableOrderWithinMatchingScenes(_ visible: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let scenes = [
            MobileSceneModel(app: app, sessionID: "matching-a"),
            MobileSceneModel(app: app, sessionID: "matching-b"),
        ].sorted { $0.id.uuidString < $1.id.uuidString }
        let conversation = ConversationModel()
        conversation.composer.draft = "Target"
        conversation.sendDraft()
        scenes[0].assistant.library.insertAndSelect(conversation)
        for scene in scenes {
            scene.openAssistantNotification(conversation.id)
            if !visible { scene.selectedDestination = .vault }
        }
        app.sceneChanged(scenes[0].id, phase: .inactive)
        app.sceneChanged(scenes[1].id, phase: .active)

        #expect(app.assistantNotificationTarget(conversation.id) === scenes[1])
        #expect(scenes[1].isShowingAssistant(conversation.id) == visible)
        app.sceneChanged(scenes[0].id, phase: .active)
        #expect(app.assistantNotificationTarget(conversation.id) === scenes[0])

        app.removeScene(scenes[0].id)
        #expect(app.assistantNotificationTarget(conversation.id) === scenes[1])
    }

    @Test(arguments: [true, false])
    func assistantNotificationReusesHiddenSelectionBeforeAnUnrelatedActiveScene(_ libraryPresented: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let owner = MobileSceneModel(app: app, sessionID: "hidden-owner")
        let other = MobileSceneModel(app: app, sessionID: "active-other")
        let conversation = ConversationModel()
        conversation.composer.draft = "Target"
        conversation.sendDraft()
        owner.assistant.library.insertAndSelect(conversation)
        owner.openAssistantNotification(conversation.id)
        if libraryPresented {
            owner.assistantLibraryRoute = .conversations
        } else {
            owner.selectedDestination = .vault
        }
        app.sceneChanged(other.id, phase: .active)
        app.sceneChanged(owner.id, phase: .background)
        #expect(!app.isAssistantNotificationFocused(conversation.id))
        var activations: [String] = []
        let router = MobileNotificationRouter(app: app) { sessionID, _ in activations.append(sessionID) }
        router.open(.assistant(conversation.id))
        #expect(activations == [owner.workspaceSession.id])
        #expect(!owner.isShowingAssistant(conversation.id))
        #expect(other.assistant.library.selectedConversationID == nil)
        router.resume()
        #expect(activations.count == 1)
        app.sceneChanged(owner.id, phase: .active)
        router.resume()
        try await waitUntil { owner.isShowingAssistant(conversation.id) }
        router.stop()

        owner.selectedDestination = .vault
        other.openAssistantNotification(conversation.id)
        app.sceneChanged(owner.id, phase: .active)
        app.sceneChanged(other.id, phase: .background)
        #expect(app.assistantNotificationTarget(conversation.id) === other)
        #expect(owner.selectedDestination == .vault)
    }

    @Test func notificationRouterWaitsForASceneAndConsumesTheTransferClickOnce() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        var activated: [String] = []
        let router = MobileNotificationRouter(app: app) { sessionID, _ in activated.append(sessionID) }
        router.open(.transfers)
        #expect(activated.isEmpty)
        let scene = MobileSceneModel(app: app, sessionID: "notification-routing")
        router.resume()
        #expect(!scene.showsTransfers)
        #expect(activated.isEmpty)
        app.sceneChanged(scene.id, phase: .active)
        router.resume()
        #expect(scene.showsTransfers)
        #expect(activated.isEmpty)
        scene.workspaceDestination = nil
        router.resume()
        #expect(!scene.showsTransfers)
        router.stop()
        router.open(.transfers)
        #expect(!scene.showsTransfers)
        #expect(activated.isEmpty)
        let foregroundRouter = MobileNotificationRouter(app: app) { sessionID, _ in activated.append(sessionID) }
        foregroundRouter.open(.transfers)
        #expect(scene.showsTransfers)
        #expect(activated.isEmpty)
        foregroundRouter.stop()
    }

    @Test func assistantNotificationRouterUsesTheLatestClick() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let scene = MobileSceneModel(app: app, sessionID: "assistant-routing")
        let first = ConversationModel()
        let second = ConversationModel()
        first.composer.draft = "First"
        second.composer.draft = "Second"
        first.sendDraft()
        scene.assistant.library.insertAndSelect(first)
        second.sendDraft()
        scene.assistant.library.insertAndSelect(second)
        app.sceneChanged(scene.id, phase: .active)
        var activations: [String] = []
        scene.assistant.library.select(first.id)
        scene.selectedDestination = .vault
        let router = MobileNotificationRouter(app: app) { sessionID, _ in activations.append(sessionID) }
        router.open(.assistant(first.id))
        router.open(.assistant(second.id))
        try await waitUntil { scene.isShowingAssistant(second.id) }
        #expect(activations.isEmpty)
        #expect(scene.assistant.library.selectedConversationID == second.id)
        router.stop()
    }

    @Test func notificationActivationRetriesAndIgnoresFailuresFromEarlierClicks() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let owner = MobileSceneModel(app: app, sessionID: "retry-notification")
        let other = MobileSceneModel(app: app, sessionID: "active-notification")
        owner.open(hostID: fixture.host.id, kind: .ssh)
        owner.activatePendingWorkspace()
        let workspaceID = try #require(owner.activeWorkspace?.id)
        owner.selectedDestination = .vault
        app.sceneChanged(owner.id, phase: .background)
        app.sceneChanged(other.id, phase: .active)
        var activations: [String] = []
        var failures: [@MainActor () -> Void] = []
        let router = MobileNotificationRouter(app: app) { sessionID, failed in
            activations.append(sessionID)
            failures.append(failed)
        }

        router.open(.terminal(workspaceID))
        #expect(activations == [owner.workspaceSession.id])
        #expect(owner.selectedDestination == .vault)
        let firstFailure = try #require(failures.first)
        firstFailure()
        router.resume()
        #expect(activations.count == 2)
        let retryFailure = try #require(failures.last)
        router.open(.terminal(workspaceID))
        #expect(activations == Array(repeating: owner.workspaceSession.id, count: 3))
        // The earlier request can fail after a new click has requested this same window.
        retryFailure()
        router.resume()
        #expect(activations.count == 3)
        app.sceneChanged(owner.id, phase: .active)
        router.resume()
        #expect(owner.selectedDestination == .workspaces)
        router.stop()
    }

    @Test func transferNotificationOpensTransfersWithoutMarkingUnread() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let scene = MobileSceneModel(app: app, sessionID: "transfers")
        scene.open(hostID: fixture.host.id, kind: .sftp)
        scene.activatePendingWorkspace()
        app.sceneChanged(scene.id, phase: .active)
        #expect(app.transferNotificationTarget() === scene)
        #expect(!scene.showsTransfers)
        let router = MobileNotificationRouter(app: app) { _, _ in Issue.record("Scene is already active") }
        defer { router.stop() }
        router.open(.transfers)
        #expect(scene.selectedDestination == .workspaces && scene.showsTransfers && scene.workspaceID == nil)
        #expect(app.unreadNotificationCount == 0)
    }

    @Test func manuallyUnreadWorkspacesFollowTheirWindowWithoutEnteringSavedDescriptors() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let first = app.workspaceSession(for: "unread-a")
        let second = app.workspaceSession(for: "unread-b")
        let id = try #require(first.open(hostID: fixture.host.id, kind: .sftp))
        first.markUnread(id)
        first.markUnread(id)
        #expect(first.unreadCompletionCount == 1 && second.unreadCompletionCount == 0)
        #expect(app.unreadNotificationCount == 1)
        let fresh = MobileWorkspaceSessionModel(id: "fresh", app: app, descriptors: first.savedWorkspaceDescriptors)
        #expect(fresh.unreadCompletionCount == 0)
        let recovery = first.recovery
        first.releaseForRecovery()
        second.acceptRecovery(recovery)
        #expect(first.unreadCompletionCount == 0 && second.unreadCompletionCount == 1)
        second.markRead(id)
        #expect(app.unreadNotificationCount == 0)
        second.markUnread(id)
        second.close(id)
        #expect(second.unreadWorkspaceIDs.isEmpty)
    }

    @Test func assistantNotificationsRespectSceneFocusAndOpenTheExistingConversation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let first = MobileSceneModel(app: app, sessionID: "assistant-a")
        let second = MobileSceneModel(app: app, sessionID: "assistant-b")
        let conversation = ConversationModel()
        conversation.composer.draft = "Test"
        conversation.sendDraft()
        first.assistant.library.insertAndSelect(conversation)
        first.openAssistantNotification(conversation.id)
        app.sceneChanged(first.id, phase: .active)
        #expect(app.isAssistantNotificationFocused(conversation.id))
        first.assistantLibraryRoute = .conversations
        #expect(!app.isAssistantNotificationFocused(conversation.id))
        first.assistantLibraryRoute = nil
        app.sceneChanged(second.id, phase: .active)
        let peer = ConversationModel()
        peer.composer.draft = "Second conversation"
        peer.sendDraft()
        second.assistant.library.insertAndSelect(peer)
        second.openAssistantNotification(peer.id)
        #expect(app.isAssistantNotificationFocused(conversation.id))
        #expect(app.isAssistantNotificationFocused(peer.id))
        #expect(first.assistant.library.conversation(id: peer.id) === peer)
        app.sceneChanged(first.id, phase: .background)
        #expect(app.isAssistantNotificationFocused(conversation.id))
        #expect(app.assistantNotificationTarget(conversation.id) === first)
        #expect(first.assistant.conversation === conversation)
        first.selectedDestination = .vault
        #expect(!app.isAssistantNotificationFocused(conversation.id))
        #expect(app.isAssistantNotificationFocused(peer.id))
        let missingConversationID = UUID()
        #expect(app.assistantNotificationTarget(missingConversationID) === second)
        #expect(second.assistantLibraryRoute == nil)
        let router = MobileNotificationRouter(app: app) { _, _ in Issue.record("Scene is already active") }
        defer { router.stop() }
        router.open(.assistant(missingConversationID))
        try await waitUntil { second.assistantLibraryRoute == .conversations }
    }

    @Test func commandCompletionDotsUseVisibleWorkspaceInItsOwningScene() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let first = MobileSceneModel(app: app, sessionID: "command-a")
        let second = MobileSceneModel(app: app, sessionID: "command-b")
        first.open(hostID: fixture.host.id, kind: .ssh)
        second.open(hostID: fixture.host.id, kind: .ssh)
        first.activatePendingWorkspace()
        second.activatePendingWorkspace()
        let workspace = try #require(first.activeWorkspace)
        app.sceneChanged(second.id, phase: .active)
        app.sceneChanged(first.id, phase: .background)
        workspace.commandMonitor.beginConnection()
        workspace.commandMonitor.receiveOSC133(exitCode: 1, durationNanos: 1)
        #expect(workspace.commandMonitor.hasUnreadCompletion)
        #expect(first.workspaceSession.hasUnreadCompletion)
        #expect(!second.workspaceSession.hasUnreadCompletion)
        #expect(!app.isCommandWorkspaceFocused(workspace.id))
        #expect(!second.activeWorkspace!.commandMonitor.hasUnreadCompletion)
        app.sceneChanged(first.id, phase: .active)
        #expect(app.isCommandWorkspaceFocused(workspace.id))
        #expect(!workspace.commandMonitor.hasUnreadCompletion)
        #expect(!first.workspaceSession.hasUnreadCompletion)
        workspace.commandMonitor.receiveOSC133(exitCode: 0, durationNanos: 1)
        #expect(!workspace.commandMonitor.hasUnreadCompletion)
        first.workspaceID = nil
        workspace.commandMonitor.receiveOSC133(exitCode: nil, durationNanos: 0)
        #expect(workspace.commandMonitor.hasUnreadCompletion)
        first.selectWorkspace(workspace.id)
        #expect(!workspace.commandMonitor.hasUnreadCompletion)
        first.closeWorkspace(workspace.id)
        workspace.commandMonitor.receiveOSC133(exitCode: 0, durationNanos: 1)
        #expect(!workspace.commandMonitor.hasUnreadCompletion)
    }

    @Test func commandNotificationWaitsForItsBackgroundWindowToActivate() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let owner = MobileSceneModel(app: app, sessionID: "command-owner")
        let other = MobileSceneModel(app: app, sessionID: "command-other")
        owner.open(hostID: fixture.host.id, kind: .ssh)
        owner.activatePendingWorkspace()
        let workspaceID = try #require(owner.activeWorkspace?.id)
        owner.selectedDestination = .vault
        app.sceneChanged(owner.id, phase: .background)
        var activations: [String] = []
        let router = MobileNotificationRouter(app: app) { sessionID, _ in activations.append(sessionID) }
        router.open(.terminal(workspaceID))

        // Wait for UIKit to foreground the app before requesting a different owner window.
        router.resume()
        #expect(activations.isEmpty)
        #expect(owner.selectedDestination == .vault)
        app.sceneChanged(other.id, phase: .active)
        router.resume()
        #expect(owner.selectedDestination == .vault)
        #expect(owner.workspaceID == workspaceID)
        #expect(other.selectedDestination == .vault)
        #expect(activations.count == 1)
        #expect(activations.first == owner.workspaceSession.id)

        // UIKit activates the owner, then the pending route selects its workspace.
        app.sceneChanged(owner.id, phase: .active)
        #expect(app.workspaceOwner(workspaceID) == owner.workspaceSession.id)
        router.resume()
        #expect(owner.selectedDestination == .workspaces)
        owner.activatePendingWorkspace()
        #expect(owner.activeWorkspace?.id == workspaceID)
        #expect(activations.count == 1)

        owner.selectedDestination = .vault
        router.open(.terminal(workspaceID))
        #expect(owner.selectedDestination == .workspaces)
        owner.activatePendingWorkspace()
        #expect(owner.activeWorkspace?.id == workspaceID)
        #expect(activations.count == 1)
    }

    @Test func paneAccessExcludesDormantAndDisconnectedWorkspacesAcrossScenes() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let first = MobileSceneModel(app: app, sessionID: "pane-a")
        let second = MobileSceneModel(app: app, sessionID: "pane-b")
        first.open(hostID: fixture.host.id, kind: .ssh)
        second.open(try #require(URL(string: "telnet://test.invalid")))
        first.activatePendingWorkspace()
        second.activatePendingWorkspace()
        let firstID = try #require(first.activeWorkspace?.id)
        let secondID = try #require(second.activeWorkspace?.id)
        let access = try #require(first.assistant.paneAccess)
        #expect(access.list().isEmpty)
        #expect(access.read(firstID) == .notConnected)
        #expect(access.read(secondID) == .notConnected)
        second.closeWorkspace(secondID)
        #expect(access.read(secondID) == .closed)
    }

    @Test func windowsOwnIndependentSessionsAndLifecycleActions() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let first = MobileSceneModel(app: app, sessionID: "a")
        let second = MobileSceneModel(app: app, sessionID: "b")
        first.activateHost(fixture.host.id)
        second.activateHost(fixture.host.id)
        first.activatePendingWorkspace()
        second.activatePendingWorkspace()
        let a = try #require(first.activeWorkspace)
        let b = try #require(second.activeWorkspace)
        #expect(a !== b)
        #expect(a.terminal !== b.terminal)
        #expect(first.workspaceSession.orderedWorkspaceItems.map(\.id) == [a.id])
        #expect(second.workspaceSession.orderedWorkspaceItems.map(\.id) == [b.id])
        first.activateHost(fixture.host.id)
        #expect(first.activeWorkspace === a)
        #expect(!first.workspaceSession.renameWorkspace(b.id, to: "Other"))
        first.closeOtherWorkspaces(than: b.id)
        #expect(first.activeWorkspace === a)
        first.closeWorkspace(b.id)
        #expect(second.activeWorkspace === b)
        first.closeAllWorkspaces()
        #expect(first.workspaceSession.orderedWorkspaceItems.isEmpty)
        #expect(second.activeWorkspace === b)
        #expect(app.connectionHistory.entries().filter { $0.endedAt == nil }.count == 1)
        second.selectWorkspace(a.id)
        #expect(second.isWorkspaceUnavailable)
    }

    @Test func vaultHostIndicatorFollowsTheWorkspaceOpenedByItsCard() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let scene = MobileSceneModel(app: app, sessionID: "vault-card")
        let other = MobileSceneModel(app: app, sessionID: "other-window")
        let host = fixture.host

        other.open(hostID: host.id, kind: .ssh)
        #expect(scene.workspaceActivatedByHostRow(for: host) == nil)

        scene.open(hostID: host.id, kind: .sftp)
        #expect(scene.workspaceActivatedByHostRow(for: host) == nil)

        scene.open(hostID: host.id, kind: .ssh)
        let first = try #require(scene.workspaceActivatedByHostRow(for: host))
        scene.open(hostID: host.id, kind: .ssh)
        let second = try #require(scene.workspaceActivatedByHostRow(for: host))
        #expect(first !== second)

        scene.selectWorkspace(first.id)
        #expect(scene.workspaceActivatedByHostRow(for: host) === first)
        scene.activateHost(host.id)
        #expect(scene.activeWorkspace === first)
    }

    @Test func everyCreationEntryPointUsesTheReceivingWindow() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let first = MobileSceneModel(app: app, sessionID: "a")
        let second = MobileSceneModel(app: app, sessionID: "b")
        second.open(hostID: fixture.host.id, kind: .ssh)
        first.open(hostID: fixture.host.id, kind: .sftp)
        first.openSameDirectory(.init(hostID: fixture.host.id, kind: .ssh, path: "/srv"))
        first.execute(Snippet(title: "Test", body: "echo test"), on: [fixture.host.id])
        first.openBatchStartup()
        first.prepareBatchStartup(hostIDs: [fixture.host.id], connectionProtocol: .ssh)
        first.completeBatchStartup()
        #expect(first.workspaceID == nil)
        #expect(first.selectedDestination == .workspaces)
        #expect(first.perform(.history(hostID: fixture.host.id)))
        first.open(try #require(URL(string: "ssh://transient.invalid")))
        #expect(first.workspaceSession.workspaces.count == 6)
        #expect(first.workspaceSession.savedWorkspaceDescriptors.count == 5)
        #expect(second.workspaceSession.workspaces.count == 1)
        let otherID = try #require(second.workspaceSession.workspaces.first?.id)
        for _ in 0..<8 {
            first.selectNextWorkspace()
            #expect(first.workspaceID != otherID)
        }
    }

    @Test(arguments: [false, true])
    func oldSnapshotsAreClaimedOnceWithIdentityAndOrderPreserved(versioned: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let records = [
            MobileWorkspaceDescriptor(hostID: fixture.host.id, title: "Shell", kind: .ssh),
            MobileWorkspaceDescriptor(hostID: fixture.host.id, title: "Files", kind: .sftp),
        ]
        let missing = MobileWorkspaceDescriptor(hostID: UUID(), title: "Removed", kind: .ssh)
        let array = String(decoding: try JSONEncoder().encode([missing] + records), as: UTF8.self)
        let raw = Data((versioned ? "{\"version\":1,\"workspaces\":\(array)}" : array).utf8)
        fixture.defaults.set(raw, forKey: MobileWorkspaceStore.key)
        let app = try fixture.makeApp()
        #expect(fixture.defaults.object(forKey: MobileWorkspaceStore.key) == nil)
        #expect(app.workspaceSession(for: "a").orderedWorkspaceItems.isEmpty)
        #expect(app.workspaceSession(for: "b").orderedWorkspaceItems.isEmpty)
        #expect(app.workspaces.isEmpty)
        #expect(app.connectionHistory.entries().isEmpty)
    }

    @Test func coldLaunchDoesNotClaimOldNativeSceneWorkspaces() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let original = try fixture.makeApp()
        let id = try #require(original.workspaceSession(for: "old").open(hostID: fixture.host.id, kind: .ssh))
        let app = try fixture.makeApp()
        app.discardWorkspaceSessions(["old"])
        let scene = MobileSceneModel(app: app, sessionID: "new")
        scene.open(WorkspaceActivityAttributes.destinationURL(for: id))
        #expect(scene.isWorkspaceUnavailable)
        #expect(app.workspaces.isEmpty)
        #expect(app.closedWorkspaceRecords.isEmpty)
    }

    @Test func missingNativeSessionHandsOffLiveWorkspacesWithoutReconnecting() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let first = MobileSceneModel(app: app, sessionID: "a")
        let second = MobileSceneModel(app: app, sessionID: "b")
        first.open(hostID: fixture.host.id, kind: .ssh)
        second.open(hostID: fixture.host.id, kind: .sftp)
        let original = try #require(second.workspaceSession.workspaces.first)
        let history = app.connectionHistory.entries()
        app.sceneChanged(first.id, phase: .active)
        app.sceneChanged(second.id, phase: .background)
        app.disconnectWorkspaceScene("b")
        app.reconcileWorkspaceSessions(openSessionIDs: ["a"], activeSessionID: "a")
        #expect(first.workspaceSession.workspaces.last === original)
        #expect(second.workspaceSession.orderedWorkspaceItems.isEmpty)
        #expect(app.connectionHistory.entries() == history)
        #expect(app.workspaceOwner(original.id) == "a")
        #expect(fixture.defaults.object(forKey: MobileWorkspaceStore.key) == nil)
        #expect(fixture.defaults.object(forKey: MobileWorkspaceStore.key) == nil)
        // A late user-close callback must still remove only the workspaces from that window.
        app.discardWorkspaceSessions(["b"])
        #expect(first.workspaceSession.workspaces.count == 1)
        #expect(first.workspaceSession.workspaces.first?.id != original.id)
        #expect(app.workspaceOwner(original.id) == nil)
        #expect(app.closedWorkspaceRecords.first?.isWindow == true)
        #expect(app.closedWorkspaceRecords.first?.items.map(\.id) == [original.id])
        #expect(second.workspaceSession.open(hostID: fixture.host.id, kind: .ssh) == nil)
    }

    @Test func systemReclaimKeepsOwnershipWhenBothNativeSessionsStillExist() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let first = MobileSceneModel(app: app, sessionID: "a")
        let second = MobileSceneModel(app: app, sessionID: "b")
        first.open(hostID: fixture.host.id, kind: .ssh)
        second.open(hostID: fixture.host.id, kind: .sftp)
        let original = try #require(second.workspaceSession.workspaces.first)
        app.sceneChanged(first.id, phase: .active, workspaceSessionID: "a")
        app.sceneChanged(second.id, phase: .background, workspaceSessionID: "b")
        app.disconnectWorkspaceScene("b")
        app.reconcileWorkspaceSessions(openSessionIDs: ["a", "b"], activeSessionID: "a")
        #expect(first.workspaceSession.workspaces.count == 1)
        #expect(second.workspaceSession.workspaces.first === original)
        #expect(app.workspaceOwner(original.id) == "b")
        var activatedOwners: [String] = []
        app.activateWorkspaceSession = { owner, _, _ in activatedOwners.append(owner) }
        first.open(WorkspaceActivityAttributes.destinationURL(for: original.id))
        #expect(activatedOwners == ["b"])
        let restored = MobileSceneModel(app: app, sessionID: "b")
        #expect(restored.workspaceSession === second.workspaceSession)
        #expect(fixture.defaults.object(forKey: MobileWorkspaceStore.key) == nil)
    }

    @Test func missingLastWindowWaitsForTheNextActiveWindow() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let first = MobileSceneModel(app: app, sessionID: "a")
        first.open(hostID: fixture.host.id, kind: .ssh)
        let original = try #require(first.workspaceSession.workspaces.first)
        app.sceneChanged(first.id, phase: .background)
        app.disconnectWorkspaceScene("a")
        app.reconcileWorkspaceSessions(openSessionIDs: [], activeSessionID: nil)
        #expect(fixture.defaults.object(forKey: MobileWorkspaceStore.key) == nil)
        let next = MobileSceneModel(app: app, sessionID: "b")
        #expect(next.workspaceSession.workspaces.isEmpty)
        app.sceneChanged(next.id, phase: .active)
        app.reconcileWorkspaceSessions(openSessionIDs: ["b"], activeSessionID: "b")
        #expect(next.workspaceSession.workspaces.first === original)
        #expect(first.workspaceSession.workspaces.isEmpty)
        #expect(app.workspaceOwner(original.id) == "b")
    }

    @Test func backgroundAndViewRemovalPreserveOwnershipButExplicitDiscardRemovesIt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let first = MobileSceneModel(app: app, sessionID: "a")
        let second = MobileSceneModel(app: app, sessionID: "b")
        first.open(hostID: fixture.host.id, kind: .ssh)
        second.open(hostID: fixture.host.id, kind: .sftp)
        let id = try #require(first.workspaceSession.workspaces.first?.id)
        app.sceneChanged(first.id, phase: .background)
        app.removeScene(first.id)
        #expect(app.workspaceSession(for: "a") === first.workspaceSession)
        #expect(app.workspaceOwner(id) == "a")
        let delegate = MobileAppDelegate()
        delegate.app = app
        delegate.discardSessions(["a"])
        #expect(first.workspaceSession.orderedWorkspaceItems.isEmpty)
        #expect(second.workspaceSession.workspaces.count == 1)
        #expect(fixture.defaults.object(forKey: MobileWorkspaceStore.key) == nil)
        first.open(WorkspaceActivityAttributes.destinationURL(for: id))
        #expect(first.isWorkspaceUnavailable)
    }

    @Test func windowCloseWaitsForNativeDiscardBeforeRemovingItsWorkspaces() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let first = MobileSceneModel(app: app, sessionID: "a")
        let second = MobileSceneModel(app: app, sessionID: "b")
        first.open(hostID: fixture.host.id, kind: .ssh)
        second.open(hostID: fixture.host.id, kind: .sftp)
        let firstID = try #require(first.workspaceSession.workspaces.first?.id)
        let secondID = try #require(second.workspaceSession.workspaces.first?.id)
        var requestedSessions: [String] = []
        app.closeWorkspaceSession = { id, _ in requestedSessions.append(id) }
        first.openSettings()

        first.closeSelectionOrWindow()

        #expect(requestedSessions == ["a"])
        #expect(first.workspaceSession.workspaces.map(\.id) == [firstID])
        #expect(fixture.defaults.object(forKey: MobileWorkspaceStore.key) == nil)
        let delegate = MobileAppDelegate()
        delegate.app = app
        delegate.discardSessions(["a"])

        #expect(first.workspaceSession.isDiscarded)
        #expect(first.workspaceSession.orderedWorkspaceItems.isEmpty)
        #expect(fixture.defaults.object(forKey: MobileWorkspaceStore.key) == nil)
        #expect(second.workspaceSession.workspaces.map(\.id) == [secondID])
        #expect(fixture.defaults.object(forKey: MobileWorkspaceStore.key) == nil)
        #expect(app.error == nil)
        first.closeSelectionOrWindow()
        #expect(requestedSessions == ["a"])
    }

    @Test func explicitWindowCloseKeepsSelectedWorkspaceUntilNativeDiscard() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let scene = MobileSceneModel(app: app, sessionID: "owner")
        scene.open(hostID: fixture.host.id, kind: .ssh)
        scene.activatePendingWorkspace()
        let workspace = try #require(scene.activeWorkspace)
        var requestedSessions: [String] = []
        app.closeWorkspaceSession = { id, _ in requestedSessions.append(id) }

        scene.closeWindow()

        #expect(requestedSessions == ["owner"])
        #expect(scene.activeWorkspace === workspace)
        #expect(!scene.workspaceSession.isDiscarded)
        app.discardWorkspaceSessions(["owner"])
        #expect(scene.workspaceSession.workspaces.isEmpty)
        #expect(scene.workspaceSession.isDiscarded)
    }

    @Test func closeAllWindowsSnapshotsNativeSessionsAndRetainsRejectedWindows() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let first = MobileSceneModel(app: app, sessionID: "first")
        let second = MobileSceneModel(app: app, sessionID: "second")
        first.open(hostID: fixture.host.id, kind: .ssh)
        second.open(hostID: fixture.host.id, kind: .sftp)
        let retainedWorkspace = try #require(second.workspaceSession.workspaces.first)
        var nativeSessions: Set<String> = ["first", "second", "background"]
        var requestedSessions: [String] = []
        app.openWorkspaceSessionIDs = { nativeSessions }
        app.closeWorkspaceSession = { id, failed in
            requestedSessions.append(id)
            if id == "second" {
                failed(NSError(domain: "WindowCloseTest", code: 1))
            } else {
                nativeSessions.remove(id)
                app.discardWorkspaceSessions([id])
            }
        }

        first.closeAllWindows()

        #expect(requestedSessions == ["background", "second", "first"])
        #expect(first.workspaceSession.isDiscarded)
        #expect(second.workspaceSession.workspaces.first === retainedWorkspace)
        #expect(fixture.defaults.object(forKey: MobileWorkspaceStore.key) == nil)
        #expect(!second.workspaceSession.isDiscarded)
        #expect(app.error == nil)
    }

    @Test func rejectedWindowCloseKeepsWorkspacesAndSavedRecordsWithoutAnAlert() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let scene = MobileSceneModel(app: app, sessionID: "a")
        scene.open(hostID: fixture.host.id, kind: .ssh)
        let workspace = try #require(scene.workspaceSession.workspaces.first)
        var reportFailure: (@MainActor (any Error) -> Void)?
        app.closeWorkspaceSession = { _, failed in reportFailure = failed }
        scene.openSettings()

        scene.closeSelectionOrWindow()
        let failed = try #require(reportFailure)
        failed(NSError(domain: "WindowCloseTest", code: 1))

        #expect(scene.workspaceSession.workspaces.first === workspace)
        #expect(!scene.workspaceSession.isDiscarded)
        #expect(fixture.defaults.object(forKey: MobileWorkspaceStore.key) == nil)
        #expect(scene.selectedDestination == .settings)
        #expect(!scene.isWorkspaceUnavailable)
        #expect(app.error == nil)
    }

    @Test func closingMissingNativeSessionReportsFailureWithoutDiscardingSavedWorkspaces() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let id = "missing-\(UUID())"
        let scene = MobileSceneModel(app: app, sessionID: id)
        scene.open(hostID: fixture.host.id, kind: .ssh)
        let workspaceID = try #require(scene.workspaceSession.workspaces.first?.id)
        var failure: (any Error)?

        MobileWorkspaceSceneRouting.close(sessionID: id) { failure = $0 }

        #expect(failure as? MobileWorkspaceSceneRouting.CloseError == .sessionNotFound)
        #expect(scene.workspaceSession.workspaces.map(\.id) == [workspaceID])
        #expect(fixture.defaults.object(forKey: MobileWorkspaceStore.key) == nil)
        #expect(app.error == nil)
    }

    @Test func missingNativeWindowReportsUnavailableWithoutCreatingAConnection() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let first = MobileSceneModel(app: app, sessionID: "a")
        let second = MobileSceneModel(app: app, sessionID: "b")
        first.open(hostID: fixture.host.id, kind: .ssh)
        let id = try #require(first.workspaceSession.workspaces.first?.id)
        app.activateWorkspaceSession = { _, _, unavailable in unavailable() }
        second.open(WorkspaceActivityAttributes.destinationURL(for: id))
        #expect(second.isWorkspaceUnavailable)
        #expect(second.workspaceSession.workspaces.isEmpty)
        #expect(app.workspaces.count == 1)
    }

    @Test func hostDeletionClosesEveryWindowAndRecoveryRecord() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        for id in ["a", "b"] { _ = app.workspaceSession(for: id).open(hostID: fixture.host.id, kind: .ssh) }
        #expect(app.deleteHost(fixture.host.id))
        #expect(app.workspaces.isEmpty)
        #expect(fixture.defaults.object(forKey: MobileWorkspaceStore.key) == nil)
    }

    private final class Background: MobileBackgroundTaskManaging {
        func begin(expiration: @escaping @MainActor () -> Void) {}
        func finish() {}
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    private final class Fixture {
        let name = "WorkspaceSessions.\(UUID())"
        let defaults: UserDefaults
        let container: ModelContainer
        let host = Host(name: "Server", host: "test.invalid")
        var apps: [MobileAppModel] = []

        init() throws {
            defaults = try #require(UserDefaults(suiteName: name))
            container = try TermindPersistence.makeContainer(inMemory: true)
            var dependencies = MobileAppDependencies.testing()
            dependencies.container = container
            let seed = try MobileAppModel(dependencies: dependencies)
            seed.library.upsert(host)
            seed.outbox.stop()
        }

        func makeApp() throws -> MobileAppModel {
            var dependencies = MobileAppDependencies.testing(background: Background())
            dependencies.container = container
            dependencies.defaults = defaults
            let app = try MobileAppModel(dependencies: dependencies)
            apps.append(app)
            return app
        }

        func cleanUp() {
            for app in apps {
                for workspace in app.workspaces { workspace.disconnect() }
                app.outbox.stop()
            }
            defaults.removePersistentDomain(forName: name)
        }
    }
}
