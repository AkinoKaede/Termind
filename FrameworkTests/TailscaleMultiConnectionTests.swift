import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

@Suite @MainActor
struct TailscaleMultiConnectionTests {
    private static let legacyGroup = Data(
        #"{"formatVersion":2,"key":{"kind":"hostGroup","id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"},"version":{"modifiedAt":0,"counter":1,"writerID":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"},"isDeleted":false,"payload":{"hostGroup":{"_0":{"id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","name":"Existing random-ID group","sortIndex":0,"isExpanded":true,"tailscale":{"network":{"controlURL":"https://controlplane.tailscale.com","dnsSuffix":"example.ts.net"},"username":"operator","hostPreferences":{"01bf448f-7943-55d0-96aa-b52f10c25f07":{"username":"deploy","charset":"utf8","sftpInitialPath":"/srv","shellIntegrationMode":"followGlobalSettings","environmentVariables":[]}}}}}}}"#
            .utf8)

    @Test func historicalRandomGroupKeepsItsHostIdentityAndPreferencesAcrossV3Edits() throws {
        let envelope = try VaultSyncCodec.decode(Self.legacyGroup)
        guard case .hostGroup(let group) = envelope.payload else { throw CocoaError(.coderReadCorrupt) }
        let hostID = try #require(UUID(uuidString: "01bf448f-7943-55d0-96aa-b52f10c25f07"))
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let persistence = HostPersistence(context: container.mainContext)
        _ = try persistence.applyRemote([envelope])
        let journal = VaultSyncJournal(context: container.mainContext)
        #expect(try journal.pendingEnvelopes().isEmpty)
        #expect(try journal.envelope(for: envelope.key)?.formatVersion == 2)
        let library = HostLibraryModel(persistence: persistence)
        library.replaceTailscalePeers([peer()], groupID: group.id)
        let host = try #require(library.host(hostID))
        #expect(library.savedTailscaleUsername(for: host) == "deploy")
        #expect(host.sftpChannelInitialPath == "/srv")
        var renamed = group
        renamed.name = "Renamed"
        library.upsert(renamed)
        #expect(library.host(hostID)?.id == host.id)
        let edited = try #require(try journal.pendingEnvelopes().first)
        #expect(edited.formatVersion == 3)
        let remote = try VaultSyncCodec.decode(VaultSyncCodec.encode(edited))
        guard case .hostGroup(let restored) = remote.payload else { throw CocoaError(.coderReadCorrupt) }
        #expect(restored.tailscale?.hostIdentityVersion == .legacy)
        #expect(restored.tailscale?.hostID(groupID: restored.id, stableNodeID: "n123") == hostID)
    }

    @Test(arguments: [TailscaleGroupConfiguration.HostIdentityVersion.legacy, .groupScoped])
    func sameNodeInTwoGroupsKeepsPreferencesAndRoutingIndependent(
        firstIdentity: TailscaleGroupConfiguration.HostIdentityVersion
    ) throws {
        let source = try TermindPersistence.makeContainer(inMemory: true)
        let library = HostLibraryModel(persistence: HostPersistence(context: source.mainContext))
        let network = try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "example.ts.net")
        var first = HostGroup(name: "First")
        first.tailscale = TailscaleGroupConfiguration(network: network, hostIdentityVersion: firstIdentity)
        var second = HostGroup(name: "Second", parentID: first.id)
        second.tailscale = TailscaleGroupConfiguration(network: network)
        for group in [first, second] {
            library.upsert(group)
            library.replaceTailscalePeers([peer()], groupID: group.id)
        }
        let firstHost = try #require(library.hosts.first { $0.groupID == first.id })
        let secondHost = try #require(library.hosts.first { $0.groupID == second.id })
        #expect(firstHost.id != secondHost.id)
        for (host, username) in [(firstHost, "alice"), (secondHost, "bob")] {
            var edited = host
            edited.tags = [username]
            #expect(library.saveTailscaleHost(edited, username: username))
        }
        let routing = MultiConnectionRoutingProbe()
        library.tailscaleConnections = routing
        _ = try library.tailscaleNetwork(for: firstHost)
        _ = try library.tailscaleNetwork(for: secondHost)
        #expect(routing.groups == [first.id, second.id])
        let firstStamp = library.networkConfigurationStamp(for: firstHost)
        second.name = "Renamed"
        second.parentID = nil
        second.tailscale = library.group(second.id)?.tailscale
        second.tailscale?.exitNodeID = "exit-two"
        library.upsert(second)
        #expect(library.networkConfigurationStamp(for: firstHost) == firstStamp)
        #expect(library.host(secondHost.id)?.groupID == second.id)

