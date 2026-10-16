import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import TermindRemoteInfrastructure

@Suite @MainActor
struct SSHTailscaleAuthenticationTests {
    @Test(arguments: [
        ("SSH-2.0-Tailscale", true),
        ("SSH-2.0-Tailscale_1.90 optional comment", true),
        ("SSH-2.0-OpenSSH_9.0 Tailscale", false),
        ("SSH-2.0-TailscaleProxy", false),
        ("host.ts.net", false),
        ("100.64.0.1", false),
    ])
    func detectionUsesOnlyTheServerSoftware(banner: String, expected: Bool) {
        #expect(SSHTailscaleAuthentication.isTailscaleServer(banner) == expected)
        #expect(!SSHTailscaleAuthentication.isTailscaleServer(nil))
    }

    @Test func serverSuccessDismissesApprovalWithoutAResponse() async throws {
        let controller = RemoteSessionConnectionController()
        let configuration = configuration()
        let host = Host(id: configuration.hostID, name: "Server", host: configuration.host)
        controller.journey.begin(host: host, route: [host], purpose: .sshSession, username: configuration.username)
        let exchange = SSHKeyboardInteractiveExchange(
            configuration: configuration, handler: { try await controller.answerKeyboardInteractive($0) })
        let probe = ApprovalProbe()
        let opening = start(exchange, probe)
        defer { exchange.cancel() }
        let challenge = try await wait(controller.keyboardAuthentication)
        #expect(challenge.username == "deploy")
        #expect(challenge.isTailscaleApproval)
        #expect(challenge.prompts.isEmpty)
        #expect(controller.journey.phase == .waiting)
        #expect(!controller.journey.plainTextLog.contains(challenge.instruction))
        probe.finish(.authenticated)
        #expect(try await opening.value == .authenticated)
        await exchange.waitForTailscaleApprovalDismissal()
        #expect(controller.keyboardAuthentication.pending.isEmpty)
        #expect(controller.journey.phase == .connecting)
        try exchange.checkTailscaleApproval()
    }

    @Test func duplicateBannersAndRetiredRequestsDoNotCancelTheNextApproval() async throws {
        let queue = SSHKeyboardInteractiveQueue()
        let exchange = SSHKeyboardInteractiveExchange(configuration: configuration(), handler: queue.handler)
        let probe = ApprovalProbe()
        let opening = start(exchange, probe)
        defer { exchange.cancel() }
        let first = try await wait(queue)
        let count = probe.readCount
        for _ in 0..<100 where probe.readCount < count + 3 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(queue.pending.map(\.id) == [first.id])
        probe.finish(.pending("Approve at https://login.example/second"))
        let second = try await wait(queue, excluding: first.id)
        #expect(second.connectionID == first.connectionID)
        #expect(second.round == 2)
        queue.cancel(first.id)
        probe.finish(.authenticated)
        #expect(try await opening.value == .authenticated)
        await exchange.waitForTailscaleApprovalDismissal()
        #expect(queue.pending.isEmpty)
    }

    @Test(arguments: [false, true])
    func cancellationClosesOnlyItsOwnPrompt(cancelConnection: Bool) async throws {
        let queue = SSHKeyboardInteractiveQueue()
        let exchange = SSHKeyboardInteractiveExchange(configuration: configuration(), handler: queue.handler)
        let other = SSHKeyboardInteractiveExchange(configuration: configuration(), handler: queue.handler)
        let probe = ApprovalProbe()
        let opening = start(exchange, probe)
        let challenge = try await wait(queue)
        try other.presentTailscaleApproval("Other connection")
        defer { other.endTailscaleApproval() }
        if cancelConnection { exchange.cancel() } else { queue.cancel(challenge.id) }
        await #expect(throws: CancellationError.self) { try await opening.value }
        await exchange.waitForTailscaleApprovalDismissal()
        let retained = try await wait(queue, excluding: challenge.id)
        #expect(retained.connectionID != challenge.connectionID)
        other.endTailscaleApproval()
        await other.waitForTailscaleApprovalDismissal()
        #expect(queue.pending.isEmpty)
    }

