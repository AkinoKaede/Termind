import SwiftUI
import TermindDomain
import UniformTypeIdentifiers

struct MobileKeyEditor: View {
    @Bindable var model: MobileKeyEditorModel
    @State private var choosingFile = false
    @State private var fileError: String?

    var body: some View {
        MobileEditorSheet(
            title: title, isDirty: model.isDirty, canSave: model.canSave,
            save: { try await model.save() },
            content: {
                Section("Key") {
                    TextField("Name", text: $model.label)
                    if !model.isEnclave {
                        Picker("Storage", selection: $model.storage) {
                            Text("This Device").tag(KeyStorage.thisDevice)
                            Text("iCloud").tag(KeyStorage.iCloud)
                            if model.mode == .generate && model.canUseEnclave {
                                Text("Secure Enclave").tag(KeyStorage.secureEnclave)
                            }
                        }
                    }
                    if model.mode == .generate {
                        if model.storage == .secureEnclave {
                            Toggle("Require User Presence", isOn: $model.requiresUserPresence)
                        } else {
                            Picker("Algorithm", selection: $model.algorithm) {
                                ForEach(MobileKeyEditorModel.Algorithm.allCases) { Text($0.rawValue).tag($0) }
                            }
                            SecureField("Passphrase", text: $model.passphrase)
                        }
                    }
                }
                if model.mode == .importKey {
                    Section("Private Key") {
                        Button("Choose File") { choosingFile = true }
                        TextEditor(text: $model.privateKey).font(.body.monospaced()).frame(minHeight: 150)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Passphrase", text: $model.passphrase)
                    }
                }
                if model.storage != .secureEnclave {
                    Section("SSH Certificate") {
                        TextEditor(text: $model.certificate).font(.caption.monospaced()).frame(minHeight: 90)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                if let publicKey = model.publicKey {
                    Section("Public Key") { Text(publicKey).font(.caption.monospaced()).textSelection(.enabled) }
                }
                if let fingerprint = model.fingerprint {
                    Section("Fingerprint") { Text(fingerprint).font(.caption.monospaced()).textSelection(.enabled) }
                }
            }
        )
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.data]) { result in
            Task {
                do { try await model.loadFile(result.get()) } catch { fileError = error.localizedDescription }
            }
        }
        .alert(
            "Unable to Read File", isPresented: Binding(get: { fileError != nil }, set: { if !$0 { fileError = nil } })
        ) {
            Button("OK", role: .cancel) { fileError = nil }
        } message: {
            Text(fileError ?? "")
        }
    }

    private var title: String {
        switch model.mode {
        case .generate: String(localized: "Generate Key")
        case .importKey: String(localized: "Import Key")
        case .edit: String(localized: "Edit Key")
        }
    }
}
