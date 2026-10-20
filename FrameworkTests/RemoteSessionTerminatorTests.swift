// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure
import Testing

@Suite @MainActor
struct RemoteSessionTerminatorTests {
    @Test(arguments: [SessionPersistenceBackendID.tmux, .zellij, .zmx, .herdr])
    func transferredConnectionIsUsedWithoutOpeningAnother(backend: SessionPersistenceBackendID) async throws {
        let fixture = Fixture(backend: backend)
        let existing = Connection()
        let transfer = fixture.transfer(existing)
        let terminator = fixture.terminator { _ in
            Issue.record("An existing connection must be transferred, not replaced")
            throw TermindSSHError.disconnected
        }
        try await terminator.terminate(fixture.request(connection: transfer), hosts: fixture.hosts)
        await transfer.disconnect()
        #expect(await existing.commands == ["list", "terminate"])
        #expect(await existing.disconnects == 1)
    }

    @Test(arguments: [false, true])
    func deadTransferredConnectionGetsOneSilentReplacement(timedOut: Bool) async throws {
        let fixture = Fixture()
        let old = Connection(failing: "list", timedOut: timedOut)
        let replacement = Connection()
        var opens = 0
        let terminator = fixture.terminator { request in
            opens += 1
            #expect(await old.disconnects == 1)
            #expect(request.interactionPolicy == .forbidden)
            #expect(!request.permitsAgentForwarding)
            #expect(request.configuration.beforeConnect == nil)
            return replacement
        }
        try await terminator.terminate(fixture.request(connection: fixture.transfer(old)), hosts: fixture.hosts)
        #expect(opens == 1)
        #expect(await old.commands == ["list"])
        #expect(await replacement.commands == ["list", "terminate"])
        #expect(await replacement.disconnects == 1)
    }

