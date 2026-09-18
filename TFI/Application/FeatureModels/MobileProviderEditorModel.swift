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
    let serviceAccount = MobileSecretDraft()
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
        wasPersisted = ai.modelProvider(provider.id) != nil
        var initial = provider
        if !wasPersisted && provider.vertex == VertexConfig() { initial.vertex.location = "" }
        original = initial
        draft = initial
        originalEndpoint = wasPersisted ? ai.endpoint(for: provider.id) : ProviderEndpoint(url: provider.inferenceURL)
        endpoint = originalEndpoint
        key.begin(in: ai, reference: provider.credentialRef)
        serviceAccount.begin(in: ai, reference: provider.vertex.credentialRef)
    }

    var hasExistingKey: Bool { wasPersisted && !original.credentialRef.isEmpty }
    var isDirty: Bool { draft != original || endpoint != originalEndpoint || key.isDirty || serviceAccount.isDirty }
    var hasServiceAccount: Bool {
        serviceAccount.action == .replace || (serviceAccount.action == .preserve && !draft.vertex.credentialRef.isEmpty)
    }
    var canSave: Bool {
        ModelProviderForm.hasValidAddress(requestProvider) && key.isValid && serviceAccount.isValid
    }

    func importServiceAccount(_ json: String) throws {
        let account = try ModelProviderServiceAccount(json: json)
        serviceAccount.text = account.json
        serviceAccount.action = .replace
        draft.vertex.clientEmail = account.clientEmail
        if draft.vertex.projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.vertex.projectID = account.projectID
        }
    }

    func removeServiceAccount() {
        serviceAccount.text = ""
        serviceAccount.action = .clear
        draft.vertex.clientEmail = ""
    }

    func discardPlaintext() {
        key.discardPlaintext()
        serviceAccount.discardPlaintext()
    }

    var requestProvider: ModelProvider {
        ModelProviderForm.normalized(draft, endpoint: endpoint).provider
    }

    func requestSecret() throws -> String {
        guard !wasPersisted || ai.modelProvider(original.id) != nil else {
            throw MobileEditorError.message(String(localized: "Provider Deleted"))
        }
        let provider = requestProvider
        guard ModelProviderForm.hasValidAddress(provider) else {
            throw MobileEditorError.message(
                String(localized: "Enter a valid provider URL, or a Vertex project and location."))
        }
        let credential = provider.usesVertexEndpoint ? serviceAccount : key
        let reference = provider.effectiveCredentialRef
        let secret = try credential.effective(in: ai, reference: reference)
        guard
            !secret.isEmpty || (!provider.usesVertexEndpoint && reference.isEmpty && credential.action != .replace)
                || (!provider.usesVertexEndpoint && credential.action == .clear)
        else {
            throw MobileEditorError.message(
                String(localized: "The provider's credential is unavailable."))
        }
        return secret
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
            try fields.merge(\.usesVertex)
            try fields.merge(\.vertex.projectID)
            try fields.merge(\.vertex.location)
            try fields.merge(\.vertex.clientEmail)
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
        guard ModelProviderForm.hasValidAddress(ModelProviderForm.normalized(value, endpoint: savedEndpoint).provider)
        else {
            throw MobileEditorError.message(
                String(localized: "Enter a valid provider URL, or a Vertex project and location."))
        }
        let edits = try [
            key.providerEdit(reference: value.credentialRef, kind: .apiKey),
            serviceAccount.providerEdit(reference: value.vertex.credentialRef, kind: .serviceAccount),
        ].compactMap { $0 }
        try ai.saveProvider(value, endpoint: savedEndpoint, credentials: edits)
        discardPlaintext()
    }

    static func mergeModel(_ original: AIModel, _ draft: AIModel, _ current: AIModel) throws -> AIModel {
        // Materializing a legacy blank name on another save is not a competing rename.
        // Keep explicit clears intact: even a saved default name is an ordinary name.
        var current = current
        if original.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            current.displayName == original.savingName.displayName
        {
            current.displayName = original.displayName
        }
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
