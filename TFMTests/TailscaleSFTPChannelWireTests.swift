import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import Termind
@testable import TermindRemoteInfrastructure

/// macOS transfer-model integration: saved login, successful SFTP, and actionable failures.
@Suite(
    .enabled(
        if: ProcessInfo.processInfo.environment["TERMIND_SSH_FIXTURE"] != nil
            || ProcessInfo.processInfo.environment["TERMIND_SSH_FIXTURE_JSON"] != nil), .serialized
)
nonisolated struct TailscaleSFTPChannelWireTests {
    @Test(arguments: [false, true]) @MainActor
    func savedUsernameInSFTPModelConnectsOrShowsTheActualFailure(rejected: Bool) async throws {
        let fixture = try Fixture.load()
        let network = try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "test.ts.net")
        var group = HostGroup(name: "Tailnet")
        group.tailscale = TailscaleGroupConfiguration(network: network)
        let library = HostLibraryModel(groups: [group])
        let provider = WireProvider(dialer: LoopbackTailnet(port: fixture.port, fingerprint: fixture.hostFingerprint))
        library.tailscaleConnections = provider
        library.replaceTailscalePeers(
            [
                TailscalePeer(
                    stableID: "fixture-node", name: "Fixture",
                    dnsName: "fixture.test.ts.net", online: true, sshHostKeys: ["fixture"])
            ], groupID: group.id)
        let host = try #require(library.hosts.first)
        #expect(library.saveTailscaleUsername(rejected ? "reject" : "none", hostID: host.id))
        let files = SFTPChannelModel(hostID: host.id)
        defer { files.disconnect() }
        files.connect(using: library)
        for _ in 0..<2_000 {
            if files.status == .connected || files.pendingAuthentication != nil { break }
            if case .failed = files.status { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(files.pendingAuthentication == nil)
        if rejected {
            guard case .failed(let reason) = files.status else {
                Issue.record("Expected an explicit SFTP failure")
                return
            }
            #expect(reason.contains("reject@fixture.test.ts.net"))
            #expect(reason.contains("libssh2"))
        } else {
            #expect(files.status == .connected)
            #expect(files.path == "/")
        }
    }

    @MainActor private final class WireProvider: TailscaleConnectionProviding {
        let dialer: LoopbackTailnet
        init(dialer: LoopbackTailnet) { self.dialer = dialer }
        func connection(for groupID: UUID) throws -> any SSHNetworkDialing { dialer }
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
