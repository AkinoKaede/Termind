import Foundation
import TermindApplication
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
}
