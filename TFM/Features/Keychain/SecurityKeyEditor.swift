// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure

struct SecurityKeyEditor: View {
    let credentials: CredentialLibraryModel
    let existing: SSHKeyRef
    var close: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SecurityKeyEditorForm(
            existing: existing, exportReference: WebAuthnSSH.exportReference, validate: WebAuthnSSH.validate,
            persist: { try credentials.upsert($0) }, close: finish)
    }

    private func finish() {
        if let close { close() } else { dismiss() }
    }
}
