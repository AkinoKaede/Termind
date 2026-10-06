import Foundation

/// One close operation. A window and all of its workspaces occupy one history slot.
public struct RecentlyClosedRecord<Item: Codable & Identifiable>: Codable, Identifiable where Item.ID == UUID {
    public let id: UUID
    public let closedAt: Date
    public let isWindow: Bool
    public var items: [Item]
    public let selectedItemID: UUID?

    public init(items: [Item], isWindow: Bool = false, selectedItemID: UUID? = nil, closedAt: Date = Date()) {
        id = isWindow ? UUID() : items.first?.id ?? UUID()
        self.closedAt = closedAt
        self.isWindow = isWindow
        self.items = items
        self.selectedItemID = selectedItemID
    }
}
