import AgentKit
import Foundation
import SwiftData
import TermindDomain

@Model
public final class PersistentAgentSkill {
    @Attribute(.unique) public var id: UUID = UUID()
    public var name = ""
    public var title = ""
    public var summary = ""
    public var body = ""
    public var isEnabled = true
    public var importedFrom = ""
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var sortIndex = 0

    public init(_ value: AgentSkill, sortIndex: Int) {
        id = value.id
        name = value.name
        title = value.title
        summary = value.summary
        body = value.body
        isEnabled = value.isEnabled
        importedFrom = value.importedFrom
        createdAt = value.createdAt
        updatedAt = value.updatedAt
        self.sortIndex = sortIndex
    }

    public var value: AgentSkill {
        AgentSkill(
            id: id, name: name, title: title, summary: summary, body: body,
            isEnabled: isEnabled, importedFrom: importedFrom,
            createdAt: createdAt, updatedAt: updatedAt
        )
    }
}
