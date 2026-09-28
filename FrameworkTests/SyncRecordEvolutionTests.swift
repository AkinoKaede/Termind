import Foundation
import SwiftData
import TermindDomain
import TermindPersistence
import Testing

@Suite @MainActor
struct SyncRecordEvolutionTests {
    // Literal shipped V1 bytes are independent of the current domain encoder.
    private static let hostV1 = Data(
        #"{"formatVersion":1,"key":{"kind":"host","id":"11111111-1111-1111-1111-111111111111"},"version":{"modifiedAt":0,"counter":1,"writerID":"22222222-2222-2222-2222-222222222222"},"isDeleted":false,"payload":{"host":{"_0":{"id":"11111111-1111-1111-1111-111111111111","name":"Old host","host":"example.invalid","port":2222,"charset":"utf8","sftpSessionInitialPath":"","tags":[],"colorTag":"none","sortIndex":0}}}}"#
            .utf8)

    @Test func frozenHostV1ReadsHistoricalAliasesWithoutSchedulingUpload() throws {
        let envelope = try VaultSyncCodec.decode(Self.hostV1)
        guard case .host(let host) = envelope.payload else {
            Issue.record("Missing host")
            return
        }
        #expect(host.sshPort == 2222)
        #expect(host.name == "Old host")
        #expect(host.telnetPort == 23)
        let container = try TermindPersistence.makeContainer(inMemory: true)
        _ = try HostPersistence(context: container.mainContext).applyRemote([envelope])
        #expect(try VaultSyncJournal(context: container.mainContext).pendingEnvelopes().isEmpty)
    }

    @Test func versionThreeHostDecoderLeavesOtherKindsOnVersionOne() throws {
        // A test-only future protocol adds a field that an old writer would lose.
        // The historical decoder upgrades in memory; only explicit editing writes V3.
        nonisolated struct HostV3: Codable, Sendable {
            var formatVersion: Int
            var key: SyncRecordKey
            var name: String
            var futureValue: String
        }
        nonisolated struct SyncRecordKey: Codable, Sendable {
            var kind: String
            var id: UUID
        }
        let decoder = VersionedRecordDecoder<HostV3>([
            "host": [
                1: { data in
                    let old = try VaultSyncCodec.decode(data)
                    guard case .host(let host) = old.payload else { throw CocoaError(.coderReadCorrupt) }
                    return HostV3(
                        formatVersion: 3, key: SyncRecordKey(kind: "host", id: old.key.id), name: host.name,
                        futureValue: "inherited")
                },
                3: { try JSONDecoder().decode(HostV3.self, from: $0) },
            ]
        ])
        let formats = SyncRecordFormats([
            "host": .init(readingVersions: [1, 3], writingVersion: 3),
            "snippet": .init(readingVersions: [1], writingVersion: 1),
        ])
        var upgraded = try decoder.decode(Self.hostV1)
        #expect(upgraded.futureValue == "inherited")
        upgraded.name = "Edited"
        upgraded.formatVersion = formats.writingVersion(for: "host")
        let written = try JSONEncoder().encode(upgraded)
        #expect(throws: CloudSyncCompatibilityError.self) { try VaultSyncCodec.decode(written) }
        #expect(try decoder.decode(written).name == "Edited")
        #expect(formats.writingVersion(for: "snippet") == 1)
        #expect(SyncRecordFormats.history.writingVersion(for: "device") == 1)
        let payload = VaultRecordPayload.snippet(Snippet(title: "Still V1", body: "pwd"))
        let snippet = VaultEnvelope(key: payload.key, version: .baseline(writerID: UUID()), payload: payload)
        #expect(try VaultSyncCodec.decode(VaultSyncCodec.encode(snippet)) == snippet)
    }

    @Test func unknownKindFutureVersionAndInvalidNumbersNeverBecomeEmptyPayloads() throws {
        var raw = try #require(JSONSerialization.jsonObject(with: Self.hostV1) as? [String: Any])
        var key = try #require(raw["key"] as? [String: Any])
        key["kind"] = "future-kind"
        raw["key"] = key
        #expect(throws: CloudSyncCompatibilityError.self) {
            try VaultSyncCodec.decode(JSONSerialization.data(withJSONObject: raw))
        }
        var host = TermindDomain.Host(name: "Invalid", host: "invalid.example")
        host.sortIndex = .infinity
        let payload = VaultRecordPayload.host(host)
        let envelope = VaultEnvelope(key: payload.key, version: .baseline(writerID: UUID()), payload: payload)
        #expect(throws: (any Error).self) { try VaultSyncCodec.encode(envelope) }
    }

    @Test func aggregateNeverReportsSuccessWhenAnotherSelectedCategoryHasFailed() {
        #expect(
            CloudSyncStatusSummary.make([.upToDate(lastSuccessfulSync: .now), .failed("failure")], isActive: true)
                == .failed("failure"))
        #expect(
            CloudSyncStatusSummary.make([.syncing(pendingCount: 2), .syncing(pendingCount: 3)], isActive: true)
                == .syncing(pendingCount: 5))
        #expect(CloudSyncStatusSummary.make([.failed("failure")], isActive: false) == .paused)
        #expect(
            CloudSyncStatusSummary.make(
                [.partiallyBlocked(pendingCount: 1, blockedCount: 2, requiresUpdate: true), .syncing(pendingCount: 3)],
                isActive: true) == .partiallyBlocked(pendingCount: 4, blockedCount: 2, requiresUpdate: true))
    }
}
