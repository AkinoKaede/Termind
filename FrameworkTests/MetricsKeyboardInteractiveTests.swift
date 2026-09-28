import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@Suite @MainActor
struct MetricsKeyboardInteractiveTests {
    @Test func multipleRoundsContinueOneConnectionWithoutRecordingAnswers() async throws {
        let sampler = JourneyMetricsSampler(rounds: [
            [], [.init(text: "Account", echo: true), .init(text: "Verification code", echo: false)],
            [.init(text: "Second code", echo: false)],
        ])
        let fixture = try Fixture(sampler: sampler)
        defer { fixture.model.shutdown() }
        let server = try fixture.add()
        try await wait { server.keyboardAuthentication.current?.round == 2 }
        let first = try #require(server.keyboardAuthentication.current)
        #expect(server.requiresAuthentication && server.showsConnectionJourney && server.needsAttention)
        #expect(!server.isConnecting)
        #expect(server.journey.phase == .waiting)
        #expect(server.journey.checkpoint?.kind == .authentication)
        #expect(fixture.model.snapshot(for: server.id)?.state == .awaitingAuthentication)
        #expect(server.status == String(localized: "Authentication required"))
        #expect(await sampler.attempts == 1)
        server.keyboardAuthentication.respond(first.id, answers: ["  deploy  ", "private-answer"])
        try await wait { server.keyboardAuthentication.current?.round == 3 }
        let second = try #require(server.keyboardAuthentication.current)
        #expect(second.id != first.id && second.connectionID == first.connectionID)
        server.keyboardAuthentication.respond(first.id, answers: ["stale", "stale"])
        #expect(server.keyboardAuthentication.current?.id == second.id)
        server.keyboardAuthentication.respond(second.id, answers: [""])
        server.keyboardAuthentication.respond(second.id, answers: ["duplicate"])
        try await wait { server.point != nil }
        #expect(await sampler.attempts == 1)
        #expect(await sampler.answers == [[], ["  deploy  ", "private-answer"], [""]])
        #expect(!server.needsAttention && !server.requiresAuthentication)
        #expect(fixture.model.snapshot(for: server.id)?.state == .live)
        #expect(!server.journey.plainTextLog.contains("private-answer"))
        #expect(!server.journey.plainTextLog.contains(first.instruction))
        #expect(!server.journey.plainTextLog.contains(first.prompts[1].text))
        #expect(fixture.library.identities.count == 1)
    }

    @Test func informationalRoundsFinishWithoutOpeningDetails() async throws {
        let sampler = JourneyMetricsSampler(rounds: [[], []])
        let fixture = try Fixture(sampler: sampler)
        defer { fixture.model.shutdown() }
        let server = try fixture.add()
        try await wait { server.point != nil }
        #expect(server.keyboardAuthentication.pending.isEmpty)
        #expect(!server.requiresAuthentication)
        #expect(await sampler.answers == [[], []])
        #expect(!server.journey.plainTextLog.contains(String(localized: "Waiting for authentication")))
    }

    @Test func monitorsSharingAJumpHostKeepTheirChallengesIndependent() async throws {
        let identity = Identity(name: "Deploy", username: "deploy")
        let jump = Host(name: "Gateway", host: "gateway.invalid", identityID: identity.id)
        let firstHost = Host(name: "First", host: "first.invalid", identityID: identity.id, jumpHostID: jump.id)
        let secondHost = Host(name: "Second", host: "second.invalid", identityID: identity.id, jumpHostID: jump.id)
        let library = HostLibraryModel(hosts: [jump, firstHost, secondHost], identities: [identity])
        try library.upsert(identity, passwordUpdate: .replace("test-only"))
        let sampler = JourneyMetricsSampler(challengeHost: jump)
        let model = ServerMetricsModel(
            hosts: library, preferences: JourneyMetricsPreferences(), makeSampler: { sampler })
        defer { model.shutdown() }
        #expect(model.add(firstHost))
        #expect(model.add(secondHost))
        let first = try #require(model.servers.first { $0.id == firstHost.id })
        let second = try #require(model.servers.first { $0.id == secondHost.id })
        try await wait { first.keyboardAuthentication.current != nil && second.keyboardAuthentication.current != nil }
        let a = try #require(first.keyboardAuthentication.current)
        let b = try #require(second.keyboardAuthentication.current)
        #expect(a.hostID == jump.id && b.hostID == jump.id)
        #expect(a.connectionID != b.connectionID)
        #expect(first.journey.checkpoint?.endpointIndex == 1)
        #expect(second.journey.checkpoint?.endpointIndex == 1)
        first.keyboardAuthentication.respond(b.id, answers: ["wrong-monitor"])
        #expect(first.keyboardAuthentication.current?.id == a.id)
        first.keyboardAuthentication.respond(a.id, answers: ["first-answer"])
        try await wait { first.point != nil }
        #expect(second.keyboardAuthentication.current?.id == b.id)
        model.setEnabled(false, for: second)
        #expect(second.keyboardAuthentication.pending.isEmpty)
        #expect(first.selection.enabled && first.collectionState == .live)
    }

