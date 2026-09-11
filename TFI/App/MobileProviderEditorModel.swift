import AgentKit
import Foundation
import Observation
import TermindApplication
import TermindDomain

@MainActor
@Observable
final class MobileProviderEditorModel {
    enum KeyAction: String, CaseIterable { case preserve, replace, clear }
    let original: ModelProvider
    let originalEndpoint: ProviderEndpoint
    var draft: ModelProvider
    var endpoint: ProviderEndpoint
    var keyAction = KeyAction.preserve
    var secret = ""
    private let ai: AIConfigurationModel
    private let wasPersisted: Bool

    init(ai: AIConfigurationModel, provider: ModelProvider) {
        self.ai = ai
        original = provider
        draft = provider
        wasPersisted = ai.modelProvider(provider.id) != nil
        originalEndpoint = wasPersisted ? ai.endpoint(for: provider.id) : ProviderEndpoint(url: provider.inferenceURL)
        endpoint = originalEndpoint
    }

    var isDirty: Bool { draft != original || endpoint != originalEndpoint || keyAction != .preserve || !secret.isEmpty }
    var canSave: Bool {
        let url = URL(string: endpoint.requestURL)
        return !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && url?.scheme == "https" && url?.host != nil && (keyAction != .replace || !secret.isEmpty)
    }

    func save() throws {
        guard canSave else { return }
        let current = ai.modelProvider(original.id)
        guard !wasPersisted || current != nil else {
            throw MobileEditorError.message(String(localized: "Provider Deleted"))
        }
        var value = current ?? draft
        // A live model refresh must not be overwritten by this form's older draft.
        value.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.isEnabled = draft.isEnabled
        let reference = value.credentialRef.isEmpty ? AIConfigurationModel.makeCredentialRef() : value.credentialRef
        var previousSecret: String?
        if keyAction != .preserve {
            previousSecret = ai.secret(for: reference)
            if let error = ai.secretStorageError { throw MobileEditorError.message(error) }
            ai.setSecret(keyAction == .clear ? nil : secret, for: reference)
            if let error = ai.secretStorageError { throw MobileEditorError.message(error) }
            value.credentialRef = keyAction == .clear ? "" : reference
        }
        guard ai.saveProvider(value, endpoint: endpoint) else {
            var message = ai.storageError ?? String(localized: "Unable to Save")
            if keyAction != .preserve {
                ai.setSecret(previousSecret, for: reference)
                if let rollback = ai.secretStorageError { message += "\n" + rollback }
            }
            throw MobileEditorError.message(message)
        }
        secret = ""
    }
}
