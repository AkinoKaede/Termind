import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobileForwardingLifecycleTests {
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

@MainActor private final class ForwardingBackgroundTask: MobileBackgroundTaskManaging {
    var expiration: (@MainActor () -> Void)?
    func begin(expiration: @escaping @MainActor () -> Void) { self.expiration = expiration }
    func finish() { expiration = nil }
}
