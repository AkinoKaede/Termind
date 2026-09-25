import AgentKit
import Foundation
import SwiftData
import TermindApplication

@Model
public final class PersistentAssistantModelSelection {
    @Attribute(.unique) public var conversationID: UUID = UUID()
    public var providerID: UUID = UUID()
    public var modelID = ""

    public init(conversationID: UUID, model: AIModelRef) {
        self.conversationID = conversationID
        providerID = model.modelProviderID
        modelID = model.modelID
    }

    public var value: AIModelRef {
        AIModelRef(modelProviderID: providerID, modelID: modelID)
    }
}

@MainActor
public final class SwiftDataAssistantModelSelectionStore: AssistantModelSelectionStoring {
    private let context: ModelContext

    public init(context: ModelContext) { self.context = context }

    public func load() throws -> [UUID: AIModelRef] {
        let rows = try context.fetch(FetchDescriptor<PersistentAssistantModelSelection>())
        return Dictionary(rows.map { ($0.conversationID, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    public func save(_ model: AIModelRef, for conversationID: UUID) throws {
        let rows = try context.fetch(
            FetchDescriptor<PersistentAssistantModelSelection>(
                predicate: #Predicate { $0.conversationID == conversationID }))
        if rows.first?.value == model { return }
        try context.commit {
            if let row = rows.first {
                row.providerID = model.modelProviderID
                row.modelID = model.modelID
            } else {
                context.insert(PersistentAssistantModelSelection(conversationID: conversationID, model: model))
            }
        }
    }
}
