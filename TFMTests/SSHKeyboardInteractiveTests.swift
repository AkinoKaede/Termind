import Foundation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure
import Testing

@testable import Termind

/// Opt-in wire tests: see Scripts/ssh-authentication-fixture.py. All ordinary
/// queue, preparation and cancellation tests run without this external fixture.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TERMIND_SSH_FIXTURE"] != nil), .serialized)
struct SSHKeyboardInteractiveWireTests {
    @Test(arguments: ["none", "password", "kbd", "multi", "push", "password-mfa", "publickey-mfa", "kbd-password"])
    func execAuthenticatesOnTheSameTransport(_ mode: String) async throws {
        let fixture = try fixture()
        let recorder = WireChallengeRecorder()
        let request = request(mode: mode, fixture: fixture, handler: recorder.handler)
        let session = SSHExecSession()
        do {
            try await session.connect(using: request)
            let result = try await session.execute(
                "fixture", workingDirectory: nil, stdin: nil, timeout: 5, outputLimit: 1024, onOutput: nil
            )
            #expect(result.stdout == "fixture\n")
            #expect(result.exitCode == 0)
            let rounds = await recorder.challenges
            #expect(rounds.count == (mode == "multi" ? 2 : ["none", "password"].contains(mode) ? 0 : 1))
            if mode == "multi" {
                #expect(rounds[0].prompts.map(\.echo) == [true, false])
                #expect(rounds[0].connectionID == rounds[1].connectionID)
                #expect(rounds[0].id != rounds[1].id)
                #expect(rounds.map(\.round) == [1, 2])
            }
        } catch {
            await session.disconnect()
            throw error
        }
        await session.disconnect()
    }

    @Test func sftpUsesTheCoordinatorResponderWithoutAPassword() async throws {
        let fixture = try fixture()
        let recorder = WireChallengeRecorder()
        let coordinator = RemoteConnectionCoordinator(keyboardInteractive: recorder.handler)
        let client = try await coordinator.connectSFTP(using: request(mode: "kbd", fixture: fixture, handler: nil))
        do {
            let files = try await client.listDirectory(at: "/")
            #expect(files.map(\.name) == ["fixture.txt"])
            #expect(await recorder.challenges.count == 1)
        } catch {
            await client.disconnect()
            throw error
        }
        await client.disconnect()
    }

    @Test func terminalUsesInteractiveAuthentication() async throws {
        let fixture = try fixture()
        let recorder = WireChallengeRecorder()
        let session = SSHSessionActor(output: { _ in }, exit: { _ in })
        try await session.connect(
            using: request(mode: "kbd", fixture: fixture, handler: recorder.handler),
            shellIntegrationEnabled: false, columns: 80, rows: 24
        )
        #expect(await recorder.challenges.count == 1)
        await session.disconnect()
    }

    @Test func forwardingAuthenticatesAndReconnectionRequestsFreshAnswers() async throws {
        let fixture = try fixture()
        let recorder = WireChallengeRecorder()
        let session = SSHForwardingSession(connectionHandler: { _, _ in }, failureHandler: { _ in })
        let request = request(mode: "kbd", fixture: fixture, handler: recorder.handler)
        try await session.connect(request)
        await session.disconnect()
        try await session.connect(request)
        await session.disconnect()
        let challenges = await recorder.challenges
        #expect(challenges.count == 2)
        #expect(challenges[0].connectionID != challenges[1].connectionID)
    }

    @Test func jumpAndDestinationNeverShareAnswers() async throws {
        let fixture = try fixture()
        let recorder = WireChallengeRecorder()
        var request = request(mode: "multi", fixture: fixture, handler: recorder.handler)
        let jumpID = UUID()
        request.configuration.jumps = [
            SSHRouteHopConfiguration(
                id: jumpID, name: "Jump", host: "127.0.0.1", port: fixture.port,
                username: "kbd", credentials: [], expectedHostKeys: []
            )
        ]
        let session = SSHExecSession()
        try await session.connect(using: request)
        await session.disconnect()
        let challenges = await recorder.challenges
        #expect(challenges.map(\.hostID) == [jumpID, request.configuration.hostID, request.configuration.hostID])
        #expect(challenges[0].connectionID != challenges[1].connectionID)
    }