        let envelopes = try VaultSyncJournal(context: source.mainContext).pendingEnvelopes()
            .map { try VaultSyncCodec.decode(VaultSyncCodec.encode($0)) }
        let target = try TermindPersistence.makeContainer(inMemory: true)
        let targetStore = HostPersistence(context: target.mainContext)
        #expect(try targetStore.conflictingTailscaleGroups(in: envelopes, deletions: []).isEmpty)
        _ = try targetStore.applyRemote(envelopes)
        let otherDevice = HostLibraryModel(persistence: targetStore)
        #expect(otherDevice.hosts.isEmpty)
        for group in [first, second] { otherDevice.replaceTailscalePeers([peer()], groupID: group.id) }
        #expect(otherDevice.host(firstHost.id)?.tags == ["alice"])
        #expect(otherDevice.host(secondHost.id)?.tags == ["bob"])
        #expect(otherDevice.savedTailscaleUsername(for: firstHost) == "alice")
        #expect(otherDevice.savedTailscaleUsername(for: secondHost) == "bob")
        otherDevice.deleteGroupProjection(first.id)
        #expect(otherDevice.host(firstHost.id) == nil)
        #expect(otherDevice.host(secondHost.id)?.tags == ["bob"])
    }

    @Test func groupScopedIdentityCannotBeWrittenAsV2AndOldReadersRejectV3() throws {
        let network = try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "example.ts.net")
        var group = HostGroup(name: "New connection")
        group.tailscale = TailscaleGroupConfiguration(network: network)
        let payload = VaultRecordPayload.hostGroup(group)
        var envelope = VaultEnvelope(key: payload.key, version: .baseline(writerID: UUID()), payload: payload)
        let bytes = try VaultSyncCodec.encode(envelope)
        #expect(try VaultSyncCodec.decode(bytes) == envelope)
        let oldReader = VersionedRecordDecoder<VaultEnvelope>([
            "hostGroup": [1: VaultSyncCodec.decode, 2: VaultSyncCodec.decode]
        ])
        #expect(throws: CloudSyncCompatibilityError.self) { try oldReader.decode(bytes) }
        envelope.formatVersion = 2
        #expect(throws: (any Error).self) { try VaultSyncCodec.encode(envelope) }
        #expect(
            try VaultSyncCodec.decode(VaultSyncCodec.encode(VaultSyncCodec.decode(Self.legacyGroup))).formatVersion == 2
        )
    }

    @Test(arguments: ["missing", "null", "unknown"])
    func v3RejectsInvalidIdentityMarkers(marker: String) throws {
        var value = try #require(JSONSerialization.jsonObject(with: Self.legacyGroup) as? [String: Any])
        value["formatVersion"] = 3
        var payload = try #require(value["payload"] as? [String: Any])
        var groupCase = try #require(payload["hostGroup"] as? [String: Any])
        var group = try #require(groupCase["_0"] as? [String: Any])
        var configuration = try #require(group["tailscale"] as? [String: Any])
        if marker == "null" { configuration["hostIdentityVersion"] = NSNull() }
        if marker == "unknown" { configuration["hostIdentityVersion"] = "future" }
        group["tailscale"] = configuration
        groupCase["_0"] = group
        payload["hostGroup"] = groupCase
        value["payload"] = payload
        #expect(throws: (any Error).self) { try VaultSyncCodec.decode(JSONSerialization.data(withJSONObject: value)) }
    }

    private func peer() -> TailscalePeer {
        TailscalePeer(
            stableID: "n123", name: "Server", dnsName: "server.example.ts.net", online: true, sshHostKeys: ["fixture"])
    }
}

@MainActor private final class MultiConnectionRoutingProbe: TailscaleConnectionProviding {
    var groups: [UUID] = []
    func connection(for groupID: UUID) throws -> any SSHNetworkDialing {
        groups.append(groupID)
        return MultiConnectionDialer()
    }
}

private nonisolated struct MultiConnectionDialer: SSHNetworkDialing {
    func open(host: String, port: Int, timeout: TimeInterval) async throws -> Int32 { throw CancellationError() }
    func hostKeys(stableNodeID: String) async throws -> Set<SSHHostKeyIdentity> { [] }
}
