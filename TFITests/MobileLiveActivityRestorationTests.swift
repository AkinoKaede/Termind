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

    @Test func coldLaunchEndsOldActivityAndOnlyLoadsRecentDescriptors() async throws {
        let suite = "termind.activity-restoration-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let seed = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Server", host: "example.invalid")
        seed.library.upsert(host)
        let descriptor = MobileWorkspaceDescriptor(hostID: host.id, title: "Saved", kind: .ssh)
        try MobileWorkspaceStore(defaults: defaults).save([descriptor])
        let backend = Backend()
        let existing = TestActivity(focusedWorkspaceID: descriptor.id)
        backend.existing = [existing]
        var dependencies = MobileAppDependencies.testing()
        dependencies.container = seed.container
        dependencies.workspaceStore = MobileWorkspaceStore(defaults: defaults)
        dependencies.liveActivities = MobileLiveActivityController(services: backend.services)
        let app = try MobileAppModel(dependencies: dependencies)
        app.sceneChanged(UUID(), phase: .active)

        #expect(await eventually { existing.ended })
        #expect(existing.updates.isEmpty)
        #expect(backend.requests.isEmpty)
        #expect(app.workspaces.isEmpty)
        #expect(app.recentWorkspaces == [descriptor])
        app.closeAll()
        #expect(await eventually { existing.ended })
    }

    @Test func coldLaunchWithoutSystemActivityDoesNotCreateOneUntilNewWorkspaceOpens() async throws {
        let suite = "termind.activity-restoration-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let seed = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Server", host: "example.invalid")
        seed.library.upsert(host)
        let descriptor = MobileWorkspaceDescriptor(hostID: host.id, title: "Saved", kind: .ssh)
        try MobileWorkspaceStore(defaults: defaults).save([descriptor])
        let backend = Backend()
        var dependencies = MobileAppDependencies.testing()
        dependencies.container = seed.container
        dependencies.workspaceStore = MobileWorkspaceStore(defaults: defaults)
        dependencies.liveActivities = MobileLiveActivityController(services: backend.services)
        let app = try MobileAppModel(dependencies: dependencies)
        let sceneID = UUID()
        app.sceneChanged(sceneID, phase: .active)
        app.sceneChanged(sceneID, phase: .background)
        app.sceneChanged(sceneID, phase: .active)
        _ = try #require(app.open(hostID: host.id, kind: .ssh))
        #expect(await eventually { backend.requests.count == 1 })
        #expect(backend.requests.map(\.workspaceCount) == [1])
        app.close(app.workspaces[0].id)
        #expect(app.recentWorkspaces == [descriptor])
        #expect(await eventually { backend.created.first?.ended == true })
        app.closeAll()
    }

    @Test func emptyColdLaunchEndsOrphanedActivity() async throws {
        let backend = Backend()
        let existing = TestActivity()
        backend.existing = [existing]
        var dependencies = MobileAppDependencies.testing()
        dependencies.liveActivities = MobileLiveActivityController(services: backend.services)
        let app = try MobileAppModel(dependencies: dependencies)
        #expect(app.workspaces.isEmpty)
        #expect(await eventually { existing.ended })
        #expect(backend.requests.isEmpty)
    }

    @Test(arguments: [false, true])
    func oldLinkRestoresBeforeOrAfterForegroundAndDoesNotResurrectDismissedCard(linkFirst: Bool) async throws {
        let suite = "termind.activity-link-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let seed = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Server", host: "example.invalid")
        seed.library.upsert(host)
        let descriptor = MobileWorkspaceDescriptor(hostID: host.id, title: "Saved", kind: .ssh)
        try MobileWorkspaceStore(defaults: defaults).save([descriptor])
        let backend = Backend()
        backend.canStart = false
        let old = TestActivity(focusedWorkspaceID: descriptor.id)
        backend.existing = [old]
        var dependencies = MobileAppDependencies.testing()
        dependencies.container = seed.container
        dependencies.workspaceStore = MobileWorkspaceStore(defaults: defaults)
        dependencies.liveActivities = MobileLiveActivityController(services: backend.services)
        let app = try MobileAppModel(dependencies: dependencies)
        defer { app.closeAll() }
        let scene = MobileSceneModel(app: app)
        #expect(await eventually { old.ended })
        if linkFirst {
            scene.open(descriptor.destinationURL)
            scene.activatePendingWorkspace()
            // Drain the serial queue while requests are disallowed.
            for _ in 0..<20 { await Task.yield() }
            #expect(backend.requests.isEmpty)
        }
        backend.canStart = true
        app.sceneChanged(scene.id, phase: .active)
        if !linkFirst {
            scene.open(descriptor.destinationURL)
            scene.activatePendingWorkspace()
        }
        #expect(await eventually { backend.requests.count == 1 })
        #expect(backend.requests.first?.sessions.map(\.id) == [descriptor.id])
        #expect(scene.workspaceID == descriptor.id)
        #expect(app.connectionHistory.entries().count == 1)
        let created = try #require(backend.created.first)
        created.state = .dismissed
        app.sceneChanged(scene.id, phase: .background)
        app.sceneChanged(scene.id, phase: .active)
        // A barrier proves earlier foreground updates have run without creating a second activity.
        app.closeAll()
        let next = session()
        app.liveActivities.start([next])
        #expect(await eventually { backend.requests.count == 2 })
        #expect(backend.requests.last?.sessions.map(\.id) == [next.id])
        app.liveActivities.update([])
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
        var ended = false
        var suspendsEnd = false
        var endContinuation: CheckedContinuation<Void, Never>?

        init(state: ActivityState = .active, focusedWorkspaceID: UUID? = nil) {
            self.state = state
            self.focusedWorkspaceID = focusedWorkspaceID
        }

        func update(_ state: TermindIOS.WorkspaceActivityAttributes.ContentState) async {
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
