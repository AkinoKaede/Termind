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

    public func snippetPackage(_ id: SnippetPackage.ID) -> SnippetPackage? {
        library.snippetPackage(id)
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
    public func searchSnippets(_ query: String) -> [Snippet] { library.searchSnippets(query) }
    public func searchHosts(_ query: String) -> [Host] { library.searchHosts(query) }
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
