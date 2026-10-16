import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import TermindPresentation
import Testing

import struct TermindDomain.Host

@Suite @MainActor
struct HostIconTests {
    @Test func darwinResolvesWithoutLinuxMetadata() throws {
        for kernel in ["Darwin", "darwin", "DARWIN"] {
            let info = RemoteSystemInfo(kernelName: kernel, kernelRelease: "25.0", architecture: "arm64")
            #expect(info.distributionDetection == .resolved(DetectedDistribution(id: "macos")))
            #expect(info.distributionID == nil)
            #expect(!info.factLines.contains("distribution_id: macos"))
        }
        #expect(RemoteSystemInfo(kernelName: "Windows_NT").distributionDetection == .resolved(nil))
    }

    @Test func manualArtworkNeverChangesDetectionAndAutomaticUsesLatestProbe() throws {
        let catalog = try fixtureCatalog()
        let host = Host(
            name: "Server", host: "server.invalid", detectedDistribution: DetectedDistribution(id: "ubuntu"))
        let library = HostLibraryModel(hosts: [host])
        var draft = host
        draft.iconOverrideID = "windows"
        #expect(library.host(host.id)?.iconOverrideID == nil)
        library.recordRemoteSystemInfo(RemoteSystemInfo(kernelName: "Darwin"), for: host.id)
        var reconnects = 0
        library.didChangeHostConnection = { _ in reconnects += 1 }
        library.didChangeTelnetConnection = { _ in reconnects += 1 }
        #expect(library.saveHost(draft))
        var saved = try #require(library.host(host.id))
        #expect(saved.iconOverrideID == "windows")
        #expect(saved.detectedDistribution?.id == "macos")
        #expect(
            catalog.resolvedEntry(overrideID: saved.iconOverrideID, distribution: saved.detectedDistribution)?.id
                == "windows")
        library.recordRemoteSystemInfo(
            RemoteSystemInfo(distributionID: "debian", kernelName: "Linux"), for: host.id)
        saved = try #require(library.host(host.id))
        #expect(saved.iconOverrideID == "windows")
        saved.iconOverrideID = nil
        #expect(library.saveHost(saved))
        #expect(
            catalog.resolvedEntry(overrideID: nil, distribution: library.host(host.id)?.detectedDistribution)?.id
                == "debian")
        #expect(reconnects == 0)
    }

    @Test func catalogResolvesOverridesAndPreservesLinuxFallbacks() throws {
        let catalog = try fixtureCatalog()
        let ubuntu = try #require(DetectedDistribution(id: "ubuntu"))
        #expect(catalog.resolvedEntry(overrideID: "macos", distribution: ubuntu)?.asset == "HostOS-macos")
        #expect(catalog.resolvedEntry(overrideID: "windows", distribution: ubuntu)?.asset == "HostOS-windows")
        #expect(catalog.resolvedEntry(overrideID: "server", distribution: ubuntu) == nil)
        #expect(catalog.resolvedEntry(overrideID: "future-os", distribution: ubuntu) == nil)
        #expect(catalog.resolvedEntry(overrideID: nil, distribution: ubuntu)?.asset == "LinuxDistro-ubuntu")
        #expect(
            catalog.entry(matching: try #require(DetectedDistribution(id: "custom", likeIDs: ["debian"])))?.id
                == "debian")
        #expect(catalog.selectableEntries.map(\.id) == ["bsd", "debian", "linux", "macos", "ubuntu", "windows"])
        #expect(Set(catalog.entries.map(\.id)).count == catalog.entries.count)
    }

    private func fixtureCatalog() throws -> HostIconCatalog {
        try JSONDecoder().decode(
            HostIconCatalog.self,
            from: Data(
                """
                {"entries":[
                {"id":"ubuntu","title":"Ubuntu","asset":"LinuxDistro-ubuntu","ids":["ubuntu"],"hex":"E95420"},
                {"id":"debian","title":"Debian","asset":"LinuxDistro-debian","ids":["debian"],"hex":"A81D33"},
                {"id":"macos","title":"macOS","asset":"HostOS-macos","ids":["macos"],"hex":"000000"},
                {"id":"windows","title":"Windows","asset":"HostOS-windows","ids":["windows"],"hex":"0078D4"},
                {"id":"linux","title":"Linux","asset":"HostOS-linux","ids":["linux"],"hex":"FCC624"},
                {"id":"bsd","title":"BSD","asset":"HostOS-bsd","ids":["bsd","dragonfly"],"hex":"AB2B28"}
                ]}
                """.utf8))
    }

    @Test func genericArtworkDoesNotReplaceExactMatchesOrManualChoices() throws {
        let catalog = try fixtureCatalog()
        let unknown = try #require(DetectedDistribution(id: "new-linux"))
        #expect(catalog.entry(matching: unknown)?.id == "linux")
        #expect(catalog.entry(matching: try #require(DetectedDistribution(id: "dragonfly")))?.id == "bsd")
        #expect(
            catalog.entry(
                matching: try #require(DetectedDistribution(id: "custom", likeIDs: ["missing", "debian", "ubuntu"])))?
                .id
                == "debian")
        #expect(
            catalog.entry(matching: try #require(DetectedDistribution(id: "ubuntu", likeIDs: ["debian"])))?.id
                == "ubuntu")
        #expect(catalog.resolvedEntry(overrideID: "server", distribution: unknown) == nil)
        #expect(catalog.resolvedEntry(overrideID: "future-icon", distribution: unknown) == nil)
        #expect(catalog.resolvedEntry(overrideID: nil, distribution: nil) == nil)
    }

    @Test func alphabeticalOrderIgnoresCaseAndUsesStableIDsForTies() throws {
        var catalog = try fixtureCatalog()
        let template = try #require(catalog.entries.first)
        catalog.entries = [("z", "alpha"), ("b", "Beta"), ("a", "ALPHA"), ("w", "Windows")].map { id, title in
            var entry = template
            entry.id = id
            entry.title = title
            return entry
        }
        #expect(catalog.selectableEntries.map(\.id) == ["a", "z", "b", "w"])
        catalog.entries.reverse()
        #expect(catalog.selectableEntries.map(\.id) == ["a", "z", "b", "w"])
    }

    @Test func legacyDomainJSONDefaultsToAutomaticAndUnknownIDsSurvive() throws {
        let host = Host(name: "Host", host: "example.invalid")
        let data = try JSONEncoder().encode(host)
        #expect(try JSONDecoder().decode(Host.self, from: data).iconOverrideID == nil)
        for id in ["server", "windows", "macos", "future-icon"] {
            var manual = host
            manual.iconOverrideID = id
            #expect(try JSONDecoder().decode(Host.self, from: JSONEncoder().encode(manual)) == manual)
            #expect(PersistentHost(manual).value == manual)
        }
    }

    @Test func savedChoicesSyncAndCanBeCleared() throws {
        let source = try TermindPersistence.makeContainer(inMemory: true)
        let destination = try TermindPersistence.makeContainer(inMemory: true)
        let store = HostPersistence(context: source.mainContext)
        let remote = HostPersistence(context: destination.mainContext)
        let library = HostLibraryModel(persistence: store)
        var host = Host(
            name: "Host", host: "example.invalid", detectedDistribution: DetectedDistribution(id: "dragonfly"))
        #expect(library.saveHost(host))
        host = try #require(library.host(host.id))
        let journal = VaultSyncJournal(context: source.mainContext)
        for choice: String? in ["windows", "macos", "freebsd", "bsd", "linux", "future-icon", nil] {
            host.iconOverrideID = choice
            #expect(library.saveHost(host))
            let envelope = try #require(try journal.envelope(for: .init(kind: .host, id: host.id)))
            #expect(envelope.formatVersion == SyncRecordFormats.vault.writingVersion(for: "host"))
            _ = try remote.applyRemote([VaultSyncCodec.decode(VaultSyncCodec.encode(envelope))])
            #expect(try remote.load().hosts.first?.iconOverrideID == choice)
            #expect(try remote.load().hosts.first?.detectedDistribution?.id == "dragonfly")
        }
    }

    @Test func tailscaleChoicesSurviveRediscoveryAndWireRoundTrips() throws {
        var group = HostGroup(name: "Tailnet")
        group.tailscale = TailscaleGroupConfiguration(
            network: try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "example.ts.net"))
        let peer = TailscalePeer(
            stableID: "n1", name: "Mac", dnsName: "mac.example.ts.net", online: true, sshHostKeys: ["ssh-ed25519 test"])
        let library = HostLibraryModel(groups: [group])
        library.replaceTailscalePeers([peer], groupID: group.id)
        var host = try #require(library.hosts.first)
        for choice: String? in ["windows", nil] {
            host.iconOverrideID = choice
            #expect(library.saveTailscaleHost(host))
            library.recordRemoteSystemInfo(RemoteSystemInfo(kernelName: "Darwin"), for: host.id)
            library.replaceTailscalePeers([peer], groupID: group.id)
            let projected = try #require(library.host(host.id))
            #expect(projected.iconOverrideID == choice)
            #expect(projected.detectedDistribution?.id == "macos")
            let payload = VaultRecordPayload.hostGroup(try #require(library.group(group.id)))
            let envelope = VaultEnvelope(key: payload.key, version: .baseline(writerID: UUID()), payload: payload)
            let restored = try VaultSyncCodec.decode(VaultSyncCodec.encode(envelope))
            #expect(restored == envelope)
            let container = try TermindPersistence.makeContainer(inMemory: true)
            let store = HostPersistence(context: container.mainContext)
            _ = try store.applyRemote([restored])
            let other = HostLibraryModel(persistence: store)
            other.replaceTailscalePeers([peer], groupID: group.id)
            #expect(other.host(host.id)?.iconOverrideID == choice)
        }
    }

    @Test func olderWireFormatsRejectLossyWritesAndDefaultToAutomatic() throws {
        var host = Host(name: "Host", host: "example.invalid", sessionPersistence: .init(enabled: false))
        for version in [1, 2, 4] {
            host.iconOverrideID = nil
            var envelope = VaultEnvelope(
                key: .init(kind: .host, id: host.id), version: .baseline(writerID: UUID()),
                payload: .host(host), formatVersion: version)
            #expect(try VaultSyncCodec.decode(VaultSyncCodec.encode(envelope)) == envelope)
            host.iconOverrideID = "windows"
            envelope.payload = .host(host)
            #expect(throws: (any Error).self) { try VaultSyncCodec.encode(envelope) }
        }
        for version in [1, 2, 4, 5] {
            let deletion = VaultEnvelope(
                key: .init(kind: .host, id: host.id), version: .baseline(writerID: UUID()),
                isDeleted: true, formatVersion: version)
            #expect(try VaultSyncCodec.decode(VaultSyncCodec.encode(deletion)) == deletion)
        }
    }

    @Test func failedSaveDoesNotPublishDraftArtwork() throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let store = HostPersistence(context: container.mainContext)
        let library = HostLibraryModel(persistence: store)
        let host = Host(name: "Host", host: "example.invalid")
        #expect(library.saveHost(host))
        let before = try #require(library.host(host.id))
        let journal = VaultSyncJournal(context: container.mainContext)
        let key = VaultRecordKey(kind: .host, id: host.id)
        let intent = try journal.envelope(for: key)
        let corrupt = try PersistentWorkspaceTemplate(WorkspaceTemplate(name: "Broken", layout: .pane(.empty)))
        corrupt.layoutData = Data("invalid".utf8)
        container.mainContext.insert(corrupt)
        try container.mainContext.save()
        var draft = before
        draft.iconOverrideID = "windows"
        #expect(!library.saveHost(draft))
        #expect(library.host(host.id) == before)
        #expect(try journal.envelope(for: key) == intent)
    }

    @Test func version53StoreMigratesThenRetainsArtworkOnReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Hosts.store")
        var host = Host(
            name: "Existing", host: "example.invalid", port: 2222, tags: ["production"], colorTag: .teal,
            detectedDistribution: DetectedDistribution(id: "ubuntu"),
            sessionPersistence: .init(enabled: true))
        do {
            let schema = Schema(versionedSchema: TermindSchemaV53.self)
            let legacy = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration("Termind", schema: schema, url: url, cloudKitDatabase: .none))
            legacy.mainContext.insert(TermindSchemaV53HostModels.PersistentHost(host))
            try legacy.mainContext.save()
        }
        do {
            let migrated = try TermindPersistence.makeContainer(url: url)
            let store = HostPersistence(context: migrated.mainContext)
            #expect(try store.load().hosts == [host])
            host.iconOverrideID = "macos"
            _ = try store.save(.init(hosts: [host]))
        }
        let reopened = try TermindPersistence.makeContainer(url: url)
        #expect(try HostPersistence(context: reopened.mainContext).load().hosts == [host])
    }
}
