import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@testable import TermindRemoteInfrastructure

/// Uses disposable localhost sshd servers and keys from the companion script.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TERMIND_AGENT_FORWARDING_FIXTURE"] != nil), .serialized)
@MainActor
struct SSHAgentForwardingWireTests {
    private struct Fixture: Decodable {
        var port: Int
        var targetPort: Int
        var deniedPort: Int
        var username: String
        var loginPrivateKey: String
        var forwardedPrivateKey: String
        var forwardedPublicKey: String
        var fingerprint: String
        var gitPath: String
    }
    private func fixture() throws -> Fixture {
        let path = try #require(ProcessInfo.processInfo.environment["TERMIND_AGENT_FORWARDING_FIXTURE"])
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
    private func setup(_ fixture: Fixture) throws -> (Host, HostLibraryModel, RemoteConnectionCoordinator) {
        let host = Host(name: "Agent fixture", host: "127.0.0.1", port: fixture.port, agentForwardingEnabled: true)
        let material = try SSHKeyMaterial.inspect(privateKey: fixture.forwardedPrivateKey, passphrase: nil)
        let key = SSHKeyRef(
            label: "Forwarded fixture", algorithm: material.algorithm,
            publicKey: material.publicKey, fingerprint: material.fingerprint, credentialRef: "fixture-key",
            storage: .thisDevice)
        let secrets = InMemorySecretStore()
        try secrets.setKeyCredential(
            .software(.init(privateKey: fixture.forwardedPrivateKey)), for: key.credentialRef, storage: key.storage)
        let library = HostLibraryModel(hosts: [host], keys: [key], secrets: secrets)
        let coordinator = RemoteConnectionCoordinator()
        coordinator.updateAgentForwarding(VaultSSHAgent.factory(library: library))
        return (host, library, coordinator)
    }
    private func request(_ host: Host, _ fixture: Fixture, port: Int? = nil) -> SSHConnectionRequest {
        SSHConnectionRequest(
            configuration: .init(
                hostID: host.id, host: host.host, port: port ?? host.sshPort, username: fixture.username,
                credentials: [.privateKey(privateKey: fixture.loginPrivateKey, publicKey: nil, passphrase: nil)],
                expectedHostKeys: [.init(algorithm: .ed25519, fingerprint: fixture.fingerprint)]))
    }
    private func ssh(_ fixture: Fixture) -> String {
        "/usr/bin/ssh -F /dev/null -o BatchMode=yes -o IdentityFile=/dev/null -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -p \(fixture.targetPort) \(fixture.username)@127.0.0.1"
    }
    @Test func execListsKeysAuthenticatesSecondHopAndReadsGit() async throws {
        let fixture = try fixture()
        let (host, library, coordinator) = try setup(fixture)
        let connection = try await coordinator.connectConnection(using: request(host, fixture))
        do {
            let command =
                "test -n \"$SSH_AUTH_SOCK\" && /usr/bin/ssh-add -L && \(ssh(fixture)) 'printf forwarded-ok' && \(ssh(fixture)) 'git-upload-pack \(fixture.gitPath)' </dev/null"
            let result = try await connection.execute(
                command, workingDirectory: nil, stdin: nil, timeout: 15, outputLimit: 8192, onOutput: nil)
            #expect(result.stdout.contains("forwarded-ok"))
            #expect(result.stdout.contains(library.keys[0].publicKey.split(separator: " ")[1]))
            // git-upload-pack without a request can return nonzero after advertising;
            // ls-remote is the complete Git protocol check below.
            let git = try await connection.execute(
                "GIT_SSH_COMMAND='/usr/bin/ssh -F /dev/null -o BatchMode=yes -o IdentityFile=/dev/null -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' /usr/bin/git ls-remote ssh://\(fixture.username)@127.0.0.1:\(fixture.targetPort)\(fixture.gitPath)",
                workingDirectory: nil, stdin: nil, timeout: 15, outputLimit: 4096, onOutput: nil)
            #expect(git.exitCode == 0)
        } catch {
            await connection.disconnect()
            throw error
        }
        await connection.disconnect()
    }
    @Test func forwardingWorksThroughAJumpHost() async throws {
        let fixture = try fixture()
        let (host, _, coordinator) = try setup(fixture)
        var routed = request(host, fixture, port: fixture.targetPort)
        routed.configuration.jumps = [
            .init(
                id: UUID(), name: "Jump fixture", host: "127.0.0.1", port: fixture.port,
                username: fixture.username,
                credentials: [.privateKey(privateKey: fixture.loginPrivateKey, publicKey: nil, passphrase: nil)],
                expectedHostKeys: [.init(algorithm: .ed25519, fingerprint: fixture.fingerprint)])
        ]
        let connection = try await coordinator.connectConnection(using: routed)
        do {
            let result = try await connection.execute(
                "test -n \"$SSH_AUTH_SOCK\" && /usr/bin/ssh-add -L",
                workingDirectory: nil, stdin: nil, timeout: 10, outputLimit: 4096, onOutput: nil)
            #expect(result.exitCode == 0)
            #expect(result.stdout.contains("ssh-ed25519"))
        } catch {
            await connection.disconnect()
            throw error
        }
        await connection.disconnect()
    }

    @Test func assistantAndMCPSharedServicesForwardWithinTheirExecLease() async throws {
        let fixture = try fixture()
        let (initialHost, library, coordinator) = try setup(fixture)
        let material = try SSHKeyMaterial.inspect(privateKey: fixture.loginPrivateKey, passphrase: nil)
        let key = SSHKeyRef(
            label: "Login fixture", algorithm: material.algorithm,
            publicKey: material.publicKey, fingerprint: material.fingerprint,
            credentialRef: "fixture-login", storage: .thisDevice)
        try library.upsert(key, credential: .software(.init(privateKey: fixture.loginPrivateKey)))
        let identity = Identity(name: "Fixture", username: fixture.username, keyID: key.id)
        _ = library.upsert(identity)
        var host = initialHost
        host.identityID = identity.id
        library.upsert(host)
        library.saveKnownHost(
            KnownHostEntry(
                hostname: host.host, port: host.sshPort, fingerprint: fixture.fingerprint))
        let services = AgentHostServices.live(store: library, coordinator: coordinator)
        let context = try await services.authentication.connectionContext(
            hostID: host.id, invocationID: UUID(), interaction: .unavailable, pool: services.connections)
        let connection = context.connection
        let command = "test -n \"$SSH_AUTH_SOCK\" && \(ssh(fixture)) 'printf shared-services-ok'"
        let result = try await services.connections.withExecLease(hostID: host.id, connection: connection) {
            try await connection.execute(
                command, workingDirectory: nil, stdin: nil, timeout: 15, outputLimit: 4096, onOutput: nil)
        }
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("shared-services-ok"))
    }

