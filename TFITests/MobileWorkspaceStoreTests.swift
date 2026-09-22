import Foundation
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobileWorkspaceStoreTests {
    @Test func emptyLegacyArrayMigratesAndCanBeSavedAgain() throws {
        try withStore("[]") { store, defaults in
            #expect(try store.load().isEmpty)
            let data = try #require(defaults.data(forKey: MobileWorkspaceStore.key))
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["version"] as? Int == 1)
            #expect((object["workspaces"] as? [Any])?.isEmpty == true)
            #expect(try store.load().isEmpty)
            let descriptor = MobileWorkspaceDescriptor(hostID: UUID(), title: "New", kind: .ssh)
            try store.save([descriptor])
            #expect(try MobileWorkspaceStore(defaults: defaults).load() == [descriptor])
        }
    }

    @Test func legacyRecordsKeepIDsTitlesAndKindsWhileDiscardingIndices() throws {
        let host = UUID()
        let other = UUID()
        let ids = (0..<5).map { _ in UUID() }
        let json = """
            [
              {"id":"\(ids[0])","hostID":"\(host)","title":"Custom","kind":"ssh"},
              {"id":"\(ids[1])","hostID":"\(host)","title":"Explicit","kind":"ssh","duplicateIndex":0},
              {"id":"\(ids[2])","hostID":"\(host)","title":"Third","kind":"ssh"},
              {"id":"\(ids[3])","hostID":"\(host)","title":"Files","kind":"sftp"},
              {"id":"\(ids[4])","hostID":"\(other)","title":"Other","kind":"ssh"}
            ]
            """
        try withStore(json) { store, defaults in
            let descriptors = try store.load()
            #expect(descriptors.map(\.id) == ids)
            #expect(descriptors.map(\.title) == ["Custom", "Explicit", "Third", "Files", "Other"])
            #expect(descriptors.map(\.kind) == [.ssh, .ssh, .ssh, .sftp, .ssh])
            let migrated = defaults.data(forKey: MobileWorkspaceStore.key)
            #expect(!String(decoding: try #require(migrated), as: UTF8.self).contains("duplicateIndex"))
            #expect(try MobileWorkspaceStore(defaults: defaults).load() == descriptors)
            #expect(defaults.data(forKey: MobileWorkspaceStore.key) == migrated)
            defaults.set(Data(json.utf8), forKey: MobileWorkspaceStore.key)
            #expect(try store.load() == descriptors)
        }
    }

    @Test func legacyRecordsWithoutIndicesPreserveTheirTitles() throws {
        let host = UUID()
        let json = """
            [
              {"id":"\(UUID())","hostID":"\(host)","title":"One","kind":"ssh"},
              {"id":"\(UUID())","hostID":"\(host)","title":"Two","kind":"ssh"},
              {"id":"\(UUID())","hostID":"\(host)","title":"Files","kind":"sftp"}
            ]
            """
        try withStore(json) { store, _ in
            let descriptors = try store.load()
            #expect(descriptors.map(\.title) == ["One", "Two", "Files"])
        }
    }

    @Test func currentSnapshotRoundTripsWithoutMigration() throws {
        try withStore("[]") { store, defaults in
            let descriptors = [
                MobileWorkspaceDescriptor(hostID: UUID(), title: "Custom", kind: .sftp)
            ]
            try store.save(descriptors)
            let data = defaults.data(forKey: MobileWorkspaceStore.key)
            #expect(try store.load() == descriptors)
            #expect(defaults.data(forKey: MobileWorkspaceStore.key) == data)
        }
    }

    @Test(arguments: [
        "broken", "null", "{}", "[{}]", #"{"version":99,"workspaces":[]}"#,
        #"{"version":1,"workspaces":[{}]}"#,
    ])
    func invalidDataIsPreservedUntilASuccessfulLoad(json: String) throws {
        try withStore(json) { store, defaults in
            #expect(throws: (any Error).self) { try store.load() }
            #expect(throws: (any Error).self) { try store.save([]) }
            #expect(defaults.data(forKey: MobileWorkspaceStore.key) == Data(json.utf8))
            defaults.set(Data("[]".utf8), forKey: MobileWorkspaceStore.key)
            #expect(try store.load().isEmpty)
            try store.save([])
        }
    }

    @Test
    func duplicateLegacyIDsAreNotMigrated() throws {
        let id = UUID()
        let host = UUID()
        let json = """
            [
              {"id":"\(id)","hostID":"\(host)","title":"One","kind":"ssh","duplicateIndex":0},
              {"id":"\(id)","hostID":"\(host)","title":"Two","kind":"ssh","duplicateIndex":1}
            ]
            """
        try withStore(json) { store, defaults in
            #expect(throws: (any Error).self) { try store.load() }
            #expect(throws: (any Error).self) { try store.save([]) }
            #expect(defaults.data(forKey: MobileWorkspaceStore.key) == Data(json.utf8))
        }
    }

    private func withStore(
        _ json: String, check: (MobileWorkspaceStore, UserDefaults) throws -> Void
    ) throws {
        let suite = "termind.workspace-store-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(json.utf8), forKey: MobileWorkspaceStore.key)
        try check(MobileWorkspaceStore(defaults: defaults), defaults)
    }
}
