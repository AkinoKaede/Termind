// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import ActivityKit
import Foundation
import SwiftUI
import TermindDomain
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobileLiveActivityRestorationTests {
    @Test func restoredActivityKeepsFocusAndEndsDuplicatesBeforeUpdating() async {
        let first = session()
        let focused = session()
        let backend = Backend()
        let dismissed = TestActivity(state: .dismissed)
        let existing = TestActivity(state: .stale, focusedWorkspaceID: focused.id)
        let duplicate = TestActivity()
        backend.existing = [dismissed, existing, duplicate]
        let controller = MobileLiveActivityController(services: backend.services)
        controller.restore([first, focused])

        #expect(await eventually { existing.updates.count == 1 })
        #expect(dismissed.ended && duplicate.ended)
        #expect(!existing.ended)
        #expect(existing.updates.first?.focusedWorkspaceID == focused.id)
        #expect(existing.updates.first?.sessions.first?.id == focused.id)
        #expect(backend.requests.isEmpty)
    }

    @Test func ordinaryUpdatesDoNotResurrectDismissedActivity() async {
        let backend = Backend()
        let existing = TestActivity()
        backend.existing = [existing]
        let controller = MobileLiveActivityController(services: backend.services)
        let original = session()
        controller.update([original])
        #expect(await eventually { existing.updates.count == 1 })
        existing.state = .dismissed
        controller.update([original])
        controller.focus(original.id, in: [original])
        let next = session()
        controller.start([next])

        #expect(await eventually { backend.requests.count == 1 })
        #expect(backend.requests.first?.sessions.map(\.id) == [next.id])
        #expect(existing.updates.count == 1)
    }

    @Test func authoritativeSnapshotDropsOrphanedSystemEntries() async {
        let backend = Backend()
        let id = UUID()
        let recovery = TermindIOS.WorkspaceActivityAttributes.Recovery(
            sourceWorkspaceID: id, hostID: UUID(), kind: "ssh")
        let card = TermindIOS.WorkspaceActivityAttributes.Session(
            id: id, title: "Server", kind: "ssh", connected: false, recovery: recovery)
        let existing = TestActivity()
        existing.contentState = .snapshot([card], focusedID: id)
        backend.existing = [existing]
        let controller = MobileLiveActivityController(services: backend.services)
        let current = session()
        controller.update([current])
        #expect(await eventually { existing.updates.last?.sessions.map(\.id) == [current.id] })
        controller.update([])
        #expect(await eventually { existing.ended })
    }

    @Test func closeLastThenOpenWaitsForOldActivityToFinishEnding() async {
        let backend = Backend()
        let existing = TestActivity()
        existing.suspendsEnd = true
        backend.existing = [existing]
        let controller = MobileLiveActivityController(services: backend.services)
        controller.update([])
        let next = session()
        controller.start([next])
        controller.focus(next.id, in: [next])

        #expect(await eventually { existing.endContinuation != nil })
        #expect(backend.requests.isEmpty)
        existing.endContinuation?.resume()
        existing.endContinuation = nil
        #expect(await eventually { backend.created.first?.updates.count == 1 })
        #expect(existing.ended)
        #expect(backend.requests.count == 1)
        #expect(backend.created.first?.updates.first?.focusedWorkspaceID == next.id)
        #expect(backend.created.first?.ended == false)
    }

    @Test(arguments: [false, true])
    func coldLaunchPublishesSavedRecordsAndCanCloseWithoutConnecting(openBeforeClose: Bool) async throws {
        let name = "ActivityRestoration.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let seed = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Server", host: "example.invalid")
        seed.library.upsert(host)
        let oldID = UUID()
        let reference = RemoteSessionReference(
            backend: .tmux, session: .init(id: "$42", name: "External", identity: Data("backend-identity".utf8)),
            hostID: host.id, endpoint: "example.invalid:22", username: "u", ownershipToken: nil)
        let card = TermindIOS.WorkspaceActivityAttributes.Session(
            id: oldID, title: "Saved", kind: "ssh", connected: true,
            recovery: .init(
                sourceWorkspaceID: oldID, hostID: host.id, kind: "ssh",
                remoteSession: try JSONEncoder().encode(reference)))
        let descriptor = MobileWorkspaceDescriptor(
            id: oldID, hostID: host.id, title: card.title, kind: .ssh, remoteSession: reference)
        try MobileWorkspaceStore(defaults: defaults).save(.init(sessions: ["old": [descriptor]]))
        let backend = Backend()
        let existing = TestActivity(focusedWorkspaceID: oldID)
        let orphan = session()
        existing.contentState = .snapshot([card, orphan], focusedID: oldID)
        backend.existing = [existing]
        var dependencies = MobileAppDependencies.testing(defaults: defaults)
        dependencies.container = seed.container
        dependencies.liveActivities = MobileLiveActivityController(services: backend.services)
        let app = try MobileAppModel(dependencies: dependencies)
        app.sceneChanged(UUID(), phase: .active)
        #expect(await eventually { !existing.updates.isEmpty })
        #expect(!existing.ended)
        #expect(existing.updates.last?.connectedCount == 0)
        #expect(existing.updates.last?.sessions.map(\.id) == [oldID])
        #expect(app.workspaces.isEmpty)
        #expect(backend.requests.isEmpty)
        let scene = MobileSceneModel(app: app, sessionID: "new")
        app.discardWorkspaceSessions(["old"])
        app.reconcileWorkspaceSessions(openSessionIDs: ["new"], activeSessionID: "new")
        #expect(scene.workspaceSession.savedWorkspaceDescriptors == [descriptor])
        if openBeforeClose {
            scene.open(card.destinationURL)
            let restored = try #require(app.workspaces.first)
            #expect(restored.id == oldID)
            #expect(!restored.sessionPersistence.requiresSelection)
            #expect(restored.sessionPersistence.attachment == reference)
            #expect(!scene.isWorkspaceUnavailable)
        }
        scene.workspaceSession.closeAll()
        #expect(await eventually { existing.ended })
        #expect(try MobileWorkspaceStore(defaults: defaults).load().sessions.values.allSatisfy(\.isEmpty))
        scene.open(card.destinationURL)
        #expect(scene.isWorkspaceUnavailable)
        #expect(app.workspaces.isEmpty)
        app.sceneChanged(scene.id, phase: .active)
        #expect(backend.requests.isEmpty)
    }

    @Test func failedSnapshotReadPreservesTheSystemCardAndStoredBytes() async throws {
        let name = "ActivityReadFailure.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let damaged = Data("unreadable".utf8)
        defaults.set(damaged, forKey: MobileWorkspaceStore.restorationKey)
        let backend = Backend()
        let existing = TestActivity()
        existing.contentState = .snapshot([session()], focusedID: nil)
        let duplicate = TestActivity()
        backend.existing = [existing, duplicate]
        var dependencies = MobileAppDependencies.testing(defaults: defaults)
        dependencies.liveActivities = MobileLiveActivityController(services: backend.services)
        let app = try MobileAppModel(dependencies: dependencies)
        app.sceneChanged(UUID(), phase: .active)
        app.persistWorkspaceDescriptors()
        let scene = MobileSceneModel(app: app, sessionID: "window")
        scene.open(WorkspaceActivityAttributes.destinationURL(for: UUID()))
        for _ in 0..<20 { await Task.yield() }
        #expect(app.error != nil)
        #expect(existing.updates.isEmpty)
        #expect(!existing.ended && !duplicate.ended)
        #expect(defaults.data(forKey: MobileWorkspaceStore.restorationKey) == damaged)
    }

    @Test func singleWindowRestoresArchivedOwnersBeforeRecreatingDismissedActivity() async throws {
        let name = "DormantActivityRecords.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let seed = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Server", host: "example.invalid")
        seed.library.upsert(host)
        let records = [
            MobileWorkspaceDescriptor(hostID: host.id, title: "Shell", kind: .ssh),
            MobileWorkspaceDescriptor(hostID: host.id, title: "Files", kind: .sftp),
        ]
        let store = MobileWorkspaceStore(defaults: defaults)
        try store.save(.init(sessions: ["old-a": [records[0]], "old-b": [records[1]]]))
        let backend = Backend()
        backend.existing = [TestActivity(state: .dismissed)]
        var dependencies = MobileAppDependencies.testing(defaults: defaults)
        dependencies.container = seed.container
        dependencies.liveActivities = MobileLiveActivityController(services: backend.services)
        let app = try MobileAppModel(dependencies: dependencies)
        let scene = MobileSceneModel(app: app, sessionID: "owner")
        app.reconcileWorkspaceSessions(
            openSessionIDs: ["old-a", "old-b", "owner"], activeSessionID: "owner", supportsMultipleScenes: false)
        app.sceneChanged(scene.id, phase: .active)
        #expect(await eventually { backend.existing[0].ended })
        #expect(backend.requests.isEmpty)
        #expect(app.workspaces.isEmpty)
        try #require(scene.workspaceSession.savedWorkspaceDescriptors == records)
        #expect(try store.load().sessions["owner"] == records)
        // A late UIKit discard must not remove records that have already moved into the visible list.
        app.discardWorkspaceSessions(["old-a", "old-b"])

        scene.selectWorkspace(records[0].id)
        scene.activatePendingWorkspace()
        try #require(await eventually { backend.requests.count == 1 })
        #expect(backend.requests[0].workspaceCount == 2)
        #expect(backend.requests[0].connectedCount == 0)
        #expect(Set(backend.requests[0].sessions.map(\.id)) == Set(records.map(\.id)))
        #expect(scene.workspaceSession.recentWorkspaces == [records[1]])
        let workspace = try #require(scene.activeWorkspace)
        #expect(!workspace.sessionPersistence.requiresSelection)
        #expect(workspace.sessionPersistence.prompt == nil)
        let dormantURL = WorkspaceActivityAttributes.destinationURL(for: records[1].id)
        scene.open(dormantURL)
        #expect(!scene.isWorkspaceUnavailable)
        #expect(scene.activeWorkspace?.id == records[1].id)
        #expect(app.workspaceOwner(records[1].id) == "owner")
        scene.workspaceSession.close(records[0].id)
        #expect(await eventually { backend.created[0].updates.last?.sessions.map(\.id) == [records[1].id] })
        scene.workspaceSession.closeAll()
        #expect(await eventually { backend.created[0].ended })
        #expect(try store.load().sessions.values.allSatisfy(\.isEmpty))
        scene.open(dormantURL)
        #expect(scene.isWorkspaceUnavailable)
        #expect(app.workspaces.isEmpty)
        #expect(scene.workspaceSession.reopenLastClosed() == records[1].id)
        try #require(await eventually { backend.requests.count == 2 })
        #expect(backend.requests[1].sessions.map(\.id) == [records[1].id])
        #expect(backend.requests[1].connectedCount == 0)
        scene.workspaceSession.closeAll()
    }

    @Test func coldLaunchWithoutRecoveryEndsUnusableCard() async throws {
        let backend = Backend()
        let existing = TestActivity()
        let id = UUID()
        existing.contentState = .snapshot(
            [
                .init(
                    id: id, title: "Orphan", kind: "ssh", connected: true,
                    recovery: .init(sourceWorkspaceID: id, hostID: UUID(), kind: "ssh"))
            ], focusedID: id)
        backend.existing = [existing]
        var dependencies = MobileAppDependencies.testing()
        dependencies.liveActivities = MobileLiveActivityController(services: backend.services)
        let app = try MobileAppModel(dependencies: dependencies)
        app.sceneChanged(UUID(), phase: .active)
        #expect(await eventually { existing.ended })
        #expect(app.workspaces.isEmpty)
        #expect(backend.requests.isEmpty)
    }

    @Test func closingBeforeForegroundCancelsPendingStart() async {
        let backend = Backend()
        backend.canStart = false
        let controller = MobileLiveActivityController(services: backend.services)
        controller.start([session()])
        for _ in 0..<20 { await Task.yield() }
        controller.update([])
        backend.canStart = true
        controller.update([session()])
        let explicit = session()
        controller.start([explicit])
        #expect(await eventually { backend.requests.count == 1 })
        #expect(backend.requests.first?.sessions.map(\.id) == [explicit.id])
    }

    private func session() -> TermindIOS.WorkspaceActivityAttributes.Session {
        TermindIOS.WorkspaceActivityAttributes.Session(id: UUID(), title: "Server", kind: "ssh", connected: false)
    }

    private final class Backend {
        var canStart = true
        var existing: [TestActivity] = []
        var requests: [TermindIOS.WorkspaceActivityAttributes.ContentState] = []
        var created: [TestActivity] = []
        var services: MobileLiveActivityServices {
            MobileLiveActivityServices(
                activities: { (self.existing + self.created).filter { !$0.ended } },
                canStart: { self.canStart },
                request: {
                    self.requests.append($0)
                    let activity = TestActivity(focusedWorkspaceID: $0.focusedWorkspaceID)
                    self.created.append(activity)
                    return activity
                })
        }
    }

    private final class TestActivity: MobileWorkspaceActivity {
        let id = UUID().uuidString
        var state: ActivityState
        let focusedWorkspaceID: UUID?
        var updates: [TermindIOS.WorkspaceActivityAttributes.ContentState] = []
        var contentState: TermindIOS.WorkspaceActivityAttributes.ContentState?
        var ended = false
        var suspendsEnd = false
        var endContinuation: CheckedContinuation<Void, Never>?

        init(state: ActivityState = .active, focusedWorkspaceID: UUID? = nil) {
            self.state = state
            self.focusedWorkspaceID = focusedWorkspaceID
        }

        func update(_ state: TermindIOS.WorkspaceActivityAttributes.ContentState) async {
            contentState = state
            updates.append(state)
        }

        func end() async {
            if suspendsEnd {
                suspendsEnd = false
                await withCheckedContinuation { endContinuation = $0 }
            }
            ended = true
            state = .ended
        }
    }
}
