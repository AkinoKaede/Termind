import Foundation
import SwiftData
import TermindDomain
import TermindPersistence
import Testing

@Suite @MainActor
struct SSHAgentForwardingPersistenceTests {
    @Test func version43HostMigratesDisabledAndNewSettingSurvivesReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Migration.store")
        let host = TermindDomain.Host(name: "Existing", host: "localhost", startupSnippetID: UUID())
        do {
            let schema = Schema(versionedSchema: TermindSchemaV43.self)
            let container = try ModelContainer(
                for: schema,
                configurations: [
                    ModelConfiguration("Termind", schema: schema, url: url, cloudKitDatabase: .none)
                ])
            container.mainContext.insert(TermindSchemaV32HostModels.PersistentHost(host))
            try container.mainContext.save()
        }
        do {
            let container = try TermindPersistence.makeContainer(url: url)
            let record = try #require(container.mainContext.fetch(FetchDescriptor<PersistentHost>()).first)
            #expect(!record.agentForwardingEnabled)
            #expect(record.value.startupSnippetID == host.startupSnippetID)
            record.agentForwardingEnabled = true
            try container.mainContext.save()
        }
        let reopened = try TermindPersistence.makeContainer(url: url)
        #expect(
            try reopened.mainContext.fetch(FetchDescriptor<PersistentHost>()).first?.value.agentForwardingEnabled
                == true)
    }

    @Test func hostVersionTwoRoundTripsAndCannotBeWrittenAsVersionOne() throws {
        let host = TermindDomain.Host(name: "Forwarded", host: "localhost", agentForwardingEnabled: true)
        let payload = VaultRecordPayload.host(host)
        var envelope = VaultEnvelope(key: payload.key, version: .baseline(writerID: UUID()), payload: payload)
        #expect(envelope.formatVersion == 2)
        #expect(try VaultSyncCodec.decode(VaultSyncCodec.encode(envelope)) == envelope)
        envelope.formatVersion = 1
        #expect(throws: (any Error).self) { try VaultSyncCodec.encode(envelope) }
        #expect(SyncRecordFormats.vault.writingVersion(for: "sshKey") == 1)
        #expect(SyncRecordFormats.vault.supports(kind: "host", version: 1))
    }
}
