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
    @State private var label = ""
    @State private var colorTag = TagColor.none
    @State private var verification: SecurityKeyCredential.UserVerification = .preferred
    @State private var reference = ""
    @State private var originalCredential: SecurityKeyCredential?
    @State private var error: String?
    @State private var running = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Label(AppStrings.SecurityKey.title.swiftUIKey, systemImage: "key.radiowaves.forward.fill").font(
                        .headline)
                    VaultNameField(text: $label, prompt: Text(AppStrings.SecurityKey.title))
                    VaultColorField(selection: $colorTag)
                }
                Section {
                    LabeledContent(AppStrings.Keychain.storeIn.swiftUIKey) {
                        Label(AppStrings.SecurityKey.title.swiftUIKey, systemImage: "key.radiowaves.forward.fill")
                    }
                    WebAuthnVerificationPicker(selection: $verification)
                    if !reference.isEmpty {
                        Text(AppStrings.SecurityKey.reference).font(.headline)
                        Text(reference).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Text(existing.publicKey).font(.caption.monospaced()).textSelection(.enabled)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            HStack {
                Button(AppStrings.Common.cancel.swiftUIKey) {
                    task?.cancel()
                    finish()
                }
                Spacer()
                if running { ProgressView().controlSize(.small) }
                Button(AppStrings.Common.save.swiftUIKey) {
                    task = Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(running || originalCredential == nil)
            }.padding()
        }
        .task {
            label = existing.label
            colorTag = existing.colorTag
            do {
                guard let credential = existing.securityKey else {
                    throw TermindSSHError.missingCredential
                }
                originalCredential = credential
                verification = credential.userVerification
                reference = try WebAuthnSSH.exportReference(credential)
            } catch { self.error = error.localizedDescription }
        }
        .onDisappear { task?.cancel() }
    }

    private func finish() {
        if let close { close() } else { dismiss() }
    }

    private func save() async {
        running = true
        error = nil
        defer { running = false }
        do {
            guard var credential = originalCredential else { throw TermindSSHError.missingCredential }
            credential.userVerification = verification
            try WebAuthnSSH.validate(credential)
            try Task.checkCancellation()
            var key = existing
            key.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
            key.colorTag = colorTag
            key.securityKey = credential
            try credentials.upsert(key)
            finish()
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}
