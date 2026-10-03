import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@Suite @MainActor
struct TailscaleIntegrationTests {
    @Test func lateMetricsSyncCannotRestoreAnExplicitlyDeletedOrdinaryHost() throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let hostID = UUID()
        let tombstone = VaultEnvelope(
            key: VaultRecordKey(kind: .host, id: hostID),
            version: .baseline(writerID: UUID()), isDeleted: true)
        try VaultSyncJournal(context: container.mainContext).acceptRemote([tombstone])
        try container.mainContext.save()
        let metrics = MetricsSyncPersistence(context: container.mainContext)
        let payload = MetricsRecordPayload.selection(
            SyncedMetricsSelection(selection: MetricsSelection(id: hostID), sortIndex: 0))
        let result = try metrics.applyRemote([
            MetricsEnvelope(key: payload.key, version: .baseline(writerID: UUID()), payload: payload)
        ])
        #expect(result.snapshot.selections.isEmpty)
        #expect(result.needsUpload.contains(payload.key))
        #expect(try metrics.journal.envelope(for: payload.key)?.isDeleted == true)
    }

    @Test func losingProBlocksRetainedDialersWithoutClosingExistingNodes() async throws {
        let group = try group("example.ts.net")
        let library = HostLibraryModel(groups: [group])
        let store = InMemoryTailscaleLocalStore()
        try store.save(TailscaleLocalState(groupID: group.id, profileID: UUID()))
        let node = TestTailscaleNode(network: try #require(group.tailscale?.network))
        let access = TailscaleTestAccess()
        let model = TailscaleModel(
            library: library, store: store, factory: { _, _, _, _ in node },
            profileStorage: .init(profiles: { [] }, erase: { _ in }),
            hostname: { "Existing device name" }, hasAccess: { access.allowed })
        model.start()
        for _ in 0..<100 where !model.runningGroups.contains(group.id) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.runningGroups.contains(group.id))
        let retained = try model.connection(for: group.id)
        access.allowed = false
        model.reconcile()
        await #expect(throws: TailscaleConfigurationError.self) {
            try await retained.open(host: "server.example.ts.net", port: 22, timeout: 1)
        }
        #expect(await node.closed == false)
        await model.shutdown()
        #expect(await node.closed)
    }

    @Test func previousStoreMigratesGroupsWithoutChangingOrdinaryHosts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Termind.store")
        let ordinaryGroup = HostGroup(name: "Existing")
        let ordinaryHost = Host(name: "Existing", host: "example.invalid", groupID: ordinaryGroup.id)
        try writePreviousStore(url, group: ordinaryGroup, host: ordinaryHost)
        for _ in 0..<2 {
            let container = try TermindPersistence.makeContainer(url: url)
            let library = HostLibraryModel(persistence: HostPersistence(context: container.mainContext))
            #expect(library.host(ordinaryHost.id)?.host == ordinaryHost.host)
            #expect(library.group(ordinaryGroup.id)?.name == ordinaryGroup.name)
            #expect(library.group(ordinaryGroup.id)?.tailscale == nil)
        }
    }

    @Test func tailnetStoreReopensWithoutLosingEnrollmentOrPreferences() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Termind.store")
        var group = try group("example.ts.net")
        let hostID = try #require(group.tailscale).hostID(groupID: group.id, stableNodeID: "n123")
        var preferences = TailscaleHostPreferences()
        preferences.username = "deploy"
        preferences.tags = ["production"]
        preferences.colorTag = .purple
        group.tailscale?.hostPreferences[hostID] = preferences
        let profileID = UUID()
        let peer = peer()
        try writeTailnetStore(url, group: group, profileID: profileID, peer: peer)
        for pass in 0..<2 {
            let container = try TermindPersistence.makeContainer(url: url)
            let localStore = SwiftDataTailscaleLocalStore(context: container.mainContext)
            var state = try #require(localStore.load().first)
            #expect(state.groupID == group.id && state.profileID == profileID)
            #expect(state.peers == [peer])
            #expect(state.hostname == (pass == 0 ? nil : "saved-device"))
            let library = HostLibraryModel(persistence: HostPersistence(context: container.mainContext))
            #expect(library.group(group.id)?.tailscale?.hostPreferences[hostID] == preferences)
            library.replaceTailscalePeers([peer], groupID: group.id)
            #expect(library.hosts.first?.id == hostID)
            let retainedHost = try #require(library.host(hostID))
            #expect(library.savedTailscaleUsername(for: retainedHost) == "deploy")
            state.hostname = "saved-device"
            try localStore.save(state)
        }
    }

    private func writeTailnetStore(_ url: URL, group: HostGroup, profileID: UUID, peer: TailscalePeer) throws {
        let container = try TermindPersistence.makeContainer(url: url)
        _ = try HostPersistence(context: container.mainContext).save(.init(groups: [group]))
        try SwiftDataTailscaleLocalStore(context: container.mainContext).save(
            TailscaleLocalState(groupID: group.id, profileID: profileID, peers: [peer]))
    }

    private func writePreviousStore(_ url: URL, group: HostGroup, host: Host) throws {
        let schema = Schema(versionedSchema: TermindSchemaV46.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration("Termind", schema: schema, url: url, cloudKitDatabase: .none)
            ])
        container.mainContext.insert(PersistentHostGroup(group))
        container.mainContext.insert(PersistentHost(host))
        try container.mainContext.save()
    }

    private func group(_ suffix: String, parentID: UUID? = nil) throws -> HostGroup {
        let network = try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: suffix)
        var group = HostGroup(name: suffix, parentID: parentID)
        group.tailscale = TailscaleGroupConfiguration(network: network)
        group.tailscale?.username = "operator"
        return group
    }

    @Test func controlURLsRemainCanonicalConnectionConfiguration() throws {
        let first = try TailscaleNetwork(controlURL: "https://LOGIN.TAILSCALE.COM:443/", dnsSuffix: "Example.TS.NET.")
        let second = try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "example.ts.net")
        #expect(first == second)
        #expect(throws: TailscaleConfigurationError.self) {
            try TailscaleNetwork(controlURL: "https://user:secret@example.com", dnsSuffix: "example.com")
        }
    }

    @Test func subgroupOverridesNearestParentAndMovingChangesNewConnections() throws {
        let parent = try group("parent.ts.net")
        var child = HostGroup(name: "Child", parentID: parent.id)
        let leaf = HostGroup(name: "Leaf", parentID: child.id)
        let host = Host(name: "Manual", host: "server", groupID: leaf.id)
        let library = HostLibraryModel(hosts: [host], groups: [parent, child, leaf])
        #expect(library.tailscaleGroup(for: host)?.id == parent.id)
        child.tailscale = try group("child.ts.net").tailscale
        library.upsert(child)
        #expect(library.tailscaleGroup(for: host)?.id == child.id)
        child.tailscale = nil
        child.parentID = nil
        library.upsert(child)
        #expect(library.tailscaleGroup(for: host) == nil)
        child.parentID = parent.id
        library.upsert(child)
        #expect(throws: TailscaleConfigurationError.self) { try library.tailscaleNetwork(for: host) }
    }

    @Test func additionalOrdinaryConnectionsCannotDropTheirRequiredTailnetRoute() throws {
        let group = try group("example.ts.net")
        let host = Host(name: "Manual", host: "server", groupID: group.id)
        let library = HostLibraryModel(hosts: [host], groups: [group])
        let provider = TestTailscaleProvider()
        library.tailscaleConnections = provider
        var configuration = SSHConnectionConfiguration(
            hostID: host.id, host: host.host, port: 22, username: "operator", credentials: [], expectedHostKeys: [],
            authenticationReference: SSHAuthenticationReference(username: "operator", permitsNone: true))
        configuration.network = try library.tailscaleNetwork(for: host)
        let snapshot = library.additionalConnectionSnapshot(from: configuration)
        #expect(try library.additionalConnectionRequest(from: snapshot).configuration.network != nil)

        library.move(hostIDs: [host.id], into: nil)

        #expect(throws: TailscaleConfigurationError.self) { try library.additionalConnectionRequest(from: snapshot) }
        #expect(try library.tailscaleNetwork(for: host) == nil)
    }

    @Test func networkStampTracksOnlyThisConnectionsRoutingAndAuthentication() throws {
        var group = try group("example.ts.net")
        let library = HostLibraryModel(groups: [group])
        library.replaceTailscalePeers([peer()], groupID: group.id)
        let host = try #require(library.hosts.first)
        let original = library.networkConfigurationStamp(for: host)
        for _ in 0..<100 { #expect(library.networkConfigurationStamp(for: host) == original) }
        var unrelated = TailscaleHostPreferences()
        unrelated.username = "another-user"
        unrelated.tags = ["production"]
        group.tailscale?.hostPreferences[UUID()] = unrelated
        library.upsert(group)
        #expect(library.networkConfigurationStamp(for: host) == original)
        group.tailscale?.username = "changed-user"
        library.upsert(group)
        let changedUser = library.networkConfigurationStamp(for: host)
        #expect(changedUser != original)
        group.tailscale?.exitNodeID = "exit-node"
        library.upsert(group)
        #expect(library.networkConfigurationStamp(for: host) != changedUser)
    }

    @Test(arguments: [true, false])
    func loginRechecksRemoteGroupChangesAfterApplyingExitNode(deleted: Bool) async throws {
        var group = try group("example.ts.net")
        let library = HostLibraryModel(groups: [group])
        let store = InMemoryTailscaleLocalStore()
        let node = TestTailscaleNode(network: try #require(group.tailscale?.network), holdExitNode: true)
        let model = TailscaleModel(
            library: library, store: store, factory: { _, _, _, _ in node },
            profileStorage: .init(profiles: { [] }, erase: { _ in }),
            hostname: { "device" }, hasAccess: { true })
        model.beginLoginAndSave(
            name: group.name, parentID: nil, controlURL: TailscaleNetwork.defaultControlURL,
            authKey: nil, groupID: group.id)
        await node.waitForExitNode()
        group.name = "Remote name"
        group.tailscale?.username = "remote-user"
        library.replacePersistedSnapshot(VaultSnapshot(groups: deleted ? [] : [group]))
        await node.releaseExitNode()
        for _ in 0..<1000 {
            if deleted ? await node.closed : model.loginCompletedGroupID != nil { break }
            await Task.yield()
        }
        if deleted {
            #expect(library.group(group.id) == nil)
            #expect(try store.load().isEmpty)
            #expect(model.loginCompletedGroupID == nil)
            #expect(await node.closed)
            #expect(await node.logoutCount == 1)
        } else {
            #expect(library.group(group.id)?.name == "Remote name")
            #expect(library.group(group.id)?.tailscale?.username == "remote-user")
            #expect(model.loginCompletedGroupID == group.id)
            #expect(try store.load().count == 1)
        }
        await model.shutdown()
    }

    @Test func sameTailnetCanBeBoundToAnExplicitSubgroup() throws {
        let parent = try group("example.ts.net")
        let library = HostLibraryModel(groups: [parent])
        var duplicate = HostGroup(name: "Duplicate", parentID: parent.id)
        duplicate.tailscale = parent.tailscale
        library.upsert(duplicate)
        #expect(library.group(duplicate.id)?.tailscale?.network == parent.tailscale?.network)
        #expect(library.storageError == nil)
    }

    @Test func discoveredHostsStayLocalAndPreferencesRoundTripThroughGroup() throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let persistence = HostPersistence(context: container.mainContext)
        let library = HostLibraryModel(persistence: persistence)
        let group = try group("example.ts.net")
        library.upsert(group)
        library.replaceTailscalePeers([peer()], groupID: group.id)
        let managed = try #require(library.hosts.first)
        #expect(managed.host == "server.example.ts.net")
        #expect(library.saveTailscaleUsername("root", hostID: managed.id))
        library.projectHostDeletion(managed.id)
        #expect(library.host(managed.id) != nil)
        var forged = managed
        forged.host = "attacker.invalid"
        #expect(!library.saveHost(forged))
        let reloaded = HostLibraryModel(persistence: persistence)
        #expect(reloaded.hosts.isEmpty)
        reloaded.replaceTailscalePeers([peer(name: "Renamed", online: false)], groupID: group.id)
        #expect(reloaded.hosts.first?.id == managed.id)
        #expect(reloaded.tailscaleUsername(for: managed) == "root")
        #expect(!reloaded.isEligible(managed, for: .keyExport))
        #expect(!reloaded.isEligible(managed, for: .jumpHost))
    }

    @Test func managedPreparationAndExtraConnectionsNeverResolveOrdinaryCredentials() async throws {
        let group = try group("example.ts.net")
        let library = HostLibraryModel(groups: [group])
        let provider = TestTailscaleProvider()
        library.tailscaleConnections = provider
        library.replaceTailscalePeers([peer()], groupID: group.id)
        let host = try #require(library.hosts.first)
        let preparation = try library.prepareSSHConnection(for: host, submissions: [:], proxySubmissions: [:])
        #expect(preparation.nodes.first?.identity == nil)
        #expect(preparation.nodes.first?.key == nil)
        let configuration = try await preparation.resolve()
        #expect(configuration.credentials.isEmpty)
        #expect(configuration.expectedHostKeys.isEmpty)
        #expect(configuration.tailscaleNodeID == "n123")
        #expect(configuration.network != nil)
        let snapshot = library.additionalConnectionSnapshot(from: configuration)
        let extra = try library.additionalConnectionRequest(from: snapshot)
        #expect(extra.configuration.credentials.isEmpty)
        #expect(extra.configuration.network != nil)
        #expect(extra.configuration.tailscaleNodeID == "n123")
        provider.allowed = false
        #expect(throws: TailscaleConfigurationError.self) { try library.additionalConnectionRequest(from: snapshot) }
    }

    @Test func tagsAndColorSyncBeforeAnotherDeviceDiscoversTheHost() throws {
        let source = try TermindPersistence.makeContainer(inMemory: true)
        let sourceLibrary = HostLibraryModel(persistence: HostPersistence(context: source.mainContext))
        let group = try group("example.ts.net")
        sourceLibrary.upsert(group)
        sourceLibrary.replaceTailscalePeers([peer()], groupID: group.id)
        var host = try #require(sourceLibrary.hosts.first)
        host.tags = ["production", "linux"]
        host.colorTag = .blue
        #expect(sourceLibrary.saveHost(host))
        sourceLibrary.recordRemoteSystemInfo(
            RemoteSystemInfo(distributionID: "ubuntu", distributionLikeIDs: ["debian"], kernelName: "Linux"),
            for: host.id)
        sourceLibrary.replaceTailscalePeers([peer(name: "Refreshed")], groupID: group.id)
        #expect(sourceLibrary.host(host.id)?.detectedDistribution?.id == "ubuntu")
        var exitGroup = try #require(sourceLibrary.group(group.id))
        exitGroup.tailscale?.exitNodeID = "exit-node-stable-id"
        sourceLibrary.upsert(exitGroup)

        let envelopes = try VaultSyncJournal(context: source.mainContext).pendingEnvelopes()
        #expect(!envelopes.contains { $0.key.kind == .host })
        let remote = try envelopes.map { try VaultSyncCodec.decode(VaultSyncCodec.encode($0)) }
        let destination = try TermindPersistence.makeContainer(inMemory: true)
        let destinationStore = HostPersistence(context: destination.mainContext)
        _ = try destinationStore.applyRemote(remote)
        let destinationLibrary = HostLibraryModel(persistence: destinationStore)
        #expect(destinationLibrary.hosts.isEmpty)
        destinationLibrary.replaceTailscalePeers([peer(name: "Renamed")], groupID: group.id)
        let discovered = try #require(destinationLibrary.host(host.id))
        #expect(discovered.tags == ["production", "linux"])
        #expect(discovered.colorTag == .blue)
        #expect(discovered.detectedDistribution?.id == "ubuntu")
        #expect(destinationLibrary.group(group.id)?.tailscale?.exitNodeID == "exit-node-stable-id")
        #expect(discovered.name == "Renamed")
        destinationLibrary.recordRemoteSystemInfo(RemoteSystemInfo(kernelName: "Linux"), for: discovered.id)
        #expect(destinationLibrary.host(discovered.id)?.detectedDistribution?.id == "ubuntu")
        destinationLibrary.recordRemoteSystemInfo(RemoteSystemInfo(kernelName: "Darwin"), for: discovered.id)
        destinationLibrary.replaceTailscalePeers([peer()], groupID: group.id)
        #expect(destinationLibrary.host(discovered.id)?.detectedDistribution == nil)
    }

    @Test func usernamePromptsAndRouteSavingNeverCreateOrdinaryIdentities() async throws {
        var group = try group("example.ts.net")
        group.tailscale?.username = ""
        let library = HostLibraryModel(groups: [group])
        let provider = TestTailscaleProvider()
        library.tailscaleConnections = provider
        library.replaceTailscalePeers([peer()], groupID: group.id)
        let host = try #require(library.hosts.first)
        let prompt = SSHAuthenticationPromptResolver.host(host, using: library, username: "")
        #expect(prompt.usernameOnly)
        #expect(prompt.username == "root")
        #expect(prompt.selectedIdentityID == nil && prompt.selectedKeyID == nil)
        #expect(!prompt.requiresPassphrase)
        let submission = SSHAuthenticationSubmission(username: "operator")
        _ = try library.saveAuthentication(submission, for: host, selectedIdentity: nil, suppliedPassword: nil)
        #expect(library.tailscaleUsername(for: host) == "operator")
        #expect(library.identities.isEmpty)
        _ = try library.saveConnectionRoute(
            SSHConnectionRoute(hosts: [host]), authentication: submission, authenticationHostID: host.id)
        #expect(library.identities.isEmpty && library.hosts.count == 1)
        let ephemeral = SSHAuthenticationSubmission(username: "another-user", password: "ignored", keyID: UUID())
        let preparation = try library.prepareSSHConnection(for: host, submissions: [host.id: ephemeral])
        let configuration = try await preparation.resolve()
        #expect(configuration.username == "another-user")
        #expect(configuration.credentials.isEmpty)
        #expect(configuration.tailscaleNodeID == "n123")
        #expect(library.tailscaleUsername(for: host) == "operator")
    }

    @Test func assistantAndExternalUsernameRequestsUseTheTailscalePrompt() async throws {
        var group = try group("example.ts.net")
        group.tailscale?.username = ""
        let library = HostLibraryModel(groups: [group])
        let provider = TestTailscaleProvider()
        library.tailscaleConnections = provider
        library.replaceTailscalePeers([peer()], groupID: group.id)
        let host = try #require(library.hosts.first)
        let interaction = AgentSSHInteraction(
            authenticate: { request in
                #expect(request.mode == .tailscaleUsername)
                #expect(request.journeyPrompt.usernameOnly)
                #expect(request.selectedIdentityID == nil && request.selectedKeyID == nil)
                return .submit(AgentSSHAuthenticationAnswer(username: "deploy", save: true))
            },
            confirmHostKey: { _ in
                Issue.record("Managed hosts must not ask for ordinary host-key trust")
                return .deny
            })
        let session = AgentSSHAuthenticationContext(
            resolver: AgentHostResolver(store: library), hostID: host.id, invocationID: UUID(), interaction: interaction
        )
        let configuration = try await session.configuration()
        #expect(configuration.username == "deploy")
        #expect(configuration.credentials.isEmpty)
        #expect(configuration.tailscaleNodeID == "n123")
        #expect(library.tailscaleUsername(for: host) == "deploy")
        #expect(library.identities.isEmpty)
        let resumed = AgentSSHAuthenticationContext(
            resolver: AgentHostResolver(store: library), hostID: host.id, invocationID: UUID(),
            interaction: AgentSSHInteraction(
                authenticate: { _ in
                    Issue.record("Saved Tailscale username must bypass the initial prompt")
                    return .cancelled
                }, confirmHostKey: { _ in .deny }))
        #expect(try await resumed.configuration().username == "deploy")
    }

    @Test func olderHostPreferencesDecodeWithoutTagsOrColor() throws {
        let data = Data(
            #"{"username":"operator","charset":"utf8","sftpInitialPath":"/srv","shellIntegrationMode":"followGlobalSettings","environmentVariables":[]}"#
                .utf8)
        let preferences = try JSONDecoder().decode(TailscaleHostPreferences.self, from: data)
        #expect(preferences.tags.isEmpty)
        #expect(preferences.colorTag == .none)
        #expect(preferences.username == "operator")
        #expect(preferences.sftpInitialPath == "/srv")
    }

    @Test func nodesWithoutSSHDisappearWithoutLosingSyncedPreferencesOrManualHosts() throws {
        let group = try group("example.ts.net")
        let manual = Host(name: "Manual", host: "manual.example.ts.net", groupID: group.id)
        let library = HostLibraryModel(hosts: [manual], groups: [group])
        library.replaceTailscalePeers([peer()], groupID: group.id)
        var managed = try #require(library.hosts.first { $0.isTailscaleManaged })
        managed.tags = ["keep"]
        #expect(library.saveHost(managed))
        var disabled = peer()
        disabled.sshHostKeys = []
        library.replaceTailscalePeers([disabled], groupID: group.id)
        #expect(library.host(managed.id) == nil)
        #expect(library.host(manual.id) != nil)
        library.replaceTailscalePeers([peer(online: false)], groupID: group.id)
        #expect(library.host(managed.id)?.tags == ["keep"])
    }

    @Test func statusRetainsNonSSHPeersForDiagnosticsAndReportsLocalDeviceDetails() throws {
        let data = Data(
            #"{"BackendState":"Running","CurrentTailnet":{"Name":"Example","MagicDNSSuffix":"example.ts.net"},"Self":{"HostName":"Phone","DNSName":"phone.example.ts.net.","TailscaleIPs":["100.64.0.1","fd7a:115c:a1e0::1"],"OS":"iOS","KeyExpiry":"2027-01-02T03:04:05.123Z"},"Peer":{"disabled":{"ID":"n456","HostName":"desktop","DNSName":"desktop.example.ts.net.","Online":true,"InNetworkMap":true,"ExitNodeOption":true}}}"#
                .utf8)
        let status = try LibTailscaleNodeSession.decodeStatus(data, controlURL: TailscaleNetwork.defaultControlURL)
        #expect(status.peers.count == 1)
        #expect(status.peers.first?.supportsSSH == false)
        #expect(status.peers.first?.exitNodeOption == true)
        let device = try #require(status.device)
        #expect(device.networkName == "Example")
        #expect(device.dnsName == "phone.example.ts.net")
        #expect(device.hostname == "Phone")
        #expect(device.addresses == ["100.64.0.1", "fd7a:115c:a1e0::1"])
        #expect(device.operatingSystem == "iOS")
        #expect(device.keyExpiry != nil)
    }

    @Test func missingTailscaleMetricsRetainConfigurationUntilExplicitGroupDeletion() throws {
        let group = try group("example.ts.net")
        var selection = MetricsSelection(id: UUID(), enabled: false)
        selection.tailscaleGroupID = group.id
        selection.displayName = "Offline node"
        let preferences = TailscaleMetricsPreferences(values: [selection])
        let library = HostLibraryModel(groups: [group])
        let metrics = ServerMetricsModel(
            hosts: library, preferences: preferences,
            makeSampler: { TailscaleTestSampler() })
        metrics.start()
        defer { metrics.shutdown() }
        #expect(metrics.servers.isEmpty)
        #expect(metrics.selections == [selection])
        #expect(metrics.replaceHosts(selectedIDs: [], editableHostIDs: []))
        #expect(preferences.values == [selection])
        metrics.removeTailscaleGroups([group.id])
        #expect(preferences.values.isEmpty)
        #expect(metrics.servers.isEmpty)
    }

    @Test func statusRequiresAnAuthoritativePeerMapAndKeepsOfflineNodes() throws {
        let data = Data(
            #"{"BackendState":"Running","CurrentTailnet":{"MagicDNSSuffix":"example.ts.net"},"Peer":{"key":{"ID":"n123","HostName":"server","DNSName":"server.example.ts.net.","Online":false,"InNetworkMap":true,"sshHostKeys":["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"]}}}"#
                .utf8)
        let status = try LibTailscaleNodeSession.decodeStatus(data, controlURL: TailscaleNetwork.defaultControlURL)
        #expect(status.running)
        #expect(status.peers.count == 1)
        #expect(status.peers.first?.online == false)
        let incomplete = Data(#"{"BackendState":"Running","CurrentTailnet":{"MagicDNSSuffix":"example.ts.net"}}"#.utf8)
        #expect(throws: DecodingError.self) {
            try LibTailscaleNodeSession.decodeStatus(incomplete, controlURL: TailscaleNetwork.defaultControlURL)
        }
        let empty = Data(
            #"{"BackendState":"Running","CurrentTailnet":{"MagicDNSSuffix":"example.ts.net"},"Peer":null}"#.utf8)
        #expect(try LibTailscaleNodeSession.decodeStatus(empty, controlURL: TailscaleNetwork.defaultControlURL).running)
        #expect(LibTailscaleNodeSession.hostKey("ssh-ed25519 invalid") == nil)
        #expect(
            LibTailscaleNodeSession.hostKey(
                "ssh-rsa AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA") == nil)
    }

    @Test func savedUsernameAppearsInCardsWithoutInventingAnUnsavedLogin() throws {
        var group = try group("example.ts.net")
        group.tailscale?.username = ""
        let library = HostLibraryModel(groups: [group])
        library.replaceTailscalePeers([peer()], groupID: group.id)
        let host = try #require(library.hosts.first)
        #expect(library.savedTailscaleUsername(for: host) == nil)
        #expect(library.loginAddress(for: host) == "server.example.ts.net")
        #expect(library.saveTailscaleUsername("operator", hostID: host.id))
        #expect(library.loginAddress(for: host) == "operator@server.example.ts.net")
        #expect(library.identities.isEmpty)
    }

    @Test func sshCommandUsesTailscaleUsernameAndPreviewsUnsavedEdits() throws {
        let group = try group("example.ts.net")
        let library = HostLibraryModel(groups: [group])
        library.replaceTailscalePeers([peer()], groupID: group.id)
        let host = try #require(library.hosts.first)

        #expect(library.sshCommand(for: host) == "ssh operator@server.example.ts.net")
        #expect(library.saveTailscaleUsername("deploy", hostID: host.id))
        #expect(library.sshCommand(for: host) == "ssh deploy@server.example.ts.net")
        #expect(
            library.sshCommand(for: host, username: " o'brien ")
                == "ssh 'o'\"'\"'brien@server.example.ts.net'")
        #expect(library.sshCommand(for: host, username: "") == "ssh server.example.ts.net")
        #expect(library.savedTailscaleUsername(for: host) == "deploy")
        #expect(library.identities.isEmpty)
    }

    @Test func hostnamePersistsLocallyAndEditsReachTheRunningNode() async throws {
        let group = try group("example.ts.net")
        let library = HostLibraryModel(groups: [group])
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let store = SwiftDataTailscaleLocalStore(context: container.mainContext)
        try store.save(TailscaleLocalState(groupID: group.id, profileID: UUID()))
        let node = TestTailscaleNode(network: try #require(group.tailscale?.network))
        let model = TailscaleModel(
            library: library, store: store, factory: { _, _, _, _ in node },
            profileStorage: .init(profiles: { [] }, erase: { _ in }),
            hostname: { "default-device" }, hasAccess: { true })
        model.start()
        for _ in 0..<100 where !model.runningGroups.contains(group.id) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try store.load().first?.hostname == "default-device")
        try await model.saveHostname("  custom-device  ", groupID: group.id)
        #expect(await node.hostname == "custom-device")
        #expect(try store.load().first?.hostname == "custom-device")
        await model.shutdown()
        let restored = TailscaleModel(
            library: library, store: store, factory: { _, _, _, _ in node },
            profileStorage: .init(profiles: { [] }, erase: { _ in }),
            hostname: { "renamed-system-device" }, hasAccess: { false })
        restored.start()
        #expect(restored.savedHostname(groupID: group.id) == "custom-device")
        await restored.shutdown()
    }

    @Test func pingDistinguishesDirectRelayUnknownAndServerFailure() throws {
        func decode(_ json: String) throws -> TailscalePingResult {
            try LibTailscaleNodeSession.decodePing(Data(json.utf8))
        }
        let direct = try decode(#"{"LatencySeconds":0.012,"Endpoint":"192.0.2.1:41641"}"#)
        #expect(direct.milliseconds == 12)
        #expect(direct.route == .direct("192.0.2.1:41641"))
        #expect(try decode(#"{"LatencySeconds":0.1,"DERPRegionID":3,"DERPRegionCode":"sin"}"#).route == .derp("sin"))
        #expect(
            try decode(#"{"LatencySeconds":0.1,"PeerRelay":"100.64.0.1:1:vni:2"}"#).route
                == .peerRelay("100.64.0.1:1:vni:2"))
        #expect(try decode(#"{"LatencySeconds":0.1}"#).route == .unknown)
        #expect(throws: TermindSSHError.self) { try decode(#"{"Err":"peer is offline"}"#) }
    }

    @Test func syncedExitNodeIsAppliedAndCanBeDisabled() async throws {
        var group = try group("example.ts.net")
        group.tailscale?.exitNodeID = "exit-one"
        let library = HostLibraryModel(groups: [group])
        let store = InMemoryTailscaleLocalStore()
        try store.save(TailscaleLocalState(groupID: group.id, profileID: UUID(), hostname: "device"))
        let exitPeer = TailscalePeer(
            stableID: "exit-one", name: "Exit without SSH", dnsName: "exit.example.ts.net",
            online: true, sshHostKeys: [], exitNodeOption: true)
        let node = TestTailscaleNode(
            network: try #require(group.tailscale?.network), peers: [exitPeer, peer()])
        let model = TailscaleModel(
            library: library, store: store, factory: { _, _, _, _ in node },
            profileStorage: .init(profiles: { [] }, erase: { _ in }),
            hostname: { "device" }, hasAccess: { true })
        model.start()
        for _ in 0..<100 where !model.runningGroups.contains(group.id) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await node.selectedExitNode == "exit-one")
        #expect(model.exitNodeCandidates(groupID: group.id).map(\.stableID) == ["exit-one"])
        #expect(!library.hosts.contains { $0.tailscale?.stableNodeID == "exit-one" })
        let retained = try model.connection(for: group.id)
        group.tailscale?.exitNodeID = "exit-two"
        library.upsert(group)
        await #expect(throws: TailscaleConfigurationError.self) {
            try await retained.open(host: "example.com", port: 22, timeout: 1)
        }
        for _ in 0..<400 {
            if await node.selectedExitNode == "exit-two" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await node.selectedExitNode == "exit-two")
        try model.saveExitNode("", groupID: group.id)
        for _ in 0..<400 {
            if await node.selectedExitNode == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await node.selectedExitNode == nil)
        #expect(library.group(group.id)?.tailscale?.exitNodeID == nil)
        await model.shutdown()
    }

    private func peer(name: String = "Server", online: Bool = true) -> TailscalePeer {
        TailscalePeer(
            stableID: "n123", name: name, dnsName: "server.example.ts.net", online: online,
            sshHostKeys: ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"])
    }
}

