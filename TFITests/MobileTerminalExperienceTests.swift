import Foundation
import GhosttyTerminal
import SwiftUI
import TermindApplication
import TermindDomain
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobileTerminalExperienceTests {
    @Test(arguments: [false, true], [false, true])
    func hiddenTerminalsHonorIndependentBellSwitchesOnlyWhileForegrounded(sound: Bool, vibration: Bool) async throws {
        var sounds = 0
        var vibrations = 0
        var dependencies = MobileAppDependencies.testing()
        dependencies.terminalEffects = MobileTerminalEffects(sound: { sounds += 1 }, vibration: { vibrations += 1 })
        let app = try MobileAppModel(dependencies: dependencies)
        let scene = MobileSceneModel(app: app, sessionID: UUID().uuidString)
        let workspace = makeWorkspace(app: app, kind: .ssh)
        scene.workspaceSession.acceptRecovery(
            .init(workspaces: [workspace], descriptors: [workspace.descriptor], order: [workspace.id]))
        app.workspaceWillOpen(workspace, close: { _ in })
        // Rebinding after a move must replace the old subscription.
        app.workspaceWillOpen(workspace, close: { _ in })
        defer { scene.workspaceSession.closeAll(rememberForReopen: false, authorized: true) }
        scene.selectedDestination = .settings
        app.terminalExperienceSettings.set(sound, for: \.bellSound)
        app.terminalExperienceSettings.set(vibration, for: \.bellVibration)
        app.sceneChanged(scene.id, phase: .active)
        workspace.terminal.terminalDidRingBell()
        #expect(await eventually { workspace.terminal.bellCount == 1 })
        #expect(sounds == (sound ? 1 : 0))
        #expect(vibrations == (vibration ? 1 : 0))

        app.sceneChanged(scene.id, phase: .background)
        workspace.terminal.terminalDidRingBell()
        #expect(await eventually { workspace.terminal.bellCount == 2 })
        app.sceneChanged(scene.id, phase: .active)
        #expect(sounds == (sound ? 1 : 0))
        #expect(vibrations == (vibration ? 1 : 0))
        app.terminalExperienceSettings.set(!sound, for: \.bellSound)
        app.terminalExperienceSettings.set(!vibration, for: \.bellVibration)
        workspace.terminal.terminalDidRingBell()
        #expect(await eventually { workspace.terminal.bellCount == 3 })
        #expect(sounds == 1)
        #expect(vibrations == 1)
        workspace.close()
        workspace.terminal.terminalDidRingBell()
        #expect(await eventually { workspace.terminal.bellCount == 4 })
        #expect(sounds == 1)
        #expect(vibrations == 1)
    }

    @Test func sftpNeverSubscribesToTerminalBellEvents() async throws {
        let app = try MobileAppModel(inMemory: true)
        let workspace = makeWorkspace(app: app, kind: .sftp)
        var rings = 0
        workspace.configureTerminalBell { rings += 1 }
        defer { workspace.close() }
        workspace.terminal.terminalDidRingBell()
        #expect(await eventually { workspace.terminal.bellCount == 1 })
        #expect(rings == 0)
    }

    @Test func screenAwakeFollowsCurrentNavigationAndLocalPreferenceWithoutRequiringConnection() throws {
        let app = try MobileAppModel(inMemory: true)
        let scene = MobileSceneModel(app: app, sessionID: UUID().uuidString)
        let terminal = makeWorkspace(app: app, kind: .mosh)
        let sftp = makeWorkspace(app: app, kind: .sftp)
        scene.workspaceSession.acceptRecovery(
            .init(
                workspaces: [terminal, sftp], descriptors: [terminal.descriptor, sftp.descriptor],
                order: [terminal.id, sftp.id]))
        defer { scene.workspaceSession.closeAll(rememberForReopen: false, authorized: true) }
        func wantsAwake(active: Bool = true) -> Bool {
            MobileScreenAwakeController.wantsAwake(
                preferences: app.terminalExperienceSettings.preferences, isActive: active,
                workspaceKind: scene.activeWorkspace?.descriptor.kind)
        }
        scene.selectedDestination = .workspaces
        scene.workspaceID = terminal.id
        #expect(!terminal.connected)
        #expect(wantsAwake())
        #expect(!wantsAwake(active: false))
        scene.workspaceID = sftp.id
        #expect(!wantsAwake())
        scene.workspaceID = terminal.id
        scene.selectedDestination = .settings
        #expect(!wantsAwake())
        scene.selectedDestination = .workspaces
        app.terminalExperienceSettings.set(false, for: \.keepScreenAwake)
        #expect(!wantsAwake())
        app.terminalExperienceSettings.set(true, for: \.keepScreenAwake)
        #expect(wantsAwake())
        scene.workspaceID = nil
        #expect(!wantsAwake())
    }

    @Test func sceneBackgroundAndRemovalReleaseOnlyTheirOwnScreenAwakeRequests() throws {
        var changes: [Bool] = []
        var dependencies = MobileAppDependencies.testing()
        dependencies.terminalEffects.setIdleTimerDisabled = { changes.append($0) }
        let app = try MobileAppModel(dependencies: dependencies)
        let first = UUID()
        let second = UUID()
        app.sceneChanged(first, phase: .active)
        app.sceneChanged(second, phase: .active)
        app.screenAwake.update(sceneID: first, wantsAwake: true)
        app.screenAwake.update(sceneID: first, wantsAwake: true)
        app.screenAwake.update(sceneID: second, wantsAwake: true)
        #expect(changes == [true])
        app.sceneChanged(first, phase: .background)
        #expect(changes == [true])
        app.removeScene(second)
        #expect(changes == [true, false])
        app.removeScene(first)
        #expect(changes == [true, false])

        let last = UUID()
        app.sceneChanged(last, phase: .active)
        app.screenAwake.update(sceneID: last, wantsAwake: true)
        app.removeScene(last)
        #expect(changes == [true, false, true, false])
    }

    @Test(
        arguments: [
            ConnectionPurpose.sshSession, .moshSession, .eternalTerminalSession, .telnetSession, .sftpChannel,
            .metrics, .portForwarding, .keyExport, .serialSession,
        ])
    func initialAndReconnectSuccessEachProduceOneFeedbackWithoutReadingBellPreferences(_ purpose: ConnectionPurpose) {
        let settings = TerminalExperienceSettingsModel()
        settings.set(false, for: \.bellVibration)
        let feedback = MobileConnectionSuccessFeedback()
        var successes = 0
        let effects = MobileTerminalEffects(connectionSucceeded: { successes += 1 })
        let host = Host(name: "Feedback", host: "test.invalid")
        let jump = Host(name: "Jump", host: "jump.invalid")
        let journey = ConnectionJourney()
        feedback.observe(journey, canPresent: { true }, feedback: effects.connectionSucceeded)
        defer { feedback.stop() }
        func begin() {
            journey.begin(host: host, route: [jump, host], purpose: purpose, username: nil)
        }
        begin()
        journey.receive(.connected(jump.id))
        journey.receive(.connected(host.id))
        #expect(successes == 0)
        journey.waitForAuthentication(at: host.id)
        journey.resume()
        journey.succeed()
        journey.succeed()
        #expect(successes == 1)
        journey.hide()
        begin()
        journey.fail("Disconnected")
        #expect(successes == 1)
        begin()
        journey.succeed()
        #expect(successes == 2)
        journey.hide()
    }

    @Test func multiplePresentationsAndRebindingDeliverOnlyOneFeedbackPerSuccess() {
        let first = MobileConnectionSuccessFeedback()
        let second = MobileConnectionSuccessFeedback()
        var successes = 0
        let host = Host(name: "Feedback", host: "test.invalid")
        let journey = ConnectionJourney()
        first.observe(journey, canPresent: { true }, feedback: { successes += 1 })
        second.observe(journey, canPresent: { true }, feedback: { successes += 1 })
        second.observe(journey, canPresent: { true }, feedback: { successes += 1 })
        defer {
            first.stop()
            second.stop()
        }
        journey.begin(host: host, route: [host], purpose: .metrics, username: nil)
        journey.succeed()
        #expect(successes == 1)
        first.stop()
        journey.begin(host: host, route: [host], purpose: .metrics, username: nil, mode: .reconnection)
        journey.succeed()
        #expect(successes == 2)
        journey.hide()
    }

    @Test(arguments: [false, true])
    func hiddenOrBackgroundSuccessIsConsumedWithoutReplay(_ background: Bool) throws {
        let app = try MobileAppModel(inMemory: true)
        let scene = MobileSceneModel(app: app, sessionID: UUID().uuidString)
        let workspace = makeWorkspace(app: app, kind: .ssh)
        scene.workspaceSession.acceptRecovery(
            .init(workspaces: [workspace], descriptors: [workspace.descriptor], order: [workspace.id]))
        defer { scene.workspaceSession.closeAll(rememberForReopen: false, authorized: true) }
        scene.selectedDestination = .workspaces
        scene.workspaceID = workspace.id
        app.sceneChanged(scene.id, phase: .active)
        let feedback = MobileConnectionSuccessFeedback()
        defer { feedback.stop() }
        var successes = 0
        let journey = workspace.journey
        func present() {
            feedback.observe(
                journey,
                canPresent: { scene.activeWorkspace?.id == workspace.id && app.isNotificationSceneActive(scene) },
                feedback: { successes += 1 })
        }
        present()
        let host = Host(name: "Feedback", host: "test.invalid")
        journey.begin(host: host, route: [host], purpose: .sshSession, username: nil)
        if background {
            app.sceneChanged(scene.id, phase: .inactive)
        } else {
            scene.selectedDestination = .settings
        }
        journey.succeed()
        app.sceneChanged(scene.id, phase: .active)
        scene.selectedDestination = .workspaces
        #expect(successes == 0)
        feedback.stop()
        present()
        journey.succeed()
        #expect(successes == 0)
        journey.begin(host: host, route: [host], purpose: .sshSession, username: nil)
        journey.succeed()
        #expect(successes == 1)
        journey.hide()
    }

    @Test(arguments: [ConnectionHistoryEntry.Kind.mosh, .eternalTerminal])
    func transportRecoveryUsesTheWorkspaceReadyBoundary(_ kind: ConnectionHistoryEntry.Kind) throws {
        let app = try MobileAppModel(inMemory: true)
        let workspace = makeWorkspace(app: app, kind: kind)
        defer { workspace.close() }
        var successes = 0
        let feedback = MobileConnectionSuccessFeedback()
        feedback.observe(workspace.journey, canPresent: { true }, feedback: { successes += 1 })
        defer { feedback.stop() }
        workspace.receiveTransportState(.recovering)
        #expect(successes == 0)
        workspace.receiveTransportState(.connected)
        #expect(successes == 1)
        workspace.receiveTransportState(.connected)
        #expect(successes == 1)
        workspace.receiveTransportState(.suspended)
        workspace.receiveTransportState(.recovering)
        workspace.receiveTransportState(.connected)
        #expect(successes == 2)
        feedback.stop()
        workspace.receiveTransportState(.recovering)
        workspace.receiveTransportState(.connected)
        #expect(successes == 2)
    }

    private func makeWorkspace(app: MobileAppModel, kind: ConnectionHistoryEntry.Kind) -> MobileWorkspace {
        MobileWorkspace(descriptor: .init(hostID: UUID(), title: "Feedback", kind: kind), hosts: app.library)
    }

}
