// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@Suite @MainActor
struct ResourceLibraryTransactionTests {
    @Test func failedSnippetAndPackageDeletionRestoresStartupAndGroupingReferences() throws {
        let package = SnippetPackage(name: "Scripts")
        let snippet = Snippet(title: "Startup", body: "pwd", packageID: package.id)
        var host = Host(name: "Server", host: "server.invalid")
        host.startupSnippetID = snippet.id
        let persistence = ResourceLibraryPersistence(
            snapshot: VaultSnapshot(hosts: [host], snippets: [snippet], snippetPackages: [package]))
        let library = HostLibraryModel(persistence: persistence)
        persistence.fails = true
        #expect(!library.removeSnippets([snippet.id]))
        #expect(library.snippets == [snippet])
        #expect(library.host(host.id)?.startupSnippetID == snippet.id)
        #expect(!library.removeSnippetPackage(package.id, keepSnippets: false))
        #expect(library.snippetPackages == [package])
        #expect(library.snippets == [snippet])
        #expect(library.host(host.id)?.startupSnippetID == snippet.id)
        persistence.fails = false
        #expect(library.removeSnippetPackage(package.id, keepSnippets: false))
        #expect(library.snippets.isEmpty)
        #expect(library.host(host.id)?.startupSnippetID == nil)
        let reopened = HostLibraryModel(persistence: persistence)
        #expect(reopened.snippets.isEmpty)
        #expect(reopened.host(host.id)?.startupSnippetID == nil)
    }

    @Test func failedHostGroupMutationsRestoreBothHostsAndGroups() {
        let group = HostGroup(name: "Production")
        let host = Host(name: "Server", host: "server.invalid", groupID: group.id)
        let persistence = ResourceLibraryPersistence(snapshot: VaultSnapshot(hosts: [host], groups: [group]))
        let library = HostLibraryModel(persistence: persistence)
        persistence.fails = true
        var changed = group
        changed.name = "Updated"
        #expect(!library.saveGroup(changed))
        #expect(library.group(group.id)?.name == "Production")
        #expect(!library.removeGroup(group.id))
        #expect(library.host(host.id)?.groupID == group.id)
        #expect(library.groups == [group])
        persistence.fails = false
        #expect(library.removeGroup(group.id))
        #expect(library.host(host.id)?.groupID == nil)
        #expect(library.groups.isEmpty)
    }

    @Test func snippetDeletionAlsoRollsBackAndClearsOfflineTailscalePreferences() throws {
        let snippet = Snippet(title: "Startup", body: "pwd")
        let network = try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "example.ts.net")
        var group = HostGroup(name: "Tailnet")
        group.tailscale = TailscaleGroupConfiguration(network: network)
        let hostID = UUID()
        var preferences = TailscaleHostPreferences()
        preferences.startupSnippetID = snippet.id
        group.tailscale?.hostPreferences[hostID] = preferences
        let persistence = ResourceLibraryPersistence(snapshot: VaultSnapshot(groups: [group], snippets: [snippet]))
        let library = HostLibraryModel(persistence: persistence)
        persistence.fails = true
        #expect(!library.removeSnippets([snippet.id]))
        #expect(library.group(group.id)?.tailscale?.hostPreferences[hostID]?.startupSnippetID == snippet.id)
        persistence.fails = false
        #expect(library.removeSnippets([snippet.id]))
        #expect(library.group(group.id)?.tailscale?.hostPreferences[hostID]?.startupSnippetID == nil)
        #expect(persistence.snapshot.groups.first?.tailscale?.hostPreferences[hostID]?.startupSnippetID == nil)
    }

    @Test func secretFileInputPreservesNewlinesAndRejectsInvalidContent() throws {
        let text = "-----BEGIN TEST KEY-----\nfirst\nsecond\n-----END TEST KEY-----\n"
        #expect(try AgentSecretFileInput.decode(Data(text.utf8)) == text)
        for data in [
            Data(), Data([0xFF]), Data("a\0b".utf8), Data(repeating: 65, count: AgentSecretFileInput.maximumBytes + 1),
        ] {
            #expect(throws: (any Error).self) { try AgentSecretFileInput.decode(data) }
        }
    }
}

@MainActor
private final class ResourceLibraryPersistence: VaultPersisting {
    var snapshot: VaultSnapshot
    var fails = false
    init(snapshot: VaultSnapshot) { self.snapshot = snapshot }
    func load() throws -> VaultSnapshot { snapshot }
    func save(_ snapshot: VaultSnapshot, touching keys: Set<VaultRecordKey>) throws -> VaultMutationSet {
        if fails { throw CocoaError(.fileWriteUnknown) }
        self.snapshot = snapshot
        return .empty
    }
}
