// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain
import Testing

@testable import TermindApplication

@Suite @MainActor
struct LibraryExpansionStateTests {
    @Test
    func legacyExpansionMigratesOnceAndThenPersistsOnlyLocally() throws {
        let fixture = try DefaultsFixture()
        defer { fixture.remove() }
        let group = HostGroup(name: "Production", isExpanded: false)
        let package = SnippetPackage(name: "Operations", isExpanded: false)
        let persistence = ExpansionVaultPersistence(
            snapshot: VaultSnapshot(groups: [group], snippetPackages: [package])
        )
        let library = HostLibraryModel(
            persistence: persistence,
            localDefaults: fixture.defaults
        )

        #expect(!library.isHostGroupExpanded(group.id))
        #expect(!library.isSnippetPackageExpanded(package.id))
        #expect(library.isUngroupedExpanded)
        #expect(library.isSnippetsUngroupedExpanded)

        library.setExpanded(true, for: group.id)
        library.setSnippetPackageExpanded(true, for: package.id)
        library.setUngroupedExpanded(false)
        library.setSnippetsUngroupedExpanded(false)

        #expect(persistence.saveCount == 0)
        let reopened = HostLibraryModel(
            persistence: persistence,
            localDefaults: fixture.defaults
        )
        #expect(reopened.isHostGroupExpanded(group.id))
        #expect(reopened.isSnippetPackageExpanded(package.id))
        #expect(!reopened.isUngroupedExpanded)
        #expect(!reopened.isSnippetsUngroupedExpanded)
    }

    @Test
    func installationsKeepIndependentExpansionState() throws {
        let first = try DefaultsFixture()
        let second = try DefaultsFixture()
        defer {
            first.remove()
            second.remove()
        }
        let group = HostGroup(name: "Production")
        let snapshot = VaultSnapshot(groups: [group])
        let firstLibrary = HostLibraryModel(
            persistence: ExpansionVaultPersistence(snapshot: snapshot),
            localDefaults: first.defaults
        )
        firstLibrary.setExpanded(false, for: group.id)

        let secondLibrary = HostLibraryModel(
            persistence: ExpansionVaultPersistence(snapshot: snapshot),
            localDefaults: second.defaults
        )

        #expect(!firstLibrary.isHostGroupExpanded(group.id))
        #expect(secondLibrary.isHostGroupExpanded(group.id))
    }

    @Test
    func remoteSnapshotsCannotReplaceLocalExpansionAndRemoveStaleIDs() throws {
        let fixture = try DefaultsFixture()
        defer { fixture.remove() }
        let group = HostGroup(name: "Production")
        let package = SnippetPackage(name: "Operations")
        let library = HostLibraryModel(
            groups: [group], snippetPackages: [package],
            localDefaults: fixture.defaults
        )
        library.setExpanded(false, for: group.id)
        library.setSnippetPackageExpanded(false, for: package.id)

        var remoteGroup = group
        remoteGroup.isExpanded = true
        var remotePackage = package
        remotePackage.isExpanded = true
        library.replacePersistedSnapshot(
            VaultSnapshot(groups: [remoteGroup], snippetPackages: [remotePackage])
        )

        #expect(!library.isHostGroupExpanded(group.id))
        #expect(!library.isSnippetPackageExpanded(package.id))

        library.replacePersistedSnapshot(VaultSnapshot())
        library.replacePersistedSnapshot(
            VaultSnapshot(groups: [remoteGroup], snippetPackages: [remotePackage])
        )
        #expect(library.isHostGroupExpanded(group.id))
        #expect(library.isSnippetPackageExpanded(package.id))
    }

    @Test
    func corruptLocalStateFallsBackToExpandedWithoutRepeatingLegacyMigration() throws {
        let fixture = try DefaultsFixture()
        defer { fixture.remove() }
        fixture.defaults.set(Data("not-json".utf8), forKey: LibraryExpansionState.storageKey)
        fixture.defaults.set(true, forKey: LibraryExpansionState.migrationKey)
        let group = HostGroup(name: "Production", isExpanded: false)
        let package = SnippetPackage(name: "Operations", isExpanded: false)

        let library = HostLibraryModel(
            groups: [group], snippetPackages: [package],
            localDefaults: fixture.defaults
        )

        #expect(library.isHostGroupExpanded(group.id))
        #expect(library.isSnippetPackageExpanded(package.id))
    }
}

private struct DefaultsFixture {
    let name: String
    let defaults: UserDefaults

    init() throws {
        name = "LibraryExpansionStateTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: name))
    }

    func remove() {
        defaults.removePersistentDomain(forName: name)
    }
}

@MainActor
private final class ExpansionVaultPersistence: VaultPersisting {
    var snapshot: VaultSnapshot
    var saveCount = 0

    init(snapshot: VaultSnapshot) {
        self.snapshot = snapshot
    }

    func load() throws -> VaultSnapshot { snapshot }

    func save(
        _ snapshot: VaultSnapshot, touching keys: Set<VaultRecordKey>
    ) throws -> VaultMutationSet {
        saveCount += 1
        self.snapshot = snapshot
        return .empty
    }

}
