import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import Termind

@Suite @MainActor
struct TailscaleSessionRoutingTests {
    @Test(arguments: [false, true])
    func savedUsernameSkipsThePromptOnANewSession(sftp: Bool) async throws {
        let network = try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "example.ts.net")
        var group = HostGroup(name: "Tailnet")
        group.tailscale = TailscaleGroupConfiguration(network: network)
        let library = HostLibraryModel(groups: [group])
        let transfers = TransferLibraryModel(library: library)
        let provider = RoutingProvider()
        library.tailscaleConnections = provider
        library.replaceTailscalePeers(
            [
                TailscalePeer(
                    stableID: "n123", name: "Server",
                    dnsName: "server.example.ts.net", online: true, sshHostKeys: ["ssh-ed25519 fixture"])
            ], groupID: group.id)
        let host = try #require(library.hosts.first)
        #expect(library.saveTailscaleUsername("operator", hostID: host.id))
        let terminal = sftp ? nil : SSHSessionModel(host: host)
        let files = sftp ? SFTPChannelModel(hostID: host.id) : nil
        defer {
            terminal?.disconnect()
            files?.disconnect()
        }
        terminal?.connect(using: library)
        files?.connect(using: transfers)
        #expect(terminal?.pendingAuthentication == nil)
        #expect(files?.pendingAuthentication == nil)
        for _ in 0..<200 {
            if await provider.dialer.openedHost != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await provider.dialer.openedHost == host.host)
    }

    @Test(arguments: [false, true])
    func usernameSubmissionKeepsTerminalAndSFTPOnTheManagedTransport(sftp: Bool) async throws {
        let network = try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "example.ts.net")
        var group = HostGroup(name: "Tailnet")
        group.tailscale = TailscaleGroupConfiguration(network: network)
        let library = HostLibraryModel(groups: [group])
        let transfers = TransferLibraryModel(library: library)
        let provider = RoutingProvider()
        library.tailscaleConnections = provider
        library.replaceTailscalePeers(
            [
                TailscalePeer(
                    stableID: "n123", name: "Server", dnsName: "server.example.ts.net", online: true,
                    sshHostKeys: ["ssh-ed25519 fixture"])
            ], groupID: group.id)
        let host = try #require(library.hosts.first)
        let terminal = sftp ? nil : SSHSessionModel(host: host)
        let files = sftp ? SFTPChannelModel(hostID: host.id) : nil
        defer {
            terminal?.disconnect()
            files?.disconnect()
        }
        terminal?.connect(using: library)
        files?.connect(using: transfers)
        let prompt = try #require(terminal?.pendingAuthentication ?? files?.pendingAuthentication)
        #expect(prompt.usernameOnly && prompt.username == "root")
        terminal?.continueAuthentication(
            identityID: nil, username: "operator", password: nil, passphrase: nil,
            keyID: nil, save: true, using: library)
        files?.continueAuthentication(
            identityID: nil, username: "operator", password: nil, passphrase: nil,
            keyID: nil, save: true, using: transfers)
        for _ in 0..<200 {
            if await provider.dialer.openedHost != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await provider.dialer.openedHost == "server.example.ts.net")
        #expect(await provider.dialer.requestedNodeIDs == ["n123"])
        #expect(library.identities.isEmpty)
        #expect(library.tailscaleUsername(for: host) == "operator")
    }
}

@MainActor private final class RoutingProvider: TailscaleConnectionProviding {
    let dialer = RoutingDialer()
    func connection(for groupID: UUID) throws -> any SSHNetworkDialing { dialer }
}

private actor RoutingDialer: SSHNetworkDialing {
    var openedHost: String?
    var requestedNodeIDs: [String] = []
    func open(host: String, port: Int, timeout: TimeInterval) async throws -> Int32 {
        openedHost = host
        throw CancellationError()
    }
    func hostKeys(stableNodeID: String) async throws -> Set<SSHHostKeyIdentity> {
        requestedNodeIDs.append(stableNodeID)
        return [SSHHostKeyIdentity(algorithm: .ed25519, fingerprint: "SHA256:tailnet")]
    }
}
