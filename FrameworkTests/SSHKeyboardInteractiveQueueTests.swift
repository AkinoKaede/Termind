import Foundation
import TermindApplication
import TermindDomain
import Testing

@Suite @MainActor
struct SSHKeyboardInteractiveQueueTests {
    @Test func concurrentConnectionsKeepAnswersSeparateAndIgnoreRetiredRequests() async throws {
        let queue = SSHKeyboardInteractiveQueue()
        let first = challenge()
        let second = challenge()
        let a = Task { try await queue.request(first) }
        let b = Task { try await queue.request(second) }
        await wait(queue, count: 2)
        queue.respond(first.id, answers: ["  验证码 \u{0}  "])
        #expect(try await a.value == ["  验证码 \u{0}  "])
        queue.respond(first.id, answers: ["stale"])
        queue.respond(second.id, answers: [])
        #expect(queue.pending.map(\.id) == [second.id])
        queue.respond(second.id, answers: [""])
        #expect(try await b.value == [""])
        #expect(queue.pending.isEmpty)
    }

    @Test func cancellationRemovesOnlyItsOwnPrompt() async throws {
        let queue = SSHKeyboardInteractiveQueue()
        let first = challenge()
        let second = challenge()
        let a = Task { try await queue.request(first) }
        let b = Task { try await queue.request(second) }
        await wait(queue, count: 2)
        a.cancel()
        await #expect(throws: CancellationError.self) { try await a.value }
        #expect(queue.pending.map(\.id) == [second.id])
        queue.cancel(second.id)
        await #expect(throws: CancellationError.self) { try await b.value }
    }

    @Test func informationalRoundsDoNotRequireAVisibleForm() async throws {
        let queue = SSHKeyboardInteractiveQueue()
        var challenge = challenge()
        challenge.prompts = []
        #expect(try await queue.request(challenge) == [])
        #expect(queue.pending.isEmpty)
    }

    @Test func disconnectCancelsTheJourneyWithoutLoggingChallenges() async throws {
        let controller = RemoteSessionConnectionController()
        let challenge = challenge()
        let host = Host(id: challenge.hostID, name: "Host", host: challenge.hostname)
        controller.journey.begin(host: host, route: [host], purpose: .sshSession, username: challenge.username)
        let task = Task { try await controller.answerKeyboardInteractive(challenge) }
        await wait(controller.keyboardAuthentication, count: 1)
        #expect(controller.journey.phase == .waiting)
        #expect(!controller.journey.plainTextLog.contains(challenge.instruction))
        controller.disconnect()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(controller.journey.phase == .hidden)
    }

    private func challenge() -> SSHKeyboardInteractiveChallenge {
        SSHKeyboardInteractiveChallenge(
            connectionID: UUID(), hostID: UUID(), hostname: "server.example", port: 22,
            username: "deploy", round: 1, name: "PAM", instruction: "Private server challenge",
            prompts: [.init(text: "OTP", echo: false)]
        )
    }

    private func wait(_ queue: SSHKeyboardInteractiveQueue, count: Int) async {
        for _ in 0..<1_000 where queue.pending.count != count { await Task.yield() }
        #expect(queue.pending.count == count)
    }
}
