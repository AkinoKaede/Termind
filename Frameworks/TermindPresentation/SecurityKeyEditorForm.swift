import SwiftUI
import TermindApplication
import TermindDomain

public struct SecurityKeyEditorForm: View {
    @State private var model: SecurityKeyEditorModel
    @State private var task: Task<Void, Never>?
    private let close: () -> Void

    public init(
        existing: SSHKeyRef,
        exportReference: @escaping (SecurityKeyCredential) throws -> String,
        validate: @escaping (SecurityKeyCredential) throws -> Void,
        persist: @escaping (SSHKeyRef) throws -> Void,
        close: @escaping () -> Void
    ) {
        _model = State(
            initialValue: SecurityKeyEditorModel(
                existing: existing, exportReference: exportReference, validate: validate, persist: persist))
        self.close = close
    }

    public var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Label(AppStrings.SecurityKey.title.swiftUIKey, systemImage: "key.radiowaves.forward.fill").font(
                        .headline)
                    VaultNameField(text: $model.label, prompt: Text(AppStrings.SecurityKey.title))
                    VaultColorField(selection: $model.colorTag)
                }
                Section(AppStrings.SecurityKey.reference.swiftUIKey) {
                    LabeledContent(AppStrings.Keychain.storeIn.swiftUIKey) {
                        Label(AppStrings.SecurityKey.title.swiftUIKey, systemImage: "key.radiowaves.forward.fill")
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
            .formStyle(.grouped)
            HStack {
                Button(AppStrings.Common.cancel.swiftUIKey) {
                    task?.cancel()
                    close()
                }
                Spacer()
                if model.isSaving { ProgressView().controlSize(.small) }
                Button(AppStrings.Common.save.swiftUIKey) {
                    task = Task { if await model.save() { close() } }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSave)
            }.padding()
        }
        .task { model.load() }
        .onDisappear { task?.cancel() }
    }
}
