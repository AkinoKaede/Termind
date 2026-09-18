import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

import struct TermindDomain.Host

@Suite @MainActor
struct ForwardingColorTests {
    @Test func legacyRulesDecodeWithoutColorAndNewRulesRoundTripEveryColor() throws {
        var rule = PortForwardingRule(hostID: UUID(), label: "Database")
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any])
        legacy.removeValue(forKey: "colorTag")
        #expect(
            try JSONDecoder().decode(PortForwardingRule.self, from: JSONSerialization.data(withJSONObject: legacy))
                == rule)
        legacy["colorTag"] = "future-color"
        #expect(
            try JSONDecoder().decode(PortForwardingRule.self, from: JSONSerialization.data(withJSONObject: legacy))
                == rule)
        for color in TagColor.allCases {
            rule.colorTag = color
            #expect(try JSONDecoder().decode(PortForwardingRule.self, from: JSONEncoder().encode(rule)) == rule)
        }
    }

    @Test func colorEditsRemainDraftsUntilSavedAndSyncCanSetAndClearThem() throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let persistence = HostPersistence(context: container.mainContext)
        let library = HostLibraryModel(persistence: persistence)
        let model = ForwardingLibraryModel(library: library)
        let host = Host(name: "Server", host: "server.invalid")
        library.upsert(host)
        let original = PortForwardingRule(hostID: host.id, colorTag: .teal)
        var draft = try model.save(original)
        draft.colorTag = .pink
        #expect(model.portForwarding(original.id)?.colorTag == .teal)
        draft = try model.save(draft)
        #expect(try persistence.load().portForwardings == [draft])

        let remoteContainer = try TermindPersistence.makeContainer(inMemory: true)
        let remote = HostPersistence(context: remoteContainer.mainContext)
        let hostPayload = VaultRecordPayload.host(host)
        _ = try remote.applyRemote([
            VaultEnvelope(key: hostPayload.key, version: .baseline(writerID: UUID()), payload: hostPayload)
        ])
        for (index, color) in [TagColor.pink, .none].enumerated() {
            draft.colorTag = color
            let payload = VaultRecordPayload.portForwarding(draft)
            let envelope = VaultEnvelope(
                key: payload.key,
                version: .next(after: nil, writerID: UUID(), now: Date(timeIntervalSince1970: Double(index + 1))),
                payload: payload)
            let received = try JSONDecoder().decode(VaultEnvelope.self, from: JSONEncoder().encode(envelope))
            _ = try remote.applyRemote([received])
            #expect(try remote.load().portForwardings == [draft])
        }
    }

    @Test func version19RulesMigrateWithoutChangingIDsHostsOrParameters() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Termind.store")
        let host = Host(name: "Server", host: "server.invalid")
        let rules = PortForwardingRule.Kind.allCases.map {
            PortForwardingRule(hostID: host.id, kind: $0, bindHost: "::1", bindPort: 15432, label: "Database")
        }
        do {
            let schema = Schema(versionedSchema: TermindSchemaV19.self)
            let legacy = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration("Termind", schema: schema, url: url, cloudKitDatabase: .none)])
            legacy.mainContext.insert(TermindSchemaV8Models.PersistentHost(host))
            for rule in rules {
                legacy.mainContext.insert(TermindSchemaV19ForwardingModels.PersistentPortForwardingRule(rule))
            }
            try legacy.mainContext.save()
        }
        let container = try TermindPersistence.makeContainer(url: url)
        let persistence = HostPersistence(context: container.mainContext)
        let snapshot = try persistence.load()
        #expect(snapshot.hosts == [host])
        #expect(Set(snapshot.portForwardings) == Set(rules))
        let model = ForwardingLibraryModel(library: HostLibraryModel(persistence: persistence))
        var colored = rules[0]
        colored.colorTag = .purple
        try model.save(colored)
        let reopened = try TermindPersistence.makeContainer(url: url)
        #expect(
            try HostPersistence(context: reopened.mainContext).load().portForwardings.first { $0.id == colored.id }
                == colored)
    }
}
