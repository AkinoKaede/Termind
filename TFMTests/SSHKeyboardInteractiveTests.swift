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
        let connection = SSHConnection()
        do {
            try await connection.connect(using: request)
            let result = try await connection.execute(
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
            await connection.disconnect()
            throw error
        }
        await connection.disconnect()
    }

    @Test func sftpUsesTheCoordinatorResponderWithoutAPassword() async throws {
        let fixture = try fixture()
        let recorder = WireChallengeRecorder()
        let coordinator = RemoteConnectionCoordinator(keyboardInteractive: recorder.handler)
        let client = try await coordinator.connectSFTP(using: request(mode: "kbd", fixture: fixture, handler: nil))
        do {
            let files = try await client.listDirectory(at: "/")
            #expect(files.map(\.name) == ["fixture.txt"])
            let localURL = FileManager.default.temporaryDirectory
                .appending(path: "termind-sftp-version-\(UUID().uuidString.lowercased())")
            defer { try? FileManager.default.removeItem(at: localURL) }
            let resume = SFTPResumeState(capturesFileVersion: true)
            try await client.downloadFile(
                from: "/fixture.txt", to: localURL, overwrite: false,
                cancellation: TransferCancellationToken(), resume: resume,
                progress: { _ in })
            #expect(resume.snapshot.committedVersion != nil)
            #expect(await recorder.challenges.count == 1)
        } catch {
            await client.disconnect()
            throw error
        }
        await client.disconnect()
    }

    @Test func multiplexedConnectionRunsExecAndCompleteSFTPOnOneAuthentication() async throws {
        let fixture = try fixture()
        let recorder = WireChallengeRecorder()
        let connection = SSHConnection()
        try await connection.connect(
            using: request(mode: "kbd", fixture: fixture, handler: recorder.handler))
        let client = try await connection.openSFTPChannel()
        do {
            async let command = connection.execute(
                "fixture", workingDirectory: nil, stdin: nil, timeout: 5,
                outputLimit: 1_024, onOutput: nil)
            async let listing = client.listDirectory(at: "/")
            #expect(try await command.stdout == "fixture\n")
            #expect(try await listing.map(\.name).contains("fixture.txt"))
            #expect(try await client.readFile(at: "/fixture.txt", maximumBytes: 100) == Data("fixture\n".utf8))

            let path = "/agent-shared-\(UUID().uuidString.lowercased()).txt"
            try await client.writeFile(Data("shared\n".utf8), at: path, overwrite: false)
            #expect(try await client.readFile(at: path, maximumBytes: 100) == Data("shared\n".utf8))
            let stream = try await client.openDownloadStream(
                at: path, maximumBytes: 100, cancellation: TransferCancellationToken())
            #expect(try await stream.readChunk() == Data("shared\n".utf8))
            #expect(try await stream.readChunk() == nil)
            try await stream.close()
            try await client.removeFile(at: path)
            #expect(await recorder.challenges.count == 1)
        } catch {
            await client.disconnect()
            await connection.disconnect()
            throw error
        }
        await client.disconnect()
        await connection.disconnect()
    }

    @Test func terminalUsesInteractiveAuthentication() async throws {
        let fixture = try fixture()
        let recorder = WireChallengeRecorder()
        let ptyChannel = SSHPTYChannel(output: { _ in }, exit: { _ in })
        try await ptyChannel.connect(
            using: request(mode: "kbd", fixture: fixture, handler: recorder.handler),
            shellIntegrationEnabled: false, columns: 80, rows: 24
        )
        #expect(await recorder.challenges.count == 1)
        await ptyChannel.disconnect()
    }

    @Test func terminalSFTPChannelReusesAuthenticationAndOutlivesThePTY() async throws {
        let fixture = try fixture()
        let recorder = WireChallengeRecorder()
        let ptyChannel = SSHPTYChannel(output: { _ in }, exit: { _ in })
        try await ptyChannel.connect(
            using: request(mode: "kbd", fixture: fixture, handler: recorder.handler),
            shellIntegrationEnabled: false, columns: 80, rows: 24
        )
        let client = try await ptyChannel.openSFTPChannel()
        #expect(try await client.listDirectory(at: "/").map(\.name) == ["fixture.txt"])
        #expect(await recorder.challenges.count == 1)

        await ptyChannel.disconnect()
        #expect(try await client.attributes(at: "/fixture.txt")?.size == 8)
        #expect(await recorder.challenges.count == 1)
        await client.disconnect()
    }

    @Test func forwardingAuthenticatesAndReconnectionRequestsFreshAnswers() async throws {
        let fixture = try fixture()
        let recorder = WireChallengeRecorder()
        let session = SSHForwardingConnection(connectionHandler: { _, _, _ in }, failureHandler: { _ in })
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
        let session = SSHConnection()
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
        let session = SSHConnection()
        let opening = Task { try await session.connect(using: request) }
        for _ in 0..<500 where queue.current == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(queue.current != nil)
        opening.cancel()
        await #expect(throws: CancellationError.self) { try await opening.value }
        for _ in 0..<100 where queue.current != nil { await Task.yield() }
        #expect(queue.current == nil)
        await session.disconnect()
    }

    @Test @MainActor func aTransferWithoutAnAuthenticatedPrimaryCannotOpenAnAuthenticationForm() async throws {
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
        await coordinator.waitForCancellation()
        #expect(queue.current == nil)
        guard case .failed = coordinator.sftpTransfers.first?.state else {
            Issue.record("An interactive-only route must fail without opening a form")
            return
        }
    }

    @Test func rejectedChallengeRetainsAuthenticationFailureClassification() async throws {
        let fixture = try fixture()
        let session = SSHConnection()
        do {
            try await session.connect(using: request(mode: "kbd", fixture: fixture, handler: { _ in ["wrong"] }))
            Issue.record("Expected an authentication failure")
        } catch let error as TermindSSHError {
            #expect(error.shouldRequestAuthentication)
        }
        await session.disconnect()
    }

    @Test(arguments: ["none", "password", "push", "publickey", "encrypted-key"])
    func silentSFTPConnectsWithoutApplicationForms(_ mode: String) async throws {
        let fixture = try fixture()
        let recorder = WireChallengeRecorder()
        let coordinator = RemoteConnectionCoordinator(keyboardInteractive: recorder.handler)
        var request = request(mode: mode, fixture: fixture, handler: recorder.handler)
        request.configuration.expectedHostKeys = [.init(algorithm: .rsa, fingerprint: fixture.hostFingerprint)]
        request.interactionPolicy = .forbidden
        let client = try await coordinator.connectSFTP(using: request)
        #expect(await recorder.challenges.isEmpty)
        await client.disconnect()
    }

    @Test(arguments: ["kbd", "multi", "password-mfa", "publickey-mfa"])
    func silentSFTPRejectsMFAWithoutUsingAnExplicitOrFallbackResponder(_ mode: String) async throws {
        let fixture = try fixture()
        let recorder = WireChallengeRecorder()
        let coordinator = RemoteConnectionCoordinator(keyboardInteractive: recorder.handler)
        var request = request(mode: mode, fixture: fixture, handler: recorder.handler)
        request.configuration.expectedHostKeys = [.init(algorithm: .rsa, fingerprint: fixture.hostFingerprint)]
        request.interactionPolicy = .forbidden
        await #expect(throws: SSHInteractionRequired.self) {
            _ = try await coordinator.connectSFTP(using: request)
        }
        #expect(await recorder.challenges.isEmpty)
    }

    @Test func silentPolicyAlsoAppliesToJumpAuthenticationAndUnknownHostKeys() async throws {
        let fixture = try fixture()
        let recorder = WireChallengeRecorder()
        let coordinator = RemoteConnectionCoordinator(keyboardInteractive: recorder.handler)
        var request = request(mode: "none", fixture: fixture, handler: recorder.handler)
        request.interactionPolicy = .forbidden
        await #expect(throws: SSHInteractionRequired.self) {
            _ = try await coordinator.connectSFTP(using: request)
        }
        let key = SSHHostKeyIdentity(algorithm: .rsa, fingerprint: fixture.hostFingerprint)
        request.configuration.expectedHostKeys = [key]
        request.configuration.jumps = [
            SSHRouteHopConfiguration(
                id: UUID(), name: "Jump", host: "127.0.0.1", port: fixture.port,
                username: "kbd", credentials: [], expectedHostKeys: [key])
        ]
        await #expect(throws: SSHInteractionRequired.self) {
            _ = try await coordinator.connectSFTP(using: request)
        }
        #expect(await recorder.challenges.isEmpty)
    }

    @Test func singleConnectionCopyDoesNotDeadlockAndChecksTheSourceSize() async throws {
        let fixture = try fixture()
        let coordinator = RemoteConnectionCoordinator()
        var request = request(mode: "none", fixture: fixture, handler: nil)
        request.configuration.expectedHostKeys = [.init(algorithm: .rsa, fingerprint: fixture.hostFingerprint)]
        request.interactionPolicy = .forbidden
        let client = try await coordinator.connectSFTP(using: request)
        do {
            try await client.copyFile(
                from: "/fixture.txt", to: "/copy.txt", on: client, byteCount: 8,
                overwrite: false, cancellation: TransferCancellationToken(), progress: { _ in })
            #expect(try await client.readFile(at: "/copy.txt", maximumBytes: 100) == Data("fixture\n".utf8))
            await #expect(throws: SFTPResumeFailure.self) {
                try await client.copyFile(
                    from: "/fixture.txt", to: "/wrong-size.txt", on: client, byteCount: 9,
                    overwrite: false, cancellation: TransferCancellationToken(), progress: { _ in })
            }
            #expect(try await client.attributes(at: "/wrong-size.txt") == nil)
        } catch {
            await client.disconnect()
            throw error
        }
        await client.disconnect()
    }

    private struct Fixture: Decodable {
        var port: Int
        var privateKey: String
        var encryptedPrivateKey: String
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
        if mode == "publickey-mfa" || mode == "publickey" {
            credentials = [.privateKey(privateKey: fixture.privateKey, publicKey: nil, passphrase: nil)]
        }
        if mode == "encrypted-key" {
            credentials = [
                .privateKey(
                    privateKey: fixture.encryptedPrivateKey, publicKey: nil, passphrase: "fixture-passphrase")
            ]
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
