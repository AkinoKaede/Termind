import SwiftUI
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure
import UniformTypeIdentifiers

struct MobileKeyEditor: View {
    @Bindable var model: MobileKeyEditorModel
    @State private var choosingFile = false
    @State private var choosingCertificate = false
    @State private var fileError: String?

    var body: some View {
        MobileEditorSheet(
            title: title, isDirty: model.isDirty, canSave: model.canSave,
            save: { try await model.save() },
            content: {
                Section("Key") {
                    LabeledContent("Name") {
                        TextField(
                            "Name", text: $model.label.singleLineText, prompt: Text(model.defaultName),
                            axis: .horizontal
                        ).singleLinePaste().lineLimit(1)
                            .multilineTextAlignment(.trailing)
                    }
                    if !model.isEnclave {
                        Picker("Store in", selection: $model.storage) {
                            Text("This Device").tag(KeyStorage.thisDevice)
                            Text("iCloud").tag(KeyStorage.iCloud)
                            if model.mode == .generate && model.canUseEnclave {
                                Text("Secure Enclave").tag(KeyStorage.secureEnclave)
                            }
                        }
                        .disabled(!model.canSelectThisDevice)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Color")
                        ColorTagPicker(selection: $model.colorTag, layout: .touch)
                    }
                    if model.mode == .generate {
                        if model.storage == .secureEnclave {
                            Toggle("Require User Presence", isOn: $model.requiresUserPresence)
                        } else {
                            Picker("Algorithm", selection: $model.algorithm) {
                                ForEach(MobileKeyEditorModel.Algorithm.allCases) { Text($0.rawValue).tag($0) }
                            }
                            if model.algorithm == .ecdsa {
                                Picker("Elliptic Curve", selection: $model.curveBits) {
                                    Text("NIST P-256").tag(256)
                                    Text("NIST P-384").tag(384)
                                    Text("NIST P-521").tag(521)
                                }
                            } else if model.algorithm == .rsa {
                                Picker("Key Size", selection: $model.rsaBits) {
                                    Text("2048 bit").tag(2048)
                                    Text("3072 bit").tag(3072)
                                    Text("4096 bit").tag(4096)
                                }
                            }
                            LabeledContent("Passphrase") {
                                SecureField("Optional", text: $model.passphrase).multilineTextAlignment(.trailing)
                            }
                            LabeledContent("Confirm Passphrase") {
                                SecureField("Confirm Passphrase", text: $model.confirmation)
                                    .multilineTextAlignment(.trailing).disabled(model.passphrase.isEmpty)
                            }
                            if !model.passphrase.isEmpty {
                                Picker("Cipher", selection: $model.cipher) {
                                    ForEach(SSHKeyMaterial.Cipher.allCases) { Text($0.displayName).tag($0) }
                                }
                                LabeledContent("Rounds") {
                                    TextField("Rounds", value: $model.rounds, format: .number).lineLimit(1)
                                        .multilineTextAlignment(.trailing).keyboardType(.numberPad)
                                }
                                if model.passphrase != model.confirmation {
                                    Text("Passphrases do not match.").foregroundStyle(.red)
                                }
                            }
                        }
                    }
                }
                if model.mode != .generate && model.storage != .secureEnclave {
                    Section("Private Key") {
                        if model.isLoadingPrivateKey {
                            ProgressView("Loading private key…")
                        } else {
                            if let error = model.privateKeyLoadError {
                                Label(error, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            Button(model.mode == .edit ? "Choose Replacement" : "Choose File", systemImage: "folder") {
                                choosingFile = true
                            }
                            TextEditor(text: $model.privateKey)
                                .multilineTextAlignment(.leading)
                                .font(.body.monospaced())
                                .frame(minHeight: 150)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            if model.replacesPublicKey {
                                Label(
                                    "Replacing this private key changes its public key. Hosts using the old key may reject the next connection.",
                                    systemImage: "arrow.triangle.2.circlepath"
                                )
                                .font(.caption)
                                .foregroundStyle(.orange)
                            }
                            SecureField("Passphrase", text: $model.passphrase)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
                if model.mode != .generate && model.storage != .secureEnclave {
                    Section("SSH Certificate") {
                        Button("Choose File", systemImage: "folder") { choosingCertificate = true }
                        TextEditor(text: $model.certificate).multilineTextAlignment(.leading).font(
                            .caption.monospaced()
                        ).frame(minHeight: 90)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                if let warning = model.certificateWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
                if let publicKey = model.publicKey {
                    Section("Public Key") { Text(publicKey).font(.caption.monospaced()).textSelection(.enabled) }
                }
                if let fingerprint = model.fingerprint {
                    Section("Fingerprint") { Text(fingerprint).font(.caption.monospaced()).textSelection(.enabled) }
                }
            }
        )
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.data, .plainText]) { result in
            Task {
                do { try await model.loadFile(result.get()) } catch { fileError = error.localizedDescription }
            }
        }
        .fileImporter(isPresented: $choosingCertificate, allowedContentTypes: [.data, .plainText]) { result in
            Task {
                do { try await model.loadCertificateFile(result.get()) } catch {
                    fileError = error.localizedDescription
                }
            }
        }
        .alert(
            "Unable to Read File", isPresented: Binding(get: { fileError != nil }, set: { if !$0 { fileError = nil } })
        ) {
            Button("OK", role: .cancel) { fileError = nil }
        } message: {
            Text(fileError ?? "")
        }
        .task { await model.loadPrivateKey() }
        .task(id: model.validationToken) { await model.derivePublicMaterial() }
    }

    private var title: String {
        switch model.mode {
        case .generate: String(localized: "Generate Key")
        case .importKey: String(localized: "Import Key")
        case .edit: String(localized: "Edit Key")
        }
    }
}
