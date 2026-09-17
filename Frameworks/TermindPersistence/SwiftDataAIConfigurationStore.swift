import AgentKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain

@MainActor
public final class AIPersistence {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    public func load() throws -> AIConfigurationSnapshot {
        try load(preservingUnresolvedReferences: false)
    }

    public func load(preservingUnresolvedReferences: Bool) throws -> AIConfigurationSnapshot {
        let modelRows = try context.fetch(
            FetchDescriptor<PersistentAIModel>(sortBy: [SortDescriptor(\.sortIndex)])
        )
        let modelsByProvider = Dictionary(grouping: modelRows, by: \.providerID)
        let providerRows = try context.fetch(
            FetchDescriptor<PersistentModelProvider>(sortBy: [SortDescriptor(\.sortIndex)])
        )
        let vertexRows = try context.fetch(FetchDescriptor<PersistentModelProviderVertexConfiguration>())
        let vertexByProvider = Dictionary(
            vertexRows.map { ($0.providerID, $0) }, uniquingKeysWith: { first, _ in first })
        var seenProviders: Set<UUID> = []
        var endpoints: [ModelProvider.ID: ProviderEndpoint] = [:]
        let providers = providerRows.compactMap { row -> ModelProvider? in
            guard seenProviders.insert(row.id).inserted else { return nil }
            var seenModels: Set<String> = []
            let models: [AIModel] = (modelsByProvider[row.id] ?? []).compactMap { modelRow -> AIModel? in
                guard seenModels.insert(modelRow.modelID).inserted else { return nil }
                return modelRow.value
            }
            endpoints[row.id] = row.endpoint
            var provider = row.value(models: models)
            vertexByProvider[row.id]?.apply(to: &provider)
            return provider
        }

        func valid(_ ref: AIModelRef) -> Bool {
            providers.first(where: { $0.id == ref.modelProviderID })?.model(ref.modelID) != nil
        }

        var roles: [AIRole: AIModelRef] = [:]
        for row in try context.fetch(FetchDescriptor<PersistentAIRoleAssignment>()) {
            guard let role = AIRole(rawValue: row.role) ?? (row.role == "securityReview" ? .guardian : nil)
            else { continue }
            let ref = AIModelRef(modelProviderID: row.providerID, modelID: row.modelID)
            if preservingUnresolvedReferences || valid(ref) { roles[role] = ref }
        }

        let selectionRow = try context.fetch(FetchDescriptor<PersistentAISelection>()).first
        let lastSelectedModel: AIModelRef? = {
            guard let providerID = selectionRow?.providerID,
                let modelID = selectionRow?.modelID
            else { return nil }
            let ref = AIModelRef(modelProviderID: providerID, modelID: modelID)
            return preservingUnresolvedReferences || valid(ref) ? ref : nil
        }()

        let mcpRows = try context.fetch(
            FetchDescriptor<PersistentMCPServer>(sortBy: [SortDescriptor(\.sortIndex)])
        )
        var seenMCPServers: Set<UUID> = []
        let mcpServers = mcpRows.compactMap { row -> MCPServer? in
            guard seenMCPServers.insert(row.id).inserted else { return nil }
            return row.value
        }

        return AIConfigurationSnapshot(
            providers: providers,
            endpoints: endpoints,
            roles: roles,
            lastSelectedModel: lastSelectedModel,
            mcpServers: mcpServers
        )
    }

    public func save(_ snapshot: AIConfigurationSnapshot) throws {
        try context.commit { try replace(snapshot) }
    }

    /// Stages rows in the caller-owned transaction.
    public func replace(_ snapshot: AIConfigurationSnapshot) throws {
        try context.delete(model: PersistentAIModel.self)
        try context.delete(model: PersistentModelProvider.self)
        try context.delete(model: PersistentModelProviderVertexConfiguration.self)
        try context.delete(model: PersistentAIRoleAssignment.self)
        try context.delete(model: PersistentAISelection.self)
        try context.delete(model: PersistentMCPServer.self)

        for (providerIndex, provider) in snapshot.providers.enumerated() {
            // A provider with no recorded endpoint is read back as
            // `Automatic` over its composed URL, which resolves to the same
            // format it already has — see `AIConfigurationModel.endpoints`.
            let endpoint =
                snapshot.endpoints[provider.id] ?? ProviderEndpoint(url: provider.inferenceURL)
            context.insert(
                PersistentModelProvider(provider, endpoint: endpoint, sortIndex: providerIndex)
            )
            context.insert(PersistentModelProviderVertexConfiguration(provider))
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
        for (serverIndex, server) in snapshot.mcpServers.enumerated() {
            context.insert(PersistentMCPServer(server, sortIndex: serverIndex))
        }
    }
}

extension AIPersistence: AIConfigurationPersisting {}
