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
                            ? AppStrings.Keychain.secureEnclave.swiftUIKey : AppStrings.Keychain.privateKey.swiftUIKey
                    ) {
                        storagePicker
                        if model.storage == .secureEnclave {
                            Toggle(
                                AppStrings.Keychain.requireUserPresence.swiftUIKey, isOn: $model.requiresUserPresence)
                        } else {
                            Picker(AppStrings.Keychain.algorithm.swiftUIKey, selection: $model.algorithm) {
                                ForEach(MobileKeyEditorModel.Algorithm.allCases) { Text($0.rawValue).tag($0) }
                            }
                            if model.algorithm == .ecdsa {
                                Picker(AppStrings.Keychain.ellipticCurve.swiftUIKey, selection: $model.curveBits) {
                                    Text(AppStrings.Keychain.nistP256).tag(256)
                                    Text(AppStrings.Keychain.nistP384).tag(384)
                                    Text(AppStrings.Keychain.nistP521).tag(521)
                                }
                            } else if model.algorithm == .rsa {
                                Picker(AppStrings.Keychain.keySize.swiftUIKey, selection: $model.rsaBits) {
                                    Text(AppStrings.Keychain.rsa2048Bits).tag(2048)
                                    Text(AppStrings.Keychain.rsa3072Bits).tag(3072)
                                    Text(AppStrings.Keychain.rsa4096Bits).tag(4096)
                                }
                            }
                            LabeledContent(AppStrings.Keychain.passphrase.swiftUIKey) {
                                RevealableSecretField(AppStrings.Common.optional, text: $model.passphrase)
                                    .multilineTextAlignment(.trailing)
                            }
                            LabeledContent(AppStrings.Keychain.confirmPassphrase.swiftUIKey) {
                                RevealableSecretField(AppStrings.Keychain.confirmPassphrase, text: $model.confirmation)
                                    .multilineTextAlignment(.trailing).disabled(model.passphrase.isEmpty)
                            }
                            Toggle(AppStrings.Keychain.savePassphrase.swiftUIKey, isOn: $model.savePassphrase)
                                .disabled(model.passphrase.isEmpty)
                            if !model.passphrase.isEmpty {
                                Picker(AppStrings.Keychain.cipher.swiftUIKey, selection: $model.cipher) {
                                    ForEach(SSHKeyMaterial.Cipher.allCases) { Text($0.displayName).tag($0) }
                                }
                                LabeledContent(AppStrings.Keychain.rounds.swiftUIKey) {
                                    TextField(
                                        AppStrings.Keychain.rounds.swiftUIKey, value: $model.rounds, format: .number
                                    ).lineLimit(1)
                                        .multilineTextAlignment(.trailing).keyboardType(.numberPad)
                                }
                                if model.passphrase != model.confirmation {
                                    Text(AppStrings.Keychain.passphrasesDoNotMatch).foregroundStyle(.red)
                                }
                            }
                        }
                    }
                } else if model.storage != .secureEnclave {
                    Section(AppStrings.Keychain.privateKey.swiftUIKey) {
                        storagePicker
                        if model.isLoadingPrivateKey {
                            ProgressView(AppStrings.Keychain.loadingPrivateKeyProgress.swiftUIKey)
                        } else {
                            if let error = model.privateKeyLoadError {
                                Label(error, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            Button(
                                model.mode == .edit
                                    ? AppStrings.Keychain.chooseReplacement.swiftUIKey
                                    : AppStrings.Keychain.chooseFile.swiftUIKey, systemImage: "folder"
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
                                    AppStrings.Keychain.replacePrivateKeyWarning.swiftUIKey,
                                    systemImage: "arrow.triangle.2.circlepath"
                                )
                                .font(.caption)
                                .foregroundStyle(.orange)
                            }
                            RevealableSecretField(AppStrings.Keychain.passphrase, text: $model.passphrase)
                                .multilineTextAlignment(.leading)
                                .disabled(!model.canEditPrivateKey)
                            Toggle(AppStrings.Keychain.savePassphrase.swiftUIKey, isOn: $model.savePassphrase)
                                .disabled(!model.canEditPrivateKey || model.passphrase.isEmpty)
                        }
                    }
                } else {
                    Section(AppStrings.Keychain.secureEnclave.swiftUIKey) {
                        LabeledContent(
                            AppStrings.Keychain.storeIn.swiftUIKey,
                            value: String(localized: AppStrings.Keychain.secureEnclave))
                    }
                }
                if model.mode != .generate && model.storage != .secureEnclave {
                    Section(AppStrings.Keychain.sshCertificate.swiftUIKey) {
                        Button(AppStrings.Keychain.chooseFile.swiftUIKey, systemImage: "folder") {
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
                    Section(AppStrings.Keychain.publicKey.swiftUIKey) {
                        Text(publicKey).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                if let fingerprint = model.fingerprint {
                    Section(AppStrings.KnownHosts.fingerprint.swiftUIKey) {
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
            AppStrings.Keychain.unableToReadFile,
            isPresented: Binding(get: { fileError != nil }, set: { if !$0 { fileError = nil } })
        ) {
            Button(AppStrings.Common.ok.swiftUIKey, role: .cancel) { fileError = nil }
        } message: {
            Text(fileError ?? "")
        }
        .onDisappear { model.clearSensitiveDrafts() }
        .task { await model.loadPrivateKey() }
        .task(id: model.validationToken) { await model.derivePublicMaterial() }
    }

    private var title: String {
        switch model.mode {
        case .generate: String(localized: AppStrings.Keychain.generateKey)
        case .importKey: String(localized: AppStrings.Keychain.importKey)
        case .edit: String(localized: AppStrings.Keychain.editKey)
        }
    }

    private var storagePicker: some View {
        Picker(AppStrings.Keychain.storeIn.swiftUIKey, selection: $model.storage) {
            Label(AppStrings.Keychain.thisDevice.swiftUIKey, systemImage: "ipad.and.iphone").tag(KeyStorage.thisDevice)
            Label(AppStrings.Keychain.iCloud.swiftUIKey, systemImage: "icloud.fill").tag(KeyStorage.iCloud)
            if model.mode == .generate && model.canUseEnclave {
                Label(AppStrings.Keychain.secureEnclave.swiftUIKey, systemImage: "checkmark.shield.fill").tag(
                    KeyStorage.secureEnclave)
            }
        }
        .disabled(!model.canEditPrivateKey || !model.canSelectThisDevice)
    }
}
