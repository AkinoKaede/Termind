import Foundation
import TermindDomain

import struct TermindDomain.Host

public nonisolated struct HostLibrarySection: Identifiable, Sendable {
    public nonisolated enum ID: Hashable, Sendable {
        case results
        case group(HostGroup.ID)
        case ungrouped

        public var groupID: HostGroup.ID? {
            guard case .group(let id) = self else { return nil }
            return id
        }
    }

    public let id: ID
    public let title: String
    public let hosts: [Host]
    public let isExpanded: Bool?

    public init(id: ID, title: String, hosts: [Host], isExpanded: Bool? = nil) {
        self.id = id
        self.title = title
        self.hosts = hosts
        self.isExpanded = isExpanded
    }
}

@MainActor
public enum HostLibrarySectionLayout {
    public static func sections(
        library: HostLibraryModel,
        query: String = "",
        selectedTags: Set<String> = []
    ) -> [HostLibrarySection] {
        let isFiltering = !query.isEmpty || !selectedTags.isEmpty
        if isFiltering {
            let matches = library.searchHosts(query).filter { $0.hasTags(selectedTags) }
            return matches.isEmpty
                ? []
                : [HostLibrarySection(id: .results, title: String(localized: "Results"), hosts: matches)]
        }

        var result: [HostLibrarySection] = []
        func append(_ group: HostGroup, prefix: String) {
            let title = prefix.isEmpty ? group.name : "\(prefix) / \(group.name)"
            result.append(
                HostLibrarySection(
                    id: .group(group.id), title: title,
                    hosts: library.hosts(in: group.id), isExpanded: group.isExpanded
                ))
            guard group.isExpanded else { return }
            for child in library.childGroups(of: group.id) {
                append(child, prefix: title)
            }
        }
        for group in library.rootGroups { append(group, prefix: "") }

        let ungrouped = library.hosts(in: nil)
        if !ungrouped.isEmpty || !library.groups.isEmpty {
            result.append(
                HostLibrarySection(
                    id: .ungrouped, title: String(localized: "Ungrouped"),
                    hosts: ungrouped, isExpanded: library.isUngroupedExpanded
                ))
        }
        return result
    }
}

public nonisolated struct SnippetLibrarySection: Identifiable, Sendable {
    public nonisolated enum ID: Hashable, Sendable {
        case results
        case package(SnippetPackage.ID)
        case ungrouped

        public var packageID: SnippetPackage.ID? {
            guard case .package(let id) = self else { return nil }
            return id
        }
    }

    public let id: ID
    public let title: String
    public let snippets: [Snippet]
    public let isExpanded: Bool?

    public init(id: ID, title: String, snippets: [Snippet], isExpanded: Bool? = nil) {
        self.id = id
        self.title = title
        self.snippets = snippets
        self.isExpanded = isExpanded
    }
}

@MainActor
public enum SnippetLibrarySectionLayout {
    public static func sections(
        library: SnippetLibraryModel,
        query: String = ""
    ) -> [SnippetLibrarySection] {
        if !query.isEmpty {
            let matches = library.searchSnippets(query)
            return matches.isEmpty
                ? []
                : [SnippetLibrarySection(id: .results, title: String(localized: "Results"), snippets: matches)]
        }

        var result: [SnippetLibrarySection] = []
        func append(_ package: SnippetPackage, prefix: String) {
            let title = prefix.isEmpty ? package.name : "\(prefix) / \(package.name)"
            result.append(
                SnippetLibrarySection(
                    id: .package(package.id), title: title,
                    snippets: library.snippets(in: package.id), isExpanded: package.isExpanded
                ))
            guard package.isExpanded else { return }
            for child in library.childSnippetPackages(of: package.id) {
                append(child, prefix: title)
            }
        }
        for package in library.rootSnippetPackages { append(package, prefix: "") }

        let ungrouped = library.snippets(in: nil)
        if !ungrouped.isEmpty || !library.snippetPackages.isEmpty {
            result.append(
                SnippetLibrarySection(
                    id: .ungrouped, title: String(localized: "Ungrouped"),
                    snippets: ungrouped, isExpanded: library.isSnippetsUngroupedExpanded
                ))
        }
        return result
    }
}