    @Test @MainActor func cancellingWhileWaitingClosesTheConnectionAndPrompt() async throws {
        let fixture = try fixture()
        let queue = SSHKeyboardInteractiveQueue()
        let request = request(mode: "kbd", fixture: fixture, handler: queue.handler)
        let session = SSHExecSession()
        let opening = Task { try await session.connect(using: request) }
        for _ in 0..<500 where queue.current == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(queue.current != nil)
        opening.cancel()
        await #expect(throws: CancellationError.self) { try await opening.value }
        for _ in 0..<100 where queue.current != nil { await Task.yield() }
        #expect(queue.current == nil)
        await session.disconnect()
    }

    @Test @MainActor func transferCancellationDismissesPendingAuthentication() async throws {
        let fixture = try fixture()
        let queue = SSHKeyboardInteractiveQueue()
        let coordinator = SFTPTransferCoordinator(
            store: HostLibraryModel(), clientFactory: { SFTPClient(keyboardInteractive: queue.handler) })
        var configuration = request(mode: "kbd", fixture: fixture, handler: nil).configuration
        configuration.expectedHostKeys = [.init(algorithm: .rsa, fingerprint: fixture.hostFingerprint)]
        let root = FileManager.default.temporaryDirectory
        coordinator.enqueue(
            direction: .download, batchID: UUID(), localURL: root.appending(path: UUID().uuidString),
            remotePath: "/fixture.txt", byteCount: 8, hostID: configuration.hostID,
            configuration: configuration, scopedRoot: root, overwrite: true)
        for _ in 0..<500 where queue.current == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(queue.current != nil)
        coordinator.cancelAll()
        await coordinator.waitForCancellation()
        #expect(queue.current == nil)
        #expect(coordinator.sftpTransfers.first?.state == .cancelled)
    }

    @Test func rejectedChallengeRetainsAuthenticationFailureClassification() async throws {
        let fixture = try fixture()
        let session = SSHExecSession()
        do {
            try await session.connect(using: request(mode: "kbd", fixture: fixture, handler: { _ in ["wrong"] }))
            Issue.record("Expected an authentication failure")
        } catch let error as TermindSSHError {
            #expect(error.shouldRequestAuthentication)
        }
        await session.disconnect()
    }

    private struct Fixture: Decodable {
        var port: Int
        var privateKey: String
        var hostFingerprint: String
    }

    private func fixture() throws -> Fixture {
        let path = try #require(ProcessInfo.processInfo.environment["TERMIND_SSH_FIXTURE"])
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private func request(
        mode: String, fixture: Fixture, handler: SSHKeyboardInteractiveHandler?
    ) -> SSHConnectionRequest {
        var credentials: [SSHCredentials] = []
        if ["password", "password-mfa", "kbd-password"].contains(mode) {
            credentials = [.password("fixture-password")]
        }
        if mode == "publickey-mfa" {
            credentials = [.privateKey(privateKey: fixture.privateKey, publicKey: nil, passphrase: nil)]
        }
        return SSHConnectionRequest(
            configuration: SSHConnectionConfiguration(
                hostID: UUID(), host: "127.0.0.1", port: fixture.port, username: mode,
                credentials: credentials, expectedHostKeys: []
            ), authorizeHostKey: { _ in .accept }, keyboardInteractive: handler
        )
    }
}

private actor WireChallengeRecorder {
    var challenges: [SSHKeyboardInteractiveChallenge] = []
    nonisolated var handler: SSHKeyboardInteractiveHandler { { try await self.answer($0) } }
    private func answer(_ challenge: SSHKeyboardInteractiveChallenge) throws -> [String] {
        challenges.append(challenge)
        return challenge.prompts.map { prompt in
            if prompt.echo { return "部署 user" }
            return prompt.text == "Optional" ? "" : "123456"
        }
    }
}
