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
                Section {
                    VaultNameField(text: $model.label, prompt: Text(model.defaultName))
                    VaultColorField(selection: $model.colorTag)
                }
                if model.mode == .generate {
                    Section(
                        model.storage == .secureEnclave
                            ? TermindCopy.Keychain.secureEnclave.swiftUIKey : TermindCopy.Keychain.privateKey.swiftUIKey
                    ) {
                        storagePicker
                        if model.storage == .secureEnclave {
                            Toggle(
                                TermindCopy.Keychain.requireUserPresence.swiftUIKey, isOn: $model.requiresUserPresence)
                        } else {
                            Picker(TermindCopy.Keychain.algorithm.swiftUIKey, selection: $model.algorithm) {
                                ForEach(MobileKeyEditorModel.Algorithm.allCases) { Text($0.rawValue).tag($0) }
                            }
                            if model.algorithm == .ecdsa {
                                Picker(TermindCopy.Keychain.ellipticCurve.swiftUIKey, selection: $model.curveBits) {
                                    Text(TermindCopy.Keychain.nistP256).tag(256)
                                    Text(TermindCopy.Keychain.nistP384).tag(384)
                                    Text(TermindCopy.Keychain.nistP521).tag(521)
                                }
                            } else if model.algorithm == .rsa {
                                Picker(TermindCopy.Keychain.keySize.swiftUIKey, selection: $model.rsaBits) {
                                    Text(TermindCopy.Keychain.rsa2048Bits).tag(2048)
                                    Text(TermindCopy.Keychain.rsa3072Bits).tag(3072)
                                    Text(TermindCopy.Keychain.rsa4096Bits).tag(4096)
                                }
                            }
                            LabeledContent(TermindCopy.Keychain.passphrase.swiftUIKey) {
                                RevealableSecretField(TermindCopy.Common.optional, text: $model.passphrase)
                                    .multilineTextAlignment(.trailing)
                            }
                            LabeledContent(TermindCopy.Keychain.confirmPassphrase.swiftUIKey) {
                                RevealableSecretField(TermindCopy.Keychain.confirmPassphrase, text: $model.confirmation)
                                    .multilineTextAlignment(.trailing).disabled(model.passphrase.isEmpty)
                            }
                            if !model.passphrase.isEmpty {
                                Picker(TermindCopy.Keychain.cipher.swiftUIKey, selection: $model.cipher) {
                                    ForEach(SSHKeyMaterial.Cipher.allCases) { Text($0.displayName).tag($0) }
                                }
                                LabeledContent(TermindCopy.Keychain.rounds.swiftUIKey) {
                                    TextField(
                                        TermindCopy.Keychain.rounds.swiftUIKey, value: $model.rounds, format: .number
                                    ).lineLimit(1)
                                        .multilineTextAlignment(.trailing).keyboardType(.numberPad)
                                }
                                if model.passphrase != model.confirmation {
                                    Text(TermindCopy.Keychain.passphrasesDoNotMatch).foregroundStyle(.red)
                                }
                            }
                        }
                    }
                } else if model.storage != .secureEnclave {
                    Section(TermindCopy.Keychain.privateKey.swiftUIKey) {
                        storagePicker
                        if model.isLoadingPrivateKey {
                            ProgressView(TermindCopy.Keychain.loadingPrivateKeyProgress.swiftUIKey)
                        } else {
                            if let error = model.privateKeyLoadError {
                                Label(error, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            Button(
                                model.mode == .edit
                                    ? TermindCopy.Keychain.chooseReplacement.swiftUIKey
                                    : TermindCopy.Keychain.chooseFile.swiftUIKey, systemImage: "folder"
                            ) {
                                choosingFile = true
                            }
                            .disabled(!model.canEditPrivateKey)
                            TextEditor(text: $model.privateKey)
                                .multilineTextAlignment(.leading)
                                .font(.body.monospaced())
                                .frame(minHeight: 150)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .disabled(!model.canEditPrivateKey)
                            if model.replacesPublicKey {
                                Label(
                                    TermindCopy.Keychain.replacePrivateKeyWarning.swiftUIKey,
                                    systemImage: "arrow.triangle.2.circlepath"
                                )
                                .font(.caption)
                                .foregroundStyle(.orange)
                            }
                            RevealableSecretField(TermindCopy.Keychain.passphrase, text: $model.passphrase)
                                .multilineTextAlignment(.leading)
                                .disabled(!model.canEditPrivateKey)
                        }
                    }
                } else {
                    Section(TermindCopy.Keychain.secureEnclave.swiftUIKey) {
                        LabeledContent(
                            TermindCopy.Keychain.storeIn.swiftUIKey,
                            value: String(localized: TermindCopy.Keychain.secureEnclave))
                    }
                }
                if model.mode != .generate && model.storage != .secureEnclave {
                    Section(TermindCopy.Keychain.sshCertificate.swiftUIKey) {
                        Button(TermindCopy.Keychain.chooseFile.swiftUIKey, systemImage: "folder") {
                            choosingCertificate = true
                        }
                        TextEditor(text: $model.certificate).multilineTextAlignment(.leading).font(
                            .caption.monospaced()
                        ).frame(minHeight: 90)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                if let warning = model.certificateWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
                if let publicKey = model.publicKey {
                    Section(TermindCopy.Keychain.publicKey.swiftUIKey) {
                        Text(publicKey).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                if let fingerprint = model.fingerprint {
                    Section(TermindCopy.KnownHosts.fingerprint.swiftUIKey) {
                        Text(fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                    }
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
            TermindCopy.Keychain.unableToReadFile.swiftUIKey,
            isPresented: Binding(get: { fileError != nil }, set: { if !$0 { fileError = nil } })
        ) {
            Button(TermindCopy.Common.ok.swiftUIKey, role: .cancel) { fileError = nil }
        } message: {
            Text(fileError ?? "")
        }
        .task { await model.loadPrivateKey() }
        .task(id: model.validationToken) { await model.derivePublicMaterial() }
    }

    private var title: String {
        switch model.mode {
        case .generate: String(localized: TermindCopy.Keychain.generateKey)
        case .importKey: String(localized: TermindCopy.Keychain.importKey)
        case .edit: String(localized: TermindCopy.Keychain.editKey)
        }
    }

    private var storagePicker: some View {
        Picker(TermindCopy.Keychain.storeIn.swiftUIKey, selection: $model.storage) {
            Label(TermindCopy.Keychain.thisDevice.swiftUIKey, systemImage: "ipad.and.iphone").tag(KeyStorage.thisDevice)
            Label(TermindCopy.Keychain.iCloud.swiftUIKey, systemImage: "icloud.fill").tag(KeyStorage.iCloud)
            if model.mode == .generate && model.canUseEnclave {
                Label(TermindCopy.Keychain.secureEnclave.swiftUIKey, systemImage: "checkmark.shield.fill").tag(
                    KeyStorage.secureEnclave)
            }
        }
        .disabled(!model.canEditPrivateKey || !model.canSelectThisDevice)
    }
}
