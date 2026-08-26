import Foundation

/// A folder used only to organise snippets. Execution settings deliberately
/// stay on the snippet, so moving a card never changes where it runs.
nonisolated struct SnippetPackage: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var parentID: SnippetPackage.ID?
    var sortIndex: Double = 0
    var isExpanded: Bool = true
}

/// A reusable multi-line script with the hosts it normally opens and runs on.
nonisolated struct Snippet: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var body: String
    var packageID: SnippetPackage.ID?
    var targetHostIDs: [Host.ID] = []
    var sortIndex: Double = 0

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        return title.lowercased().contains(q)
            || body.lowercased().contains(q)
    }
}
