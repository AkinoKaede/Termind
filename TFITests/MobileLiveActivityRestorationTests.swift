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
        controller.update([first, focused])

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

    @Test func removedRecoveryCannotBeReadBackFromStaleSystemContent() {
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
        #expect(controller.recovery(for: id) == recovery)
        controller.remove(id)
        #expect(controller.recovery(for: id) == nil)
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

    @Test func coldLaunchRetainsRecoverableSystemActivityWithoutConnecting() async throws {
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
        let backend = Backend()
        let existing = TestActivity(focusedWorkspaceID: oldID)
        existing.contentState = .snapshot([card], focusedID: oldID)
        backend.existing = [existing]
        var dependencies = MobileAppDependencies.testing()
        dependencies.container = seed.container
        dependencies.liveActivities = MobileLiveActivityController(services: backend.services)
        let app = try MobileAppModel(dependencies: dependencies)
        app.sceneChanged(UUID(), phase: .active)
        #expect(await eventually { !existing.updates.isEmpty })
        #expect(!existing.ended)
        #expect(existing.updates.last?.connectedCount == 0)
        #expect(app.workspaces.isEmpty)
        #expect(backend.requests.isEmpty)
        let scene = MobileSceneModel(app: app, sessionID: "new")
        scene.open(card.destinationURL)
        let rebuilt = try #require(app.workspaces.first)
        #expect(rebuilt.id != oldID)
        #expect(rebuilt.sessionPersistence.requiresSelection)
        #expect(rebuilt.sessionPersistence.attachment == reference)
        scene.workspaceSession.closeAll()
        #expect(await eventually { existing.ended })
        app.sceneChanged(scene.id, phase: .active)
        #expect(backend.requests.isEmpty)
    }

    @Test func coldLaunchWithoutRecoveryEndsUnusableCard() async throws {
        let backend = Backend()
        let existing = TestActivity()
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

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private final class Backend {
        var canStart = true
        var existing: [TestActivity] = []
        var requests: [TermindIOS.WorkspaceActivityAttributes.ContentState] = []
        var created: [TestActivity] = []
        var services: MobileLiveActivityServices {
            MobileLiveActivityServices(
                activities: { self.existing },
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
                await withCheckedContinuation { endContinuation = $0 }
            }
            ended = true
            state = .ended
        }
    }
}
