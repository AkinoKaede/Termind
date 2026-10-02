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

    private struct Fixture: Decodable {
        var port: Int
        var hostFingerprint: String

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
