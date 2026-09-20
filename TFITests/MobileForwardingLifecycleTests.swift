import Foundation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobileForwardingLifecycleTests {
    @Test func backgroundExpirationStopsEstablishedRecoveryAndForegroundCannotReviveIt() async throws {
        let background = ForwardingBackgroundTask()
        var dependencies = MobileAppDependencies.testing(background: background)
        var sessions: [MobileRecoverySession] = []
        dependencies.makeForwardings = { library in
            PortForwardingController(
                hosts: library,
                makeConnection: { _, failure in
                    let session = MobileRecoverySession(failure: failure)
                    sessions.append(session)
                    return session
                },
                makeReconnectController: {
                    SessionReconnectController(sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
                })
        }
        let app = try MobileAppModel(dependencies: dependencies)
        let identity = Identity(name: "User", username: "user")
        let host = TermindDomain.Host(
            name: "Server", host: "server.invalid", identityID: identity.id,
            portForwardingMaxConnections: 12)
        app.library.upsert(identity)
        app.library.upsert(host)
        let rule = PortForwardingRule(hostID: host.id)
        try app.forwardingLibrary.save(rule)
        let scene = UUID()
        defer {
            app.forwardings.stopAll()
            app.removeScene(scene)
            app.outbox.stop()
        }
        app.sceneChanged(scene, phase: .active)
        app.forwardings.start(rule.id)
        try await wait { app.forwardings.state(for: rule.id) == .running(activeConnections: 0) }
        let context = try #require(app.forwardings.connection(for: rule.id))
        #expect(context.poolStatus == .single)
        #expect(sessions.count == 1)
        await sessions[0].fail()
        try await wait { app.forwardings.state(for: rule.id) == .reconnecting }
        #expect(!context.journey.isPresented)
        app.sceneChanged(scene, phase: .background)
        let expire = try #require(background.expiration)
        expire()
        app.sceneChanged(scene, phase: .active)
        context.connection.reconnect.retryNow()
        #expect(app.forwardings.state(for: rule.id) == .stopped)
        #expect(app.forwardings.connection(for: rule.id) == nil)
        #expect(context.connection.reconnectState == nil)
        #expect(sessions.count == 1)
    }

    @Test func backgroundExpirationCancelsSharedAuthenticationAndForegroundNeverRestartsIt() async throws {
        let background = ForwardingBackgroundTask()
        let app = try MobileAppModel(inMemory: true, background: background)
        let host = TermindDomain.Host(name: "Server", host: "server.invalid")
        app.library.upsert(host)
        let rule = PortForwardingRule(hostID: host.id)
        try app.forwardingLibrary.save(rule)
        let firstScene = UUID()
        let secondScene = UUID()
        defer {
            app.forwardings.stopAll()
            app.removeScene(firstScene)
            app.removeScene(secondScene)
        }
        app.sceneChanged(firstScene, phase: .active)
        app.sceneChanged(secondScene, phase: .active)
        app.forwardings.start(rule.id)
        try await wait { app.forwardings.connection(for: rule.id)?.authenticationPrompt != nil }
        let context = try #require(app.forwardings.connection(for: rule.id))
        app.sceneChanged(firstScene, phase: .background)
        #expect(background.expiration == nil)
        #expect(context.authenticationPrompt != nil)
        app.sceneChanged(secondScene, phase: .background)
        let expire = try #require(background.expiration)
        expire()
        #expect(context.authenticationPrompt == nil)
        #expect(app.forwardings.state(for: rule.id) == .stopped)
        app.sceneChanged(secondScene, phase: .active)
        #expect(app.forwardings.connection(for: rule.id) == nil)
        #expect(app.forwardings.state(for: rule.id) == .stopped)
    }

    @Test func syncedRulesAndJumpHostChangesStopAffectedRunsWithoutRestarting() async throws {
        let app = try MobileAppModel(inMemory: true)
        defer { app.forwardings.stopAll() }
        let jump = TermindDomain.Host(name: "Jump", host: "jump.invalid")
        let host = TermindDomain.Host(name: "Server", host: "server.invalid", jumpHostID: jump.id)
        app.library.upsert(jump)
        app.library.upsert(host)
        var rule = PortForwardingRule(hostID: host.id)
        try app.forwardingLibrary.save(rule)
        app.forwardings.start(rule.id)
        try await wait { app.forwardings.connection(for: rule.id)?.authenticationPrompt != nil }
        rule.bindPort = 9090
        app.applyRemoteVault(
            .init(hosts: [jump, host], portForwardings: [rule]),
            keys: [VaultRecordKey(kind: .portForwarding, id: rule.id)])
        #expect(app.forwardings.state(for: rule.id) == .stopped)
        #expect(app.forwardings.connection(for: rule.id) == nil)
        app.forwardings.start(rule.id)
        try await wait { app.forwardings.connection(for: rule.id)?.authenticationPrompt != nil }
        var changedJump = jump
        changedJump.port = 2222
        app.applyRemoteVault(
            .init(hosts: [changedJump, host], portForwardings: [rule]),
            keys: [VaultRecordKey(kind: .host, id: jump.id)])
        #expect(app.forwardings.state(for: rule.id) == .stopped)
        #expect(app.forwardings.connection(for: rule.id) == nil)
        app.forwardings.start(rule.id)
        try await wait { app.forwardings.connection(for: rule.id)?.authenticationPrompt != nil }
        app.deleteHost(jump.id)
        #expect(app.forwardings.state(for: rule.id) == .stopped)
        #expect(app.forwardings.connection(for: rule.id) == nil)
        app.outbox.stop()
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CocoaError(.coderInvalidValue)
    }
}

private actor MobileRecoverySession: SSHForwardingConnectionProtocol {
    let failure: SSHForwardingConnection.FailureHandler
    init(failure: @escaping SSHForwardingConnection.FailureHandler) { self.failure = failure }
    func connect(_ request: SSHConnectionRequest, progress: SSHRouteProgressHandler?) {}
    func start(_ rule: PortForwardingRule, generation: UUID) {}
    func stop(_ id: UUID) {}
    func disconnect() {}
    func fail() { failure("Connection lost") }
}

@MainActor private final class ForwardingBackgroundTask: MobileBackgroundTaskManaging {
    var expiration: (@MainActor () -> Void)?
    func begin(expiration: @escaping @MainActor () -> Void) { self.expiration = expiration }
    func finish() { expiration = nil }
}
