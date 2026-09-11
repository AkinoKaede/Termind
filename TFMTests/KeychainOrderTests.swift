import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind

@Suite
@MainActor
struct KeychainOrderTests {
    @Test
    func unsortedInputsStartAlphabeticallyAndCanBeReordered() throws {
        let zebra = SSHKeyRef(label: "Zebra")
        let alpha = SSHKeyRef(label: "Alpha")
        let store = HostLibraryModel(keys: [zebra, alpha])

        #expect(store.searchKeys("").map(\.id) == [alpha.id, zebra.id])

        store.move(keyIDs: [zebra.id], before: alpha.id)

        #expect(store.searchKeys("").map(\.id) == [zebra.id, alpha.id])
    }

    @Test
    func identityBatchMoveDeduplicatesAndKeepsSuppliedOrder() {
        let first = Identity(name: "First", username: "first", sortIndex: 0)
        let second = Identity(name: "Second", username: "second", sortIndex: 1)
        let third = Identity(name: "Third", username: "third", sortIndex: 2)
        let store = HostLibraryModel(identities: [first, second, third])

        store.move(
            identityIDs: [third.id, UUID(), third.id, second.id],
            before: first.id
        )

        #expect(
            store.searchIdentities("").map(\.id)
                == [third.id, second.id, first.id]
        )
    }

    @Test
    func editingANameKeepsPositionAndNewItemsAppend() throws {
        let first = SSHKeyRef(
            label: "First", credentialRef: "termind.key.\(UUID().uuidString)", sortIndex: 0
        )
        let second = SSHKeyRef(
            label: "Second", credentialRef: "termind.key.\(UUID().uuidString)", sortIndex: 1
        )
        let store = HostLibraryModel(keys: [first, second])
        var renamed = first
        renamed.label = "Zulu"

        try store.upsert(renamed)
        let appended = SSHKeyRef(
            label: "Aardvark", credentialRef: "termind.key.\(UUID().uuidString)"
        )
        try store.upsert(appended)

        #expect(store.searchKeys("").map(\.id) == [first.id, second.id, appended.id])
        #expect(store.searchKeys("zulu").map(\.id) == [first.id])
    }

    @Test
    func keyAndIdentityOrdersSurvivePersistenceReload() throws {
        let configuration = localModelConfiguration(
            "KeychainOrderTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema,
            configurations: [configuration]
        )
        let store = HostLibraryModel(modelContext: container.mainContext)
        let firstKey = SSHKeyRef(label: "First")
        let secondKey = SSHKeyRef(label: "Second")
        let firstIdentity = Identity(name: "First", username: "first")
        let secondIdentity = Identity(name: "Second", username: "second")
        try store.upsert(firstKey)
        try store.upsert(secondKey)
        store.upsert(firstIdentity)
        store.upsert(secondIdentity)

        store.move(keyIDs: [secondKey.id], before: firstKey.id)
        store.move(identityIDs: [secondIdentity.id], before: firstIdentity.id)

        let reloaded = HostLibraryModel(modelContext: container.mainContext)
        #expect(reloaded.searchKeys("").map(\.id) == [secondKey.id, firstKey.id])
        #expect(
            reloaded.searchIdentities("").map(\.id)
                == [secondIdentity.id, firstIdentity.id]
        )
    }

    @Test
    func dropPoliciesExpressFixedAndExchangeableSections() {
        let fixed = ManagedCardDropPolicy<KeychainPageView.SectionID>.sameSection
        #expect(fixed.allowsMove(from: .keys, to: .keys))
        #expect(!fixed.allowsMove(from: .keys, to: .identities))

        let exchangeable = ManagedCardDropPolicy<HostsPageView.SectionID>.anySection
        #expect(
            exchangeable.allowsMove(
                from: .ungrouped, to: .group(UUID())
            )
        )
    }

    @Test
    func dropResolverFindsGridSlotsAndCollapsedSectionEnd() {
        let sections = [
            ManagedCardDropSection(
                id: "keys", frame: CGRect(x: 0, y: 0, width: 300, height: 100),
                isExpanded: true, itemIDs: ["a", "b"]
            ),
            ManagedCardDropSection(
                id: "identities", frame: CGRect(x: 0, y: 200, width: 300, height: 80),
                isExpanded: false, itemIDs: ["c"]
            ),
        ]
        let frames = [
            "a": CGRect(x: 0, y: 10, width: 100, height: 70),
            "b": CGRect(x: 120, y: 10, width: 100, height: 70),
            "c": CGRect(x: 0, y: 210, width: 100, height: 60),
        ]

        #expect(
            ManagedCardDropResolver.location(
                at: CGPoint(x: 110, y: 40), sections: sections,
                itemFrames: frames
            ) == ManagedCardDropLocation(section: "keys", index: 1)
        )
        #expect(
            ManagedCardDropResolver.location(
                at: CGPoint(x: 20, y: 240), sections: sections,
                itemFrames: frames
            ) == ManagedCardDropLocation(section: "identities", index: 1)
        )
    }
}
