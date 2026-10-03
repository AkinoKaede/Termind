import Foundation
import TermindApplication
import TermindDomain
import Testing

@Suite @MainActor
struct TailscaleHostIdentityTests {
    private let groupID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!

    // Independently generated with Python hashlib.sha1 and uuid.NAMESPACE_URL.
    @Test(arguments: [
        ("example.ts.net", "n123", "75e53f16-003f-5fa1-87f3-663b8726f413"),
        ("other.ts.net", "n123", "e3c78211-3fa4-546b-a5b7-4a429a7972cc"),
        ("example.ts.net", "节点:é🙂", "8f19a534-101c-5a8a-a22e-ef7c969e4ebf"),
        ("a", "b:c", "9fb0d403-eb25-5326-a72f-b5522674c7a9"),
        ("a:b", "c", "571f7dca-a7c4-5ff8-a3d9-7e29b11f6072"),
    ])
    func uuidUsesLengthDelimitedUTF8(suffix: String, nodeID: String, expected: String) throws {
        let configuration = try configuration(suffix)
        #expect(configuration.hostID(groupID: groupID, stableNodeID: nodeID) == UUID(uuidString: expected))
    }

    @Test func identityUsesGroupTailnetAndNodeButNotControlURL() throws {
        let original = try configuration("example.ts.net")
        let id = original.hostID(groupID: groupID, stableNodeID: "n123")
        let canonical = try configuration("EXAMPLE.TS.NET.", controlURL: "https://LOGIN.TAILSCALE.COM:443/")
        let otherControl = try configuration("example.ts.net", controlURL: "https://headscale.example.com")
        #expect(canonical.hostID(groupID: groupID, stableNodeID: "n123") == id)
        #expect(otherControl.hostID(groupID: groupID, stableNodeID: "n123") == id)
        #expect(original.hostID(groupID: UUID(), stableNodeID: "n123") != id)
        #expect(original.hostID(groupID: groupID, stableNodeID: "n456") != id)
        #expect(try configuration("other.ts.net").hostID(groupID: groupID, stableNodeID: "n123") != id)
    }

    @Test func switchingTailnetsDoesNotAttachHistoryToAnotherNetwork() throws {
        var group = HostGroup(id: groupID, name: "Servers")
        let firstNetwork = try configuration("first.ts.net")
        group.tailscale = firstNetwork
        let library = HostLibraryModel(groups: [group])
        var peer = TailscalePeer(
            stableID: "n123", name: "First", dnsName: "first.first.ts.net", online: true, sshHostKeys: ["fixture"])
        library.replaceTailscalePeers([peer], groupID: groupID)
        let firstHost = try #require(library.hosts.first)
        let history = ConnectionHistoryModel()
        let event = try #require(history.record(kind: .ssh, for: firstHost.id))

        group.name = "Renamed group"
        library.upsert(group)
        peer.name = "Renamed node"
        peer.dnsName = "renamed.first.ts.net"
        library.replaceTailscalePeers([peer], groupID: groupID)
        #expect(library.host(firstHost.id)?.name == peer.name)
        #expect(history.recentLocalHosts(in: library, limit: 10).first?.entry.id == event.id)

        group.tailscale = try configuration("second.ts.net")
        library.upsert(group)
        #expect(library.hosts.isEmpty)
        library.replaceTailscalePeers([peer], groupID: groupID)
        #expect(library.hosts.first?.id != firstHost.id)
        #expect(history.entries().map(\.id) == [event.id])
        #expect(history.recentLocalHosts(in: library, limit: 10).isEmpty)

        group.tailscale = firstNetwork
        library.upsert(group)
        library.replaceTailscalePeers([peer], groupID: groupID)
        #expect(library.hosts.first?.id == firstHost.id)
        #expect(history.recentLocalHosts(in: library, limit: 10).first?.entry.id == event.id)
    }

    private func configuration(
        _ suffix: String, controlURL: String = TailscaleNetwork.defaultControlURL
    ) throws -> TailscaleGroupConfiguration {
        TailscaleGroupConfiguration(network: try TailscaleNetwork(controlURL: controlURL, dnsSuffix: suffix))
    }
}
