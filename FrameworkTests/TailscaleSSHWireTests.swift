// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import CSSH2
import Darwin
import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import TermindRemoteInfrastructure

/// Transport behavior shared by macOS and iOS, exercised against a real SSH/SFTP fixture.
@Suite(
    .enabled(
        if: ProcessInfo.processInfo.environment["TERMIND_SSH_FIXTURE"] != nil
            || ProcessInfo.processInfo.environment["TERMIND_SSH_FIXTURE_JSON"] != nil), .serialized
)
nonisolated struct TailscaleSSHWireTests {
    @Test func noneAuthenticationSupportsSFTPAndAdditionalConnections() async throws {
        let fixture = try Fixture.load()
        let network = LoopbackTailnet(port: fixture.port, fingerprint: fixture.hostFingerprint)
        for _ in 0..<2 {
            var configuration = SSHConnectionConfiguration(
                hostID: UUID(), host: "fixture.test.ts.net", port: 22,
                username: "none", credentials: [], expectedHostKeys: [])
            configuration.network = network
            configuration.tailscaleNodeID = "fixture-node"
            let connection = SSHConnection()
            do {
                try await connection.connect(
                    using: SSHConnectionRequest(
                        configuration: configuration,
                        interactionPolicy: .forbidden))
                let files = try await connection.openSFTPChannel()
                let contents = try await files.readFile(at: "/fixture.txt", maximumBytes: 1024)
                #expect(contents == Data("fixture\n".utf8))
                #expect(try await files.listDirectory(at: "/").count == 1)
                await files.disconnect()
                await connection.disconnect()
            } catch {
                await connection.disconnect()
                throw error
            }
        }
    }

    @Test @MainActor func freeOrdinaryHostUsesItsSavedUsernameWithoutAnEmbeddedTailnet() async throws {
        let fixture = try Fixture.load()
        let identity = Identity(name: "Username only", username: "none")
        let host = Host(name: "Tailscale SSH", host: "127.0.0.1", port: fixture.tailscalePort, identityID: identity.id)
        let library = HostLibraryModel(
            hosts: [host], identities: [identity],
            knownHosts: [
                KnownHostEntry(
                    hostname: host.host, port: host.port, algorithm: .rsa, fingerprint: fixture.hostFingerprint)
            ])
        library.hostAccess = HostAccessPolicy(entitlement: .free)
        let configuration = try await library.prepareSSHConnection(
            for: SSHConnectionRoute(hosts: [host]), submissions: [:]
        ).resolve()
        #expect(configuration.username == identity.username)
        #expect(configuration.credentials.isEmpty)
        #expect(configuration.network == nil && configuration.tailscaleNodeID == nil)
        let connection = SSHConnection()
        try await connection.connect(
            using: SSHConnectionRequest(configuration: configuration, interactionPolicy: .forbidden))
        do {
            let result = try await connection.execute(
                "fixture", workingDirectory: nil, stdin: nil, timeout: 5, outputLimit: 1024, onOutput: nil)
            #expect(result.stdout == "fixture\n")
        } catch {
            await connection.disconnect()
            throw error
        }
        await connection.disconnect()
    }

    @Test(arguments: [false, true]) @MainActor
    func approvalAutomaticallyContinuesOnTheSameTransport(managed: Bool) async throws {
        let fixture = try Fixture.load()
        let queue = SSHKeyboardInteractiveQueue()
        let username = "check-\(UUID().uuidString)"
        var configuration = fixture.configuration(username: username)
        if managed {
            configuration.host = "fixture.test.ts.net"
            configuration.port = 22
            configuration.network = LoopbackTailnet(port: fixture.tailscalePort, fingerprint: fixture.hostFingerprint)
            configuration.tailscaleNodeID = "fixture-node"
        }
        let connection = SSHConnection()
        let request = SSHConnectionRequest(configuration: configuration, keyboardInteractive: queue.handler)
        let opening = Task { try await connection.connect(using: request) }
        defer { opening.cancel() }
        do {
            let challenge = try await waitForApproval(queue)
            #expect(challenge.username == username && challenge.isTailscaleApproval)
            try await fixture.control("repeat", username: username)
            try await fixture.control("accept", username: username)
            try await opening.value
            #expect(queue.pending.isEmpty)
            let files = try await connection.openSFTPChannel()
            #expect(try await files.readFile(at: "/fixture.txt", maximumBytes: 1024) == Data("fixture\n".utf8))
            await files.disconnect()
        } catch {
            opening.cancel()
            await connection.disconnect()
            throw error
        }
        await connection.disconnect()
    }

    @Test @MainActor func terminalAndJumpUseTheSameAutomaticApproval() async throws {
        let fixture = try Fixture.load()
        let queue = SSHKeyboardInteractiveQueue()
        let jumpUser = "check-\(UUID().uuidString)"
        let targetUser = "check-\(UUID().uuidString)"
        let jumpID = UUID()
        var configuration = fixture.configuration(username: targetUser)
        configuration.jumps = [
            .init(
                id: jumpID, name: "Jump", host: "127.0.0.1", port: fixture.tailscalePort,
                username: jumpUser, credentials: [], expectedHostKeys: configuration.expectedHostKeys)
        ]
        let channel = SSHPTYChannel(output: { _ in }, exit: { _ in })
        let request = SSHConnectionRequest(configuration: configuration, keyboardInteractive: queue.handler)
        let opening = Task {
            try await channel.connect(using: request, shellIntegrationEnabled: false, columns: 80, rows: 24)
        }
        defer { opening.cancel() }
        do {
            let jump = try await waitForApproval(queue)
            #expect(jump.hostID == jumpID)
            try await fixture.control("accept", username: jumpUser)
            let target = try await waitForApproval(queue, excluding: jump.id)
            #expect(target.hostID == configuration.hostID)
            #expect(target.connectionID != jump.connectionID)
            try await fixture.control("accept", username: targetUser)
            try await opening.value
            #expect(queue.pending.isEmpty)
        } catch {
            opening.cancel()
            await channel.disconnect()
            throw error
        }
        await channel.disconnect()
    }

    @Test(arguments: ["reject", "disconnect", "cancel"]) @MainActor
    func failedOrCancelledApprovalRemovesThePrompt(action: String) async throws {
        let fixture = try Fixture.load()
        let queue = SSHKeyboardInteractiveQueue()
        let username = "check-\(UUID().uuidString)"
        let request = SSHConnectionRequest(
            configuration: fixture.configuration(username: username), keyboardInteractive: queue.handler)
        let connection = SSHConnection()
        let opening = Task { try await connection.connect(using: request) }
        defer { opening.cancel() }
        do {
            let challenge = try await waitForApproval(queue)
            if action == "cancel" {
                queue.cancel(challenge.id)
                await #expect(throws: CancellationError.self) { try await opening.value }
            } else {
                try await fixture.control(action, username: username)
                await #expect(throws: TermindSSHError.self) { try await opening.value }
            }
            #expect(queue.pending.isEmpty)
        } catch {
            opening.cancel()
            await connection.disconnect()
            throw error
        }
        await connection.disconnect()
    }

    @Test func forbiddenApprovalNeverInvokesTheResponder() async throws {
        let fixture = try Fixture.load()
        let connection = SSHConnection()
        await #expect(throws: SSHInteractionRequired.self) {
            try await connection.connect(
                using: SSHConnectionRequest(
                    configuration: fixture.configuration(username: "check-\(UUID().uuidString)"),
                    keyboardInteractive: { _ in
                        Issue.record("Unexpected approval form")
                        return []
                    },
                    interactionPolicy: .forbidden))
        }
        await connection.disconnect()
    }

    @Test(arguments: [false, true])
    func passwordFallbackAndOrdinaryBannersRetainNormalAuthentication(tailscale: Bool) async throws {
        let fixture = try Fixture.load()
        var configuration = fixture.configuration(username: tailscale ? "password" : "banner-password")
        if !tailscale { configuration.port = fixture.port }
        configuration.credentials = [.password("fixture-password")]
        let connection = SSHConnection()
        try await connection.connect(
            using: SSHConnectionRequest(
                configuration: configuration,
                keyboardInteractive: { _ in
                    Issue.record("An accepted banner needs no form")
                    return []
                }))
        await connection.disconnect()
    }

    @Test(arguments: [false, true]) func hostKeyMismatchNeverReachesApproval(managed: Bool) async throws {
        let fixture = try Fixture.load()
        var configuration = fixture.configuration(username: "check-\(UUID().uuidString)")
        configuration.expectedHostKeys = [.init(algorithm: .rsa, fingerprint: "SHA256:wrong")]
        if managed {
            configuration.host = "fixture.test.ts.net"
            configuration.network = LoopbackTailnet(port: fixture.tailscalePort, fingerprint: "SHA256:wrong")
            configuration.tailscaleNodeID = "fixture-node"
        }
        let connection = SSHConnection()
        await #expect(throws: (any Error).self) {
            try await connection.connect(
                using: SSHConnectionRequest(
                    configuration: configuration,
                    keyboardInteractive: { _ in
                        Issue.record("Host key must be verified first")
                        return []
                    }))
        }
        await connection.disconnect()
    }

    @Test func managedHostDoesNotFallBackToConfiguredPassword() async throws {
        let fixture = try Fixture.load()
        var configuration = fixture.configuration(username: "password")
        configuration.host = "fixture.test.ts.net"
        configuration.network = LoopbackTailnet(port: fixture.tailscalePort, fingerprint: fixture.hostFingerprint)
        configuration.tailscaleNodeID = "fixture-node"
        configuration.credentials = [.password("fixture-password")]
        let connection = SSHConnection()
        await #expect(throws: TermindSSHError.self) {
            try await connection.connect(using: SSHConnectionRequest(configuration: configuration))
        }
        await connection.disconnect()
    }

    @Test(arguments: [false, true], ["none", "password"])
    func queryRestoresSessionSettings(blocking: Bool, username: String) async throws {
        let fixture = try Fixture.load()
        try await Task.detached {
            #expect(libssh2_init(0) == 0)
            let socket = try SSHSocketConnector.open(host: "127.0.0.1", port: fixture.tailscalePort)
            defer { Darwin.close(socket) }
            let session = try #require(libssh2_session_init_ex(nil, nil, nil, nil))
            defer { _ = libssh2_session_free(session) }
            libssh2_session_set_blocking(session, 1)
            try SSHConnectionOpener.performHandshake(session, socket: socket, peer: "fixture", timeout: 5)
            libssh2_session_set_blocking(session, blocking ? 1 : 0)
            libssh2_session_set_read_timeout(session, 3)
            let result = try SSHTailscaleAuthentication.query(username: username, session: session, exchange: nil)
            #expect(result == (username == "none" ? .authenticated : .methods(["password"])))
            #expect(libssh2_session_get_blocking(session) == (blocking ? 1 : 0))
            #expect(libssh2_session_get_read_timeout(session) == 3)
            #expect(libssh2_session_get_timeout(session) == 5_000)
        }.value
    }

    @MainActor private func waitForApproval(
        _ queue: SSHKeyboardInteractiveQueue, excluding: UUID? = nil
    ) async throws -> SSHKeyboardInteractiveChallenge {
        for _ in 0..<500 {
            if let challenge = queue.current, challenge.id != excluding { return challenge }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "Missing wire approval", code: 1)
    }

    private struct Fixture: Decodable {
        var port: Int
        var tailscalePort: Int
        var approvalPort: Int
        var hostFingerprint: String

        func configuration(username: String) -> SSHConnectionConfiguration {
            SSHConnectionConfiguration(
                hostID: UUID(), host: "127.0.0.1", port: tailscalePort, username: username,
                credentials: [], expectedHostKeys: [.init(algorithm: .rsa, fingerprint: hostFingerprint)])
        }

        func control(_ action: String, username: String) async throws {
            try await Task.detached {
                let socket = try SSHSocketConnector.open(host: "127.0.0.1", port: approvalPort)
                defer { Darwin.close(socket) }
                let command = Array("\(action) \(username)\n".utf8)
                let sent = command.withUnsafeBytes { Darwin.send(socket, $0.baseAddress, $0.count, 0) }
                #expect(sent == command.count)
                var response = [UInt8](repeating: 0, count: 16)
                let received = Darwin.recv(socket, &response, response.count, 0)
                #expect(received > 0)
                #expect(String(decoding: response.prefix(max(0, received)), as: UTF8.self) == "ok\n")
            }.value
        }

        static func load() throws -> Self {
            let environment = ProcessInfo.processInfo.environment
            // Passing public endpoint metadata through the test runner also works in the app sandbox.
            let data: Data
            if let json = environment["TERMIND_SSH_FIXTURE_JSON"] {
                data = Data(json.utf8)
            } else {
                let path = try #require(environment["TERMIND_SSH_FIXTURE"])
                data = try Data(contentsOf: URL(fileURLWithPath: path))
            }
            return try JSONDecoder().decode(Self.self, from: data)
        }
    }
    private struct LoopbackTailnet: SSHNetworkDialing {
        var port: Int
        var fingerprint: String
        func open(host: String, port: Int, timeout: TimeInterval) async throws -> Int32 {
            #expect(host == "fixture.test.ts.net")
            return try SSHSocketConnector.open(host: "127.0.0.1", port: self.port)
        }
        func hostKeys(stableNodeID: String) async throws -> Set<SSHHostKeyIdentity> {
            #expect(stableNodeID == "fixture-node")
            return [SSHHostKeyIdentity(algorithm: .rsa, fingerprint: fingerprint)]
        }
    }
}
