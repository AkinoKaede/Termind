import Foundation
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobileWorkspaceStoreTests {
    @Test func legacyReadPreservesBytesUntilOwnershipIsSaved() throws {
        try withStore("[]") { store, defaults in
            #expect(try store.load().unassigned.isEmpty)
            #expect(defaults.data(forKey: MobileWorkspaceStore.key) == Data("[]".utf8))
            let descriptor = MobileWorkspaceDescriptor(hostID: UUID(), title: "New", kind: .ssh)
            let snapshot = MobileWorkspaceStore.Snapshot(sessions: ["first": [descriptor]])
            try store.save(snapshot)
            #expect(try MobileWorkspaceStore(defaults: defaults).load() == snapshot)
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
            let descriptors = try store.load().unassigned
            #expect(descriptors.map(\.id) == ids)
            #expect(descriptors.map(\.title) == ["Custom", "Explicit", "Third", "Files", "Other"])
            #expect(descriptors.map(\.kind) == [.ssh, .ssh, .ssh, .sftp, .ssh])
            let migrated = defaults.data(forKey: MobileWorkspaceStore.key)
            #expect(migrated == Data(json.utf8))
            #expect(try MobileWorkspaceStore(defaults: defaults).load().unassigned == descriptors)
            #expect(defaults.data(forKey: MobileWorkspaceStore.key) == migrated)
            defaults.set(Data(json.utf8), forKey: MobileWorkspaceStore.key)
            #expect(try store.load().unassigned == descriptors)
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
            let descriptors = try store.load().unassigned
            #expect(descriptors.map(\.title) == ["One", "Two", "Files"])
        }
    }

    @Test func currentSnapshotRoundTripsWithoutMigration() throws {
        try withStore("[]") { store, defaults in
            let descriptors = [
                MobileWorkspaceDescriptor(hostID: UUID(), title: "Custom", kind: .sftp)
            ]
            try store.save(.init(unassigned: descriptors))
            let data = defaults.data(forKey: MobileWorkspaceStore.key)
            #expect(try store.load().unassigned == descriptors)
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
            #expect(throws: (any Error).self) { try store.save(.init()) }
            #expect(defaults.data(forKey: MobileWorkspaceStore.key) == Data(json.utf8))
            defaults.set(Data("[]".utf8), forKey: MobileWorkspaceStore.key)
            #expect(try store.load().unassigned.isEmpty)
            try store.save(.init())
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
            #expect(throws: (any Error).self) { try store.save(.init()) }
            #expect(defaults.data(forKey: MobileWorkspaceStore.key) == Data(json.utf8))
        }
    }

    @Test func duplicateOwnersAreRejectedWithoutOverwritingAValidSnapshot() throws {
        try withStore("[]") { store, defaults in
            let descriptor = MobileWorkspaceDescriptor(hostID: UUID(), title: "Saved", kind: .ssh)
            let valid = MobileWorkspaceStore.Snapshot(sessions: ["a": [descriptor]])
            try store.save(valid)
            let bytes = defaults.data(forKey: MobileWorkspaceStore.key)
            #expect(throws: (any Error).self) {
                try store.save(.init(sessions: ["a": [descriptor], "b": [descriptor]]))
            }
            #expect(defaults.data(forKey: MobileWorkspaceStore.key) == bytes)
            #expect(try store.load() == valid)
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
