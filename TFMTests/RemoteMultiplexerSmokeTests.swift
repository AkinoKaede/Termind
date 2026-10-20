// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure
import Testing

/// Explicitly opt in with an isolated SSH fixture, never a normal user account.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TERMIND_MULTIPLEXER_FIXTURE"] != nil), .serialized)
@MainActor
struct RemoteMultiplexerSmokeTests {
    private struct Fixture: Decodable {
        let port: Int
        let hostFingerprint: String
        let privateKeyPath: String
    }

    @Test(.timeLimit(.minutes(2)), arguments: SessionPersistenceBackendID.supported)
    func nativeCreateRetryAttachDetachRestoreAndOwnedClose(backendID: SessionPersistenceBackendID) async throws {
        let path = try #require(ProcessInfo.processInfo.environment["TERMIND_MULTIPLEXER_FIXTURE"])
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let hostID = UUID()
        let control = SSHPTYChannel(output: { _ in }, exit: { _ in })
        await control.configureStartup { _ in nil }
        try await connect(control, fixture: fixture, hostID: hostID)
        try await control.releaseTerminalForControl()
        let execute = try await control.sessionCommandExecutor()
        let backend = try RemoteSessionBackendRegistry.live.backend(backendID, execute: execute)
        let token = UUID()
        let marker = "/tmp/termind-multiplexer-smoke-\(token.uuidString)"
        var owned: RemoteSessionReference?
        var client: SSHPTYChannel?
        do {
            _ = try await backend.probe()
            let before = try await backend.sessions()
            let session = try await backend.create(
                token: token, startupCommand: "cd /tmp; export TERMIND_SMOKE=yes; printf once >> '\(marker)'",
                shellIntegration: true, environment: [.init(variable: "SHELL", value: "/bin/bash")])
            let reference = RemoteSessionReference(
                backend: backendID, session: session, hostID: hostID, endpoint: "localhost:\(fixture.port)",
                username: "root", ownershipToken: token)
            owned = reference
            let retried = try await backend.create(
                token: token, startupCommand: "printf REPLAY >> '\(marker)'", shellIntegration: true, environment: [])
            #expect(backend.matches(reference, session: retried))
            let manual = RemoteSessionReference(
                backend: backendID, session: session, hostID: hostID, endpoint: reference.endpoint,
                username: reference.username, ownershipToken: nil)
            await #expect(throws: RemoteSessionFailure.ownershipMismatch) { try await backend.terminate(manual) }
            for _ in 0..<2 {
                let terminal = SSHPTYChannel(output: { _ in }, exit: { _ in })
                client = terminal
                await terminal.configureStartup { _ in
                    let launch = try backend.launch(reference, created: false)
                    return SSHPTYStartupPlan(command: launch.command, runtimeAttachment: launch.attachment)
                }
                try await connect(terminal, fixture: fixture, hostID: hostID)
                try await Task.sleep(for: .milliseconds(500))
                #expect(try await backend.sessions().contains { backend.matches(reference, session: $0) })
                #expect(try await execute("cat '\(marker)'").stdout == "once")
                await terminal.disconnect()
                client = nil
                #expect(try await backend.sessions().contains { backend.matches(reference, session: $0) })
            }
            try await backend.terminate(reference)
            owned = nil
            let after = try await backend.sessions()
            #expect(!after.contains { backend.matches(reference, session: $0) })
            // In particular, stopping/deleting our named Herdr session must not touch default.
            for existing in before {
                let external = RemoteSessionReference(
                    backend: backendID, session: existing, hostID: hostID, endpoint: reference.endpoint,
                    username: reference.username, ownershipToken: nil)
                #expect(after.contains { backend.matches(external, session: $0) })
            }
            _ = try await execute("rm -f '\(marker)'")
            await control.disconnect()
        } catch {
            if let client { await client.disconnect() }
            if let owned { try? await backend.terminate(owned) }
            _ = try? await execute("rm -f '\(marker)'")
            await control.disconnect()
            throw error
        }
    }

    private func connect(_ channel: SSHPTYChannel, fixture: Fixture, hostID: UUID) async throws {
        let key = try String(contentsOfFile: fixture.privateKeyPath, encoding: .utf8)
        try await channel.connect(
            using: SSHConnectionRequest(
                configuration: .init(
                    hostID: hostID, host: "127.0.0.1", port: fixture.port, username: "root",
                    credentials: [.privateKey(privateKey: SSHSecret(key), publicKey: nil, passphrase: nil)],
                    expectedHostKeys: [.init(algorithm: .ed25519, fingerprint: fixture.hostFingerprint)])),
            shellIntegrationEnabled: true, columns: 80, rows: 24)
    }
}
