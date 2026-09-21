import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

import struct TermindDomain.Host

@Suite @MainActor
struct HostShellIntegrationTests {
    @Test(arguments: HostShellIntegrationMode.allCases, [false, true])
    func overridesResolveAndRoundTrip(mode: HostShellIntegrationMode, global: Bool) throws {
        let expected = mode == .enabled || (mode == .followGlobalSettings && global)
        #expect(mode.isEnabled(globalSetting: global) == expected)
        let host = Host(
            name: "Server", host: "server.invalid", shellIntegrationMode: mode,
            startupSnippetID: UUID()
        )
        #expect(try JSONDecoder().decode(Host.self, from: JSONEncoder().encode(host)) == host)
        #expect(PersistentHost(host).value == host)
    }

    @Test func legacyAndUnknownModesFollowGlobalSettings() throws {
        let host = Host(name: "Server", host: "server.invalid")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as? [String: Any])
        for value: Any? in [nil, NSNull(), "future-mode"] {
            json["shellIntegrationMode"] = value
            let decoded = try JSONDecoder().decode(Host.self, from: JSONSerialization.data(withJSONObject: json))
            #expect(decoded == host)
        }
        json.removeValue(forKey: "startupSnippetID")
        let decoded = try JSONDecoder().decode(
            Host.self, from: JSONSerialization.data(withJSONObject: json)
        )
        #expect(decoded.startupSnippetID == nil)
    }

    @Test func savedModesSyncAndCanReturnToFollowingGlobalSettings() throws {
        let sourceContainer = try TermindPersistence.makeContainer(inMemory: true)
        let destinationContainer = try TermindPersistence.makeContainer(inMemory: true)
        let source = HostPersistence(context: sourceContainer.mainContext)
        let destination = HostPersistence(context: destinationContainer.mainContext)
        let library = HostLibraryModel(persistence: source)
        let journal = VaultSyncJournal(context: sourceContainer.mainContext)
        var host = Host(
            name: "Server", host: "server.invalid", startupSnippetID: UUID()
        )
        library.upsert(host)
        host = try #require(library.host(host.id))
        let key = VaultRecordKey(kind: .host, id: host.id)
        for mode in [HostShellIntegrationMode.enabled, .disabled, .followGlobalSettings] {
            var draft = host
            draft.shellIntegrationMode = mode
            #expect(library.host(host.id) == host)
            #expect(library.saveHost(draft))
            host = draft
            #expect(try source.load().hosts == [host])
            let outgoing = try #require(try journal.envelope(for: key))
            let incoming = try JSONDecoder().decode(VaultEnvelope.self, from: JSONEncoder().encode(outgoing))
            _ = try destination.applyRemote([incoming])
            #expect(try destination.load().hosts == [host])
            #expect(host.hasSameConnectionRoute(as: Host(id: host.id, name: host.name, host: host.host)))
        }
    }

    @Test func failedSavePreservesTheOriginalHostAndUploadIntent() throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let persistence = HostPersistence(context: container.mainContext)
        var host = Host(name: "Server", host: "server.invalid")
        let library = HostLibraryModel(persistence: persistence)
        library.upsert(host)
        host = try #require(library.host(host.id))
        let journal = VaultSyncJournal(context: container.mainContext)
        let key = VaultRecordKey(kind: .host, id: host.id)
        let before = try journal.envelope(for: key)
        let corrupt = try PersistentWorkspaceTemplate(WorkspaceTemplate(name: "Broken", layout: .pane(.empty)))
        corrupt.layoutData = Data("invalid".utf8)
        container.mainContext.insert(corrupt)
        try container.mainContext.save()
        var notifications = 0
        library.didRecordVaultChanges = { _ in notifications += 1 }
        var draft = host
        draft.shellIntegrationMode = .disabled
        #expect(!library.saveHost(draft))
        #expect(library.host(host.id) == host)
        #expect(library.storageError != nil)
        #expect(try journal.envelope(for: key) == before)
        #expect(try container.mainContext.fetch(FetchDescriptor<PersistentHost>()).map(\.value) == [host])
        #expect(notifications == 0)
    }

    @Test(arguments: [20, 21])
    func oldStoresMigrateAndReopenWithoutLosingHostFields(version: Int) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Termind.store")
        var host = Host(
            name: "Production", host: "server.invalid", port: 2222, identityID: UUID(), jumpHostID: UUID(),
            proxy: HostProxy(kind: .socks5, hostname: "proxy.invalid", port: 1080),
            sftpChannelInitialPath: "/srv/app", groupID: UUID(), tags: ["production"], colorTag: .teal,
            detectedDistribution: DetectedDistribution(id: "ubuntu", likeIDs: ["debian"]), sortIndex: 2.5)
        do {
            let schema = Schema(versionedSchema: version == 20 ? TermindSchemaV20.self : TermindSchemaV21.self)
            let legacy = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration("Termind", schema: schema, url: url, cloudKitDatabase: .none))
            legacy.mainContext.insert(TermindSchemaV8Models.PersistentHost(host))
            try legacy.mainContext.save()
        }
        do {
            let migrated = try TermindPersistence.makeContainer(url: url)
            let persistence = HostPersistence(context: migrated.mainContext)
            #expect(try persistence.load().hosts == [host])
            host.shellIntegrationMode = .disabled
            _ = try persistence.save(VaultSnapshot(hosts: [host]))
        }
        let reopened = try TermindPersistence.makeContainer(url: url)
        #expect(try HostPersistence(context: reopened.mainContext).load().hosts == [host])
    }
}
