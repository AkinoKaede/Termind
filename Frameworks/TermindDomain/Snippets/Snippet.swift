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
    public var colorTag: TagColor = .none
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
        targetHostIDs: [Host.ID] = [], sortIndex: Double = 0, colorTag: TagColor = .none
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.packageID = packageID
        self.colorTag = colorTag
        self.targetHostIDs = targetHostIDs
        self.sortIndex = sortIndex
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, body, packageID, targetHostIDs, sortIndex, colorTag
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            title: try values.decode(String.self, forKey: .title),
            body: try values.decode(String.self, forKey: .body),
            packageID: try values.decodeIfPresent(UUID.self, forKey: .packageID),
            targetHostIDs: try values.decode([UUID].self, forKey: .targetHostIDs),
            sortIndex: try values.decode(Double.self, forKey: .sortIndex),
            colorTag: (try? values.decode(TagColor.self, forKey: .colorTag)) ?? .none)
    }

}