@MainActor private final class TestTailscaleProvider: TailscaleConnectionProviding {
    var allowed = true
    func connection(for groupID: UUID) throws -> any SSHNetworkDialing {
        guard allowed else { throw TailscaleConfigurationError.requiresPro }
        return TestTailscaleDialer()
    }
}

private nonisolated struct TestTailscaleDialer: SSHNetworkDialing {
    func open(host: String, port: Int, timeout: TimeInterval) async throws -> Int32 { throw CancellationError() }
    func hostKeys(stableNodeID: String) async throws -> Set<SSHHostKeyIdentity> { [] }
}

@MainActor private final class TailscaleMetricsPreferences: MetricsConfigurationStoring {
    var values: [MetricsSelection]
    init(values: [MetricsSelection]) { self.values = values }
    func load() throws -> [MetricsSelection] { values }
    func save(_ selections: [MetricsSelection]) throws { values = selections }
}

private nonisolated struct TailscaleTestSampler: MetricsSampling {
    func connect(_ configuration: SSHConnectionConfiguration) async throws { throw CancellationError() }
    func sample() async throws -> MetricsSample { throw CancellationError() }
    func gpu() async throws -> NvidiaSnapshot? { nil }
    func disconnect() async {}
}

@MainActor private final class TailscaleTestAccess { var allowed = true }

