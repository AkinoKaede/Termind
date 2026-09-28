import CryptoKit
import Foundation
import Logging
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@Suite(.enabled(if: ProcessInfo.processInfo.environment["TERMIND_SECURITY_KEY_FIXTURE"] != nil), .serialized)
struct SecurityKeySSHWireTests {
    private struct Fixture: Decodable {
        var port: Int
        var username: String
        var privateKey: Data
        var fingerprint: String
    }

    @Test(arguments: [false, true]) func authenticatesAgainstOpenSSHWithWebAuthnSignature(throughJump: Bool)
        async throws
    {
        let path = try #require(ProcessInfo.processInfo.environment["TERMIND_SECURITY_KEY_FIXTURE"])
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let key = try P256.Signing.PrivateKey(rawRepresentation: fixture.privateKey)
        let credential = SecurityKeyCredential(
            credentialID: Data([1, 2, 3]), publicKeyX963: key.publicKey.x963Representation)
        let expected: Set<SSHHostKeyIdentity> = [.init(algorithm: .ed25519, fingerprint: fixture.fingerprint)]
        var configuration = SSHConnectionConfiguration(
            hostID: UUID(), host: "127.0.0.1", port: fixture.port,
            username: fixture.username, credentials: [.securityKey(credential)], expectedHostKeys: expected)
        if throughJump {
            configuration.jumps = [
                .init(
                    id: UUID(), name: "Fixture jump", host: "127.0.0.1", port: fixture.port,
                    username: fixture.username, credentials: [.securityKey(credential)], expectedHostKeys: expected)
            ]
        }
        let request = SSHConnectionRequest(
            configuration: configuration,
            securityKeySigning: { request in
                let encoded = request.challenge.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                let client = Data(
                    "{\"type\":\"webauthn.get\",\"challenge\":\"\(encoded)\",\"origin\":\"https://\(SecurityKeyCredential.relyingParty)\"}"
                        .utf8)
                let auth =
                    Data(SHA256.hash(data: Data(SecurityKeyCredential.relyingParty.utf8))) + Data([1, 0, 0, 0, 1])
                return SecurityKeyAssertion(
                    credentialID: credential.credentialID, authenticatorData: auth,
                    clientDataJSON: client,
                    signature: try key.signature(for: auth + Data(SHA256.hash(data: client))).derRepresentation)
            })
        let host = Host(
            id: configuration.hostID, name: "Forwarding fixture", host: "127.0.0.1", agentForwardingEnabled: true)
        let reference = try WebAuthnSSH.keyReference(credential, label: "Forwarded YubiKey")
        let library = await MainActor.run { HostLibraryModel(hosts: [host], keys: [reference]) }
        let coordinator = RemoteConnectionCoordinator()
        let factory = await MainActor.run {
            VaultSSHAgent.factory(library: library, securityKeySigning: request.securityKeySigning)
        }
        coordinator.updateAgentForwarding(factory)
        let connection = try await coordinator.connectConnection(using: request)
        do {
            let result = try await connection.execute(
                "printf fido-ok", workingDirectory: nil, stdin: nil,
                timeout: 10, outputLimit: 4096, onOutput: nil)
            #expect(result.exitCode == 0)
            #expect(result.stdout == "fido-ok")
            let forwarded = try await connection.execute(
                "/usr/bin/ssh -F /dev/null -o BatchMode=yes -o IdentityFile=/dev/null -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -p \(fixture.port) \(fixture.username)@127.0.0.1 'printf forwarded-fido-ok'",
                workingDirectory: nil, stdin: nil, timeout: 15, outputLimit: 4096, onOutput: nil)
            #expect(forwarded.exitCode == 0)
            #expect(forwarded.stdout == "forwarded-fido-ok")
        } catch {
            await connection.disconnect()
            throw error
        }
        await connection.disconnect()
        let sftp = try await coordinator.connectSFTP(using: request)
        await sftp.disconnect()
    }
    @Test(arguments: [false, true])
    func rejectedPublicKeyPreservesFailureAndLogsBeforeSigning(throughJump: Bool) async throws {
        let path = try #require(ProcessInfo.processInfo.environment["TERMIND_SECURITY_KEY_FIXTURE"])
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let key = P256.Signing.PrivateKey()
        let credential = SecurityKeyCredential(
            credentialID: Data("sensitive-credential-id".utf8), publicKeyX963: key.publicKey.x963Representation)
        let expected: Set<SSHHostKeyIdentity> = [.init(algorithm: .ed25519, fingerprint: fixture.fingerprint)]
        var configuration = SSHConnectionConfiguration(
            hostID: UUID(), host: "127.0.0.1", port: fixture.port,
            username: fixture.username, credentials: [.securityKey(credential)], expectedHostKeys: expected)
        if throughJump {
            configuration.jumps = [
                .init(
                    id: UUID(), name: "Fixture jump", host: "127.0.0.1", port: fixture.port,
                    username: fixture.username, credentials: [.securityKey(credential)], expectedHostKeys: expected)
            ]
        }
        let request = SSHConnectionRequest(
            configuration: configuration,
            securityKeySigning: { _ in
                Issue.record("A rejected public key must not prompt for a signature")
                throw CancellationError()
            })
        let capture = SecurityKeyLogCapture()
        let logger = Logger(label: "termind.security-key-test") { _ in SecurityKeyLogHandler(capture: capture) }
        let coordinator = RemoteConnectionCoordinator(logger: logger)
        do {
            let connection = try await coordinator.connectConnection(using: request)
            await connection.disconnect()
            Issue.record("An unregistered public key must fail authentication")
        } catch {
            #expect(error.localizedDescription.contains("Username/PublicKey combination invalid"))
            #expect(error.localizedDescription.contains("[libssh2 -18]"))
            #expect(
                error.localizedDescription.contains(
                    String(
                        localized:
                            "The server rejected the username or public key. Check the login user and the key in authorized_keys."
                    )))
        }
        let logs = capture.entries
        let failure = try #require(logs.first { $0.message == "ssh.security_key.failed" })
        #expect(failure.metadata["stage"] == "public_key_offer")
        #expect(failure.metadata["libssh2_code"] == "-18")
        #expect(failure.metadata["operation_id"] != nil)
        #expect(!logs.contains { $0.message == "ssh.security_key.signing" })
        let serialized = String(describing: logs)
        #expect(!serialized.contains("sensitive-credential-id"))
        #expect(!serialized.contains(credential.credentialID.base64EncodedString()))
        #expect(!serialized.contains(key.publicKey.x963Representation.base64EncodedString()))
    }

}

private nonisolated struct SecurityKeyLogEntry: Sendable {
    let message: String
    let metadata: [String: String]
}

private nonisolated final class SecurityKeyLogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SecurityKeyLogEntry] = []
    var entries: [SecurityKeyLogEntry] { lock.withLock { storage } }
    func append(_ event: LogEvent, metadata: Logger.Metadata) {
        lock.withLock {
            storage.append(.init(message: event.message.description, metadata: metadata.mapValues(\.description)))
        }
    }
}

private nonisolated struct SecurityKeyLogHandler: LogHandler {
    let capture: SecurityKeyLogCapture
    var metadataProvider: Logger.MetadataProvider?
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
    func log(event: LogEvent) {
        var combined = metadata
        if let explicit = event.metadata { combined.merge(explicit) { _, new in new } }
        capture.append(event, metadata: combined)
    }
}
