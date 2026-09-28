import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobileAgentForwardingInteractionTests {
    private func challenge() -> SSHKeyboardInteractiveChallenge {
        .init(
            connectionID: UUID(), hostID: UUID(), hostname: "fixture", port: 22,
            username: "user", round: 0, name: "Agent Forwarding", instruction: "Fixture key",
            prompts: [.init(text: "Passphrase", echo: false)])
    }
    @Test func inactiveSceneCannotRequestUnlock() async {
        let model = MobileAgentForwardingInteraction()
        await #expect(throws: SSHInteractionRequired.self) { try await model.request(challenge()) }
        #expect(model.current == nil)
    }
    @Test func requestsQueueAndBackgroundCancelsRemainingWaiters() async throws {
        let model = MobileAgentForwardingInteraction()
        model.isActive = true
        let first = challenge()
        let second = challenge()
        let a = Task { try await model.request(first) }
        for _ in 0..<100 where model.current == nil { await Task.yield() }
        let b = Task { try await model.request(second) }
        for _ in 0..<100 where model.pending.count < 2 { await Task.yield() }
        #expect(model.pending.map(\.id) == [first.id, second.id])
        model.respond(first.id, answers: ["fixture"])
        #expect(try await a.value == ["fixture"])
        #expect(model.current?.id == second.id)
        model.isActive = false
        await #expect(throws: CancellationError.self) { try await b.value }
        #expect(model.pending.isEmpty)
    }
    @Test func cancellationRemovesOnlyItsOwnRequest() async throws {
        let model = MobileAgentForwardingInteraction()
        model.isActive = true
        let first = challenge()
        let second = challenge()
        let a = Task { try await model.request(first) }
        for _ in 0..<100 where model.current == nil { await Task.yield() }
        let b = Task { try await model.request(second) }
        for _ in 0..<100 where model.pending.count < 2 { await Task.yield() }
        a.cancel()
        await #expect(throws: CancellationError.self) { try await a.value }
        #expect(model.current?.id == second.id)
        model.respond(second.id, answers: ["second"])
        #expect(try await b.value == ["second"])
    }
    @Test func securityKeySharesQueueAndBackgroundCancelsSigning() async throws {
        let model = MobileAgentForwardingInteraction()
        model.isActive = true
        let challenge = challenge()
        let unlock = Task { try await model.request(challenge) }
        while model.current == nil { await Task.yield() }
        let request = SecurityKeySigningRequest(
            hostID: UUID(), hostname: "fixture",
            credential: .init(credentialID: Data([1]), publicKeyX963: Data()), challenge: Data([1]), keyName: "YubiKey")
        let signing = Task { try await model.sign(request) }
        while model.pending.count < 2 { await Task.yield() }
        #expect(model.current?.id == challenge.id)
        model.respond(challenge.id, answers: ["passphrase"])
        _ = try await unlock.value
        guard case .securityKey(let current) = model.current else {
            model.cancelAll()
            Issue.record("Expected the queued security key form")
            return
        }
        #expect(current.keyName == "YubiKey")
        model.isActive = false
        await #expect(throws: CancellationError.self) { try await signing.value }
        #expect(model.pending.isEmpty)
    }

}
