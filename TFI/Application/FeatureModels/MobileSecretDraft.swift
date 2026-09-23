import Foundation
import Observation
import TermindApplication
import TermindPresentation

/// Plaintext lives only in an editor or a request. Previewing never writes the Keychain.
@MainActor @Observable
final class MobileSecretDraft {
    enum Action: String, CaseIterable { case preserve, replace, clear }
    private var originalReference = ""
    private var originalSecret: String?
    private var readError: String?

    func begin(in ai: AIConfigurationModel, reference: String) {
        originalReference = reference
        if !reference.isEmpty {
            originalSecret = ai.secret(for: reference)
            readError = ai.secretStorageError
        }
    }

    var action = Action.preserve
    var text = ""
    var isDirty: Bool { action != .preserve || !text.isEmpty }
    var isValid: Bool { action != .replace || !text.isEmpty }

    func effective(in ai: AIConfigurationModel, reference: String) throws -> String {
        switch action {
        case .clear: return ""
        case .replace: return text
        case .preserve:
            guard !reference.isEmpty else { return "" }
            let value = ai.secret(for: reference) ?? ""
            if let error = ai.secretStorageError { throw MobileEditorError.message(error) }
            return value
        }
    }

    func providerEdit(reference: String, kind: ModelProviderCredentialKind) throws -> ModelProviderCredentialEdit? {
        guard action != .preserve else { return nil }
        if let readError { throw MobileEditorError.message(readError) }
        guard reference == originalReference else { throw SettingsDraftMerge.Conflict.changed }
        return .init(
            kind: kind, reference: reference, previous: originalSecret, replacement: action == .clear ? nil : text)
    }

    func discardPlaintext() {
        text = ""
        originalSecret = nil
    }

    func commit(in ai: AIConfigurationModel, reference: String, kind: String = "key", save: (String) -> Bool) throws {
        if action != .preserve {
            if let readError { throw MobileEditorError.message(readError) }
            guard reference == originalReference else { throw SettingsDraftMerge.Conflict.changed }
            if !reference.isEmpty {
                let current = ai.secret(for: reference)
                if let error = ai.secretStorageError { throw MobileEditorError.message(error) }
                guard current == originalSecret else { throw SettingsDraftMerge.Conflict.changed }
            }
        }
        let ref = reference.isEmpty ? AIConfigurationModel.makeCredentialRef(kind) : reference
        var previous: String?
        if action != .preserve {
            previous = ai.secret(for: ref)
            if let error = ai.secretStorageError { throw MobileEditorError.message(error) }
            ai.setSecret(action == .clear ? nil : text, for: ref)
            if let error = ai.secretStorageError { throw MobileEditorError.message(error) }
        }
        let next = action == .preserve ? reference : action == .clear ? "" : ref
        guard save(next) else {
            var message = ai.storageError ?? String(localized: TermindCopy.Common.unableToSave)
            if action != .preserve {
                ai.setSecret(previous, for: ref)
                if let error = ai.secretStorageError { message += "\n" + error }
            }
            throw MobileEditorError.message(message)
        }
        text = ""
    }
}
