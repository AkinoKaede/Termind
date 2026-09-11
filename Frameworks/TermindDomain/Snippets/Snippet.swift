import Foundation

/// A folder used only to organise snippets. Execution settings deliberately
/// stay on the snippet, so moving a card never changes where it runs.
public nonisolated struct SnippetPackage: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var parentID: SnippetPackage.ID?
    public var sortIndex: Double = 0
    public var isExpanded: Bool = true
    public init(
        id: UUID = UUID(), name: String, parentID: SnippetPackage.ID? = nil, sortIndex: Double = 0,
        isExpanded: Bool = true
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.sortIndex = sortIndex
        self.isExpanded = isExpanded
    }

}

/// A reusable multi-line script with the hosts it normally opens and runs on.
public nonisolated struct Snippet: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var title: String
    public var body: String
    public var packageID: SnippetPackage.ID?
    public var targetHostIDs: [Host.ID] = []
    public var sortIndex: Double = 0

    public func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        return title.lowercased().contains(q)
            || body.lowercased().contains(q)
    }
    public init(
        id: UUID = UUID(), title: String, body: String, packageID: SnippetPackage.ID? = nil,
        targetHostIDs: [Host.ID] = [], sortIndex: Double = 0
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.packageID = packageID
        self.targetHostIDs = targetHostIDs
        self.sortIndex = sortIndex
    }

}