    @Test func serverDenialFailsBeforeExecutingCommand() async throws {
        let fixture = try fixture()
        let (host, _, coordinator) = try setup(fixture)
        let connection = try await coordinator.connectConnection(
            using: request(host, fixture, port: fixture.deniedPort))
        await #expect(throws: (any Error).self) {
            try await connection.execute(
                "printf must-not-run", workingDirectory: nil, stdin: nil, timeout: 5, outputLimit: 1024, onOutput: nil)
        }
        await connection.disconnect()
    }
    @Test func terminalProvidesAgentAndRevocationStopsSigning() async throws {
        let fixture = try fixture()
        let (initialHost, library, coordinator) = try setup(fixture)
        var host = initialHost
        let output = Output()
        let pty = coordinator.makePTYChannel(output: { output.append($0) }, exit: { _ in })
        try await pty.connect(using: request(host, fixture), shellIntegrationEnabled: false, columns: 80, rows: 24)
        await pty.write(Data("\(ssh(fixture)) 'printf wire-pty-%s ok'\n".utf8))
        for _ in 0..<150 {
            if output.text.contains("wire-pty-ok") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(output.text.contains("wire-pty-ok"))
        host.agentForwardingEnabled = false
        library.upsert(host)
        await pty.write(Data("/usr/bin/ssh-add -L >/dev/null 2>&1; printf 'revoked-%s' $?\n".utf8))
        for _ in 0..<50 {
            if output.text.contains("revoked-1") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(output.text.contains("revoked-1"))
        await pty.disconnect()
    }
}

private nonisolated final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.withLock { bytes.append(data) } }
    var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
}
