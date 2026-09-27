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
        #expect(fixture.defaults.data(forKey: MobileWorkspaceStore.key) == raw)
        let first = app.workspaceSession(for: "a")
        let second = app.workspaceSession(for: "b")
        #expect(first.savedWorkspaceDescriptors == records)
        #expect(second.orderedWorkspaceItems.isEmpty)
        #expect(app.workspaceSession(for: "a") === first)
        #expect(app.workspaces.isEmpty)
        #expect(app.connectionHistory.entries().isEmpty)
        let saved = try fixture.store.load()
        #expect(saved.version == 2)
        #expect(saved.unassigned.isEmpty)
        #expect(saved.sessions == ["a": records])
    }

    @Test func coldLaunchConsolidatesAllWindowsBeforeRoutingAnActivityLink() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let original = try fixture.makeApp()
        let a = original.workspaceSession(for: "old-a")
        let b = original.workspaceSession(for: "old-b")
        let firstID = try #require(a.open(hostID: fixture.host.id, kind: .ssh))
        let secondID = try #require(b.open(hostID: fixture.host.id, kind: .sftp))
        #expect(a.renameWorkspace(firstID, to: "First"))
        let historyCount = original.connectionHistory.entries().count
        for workspace in original.workspaces { workspace.disconnect() }
        let app = try fixture.makeApp()
        // Old native sessions can be discarded while the new process is starting.
        app.discardWorkspaceSessions(["old-a", "old-b"])
        let first = MobileSceneModel(app: app, sessionID: "new-a")
        let second = MobileSceneModel(app: app, sessionID: "new-b")
        #expect(first.workspaceSession.savedWorkspaceDescriptors.map(\.id) == [firstID, secondID])
        #expect(first.workspaceSession.savedWorkspaceDescriptors.first?.title == "First")
        #expect(second.workspaceSession.orderedWorkspaceItems.isEmpty)
        #expect(app.workspaces.isEmpty)
        #expect(app.connectionHistory.entries().count == historyCount)
        var requests: [String] = []
        let delegate = MobileSceneDelegate()
        app.activateWorkspaceSession = { owner, workspaceID, _ in
            requests.append(owner)
            delegate.receiveWorkspaceActivity(MobileWorkspaceSceneRouting.activity(for: workspaceID))
        }
        second.open(WorkspaceActivityAttributes.destinationURL(for: secondID))
        #expect(requests == ["new-a"])
        #expect(app.workspaces.isEmpty)
        let pending = try #require(delegate.consumePendingWorkspaceID())
        first.open(WorkspaceActivityAttributes.destinationURL(for: pending))
        first.activatePendingWorkspace()
        let live = try #require(first.activeWorkspace)
        first.open(WorkspaceActivityAttributes.destinationURL(for: pending))
        #expect(first.activeWorkspace === live)
        #expect(second.workspaceSession.workspaces.isEmpty)
        #expect(delegate.consumePendingWorkspaceID() == nil)
        #expect(app.connectionHistory.entries().count == historyCount + 1)
        #expect(try fixture.store.load().sessions.keys.sorted() == ["new-a"])
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
        #expect(try fixture.store.load().sessions["a"]?.count == 2)
        #expect(try fixture.store.load().sessions["b"] == nil)
        // A late user-close callback must still remove only the workspaces from that window.
        app.discardWorkspaceSessions(["b"])
        #expect(first.workspaceSession.workspaces.count == 1)
        #expect(first.workspaceSession.workspaces.first?.id != original.id)
        #expect(app.workspaceOwner(original.id) == nil)
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
        #expect(try fixture.store.load().sessions.keys.sorted() == ["a", "b"])
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
        #expect(try fixture.store.load().sessions["a"]?.map(\.id) == [original.id])
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
        #expect(try fixture.store.load().sessions["a"] == nil)
        first.open(WorkspaceActivityAttributes.destinationURL(for: id))
        #expect(first.isWorkspaceUnavailable)
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
        #expect(try fixture.store.load().sessions.values.allSatisfy(\.isEmpty))
    }

    private final class Background: MobileBackgroundTaskManaging {
        func begin(expiration: @escaping @MainActor () -> Void) {}
        func finish() {}
    }

    private final class Fixture {
        let name = "WorkspaceSessions.\(UUID())"
        let defaults: UserDefaults
        let container: ModelContainer
        let host = Host(name: "Server", host: "test.invalid")
        var apps: [MobileAppModel] = []
        var store: MobileWorkspaceStore { MobileWorkspaceStore(defaults: defaults) }

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
            dependencies.workspaceStore = store
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
