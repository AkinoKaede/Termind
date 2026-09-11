import Foundation
import TermindDomain

import struct TermindDomain.Host

/// The Snippets feature's deliberately narrow view of the shared vault.
@Observable
final class SnippetLibraryModel {
    private let library: HostLibraryModel

    init(library: HostLibraryModel) {
        self.library = library
    }

    var hosts: [Host] { library.hosts }
    var snippets: [Snippet] { library.snippets }
    var snippetPackages: [SnippetPackage] { library.snippetPackages }
    var rootSnippetPackages: [SnippetPackage] { library.rootSnippetPackages }
    var isSnippetsUngroupedExpanded: Bool { library.isSnippetsUngroupedExpanded }

    func snippetPackage(_ id: SnippetPackage.ID) -> SnippetPackage? {
        library.snippetPackage(id)
    }
    func childSnippetPackages(of parent: SnippetPackage.ID) -> [SnippetPackage] {
        library.childSnippetPackages(of: parent)
    }
    func descendantSnippetPackages(of parent: SnippetPackage.ID) -> [SnippetPackage] {
        library.descendantSnippetPackages(of: parent)
    }
    func snippets(in package: SnippetPackage.ID?) -> [Snippet] { library.snippets(in: package) }
    func snippetPackagePath(_ packageID: SnippetPackage.ID?) -> String? {
        library.snippetPackagePath(packageID)
    }
    func searchSnippets(_ query: String) -> [Snippet] { library.searchSnippets(query) }
    func searchHosts(_ query: String) -> [Host] { library.searchHosts(query) }
    func loginAddress(for host: Host) -> String { library.loginAddress(for: host) }

    func setSnippetPackageExpanded(_ expanded: Bool, for packageID: SnippetPackage.ID) {
        library.setSnippetPackageExpanded(expanded, for: packageID)
    }
    func setSnippetsUngroupedExpanded(_ expanded: Bool) {
        library.setSnippetsUngroupedExpanded(expanded)
    }
    func upsert(_ snippet: Snippet) { library.upsert(snippet) }
    func upsert(_ package: SnippetPackage) { library.upsert(package) }
    func delete(snippetIDs: [Snippet.ID]) { library.delete(snippetIDs: snippetIDs) }
    func delete(snippetPackageID: SnippetPackage.ID, keepSnippets: Bool) {
        library.delete(snippetPackageID: snippetPackageID, keepSnippets: keepSnippets)
    }
    func move(
        snippetIDs: [Snippet.ID], into packageID: SnippetPackage.ID?,
        before next: Snippet.ID? = nil
    ) {
        library.move(snippetIDs: snippetIDs, into: packageID, before: next)
    }
}
