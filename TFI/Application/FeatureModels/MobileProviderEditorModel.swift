import AgentKit
import Foundation
import Observation
import TermindApplication
import TermindDomain

@MainActor @Observable
final class MobileProviderEditorModel {
    typealias KeyAction = MobileSecretDraft.Action
    let original: ModelProvider
    let originalEndpoint: ProviderEndpoint
    var draft: ModelProvider
    var endpoint: ProviderEndpoint
    let key = MobileSecretDraft()
    var keyAction: KeyAction {
        get { key.action }
        set { key.action = newValue }
    }
    var secret: String {
        get { key.text }
        set { key.text = newValue }
    }
    private let ai: AIConfigurationModel
    private let wasPersisted: Bool

    init(ai: AIConfigurationModel, provider: ModelProvider) {
        self.ai = ai
        original = provider
        draft = provider
        wasPersisted = ai.modelProvider(provider.id) != nil
        originalEndpoint = wasPersisted ? ai.endpoint(for: provider.id) : ProviderEndpoint(url: provider.inferenceURL)
        endpoint = originalEndpoint
        key.begin(in: ai, reference: provider.credentialRef)
    }

    var hasExistingKey: Bool { wasPersisted && !original.credentialRef.isEmpty }
    var isDirty: Bool { draft != original || endpoint != originalEndpoint || key.isDirty }
    var canSave: Bool {
        let url = URL(string: endpoint.requestURL)
        return !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ["http", "https"].contains(url?.scheme?.lowercased() ?? "")
            && url?.host?.isEmpty == false && key.isValid
    }

    var requestProvider: ModelProvider {
        var provider = draft
        provider.inferenceURL = endpoint.requestURL
        provider.baseURL = endpoint.baseURL
        provider.apiFormat = endpoint.format
        return provider
    }

    func requestSecret() throws -> String {
        guard !wasPersisted || ai.modelProvider(original.id) != nil else {
            throw MobileEditorError.message(String(localized: "Provider Deleted"))
        }
        if key.action == .preserve {
            guard let secret = ai.modelSecret(for: ai.modelProvider(original.id) ?? requestProvider) else {
                throw MobileEditorError.message(
                    ai.secretStorageError ?? String(localized: "The provider's credential is unavailable."))
            }
            return secret
        }
        return try key.effective(in: ai, reference: draft.effectiveCredentialRef)
    }

    func add(_ models: [AIModel]) {
        for model in models where !draft.models.contains(where: { $0.id == model.id }) { draft.models.append(model) }
    }

    func add(id: String) {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        add([ModelCapabilityResolver.resolve(model: AIModel(id: id), provider: requestProvider).model])
    }

    func remove(_ ids: Set<String>) { draft.models.removeAll { ids.contains($0.id) } }

    func update(_ model: AIModel) {
        guard let index = draft.models.firstIndex(where: { $0.id == model.id }) else { return }
        draft.models[index] = model
    }

    func save() throws {
        guard canSave else { return }
        let current = ai.modelProvider(original.id)
        guard !wasPersisted || current != nil else {
            throw MobileEditorError.message(String(localized: "Provider Deleted"))
        }
        var value = draft
        var savedEndpoint = endpoint
        if let current {
            var fields = SettingsFields(original, draft, current)
            try fields.merge(\.name)
            try fields.merge(\.isEnabled)
            value = fields.result
            value.models = try SettingsDraftMerge.collection(
                original.models, draft.models, current.models, merge: Self.mergeModel)
            // Discovery time is observational metadata, not an editable conflict.
            if draft.modelsFetchedAt != original.modelsFetchedAt { value.modelsFetchedAt = draft.modelsFetchedAt }
            var connection = SettingsFields(originalEndpoint, endpoint, ai.endpoint(for: original.id))
            try connection.merge(\.url)
            try connection.merge(\.apiType)
            savedEndpoint = connection.result
        }
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        try key.commit(in: ai, reference: value.credentialRef) { reference in
            value.credentialRef = reference
            return ai.saveProvider(value, endpoint: savedEndpoint)
        }
    }

    static func mergeModel(_ original: AIModel, _ draft: AIModel, _ current: AIModel) throws -> AIModel {
        var fields = SettingsFields(original, draft, current)
        try fields.merge(\.displayName)
        try fields.merge(\.kind)
        try fields.merge(\.input)
        try fields.merge(\.abilities)
        try fields.merge(\.contextLength)
        try fields.merge(\.maxOutputTokens)
        try fields.merge(\.isShownInAssistant)
        try fields.merge(\.reasoningProfile)
        return fields.result
    }
}
