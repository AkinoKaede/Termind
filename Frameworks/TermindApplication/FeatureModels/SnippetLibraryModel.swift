// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

import struct TermindDomain.Host

/// The Snippets feature's deliberately narrow view of the shared vault.
@Observable
public final class SnippetLibraryModel {
    private let library: HostLibraryModel

    public init(library: HostLibraryModel) {
        self.library = library
    }

    public var hosts: [Host] { library.hosts }
    public var snippets: [Snippet] { library.snippets }
    public var snippetPackages: [SnippetPackage] { library.snippetPackages }
    public var rootSnippetPackages: [SnippetPackage] { library.rootSnippetPackages }
    public var isSnippetsUngroupedExpanded: Bool { library.isSnippetsUngroupedExpanded }
    public var storageError: String? { library.storageError }

    public func save(_ snippet: Snippet) throws {
        guard library.saveSnippet(snippet) else { throw CocoaError(.fileWriteUnknown) }
    }

    public func requireExecutionHost(_ id: UUID) throws {
        guard let host = library.host(id) else { throw CocoaError(.fileNoSuchFile) }
        try library.require(host, for: .snippetExecution)
    }

    public func save(_ package: SnippetPackage) throws {
        guard library.saveSnippetPackage(package) else { throw CocoaError(.fileWriteUnknown) }
    }

    public func removeSnippet(_ id: UUID) throws {
        guard library.removeSnippets([id]) else { throw CocoaError(.fileWriteUnknown) }
    }

    public func removePackage(_ id: UUID, keepSnippets: Bool) throws {
        guard library.removeSnippetPackage(id, keepSnippets: keepSnippets) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    public func snippetPackage(_ id: SnippetPackage.ID) -> SnippetPackage? {
        library.snippetPackage(id)
    }
    public func isSnippetPackageExpanded(_ id: SnippetPackage.ID) -> Bool {
        library.isSnippetPackageExpanded(id)
    }
    public func childSnippetPackages(of parent: SnippetPackage.ID) -> [SnippetPackage] {
        library.childSnippetPackages(of: parent)
    }
    public func descendantSnippetPackages(of parent: SnippetPackage.ID) -> [SnippetPackage] {
        library.descendantSnippetPackages(of: parent)
    }
    public func snippets(in package: SnippetPackage.ID?) -> [Snippet] { library.snippets(in: package) }
    public func snippetPackagePath(_ packageID: SnippetPackage.ID?) -> String? {
        library.snippetPackagePath(packageID)
    }
    public func modifiedAt(for snippetID: Snippet.ID) -> Date? {
        library.snippetModifiedAt(snippetID)
    }
    public func searchSnippets(_ query: String) -> [Snippet] { library.searchSnippets(query) }
    public func searchHosts(_ query: String) -> [Host] { library.hosts(matching: query, for: .snippetExecution) }
    public func validTargetIDs(for snippet: Snippet) -> [Host.ID] {
        let wanted = Set(snippet.targetHostIDs)
        return searchHosts("").filter { wanted.contains($0.id) }.map(\.id)
    }
    public func loginAddress(for host: Host) -> String { library.loginAddress(for: host) }

    public func setSnippetPackageExpanded(_ expanded: Bool, for packageID: SnippetPackage.ID) {
        library.setSnippetPackageExpanded(expanded, for: packageID)
    }
    public func setSnippetsUngroupedExpanded(_ expanded: Bool) {
        library.setSnippetsUngroupedExpanded(expanded)
    }
    public func upsert(_ snippet: Snippet) { library.upsert(snippet) }
    public func upsert(_ package: SnippetPackage) { library.upsert(package) }
    public func delete(snippetIDs: [Snippet.ID]) { library.delete(snippetIDs: snippetIDs) }
    public func delete(snippetPackageID: SnippetPackage.ID, keepSnippets: Bool) {
        library.delete(snippetPackageID: snippetPackageID, keepSnippets: keepSnippets)
    }
    public func move(
        snippetIDs: [Snippet.ID], into packageID: SnippetPackage.ID?,
        before next: Snippet.ID? = nil
    ) {
        library.move(snippetIDs: snippetIDs, into: packageID, before: next)
    }
}
