// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication
import TermindDomain

/// Shared fields; each platform owns the surrounding editor and actions.
public struct SecurityKeyEditorSections: View {
    @Bindable private var model: SecurityKeyEditorModel
    private let showsTitle: Bool

    public init(model: SecurityKeyEditorModel, showsTitle: Bool = false) {
        self.model = model
        self.showsTitle = showsTitle
    }

    public var body: some View {
        Section {
            if showsTitle {
                Label(AppStrings.SecurityKey.title.swiftUIKey, systemImage: "key.radiowaves.forward.fill")
                    .font(.headline)
            }
            VaultNameField(text: $model.label, prompt: Text(AppStrings.SecurityKey.title))
            VaultColorField(selection: $model.colorTag)
        }
        Section(AppStrings.SecurityKey.reference.swiftUIKey) {
            LabeledContent(AppStrings.Keychain.storeIn.swiftUIKey) {
                Label(AppStrings.SecurityKey.title.swiftUIKey, systemImage: "key.radiowaves.forward.fill")
                    .labelStyle(.titleAndIcon)
            }
            WebAuthnVerificationPicker(selection: $model.verification)
            if !model.reference.isEmpty {
                Text(model.reference).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        Section(AppStrings.Keychain.publicKey.swiftUIKey) {
            Text(model.existing.publicKey).font(.caption.monospaced()).textSelection(.enabled)
        }
        if let error = model.error { Text(error).foregroundStyle(.red) }
    }
}
