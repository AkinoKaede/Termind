// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Observation
import TermindApplication
import TermindPresentation

/// Plaintext lives only in an editor or a request. Previewing never writes the Keychain.
@MainActor @Observable
final class MobileSecretDraft {
    enum Action: String, CaseIterable { case preserve, replace, clear }
    enum EditingMode { case explicitAction, direct }
    let editingMode: EditingMode
    private var originalReference = ""
    private var originalSecret: String?
    private var readError: String?

    init(editingMode: EditingMode = .explicitAction) {
        self.editingMode = editingMode
    }

    func begin(in ai: AIConfigurationModel, reference: String) {
        originalReference = reference
        originalSecret = nil
        readError = nil
        if !reference.isEmpty {
            originalSecret = ai.secret(for: reference)
            readError = ai.secretStorageError
        }
        if editingMode == .direct { text = originalSecret ?? "" }
    }

    var action = Action.preserve
    var text = "" {
        didSet {
            guard editingMode == .direct else { return }
            action = !canEdit || text == (originalSecret ?? "") ? .preserve : text.isEmpty ? .clear : .replace
        }
    }
    var canEdit: Bool {
        editingMode != .direct || originalReference.isEmpty || (readError == nil && originalSecret != nil)
    }
    var isDirty: Bool { action != .preserve || (editingMode == .explicitAction && !text.isEmpty) }
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
        originalSecret = nil
        text = ""
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
            var message = ai.storageError ?? String(localized: AppStrings.Common.unableToSave)
            if action != .preserve {
                ai.setSecret(previous, for: ref)
                if let error = ai.secretStorageError { message += "\n" + error }
            }
            throw MobileEditorError.message(message)
        }
        text = ""
    }
}
