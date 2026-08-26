import Foundation
import SwiftData

@Model
final class PersistentModelProvider {
    @Attribute(.unique) var id: UUID = UUID()
    var name = ""
    var kind = ModelProviderKind.openAI.rawValue
    var isEnabled = true
    var baseURL = ""
    var apiPath = ""
    var credentialRef = ""
    var usesResponsesAPI = false
    var usesVertex = false
    var vertexProjectID = ""
    var vertexLocation = "global"
    var vertexCredentialRef = ""
    var vertexClientEmail = ""
    var modelsFetchedAt: Date?
    var sortIndex = 0

    init(_ value: ModelProvider, sortIndex: Int) {
        id = value.id
        name = value.name
        kind = value.kind.rawValue
        isEnabled = value.isEnabled
        baseURL = value.baseURL
        apiPath = value.apiPath
        credentialRef = value.credentialRef
        usesResponsesAPI = value.usesResponsesAPI
        usesVertex = value.usesVertex
        vertexProjectID = value.vertex.projectID
        vertexLocation = value.vertex.location
        vertexCredentialRef = value.vertex.credentialRef
        vertexClientEmail = value.vertex.clientEmail
        modelsFetchedAt = value.modelsFetchedAt
        self.sortIndex = sortIndex
    }

    func value(models: [AIModel]) -> ModelProvider {
        ModelProvider(
            id: id,
            name: name,
            kind: ModelProviderKind(rawValue: kind) ?? .openAI,
            isEnabled: isEnabled,
            baseURL: baseURL,
            apiPath: apiPath,
            credentialRef: credentialRef,
            usesResponsesAPI: usesResponsesAPI,
            usesVertex: usesVertex,
            vertex: VertexConfig(
                projectID: vertexProjectID,
                location: vertexLocation,
                credentialRef: vertexCredentialRef,
                clientEmail: vertexClientEmail
            ),
            models: models,
            modelsFetchedAt: modelsFetchedAt
        )
    }
}

@Model
final class PersistentAIModel {
    @Attribute(.unique) var recordID: UUID = UUID()
    var providerID: UUID = UUID()
    var modelID = ""
    var displayName = ""
    var ownedBy = ""
    var kind = AIModel.Kind.chat.rawValue
    var input: [String] = []
    var output: [String] = []
    var abilities: [String] = []
    var contextLength: Int?
    var maxOutputTokens: Int?
    var iconHint = ""
    var createdAt: Date?
    var origin = AIModel.Origin.manual.rawValue
    var reasoningProfileData: Data?
    var sortIndex = 0

    init(_ value: AIModel, providerID: UUID, sortIndex: Int) {
        self.providerID = providerID
        modelID = value.id
        displayName = value.displayName
        ownedBy = value.ownedBy
        kind = value.kind.rawValue
        input = value.input.map(\.rawValue).sorted()
        output = value.output.map(\.rawValue).sorted()
        abilities = value.abilities.map(\.rawValue).sorted()
        contextLength = value.contextLength
        maxOutputTokens = value.maxOutputTokens
        iconHint = value.iconHint
        createdAt = value.createdAt
        origin = value.origin.rawValue
        reasoningProfileData = value.reasoningProfile.flatMap { try? JSONEncoder().encode($0) }
        self.sortIndex = sortIndex
    }

    var value: AIModel {
        var model = AIModel(id: modelID)
        model.displayName = displayName
        model.ownedBy = ownedBy
        model.kind = AIModel.Kind(rawValue: kind) ?? .chat
        model.input = Set(input.compactMap(AIModel.Modality.init(rawValue:)))
        if model.input.isEmpty { model.input = [.text] }
        model.output = Set(output.compactMap(AIModel.Modality.init(rawValue:)))
        if model.output.isEmpty { model.output = [.text] }
        model.abilities = Set(abilities.compactMap(AIModel.Ability.init(rawValue:)))
        model.contextLength = contextLength
        model.maxOutputTokens = maxOutputTokens
        model.iconHint = iconHint
        model.createdAt = createdAt
        model.origin = AIModel.Origin(rawValue: origin) ?? .manual
        model.reasoningProfile = reasoningProfileData.flatMap {
            try? JSONDecoder().decode(ReasoningProfile.self, from: $0)
        }
        return model
    }
}

