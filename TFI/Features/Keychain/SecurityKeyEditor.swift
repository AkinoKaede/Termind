// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure

struct SecurityKeyEditor: View {
    @State private var model: SecurityKeyEditorModel

    init(credentials: CredentialLibraryModel, existing: SSHKeyRef) {
        let model = SecurityKeyEditorModel(
            existing: existing, exportReference: WebAuthnSSH.exportReference, validate: WebAuthnSSH.validate,
            persist: { try credentials.upsert($0) })
        model.load()
        _model = State(initialValue: model)
    }

    var body: some View {
        MobileEditorSheet(
            title: String(localized: AppStrings.Keychain.editKey),
            isDirty: model.isDirty, canSave: model.canSave,
            save: { try await model.saveChanges() },
            content: { SecurityKeyEditorSections(model: model) })
    }
}
