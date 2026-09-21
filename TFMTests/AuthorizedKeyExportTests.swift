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
    func legacyPrivateKeyEnvelopeRequiresACompleteJSONObject() throws {
        var encoded = try JSONEncoder().encode(
            SSHPrivateKeySecret(privateKey: "-----BEGIN TEST-----\nsecret\n-----END TEST-----")
        )
        let secret = try KeychainSecretStore.decodePrivateKeySecret(from: &encoded)
        #expect(encoded.isEmpty)
        #expect(secret.matches("-----BEGIN TEST-----\nsecret\n-----END TEST-----"))

        #expect(throws: KeychainSecretError.self) {
            var data = Data(#"{"privateKey":"secret""#.utf8)
            _ = try KeychainSecretStore.decodePrivateKeySecret(
                from: &data
            )
        }
        #expect(throws: KeychainSecretError.self) {
            var data = Data(#"{"privateKey":"secret"} trailing"#.utf8)
            _ = try KeychainSecretStore.decodePrivateKeySecret(
                from: &data
            )
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
        _ command: String, workingDirectory: String?, stdin: SSHCommandInput?,
        timeout: TimeInterval, outputLimit: Int, onOutput: SSHExecOutputHandler?
    ) async throws -> SSHExecResult {
        executions += 1
        let input: String
        switch stdin {
        case .plain(let bytes):
            input = String(decoding: bytes, as: UTF8.self)
        case .secret(let secret):
            defer { secret.clear() }
            input = try secret.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
        case nil:
            input = ""
        }
        inputs.append(input)
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