    @Test func uncertainTerminationIsNeverRetried() async {
        let fixture = Fixture()
        let old = Connection(failing: "terminate")
        var opens = 0
        let terminator = fixture.terminator { _ in
            opens += 1
            return Connection()
        }
        await #expect(throws: (any Error).self) {
            try await terminator.terminate(fixture.request(connection: fixture.transfer(old)), hosts: fixture.hosts)
        }
        #expect(opens == 0)
        #expect(await old.commands == ["list", "terminate"])
        #expect(await old.disconnects == 1)
    }

    @Test func identityMismatchNeverTerminatesOrReconnects() async {
        let fixture = Fixture()
        let old = Connection(mismatched: true)
        var opens = 0
        let terminator = fixture.terminator { _ in
            opens += 1
            return Connection()
        }
        await #expect(throws: RemoteSessionFailure.ownershipMismatch) {
            try await terminator.terminate(fixture.request(connection: fixture.transfer(old)), hosts: fixture.hosts)
        }
        #expect(opens == 0)
        #expect(await old.commands == ["list"])
        #expect(await old.disconnects == 1)
    }

    @Test func disconnectedSessionAttemptsOnlyOneConnection() async {
        let fixture = Fixture()
        var opens = 0
        let terminator = fixture.terminator { request in
            opens += 1
            #expect(request.interactionPolicy == .forbidden)
            throw TermindSSHError.disconnected
        }
        await #expect(throws: (any Error).self) {
            try await terminator.terminate(fixture.request(), hosts: fixture.hosts)
        }
        #expect(opens == 1)
    }

    @Test(arguments: [false, true])
    func missingCredentialsOrChangedUsernameCannotOpenAConnection(missingCredentials: Bool) async {
        let fixture = Fixture()
        var snapshot = fixture.snapshot
        snapshot.target.authentication = .init(
            username: missingCredentials ? "user" : "someone-else",
            permitsNone: !missingCredentials, hasEphemeralSecret: missingCredentials)
        let terminator = fixture.terminator { _ in
            Issue.record("An unverified identity must not open a cleanup connection")
            return Connection()
        }
        await #expect(throws: (any Error).self) {
            try await terminator.terminate(
                .init(reference: fixture.reference, snapshot: snapshot), hosts: fixture.hosts)
        }
    }

    @Test func cancellingBeforeExecutionStillReleasesTransferredOwnership() async {
        let fixture = Fixture()
        let old = Connection()
        let closer = RemoteSessionCloseCoordinator { _ in Issue.record("Cancelled cleanup must not execute") }
        closer.enqueue(fixture.request(connection: fixture.transfer(old)))
        closer.cancelAll()
        await closer.waitUntilIdle()
        #expect(await old.commands.isEmpty)
        #expect(await old.disconnects == 1)
    }

    @Test func duplicateCloseReleasesBothConnectionsButTerminatesOnce() async {
        let fixture = Fixture()
        let first = Connection()
        let duplicate = Connection()
        let terminator = fixture.terminator { _ in
            Issue.record("Deduplication must keep the first transferred connection")
            throw TermindSSHError.disconnected
        }
        let closer = RemoteSessionCloseCoordinator {
            try await terminator.terminate($0, hosts: fixture.hosts)
        }
        let duplicateTransfer = fixture.transfer(duplicate)
        closer.enqueue(fixture.request(connection: fixture.transfer(first)))
        closer.enqueue(fixture.request(connection: duplicateTransfer))
        await closer.waitUntilIdle()
        await duplicateTransfer.disconnect()
        #expect(await first.commands == ["list", "terminate"])
        #expect(await duplicate.commands.isEmpty)
        #expect(await first.disconnects == 1)
        #expect(await duplicate.disconnects == 1)
    }

    private struct Fixture {
        let reference: RemoteSessionReference
        let snapshot: SSHAdditionalConnectionSnapshot
        let hosts = HostLibraryModel()

        init(backend: SessionPersistenceBackendID = .tmux) {
            let hostID = UUID()
            reference = .init(
                backend: backend, session: .init(id: "1", name: "Session", identity: Data([1])),
                hostID: hostID, endpoint: "example.invalid:22", username: "user", ownershipToken: UUID())
            snapshot = .init(
                target: .init(
                    id: hostID, name: "Host", host: "example.invalid", port: 22,
                    authentication: .init(username: "user", permitsNone: true), expectedHostKeys: [], proxy: nil))
        }

        func request(connection: RemoteSessionCloseConnection? = nil) -> RemoteSessionCloseRequest {
            .init(reference: reference, snapshot: snapshot, connection: connection)
        }

        func transfer(_ connection: Connection) -> RemoteSessionCloseConnection {
            .init(
                prepare: { { try await connection.run($0) } },
                release: { await connection.disconnect() })
        }

        func terminator(
            connect: @escaping (SSHConnectionRequest) async throws -> any SSHConnectionProtocol
        ) -> RemoteSessionTerminator {
            let reference = reference
            return RemoteSessionTerminator(
                connect: connect,
                backends: .init([reference.backend: { Backend(reference: reference, execute: $0) }]))
        }
    }

    private nonisolated struct Backend: RemoteSessionBackend {
        let reference: RemoteSessionReference
        let execute: RemoteSessionCommandExecutor
        var id: SessionPersistenceBackendID { reference.backend }
        var capabilities: RemoteSessionCapabilities { .init() }
        func sessions() async throws -> [RemoteSessionDescriptor] {
            let result = try await execute("list")
            return result.stdout == "mismatch" ? [] : [reference.session]
        }
        func matches(_ reference: RemoteSessionReference, session: RemoteSessionDescriptor) -> Bool {
            self.reference.hasSameIdentity(as: reference) && session == reference.session
        }
        func create(
            token: UUID, startupCommand: String?, shellIntegration: Bool, environment: [HostEnvironmentVariable]
        ) async throws -> RemoteSessionDescriptor {
            Issue.record("Cleanup must never create a session")
            throw RemoteSessionFailure.unsupported
        }
        func launch(_ attachment: RemoteSessionReference, created: Bool) throws -> RemoteSessionLaunch {
            Issue.record("Cleanup must never attach a terminal")
            throw RemoteSessionFailure.unsupported
        }
        func terminate(_ attachment: RemoteSessionReference) async throws { _ = try await execute("terminate") }
    }

    private actor Connection: SSHConnectionProtocol {
        let failing: String?
        let mismatched: Bool
        let timedOut: Bool
        var commands: [String] = []
        var disconnects = 0
        init(failing: String? = nil, mismatched: Bool = false, timedOut: Bool = false) {
            self.failing = failing
            self.mismatched = mismatched
            self.timedOut = timedOut
        }
        func connect(using configuration: SSHConnectionConfiguration) async throws {}
        func run(_ command: String) throws -> RemoteSessionCommandResult {
            commands.append(command)
            if command == failing {
                if timedOut { throw RemoteSessionFailure.timedOut }
                throw TermindSSHError.disconnected
            }
            return .init(stdout: mismatched ? "mismatch" : "", stderr: "", exitCode: 0)
        }
        func execute(
            _ command: String, workingDirectory: String?, stdin: SSHCommandInput?,
            timeout: TimeInterval, outputLimit: Int, onOutput: SSHExecOutputHandler?
        ) async throws -> SSHExecResult {
            let result = try run(command)
            return .init(
                stdout: result.stdout, stderr: "", exitCode: 0, stdoutTruncated: false, stderrTruncated: false)
        }
        func openSFTPChannel() async throws -> any SFTPChannelProtocol { throw TermindSSHError.disconnected }
        func disconnect() async { disconnects += 1 }
    }
}
