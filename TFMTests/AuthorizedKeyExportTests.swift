import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import Testing

@testable import Termind
@testable import TermindRemoteInfrastructure

struct AuthorizedKeyExportTests {
    @Test
    func exportPlacesTheKeyNameCommentAboveThePublicKey() throws {
        let input = try SSHConnectionOpener.authorizedKeyInstallInput(
            publicKey: "ssh-ed25519 AAAAC3Nza test@example.com",
            keyName: "Production"
        )

        #expect(
            String(decoding: input, as: UTF8.self)
                == "# Production Key by Termind\nssh-ed25519 AAAAC3Nza test@example.com\n"
        )
    }

    @Test
    func exportKeepsTheGeneratedCommentOnOneLine() throws {
        let input = try SSHConnectionOpener.authorizedKeyInstallInput(
            publicKey: "ssh-ed25519 AAAAC3Nza",
            keyName: "  Production\n\tServer  "
        )

        #expect(
            String(decoding: input, as: UTF8.self)
                == "# Production Server Key by Termind\nssh-ed25519 AAAAC3Nza\n"
        )
    }

    @Test
    func softwareKeyEnvelopeRoundTripsWithoutKeepingTheSourceBuffer() throws {
        let privateKey = "-----BEGIN TEST-----\nsecret-钥匙\n-----END TEST-----"
        let stored = SSHPrivateKeySecret(privateKey: privateKey)
        var encoded = KeychainSecretStore.encodeSoftwareKey(stored)

        #expect(encoded.starts(with: Data("termind-ssh-key\0".utf8) + Data([0x01])))
        let decoded = try KeychainSecretStore.decodeSoftwareKey(from: &encoded)
        #expect(encoded.isEmpty)
        #expect(decoded == stored)

        var runtimeEncoded = KeychainSecretStore.encodeSoftwareKey(stored)
        let runtime = try KeychainSecretStore.decodeSoftwareKeyRuntimeSecret(from: &runtimeEncoded)
        #expect(runtimeEncoded.isEmpty)
        #expect(runtime.matches(privateKey))
    }

    @Test
    func legacyPrivateKeyEnvelopeRequiresACompleteJSONObject() throws {
        var encoded = try JSONEncoder().encode(
            SSHPrivateKeySecret(privateKey: "-----BEGIN TEST-----\nsecret\n-----END TEST-----")
        )
        let secret = try KeychainSecretStore.decodeSoftwareKeyRuntimeSecret(from: &encoded)
        #expect(encoded.isEmpty)
        #expect(secret.matches("-----BEGIN TEST-----\nsecret\n-----END TEST-----"))

        #expect(throws: KeychainSecretError.self) {
            var data = Data(#"{"privateKey":"secret""#.utf8)
            _ = try KeychainSecretStore.decodeSoftwareKeyRuntimeSecret(
                from: &data
            )
        }
        #expect(throws: KeychainSecretError.self) {
            var data = Data(#"{"privateKey":"secret"} trailing"#.utf8)
            _ = try KeychainSecretStore.decodeSoftwareKeyRuntimeSecret(
                from: &data
            )
        }
    }

    @Test
    func currentSoftwareKeyEnvelopeRejectsMalformedValuesWithoutJSONFallback() {
        let magic = Data("termind-ssh-key\0".utf8)
        let malformed: [Data] = [
            magic.prefix(5),
            magic,
            magic + Data([0x02]) + Data(#"{"privateKey":"fallback"}"#.utf8),
            magic + Data([0x01]),
            magic + Data([0x01, 0xC0, 0x80]),
        ].map(Data.init)

        for value in malformed {
            #expect(throws: KeychainSecretError.self) {
                var data = value
                _ = try KeychainSecretStore.decodeSoftwareKey(from: &data)
            }
            #expect(throws: KeychainSecretError.self) {
                var data = value
                _ = try KeychainSecretStore.decodeSoftwareKeyRuntimeSecret(from: &data)
            }
        }
    }

    @Test
    func multipleKeysReuseOneAuthenticatedConnection() async throws {
        let password = SSHSecret("one-use")
        let request = SSHConnectionRequest(
            configuration: SSHConnectionConfiguration(
                hostID: UUID(), host: "server.invalid", port: 22,
                username: "deploy", credentials: [.password(password)],
                expectedHostKeys: []
            )
        )
        let connection = AuthorizedKeyConnection()

        try await SSHPTYChannelWorker.installAuthorizedKeys(
            [
                SSHAuthorizedKeyInstall(publicKey: "ssh-ed25519 first", name: "First"),
                SSHAuthorizedKeyInstall(publicKey: "ssh-ed25519 second", name: "Second"),
            ],
            using: request, connection: connection
        )

        let snapshot = await connection.snapshot()
        #expect(snapshot.connects == 1)
        #expect(snapshot.executions == 2)
        #expect(snapshot.disconnects == 1)
        #expect(
            snapshot.inputs == [
                "# First Key by Termind\nssh-ed25519 first\n",
                "# Second Key by Termind\nssh-ed25519 second\n",
            ])
        #expect(password.isConsumed)
    }
}

private actor AuthorizedKeyConnection: SSHConnectionProtocol {
    struct Snapshot: Sendable {
        var connects: Int
        var executions: Int
        var disconnects: Int
        var inputs: [String]
    }

    private var connects = 0
    private var executions = 0
    private var disconnects = 0
    private var inputs: [String] = []

    func connect(using configuration: SSHConnectionConfiguration) async throws {
        connects += 1
    }

    func execute(
        _ command: String, workingDirectory: String?, stdin: Data?,
        timeout: TimeInterval, outputLimit: Int, onOutput: SSHExecOutputHandler?
    ) async throws -> SSHExecResult {
        executions += 1
        inputs.append(stdin.map { String(decoding: $0, as: UTF8.self) } ?? "")
        return SSHExecResult(
            stdout: "", stderr: "", exitCode: 0,
            stdoutTruncated: false, stderrTruncated: false
        )
    }

    func openSFTPChannel() async throws -> any SFTPChannelProtocol {
        throw TermindSSHError.disconnected
    }

    func disconnect() async {
        disconnects += 1
    }

    func snapshot() -> Snapshot {
        Snapshot(
            connects: connects, executions: executions,
            disconnects: disconnects, inputs: inputs
        )
    }
}