@Model
final class PersistentAIRoleAssignment {
    @Attribute(.unique) var role = ""
    var providerID: UUID = UUID()
    var modelID = ""

    init(role: AIRole, ref: AIModelRef) {
        self.role = role.rawValue
        providerID = ref.modelProviderID
        modelID = ref.modelID
    }
}

@Model
final class PersistentAISelection {
    @Attribute(.unique) var key = "lastSelectedModel"
    var providerID: UUID?
    var modelID: String?

    init(_ ref: AIModelRef?) {
        providerID = ref?.modelProviderID
        modelID = ref?.modelID
    }
}

@MainActor
final class AIPersistence {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func load() throws -> AIConfigurationSnapshot {
        let modelRows = try context.fetch(
            FetchDescriptor<PersistentAIModel>(sortBy: [SortDescriptor(\.sortIndex)])
        )
        let modelsByProvider = Dictionary(grouping: modelRows, by: \.providerID)
        let providerRows = try context.fetch(
            FetchDescriptor<PersistentModelProvider>(sortBy: [SortDescriptor(\.sortIndex)])
        )
        var seenProviders: Set<UUID> = []
        let providers = providerRows.compactMap { row -> ModelProvider? in
            guard seenProviders.insert(row.id).inserted else { return nil }
            var seenModels: Set<String> = []
            let models: [AIModel] = (modelsByProvider[row.id] ?? []).compactMap { modelRow -> AIModel? in
                guard seenModels.insert(modelRow.modelID).inserted else { return nil }
                return modelRow.value
            }
            return row.value(models: models)
        }

        func valid(_ ref: AIModelRef) -> Bool {
            providers.first(where: { $0.id == ref.modelProviderID })?.model(ref.modelID) != nil
        }

        var roles: [AIRole: AIModelRef] = [:]
        for row in try context.fetch(FetchDescriptor<PersistentAIRoleAssignment>()) {
            guard let role = AIRole(rawValue: row.role) else { continue }
            let ref = AIModelRef(modelProviderID: row.providerID, modelID: row.modelID)
            if valid(ref) { roles[role] = ref }
        }

        let selectionRow = try context.fetch(FetchDescriptor<PersistentAISelection>()).first
        let lastSelectedModel: AIModelRef? = {
            guard let providerID = selectionRow?.providerID,
                let modelID = selectionRow?.modelID
            else { return nil }
            let ref = AIModelRef(modelProviderID: providerID, modelID: modelID)
            return valid(ref) ? ref : nil
        }()

        return AIConfigurationSnapshot(
            providers: providers,
            roles: roles,
            lastSelectedModel: lastSelectedModel
        )
    }

    func save(_ snapshot: AIConfigurationSnapshot) throws {
        do {
            try context.delete(model: PersistentAIModel.self)
            try context.delete(model: PersistentModelProvider.self)
            try context.delete(model: PersistentAIRoleAssignment.self)
            try context.delete(model: PersistentAISelection.self)

            for (providerIndex, provider) in snapshot.providers.enumerated() {
                context.insert(PersistentModelProvider(provider, sortIndex: providerIndex))
                for (modelIndex, model) in provider.models.enumerated() {
                    context.insert(
                        PersistentAIModel(model, providerID: provider.id, sortIndex: modelIndex)
                    )
                }
            }
            for role in AIRole.allCases {
                guard let ref = snapshot.roles[role] else { continue }
                context.insert(PersistentAIRoleAssignment(role: role, ref: ref))
            }
            context.insert(PersistentAISelection(snapshot.lastSelectedModel))
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}

extension AIPersistence: AIConfigurationPersisting {}
