import Foundation
import SwiftData
import TermindDomain
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite
@MainActor
struct SnippetFeatureTests {
    @Test
    func snippetMovePreservesBatchOrderAcrossPackages() {
        let source = SnippetPackage(name: "Source")
        let destination = SnippetPackage(name: "Destination")
        let first = Snippet(title: "First", body: "one", packageID: source.id, sortIndex: 0)
        let second = Snippet(title: "Second", body: "two", packageID: source.id, sortIndex: 1)
        let before = Snippet(
            title: "Before", body: "before", packageID: destination.id, sortIndex: 0
        )
        let after = Snippet(
            title: "After", body: "after", packageID: destination.id, sortIndex: 1
        )
        let store = HostLibraryModel(
            snippets: [first, second, before, after],
            snippetPackages: [source, destination]
        )

        store.move(
            snippetIDs: [second.id, first.id], into: destination.id,
            before: after.id
        )

        #expect(
            store.snippets(in: destination.id).map(\.id)
                == [before.id, second.id, first.id, after.id]
        )
    }

    @Test
    func movingIntoNestedPackageExpandsItsAncestors() {
        let root = SnippetPackage(name: "Root", isExpanded: false)
        let child = SnippetPackage(
            name: "Child", parentID: root.id, isExpanded: false
        )
        let snippet = Snippet(title: "Status", body: "uptime")
        let store = HostLibraryModel(
            snippets: [snippet], snippetPackages: [root, child]
        )

        store.move(snippetIDs: [snippet.id], into: child.id)

        #expect(store.snippetPackage(root.id)?.isExpanded == true)
        #expect(store.snippetPackage(child.id)?.isExpanded == true)
    }

    @Test
    func deletingPackageCanKeepTreeSnippetsUngrouped() {
        let existing = Snippet(title: "Existing", body: "pwd", sortIndex: 0)
        let root = SnippetPackage(name: "Root")
        let child = SnippetPackage(name: "Child", parentID: root.id)
        let first = Snippet(
            title: "First", body: "one", packageID: root.id, sortIndex: 0
        )
        let second = Snippet(
            title: "Second", body: "two", packageID: child.id, sortIndex: 0
        )
        let store = HostLibraryModel(
            snippets: [existing, first, second], snippetPackages: [root, child]
        )

        store.delete(snippetPackageID: root.id, keepSnippets: true)

        #expect(store.snippetPackages.isEmpty)
        #expect(store.snippets(in: nil).map(\.id) == [existing.id, first.id, second.id])
    }

    @Test
    func deletingHostRemovesItFromEverySnippetTarget() {
        let removed = Host(name: "Removed", host: "removed.example")
        let kept = Host(name: "Kept", host: "kept.example")
        let snippet = Snippet(
            title: "Status", body: "uptime",
            targetHostIDs: [removed.id, kept.id]
        )
        let store = HostLibraryModel(hosts: [removed, kept], snippets: [snippet])

        store.projectHostDeletion(removed.id)

        #expect(store.snippet(snippet.id)?.targetHostIDs == [kept.id])
    }

    @Test
    func snippetPersistenceRoundTripKeepsPackagesTargetsAndExpansion() throws {
        let configuration = localModelConfiguration(
            "SnippetFeatureTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema,
            configurations: [configuration]
        )
        let store = HostLibraryModel(modelContext: container.mainContext)
        let host = Host(name: "Web", host: "web.example")
        let package = SnippetPackage(name: "Operations", isExpanded: false)
        let script = """
            #!/bin/sh
            systemctl status nginx
            journalctl -u nginx -n 20
            """
        let snippet = Snippet(
            title: "Status", body: script,
            packageID: package.id, targetHostIDs: [host.id]
        )

        store.upsert(host)
        store.upsert(package)
        store.setSnippetPackageExpanded(false, for: package.id)
        store.upsert(snippet)

        let reloaded = HostLibraryModel(modelContext: container.mainContext)
        #expect(reloaded.snippetPackage(package.id)?.isExpanded == false)
        #expect(reloaded.snippet(snippet.id)?.packageID == package.id)
        #expect(reloaded.snippet(snippet.id)?.targetHostIDs == [host.id])
        #expect(reloaded.snippet(snippet.id)?.body == script)
    }

    @Test
    func executingSnippetsKeepsDefaultTitlesAndRequestOrder() {
        let firstHost = Host(name: "A", host: "a.example")
        let secondHost = Host(name: "B", host: "b.example")
        let first = Snippet(
            title: "First Workspace", body: "uptime",
            targetHostIDs: [secondHost.id, firstHost.id]
        )
        let second = Snippet(
            title: "Second Workspace", body: "whoami",
            targetHostIDs: [firstHost.id]
        )
        let store = HostLibraryModel(hosts: [secondHost, firstHost], snippets: [first, second])
        let app = AppModel(hosts: store)
        let window = WindowModel()

        app.execute([first, second], in: window)

        #expect(window.workspaces.count == 2)
        #expect(window.workspaces[0].title(in: store) == String(localized: "Workspace"))
        #expect(window.workspaces[0].panes.map(\.hostID) == [firstHost.id, secondHost.id])
        #expect(window.workspaces[1].title(in: store) == "\(firstHost.name) (1)")
        #expect(window.selectedWorkspaceID == window.workspaces[0].id)
    }

    @Test
    func temporaryTargetOverrideDoesNotMutateSnippet() {
        let saved = Host(name: "Saved", host: "saved.example")
        let temporary = Host(name: "Temporary", host: "temporary.example")
        let snippet = Snippet(
            title: "Status", body: "uptime", targetHostIDs: [saved.id]
        )
        let store = HostLibraryModel(hosts: [saved, temporary], snippets: [snippet])
        let app = AppModel(hosts: store)
        let window = WindowModel()

        app.execute([snippet], overrideHostIDs: [temporary.id], in: window)

        #expect(window.workspaces.first?.panes.map(\.hostID) == [temporary.id])
        #expect(store.snippet(snippet.id)?.targetHostIDs == [saved.id])
    }
}