    @Test(arguments: Retirement.allCases)
    func retiringAttemptsCancelsPromptsAndRejectsLateCallbacks(_ retirement: Retirement) async throws {
        let fixture = try Fixture()
        defer { fixture.model.shutdown() }
        let server = try fixture.add()
        try await wait { server.keyboardAuthentication.current != nil }
        let oldChallenge = try #require(server.keyboardAuthentication.current)
        let oldRequest = try #require(await fixture.sampler.requests.first)
        let retiredHandler = try #require(oldRequest.keyboardInteractive)
        switch retirement {
        case .pause: fixture.model.setEnabled(false, for: server)
        case .remove: fixture.model.remove(server.id)
        case .retry: fixture.model.retry(server)
        case .configuration:
            var host = fixture.host
            host.port += 1
            fixture.library.upsert(host)
            fixture.model.reconcile()
        case .suspend: fixture.model.suspend()
        case .shutdown: fixture.model.shutdown()
        }
        #expect(server.keyboardAuthentication.pending.isEmpty)
        #expect(!server.needsAttention)
        server.keyboardAuthentication.respond(oldChallenge.id, answers: ["stale"])
        await #expect(throws: CancellationError.self) { try await retiredHandler(oldChallenge) }
        if retirement == .suspend { fixture.model.resume() }
        if retirement == .pause { fixture.model.setEnabled(true, for: server) }
        if retirement == .remove {
            #expect(fixture.model.servers.isEmpty)
        } else if retirement == .shutdown {
            #expect(server.journey.phase == .hidden)
        } else {
            try await wait { server.keyboardAuthentication.current != nil }
            let next = try #require(server.keyboardAuthentication.current)
            #expect(next.id != oldChallenge.id)
            await #expect(throws: CancellationError.self) { try await retiredHandler(oldChallenge) }
            #expect(server.keyboardAuthentication.current?.id == next.id)
            #expect(server.journey.phase == .waiting && server.needsAttention)
            server.keyboardAuthentication.respond(next.id, answers: ["new-answer"])
            try await wait { server.point != nil }
            #expect(await fixture.sampler.answers == [["new-answer"]])
        }
    }

    @Test func transportCancellationRemovesThePendingPrompt() async throws {
        let fixture = try Fixture()
        defer { fixture.model.shutdown() }
        let server = try fixture.add()
        try await wait { server.keyboardAuthentication.current != nil }
        // A transport may cancel its responder independently of the monitor's worker.
        await fixture.sampler.cancelResponder()
        try await wait { server.keyboardAuthentication.pending.isEmpty && server.journey.phase != .waiting }
        #expect(server.needsAttention)
        #expect(server.journey.phase == .failed(server.status))
    }

    enum Retirement: CaseIterable { case pause, remove, retry, configuration, suspend, shutdown }

    private func wait(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition(), sourceLocation: sourceLocation)
    }

    private struct Fixture {
        let host: Host
        let library: HostLibraryModel
        let sampler: JourneyMetricsSampler
        let model: ServerMetricsModel

        init(sampler: JourneyMetricsSampler = JourneyMetricsSampler()) throws {
            self.sampler = sampler
            let identity = Identity(name: "Deploy", username: "deploy")
            host = Host(name: "Monitor", host: "metrics.invalid", identityID: identity.id)
            library = HostLibraryModel(hosts: [host], identities: [identity])
            try library.upsert(identity, passwordUpdate: .replace("test-only"))
            model = ServerMetricsModel(
                hosts: library, preferences: JourneyMetricsPreferences(), makeSampler: { sampler })
        }

        func add() throws -> ServerMetric {
            #expect(model.add(host))
            return try #require(model.servers.first)
        }
    }
}

@MainActor private final class JourneyMetricsPreferences: MetricsConfigurationStoring {
    func load() -> [MetricsSelection] { [] }
    func save(_ selections: [MetricsSelection]) {}
}

private actor JourneyMetricsSampler: MetricsSampling {
    let rounds: [[SSHKeyboardInteractiveChallenge.Prompt]]
    let challengeHost: Host?
    var attempts = 0
    var answers: [[String]] = []
    var requests: [SSHConnectionRequest] = []
    private var responder: Task<[String], any Error>?

    init(
        rounds: [[SSHKeyboardInteractiveChallenge.Prompt]] = [[.init(text: "Verification code", echo: false)]],
        challengeHost: Host? = nil
    ) {
        self.rounds = rounds
        self.challengeHost = challengeHost
    }

    func connect(_ configuration: SSHConnectionConfiguration) async throws {
        Issue.record("Metrics must supply the request containing its own authentication handler")
        throw CancellationError()
    }

    func connect(_ request: SSHConnectionRequest) async throws {
        attempts += 1
        requests.append(request)
        let handler = try #require(request.keyboardInteractive)
        let connectionID = UUID()
        for (index, prompts) in rounds.enumerated() {
            let challenge = SSHKeyboardInteractiveChallenge(
                connectionID: connectionID, hostID: challengeHost?.id ?? request.configuration.hostID,
                hostname: challengeHost?.host ?? request.configuration.host, port: request.configuration.port,
                username: request.configuration.username, round: index + 1, name: "PAM",
                instruction: "Private server instruction", prompts: prompts)
            let task = Task { try await handler(challenge) }
            responder = task
            let answer = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            answers.append(answer)
        }
    }

    func cancelResponder() { responder?.cancel() }
    func sample() async throws -> MetricsSample {
        .init(uptime: 1, cpu: [10, 0, 10, 80], memoryUsed: 50, memoryTotal: 100)
    }
    func gpu() async throws -> NvidiaSnapshot? { nil }
    func disconnect() async {}
}