private actor TestTailscaleNode: TailscaleNodeSession {
    let network: TailscaleNetwork
    let peers: [TailscalePeer]
    var closed = false
    var hostname = ""
    var selectedExitNode: String?
    var logoutCount = 0
    private var holdExitNode: Bool
    private var exitNodeContinuation: CheckedContinuation<Void, Never>?
    func setExitNode(_ stableID: String?) async throws {
        if holdExitNode {
            holdExitNode = false
            await withCheckedContinuation { exitNodeContinuation = $0 }
        }
        selectedExitNode = stableID
    }
    func waitForExitNode() async {
        while exitNodeContinuation == nil { await Task.yield() }
    }
    func releaseExitNode() {
        exitNodeContinuation?.resume()
        exitNodeContinuation = nil
    }
    func setHostname(_ hostname: String) async throws { self.hostname = hostname }
    init(network: TailscaleNetwork, peers: [TailscalePeer] = [], holdExitNode: Bool = false) {
        self.network = network
        self.peers = peers
        self.holdExitNode = holdExitNode
    }
    func status() async throws -> TailscaleNodeStatus {
        TailscaleNodeStatus(running: true, network: network, authURL: nil, peers: peers)
    }
    func login() async throws {}
    func logout() async throws { logoutCount += 1 }
    func close() async { closed = true }
    func dial(host: String, port: Int, timeout: TimeInterval) async throws -> Int32 { throw CancellationError() }
    func hostKeys(stableNodeID: String) async throws -> Set<SSHHostKeyIdentity> { [] }
}