    @Test func deadlineIncludesTimeWithTheApprovalFormOpen() async throws {
        let queue = SSHKeyboardInteractiveQueue()
        let exchange = SSHKeyboardInteractiveExchange(configuration: configuration(), handler: queue.handler)
        let probe = ApprovalProbe()
        let opening = start(exchange, probe)
        _ = try await wait(queue)
        probe.advanceTime()
        await #expect {
            try await opening.value
        } throws: { error in
            if case TailscaleConfigurationError.approvalTimedOut = error { return true }
            return false
        }
        await exchange.waitForTailscaleApprovalDismissal()
        #expect(queue.pending.isEmpty)
    }

    @Test func disconnectDismissesApprovalAndDoesNotExposeTheBannerInErrors() async throws {
        let queue = SSHKeyboardInteractiveQueue()
        let exchange = SSHKeyboardInteractiveExchange(configuration: configuration(), handler: queue.handler)
        let probe = ApprovalProbe()
        let opening = start(exchange, probe)
        let challenge = try await wait(queue)
        probe.disconnect()
        await #expect {
            try await opening.value
        } throws: { error in
            if case TermindSSHError.disconnected = error { return true }
            return false
        }
        await exchange.waitForTailscaleApprovalDismissal()
        #expect(queue.pending.isEmpty)
        let failure = SSHTailscaleAuthentication.failure(code: -18).localizedDescription
        #expect(!failure.contains(challenge.instruction))
        #expect(!failure.contains("https://"))
        #expect(failure.contains("libssh2 -18"))
    }

    @Test func forbiddenInteractionAndMissingResponderFailWithoutShowingAForm() throws {
        let exchange = SSHKeyboardInteractiveExchange(
            configuration: configuration(),
            handler: { _ in
                Issue.record("Forbidden approval")
                return []
            },
            allowsUserInteraction: false)
        for candidate in [exchange, nil] {
            #expect(throws: SSHInteractionRequired.self) {
                try SSHTailscaleAuthentication.run(exchange: candidate) { .pending("Browser approval") }
            }
        }
    }

    @Test func methodsAndImmediateSuccessDoNotNeedAnInteractiveResponder() throws {
        for result in [SSHTailscaleAuthentication.Step.authenticated, .methods(["password", "publickey"])] {
            #expect(try SSHTailscaleAuthentication.run(exchange: nil) { result } == result)
        }
    }

    @Test func responderAcknowledgementDoesNotAuthorizeTheConnection() async throws {
        let exchange = SSHKeyboardInteractiveExchange(configuration: configuration(), handler: { _ in [] })
        let probe = ApprovalProbe()
        let opening = start(exchange, probe)
        for _ in 0..<100 where probe.readCount < 3 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(probe.readCount >= 3)
        probe.advanceTime()
        await #expect {
            try await opening.value
        } throws: { error in
            if case TailscaleConfigurationError.approvalTimedOut = error { return true }
            return false
        }
        await exchange.waitForTailscaleApprovalDismissal()
    }

    private func configuration() -> SSHConnectionConfiguration {
        .init(
            hostID: UUID(), host: "server.example", port: 22, username: "deploy", credentials: [], expectedHostKeys: [])
    }

    private func start(
        _ exchange: SSHKeyboardInteractiveExchange, _ probe: ApprovalProbe
    ) -> Task<SSHTailscaleAuthentication.Step, any Error> {
        Task.detached {
            try SSHTailscaleAuthentication.run(
                exchange: exchange, now: { probe.now }, pause: { Thread.sleep(forTimeInterval: 0.005) },
                step: { try probe.next() })
        }
    }

    private func wait(
        _ queue: SSHKeyboardInteractiveQueue, excluding: UUID? = nil
    ) async throws -> SSHKeyboardInteractiveChallenge {
        for _ in 0..<200 {
            if let challenge = queue.current, challenge.id != excluding { return challenge }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "Missing approval prompt", code: 1)
    }
}

private nonisolated final class ApprovalProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    private var reads = 0
    private var stopped = false
    private var step = SSHTailscaleAuthentication.Step.pending("Approve at https://login.example/ssh/check")
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    var readCount: Int { lock.withLock { reads } }
    func finish(_ step: SSHTailscaleAuthentication.Step) { lock.withLock { self.step = step } }
    func advanceTime() { lock.withLock { instant = instant.advanced(by: .seconds(601)) } }
    func disconnect() { lock.withLock { stopped = true } }
    func next() throws -> SSHTailscaleAuthentication.Step {
        try lock.withLock {
            reads += 1
            if stopped { throw TermindSSHError.disconnected }
            return step
        }
    }
}
