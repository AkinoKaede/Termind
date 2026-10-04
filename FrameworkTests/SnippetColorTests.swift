import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

import struct TermindDomain.Host

@Suite @MainActor
struct SnippetColorTests {
    @Test func legacySnippetsDecodeWithoutColorAndDuplicationPreservesEveryColor() throws {
        var snippet = Snippet(title: "Deploy", body: "deploy", packageID: UUID(), targetHostIDs: [UUID()])
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snippet)) as? [String: Any])
        legacy.removeValue(forKey: "colorTag")
        #expect(
            try JSONDecoder().decode(Snippet.self, from: JSONSerialization.data(withJSONObject: legacy)) == snippet)
        legacy["colorTag"] = "future-color"
        #expect(
            try JSONDecoder().decode(Snippet.self, from: JSONSerialization.data(withJSONObject: legacy)) == snippet)
        for color in TagColor.allCases {
            snippet.colorTag = color
            #expect(try JSONDecoder().decode(Snippet.self, from: JSONEncoder().encode(snippet)) == snippet)
            let copy = snippet.duplicated()
            #expect(copy.id != snippet.id)
            #expect(copy.colorTag == color)
            #expect(copy.body == snippet.body)
            #expect(copy.packageID == snippet.packageID)
            #expect(copy.targetHostIDs == snippet.targetHostIDs)
        }
    }

    @Test func colorsPersistOnlyWhenSavedAndSyncCanSetAndClearThem() throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let persistence = HostPersistence(context: container.mainContext)
        let library = SnippetLibraryModel(library: HostLibraryModel(persistence: persistence))
        let original = Snippet(title: "Status", body: "uptime", colorTag: .teal)
        library.upsert(original)
        var draft = original
        draft.colorTag = .pink
        #expect(library.snippets == [original])
        library.upsert(draft)
        #expect(try persistence.load().snippets == [draft])

        let remoteContainer = try TermindPersistence.makeContainer(inMemory: true)
        let remote = HostPersistence(context: remoteContainer.mainContext)
        for (index, color) in [TagColor.pink, .none].enumerated() {
            draft.colorTag = color
            let payload = VaultRecordPayload.snippet(draft)
            let envelope = VaultEnvelope(
                key: payload.key,
                version: .next(after: nil, writerID: UUID(), now: Date(timeIntervalSince1970: Double(index + 1))),
                payload: payload)
            #expect(envelope.formatVersion == 2)
            let received = try VaultSyncCodec.decode(VaultSyncCodec.encode(envelope))
            _ = try remote.applyRemote([received])
            #expect(try remote.load().snippets == [draft])
        }
    }

    @Test func versionOneDefaultsToNoColorAndRejectsLossyColorWrites() throws {
        var snippet = Snippet(title: "Status", body: "uptime")
        var payload = VaultRecordPayload.snippet(snippet)
        var envelope = VaultEnvelope(
            key: payload.key, version: .baseline(writerID: UUID()), payload: payload, formatVersion: 1)
        #expect(try VaultSyncCodec.decode(VaultSyncCodec.encode(envelope)) == envelope)
        snippet.colorTag = .red
        payload = .snippet(snippet)
        envelope.payload = payload
        #expect(throws: (any Error).self) { try VaultSyncCodec.encode(envelope) }
        envelope.formatVersion = 2
        #expect(try VaultSyncCodec.decode(VaultSyncCodec.encode(envelope)) == envelope)
    }

    @Test func historicalV1AndColoredV2CanBeAppliedToTheSameJournal() throws {
        let bytes = Data(
            #"{"formatVersion":1,"key":{"kind":"snippet","id":"11111111-1111-1111-1111-111111111111"},"version":{"modifiedAt":0,"counter":1,"writerID":"22222222-2222-2222-2222-222222222222"},"isDeleted":false,"payload":{"snippet":{"_0":{"id":"11111111-1111-1111-1111-111111111111","title":"Legacy","body":"pwd","targetHostIDs":[],"sortIndex":2}}}}"#
                .utf8)
        var legacy = try VaultSyncCodec.decode(bytes)
        guard case .snippet(var snippet) = legacy.payload else {
            Issue.record("Missing legacy snippet")
            return
        }
        #expect(snippet.colorTag == .none)
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let persistence = HostPersistence(context: container.mainContext)
        _ = try persistence.applyRemote([legacy])
        #expect(try persistence.load().snippets == [snippet])
        #expect(try VaultSyncJournal(context: container.mainContext).pendingEnvelopes().isEmpty)

        snippet.colorTag = .blue
        let colored = VaultEnvelope(
            key: legacy.key, version: .next(after: legacy.version, writerID: UUID()),
            payload: .snippet(snippet))
        _ = try persistence.applyRemote([VaultSyncCodec.decode(VaultSyncCodec.encode(colored))])
        #expect(try persistence.load().snippets == [snippet])

        legacy.version = .next(after: colored.version, writerID: UUID())
        _ = try persistence.applyRemote([VaultSyncCodec.decode(VaultSyncCodec.encode(legacy))])
        snippet.colorTag = .none
        #expect(try persistence.load().snippets == [snippet])
        for version in [1, 2] {
            let deletion = VaultEnvelope(
                key: legacy.key, version: .next(after: legacy.version, writerID: UUID()),
                isDeleted: true, formatVersion: version)
            #expect(try VaultSyncCodec.decode(VaultSyncCodec.encode(deletion)) == deletion)
        }
    }

    @Test func version50StoreMigratesWithoutChangingSnippetContentAndRetainsColorOnReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Snippets.store")
        let host = Host(name: "Server", host: "server.invalid")
        let package = SnippetPackage(name: "Operations")
        var snippet = Snippet(
            title: "Status", body: "uptime\npwd", packageID: package.id, targetHostIDs: [host.id], sortIndex: 3)
        do {
            let schema = Schema(versionedSchema: TermindSchemaV50.self)
            let legacy = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration("Termind", schema: schema, url: url, cloudKitDatabase: .none)])
            legacy.mainContext.insert(PersistentHost(host))
            legacy.mainContext.insert(PersistentSnippetPackage(package))
            legacy.mainContext.insert(TermindSchemaV50SnippetModels.PersistentSnippet(snippet))
            try legacy.mainContext.save()
        }
        do {
            let container = try TermindPersistence.makeContainer(url: url)
            let persistence = HostPersistence(context: container.mainContext)
            let snapshot = try persistence.load()
            #expect(snapshot.snippets == [snippet])
            #expect(snapshot.hosts == [host])
            #expect(snapshot.snippetPackages == [package])
            snippet.colorTag = .purple
            let model = SnippetLibraryModel(library: HostLibraryModel(persistence: persistence))
            model.upsert(snippet)
        }
        let reopened = try TermindPersistence.makeContainer(url: url)
        #expect(try HostPersistence(context: reopened.mainContext).load().snippets == [snippet])
    }
}
