import Foundation
import Observation
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure

@MainActor
@Observable
final class MobileKeyEditorModel: Identifiable {
    enum Mode { case generate, importKey, edit }
    enum Algorithm: String, CaseIterable, Identifiable {
        case ed25519 = "Ed25519"
        case ecdsa = "ECDSA"
        case rsa = "RSA"
        var id: Self { self }

    }
    let id = UUID()
    let mode: Mode
    private let original: SSHKeyRef?
    private let credentials: CredentialLibraryModel
    var label: String
    var storage: KeyStorage
    var usesWebAuthn = false
    var verification: SecurityKeyCredential.UserVerification = .preferred
    var securityKeyReference = "" {
        didSet {
            if let credential = try? WebAuthnSSH.importReference(securityKeyReference) {
                verification = credential.userVerification
            }
        }
    }
    var algorithm: Algorithm = .ed25519
    var colorTag = TagColor.none
    var curveBits = 256
    var rsaBits = 3072
    var cipher = SSHKeyMaterial.Cipher.aes256
    var rounds = 100
    var confirmation = ""
    var privateKey = "" {
        didSet {
            if canEditPrivateKey, !isLoadingPrivateKey, !originalPrivateKey.isEmpty,
                privateKey != originalPrivateKey, publicKey == original?.publicKey
            {
                publicKey = ""
            }
            if privateKey != originalPrivateKey, oldValue == originalPrivateKey, !originalPassphrase.isEmpty {
                passphrase = ""
            }
        }
    }
    var publicKey: String
    var passphrase = ""
    var savePassphrase = true
    private var originalPassphrase = ""
    private var originalSavePassphrase = true
    var certificate: String
    var requiresUserPresence = false
    private(set) var isLoadingPrivateKey: Bool
    private(set) var privateKeyLoadError: String?
    private(set) var inspectedMaterial: SSHKeyMaterial?
    private(set) var canEditPrivateKey: Bool
    private var originalPrivateKey = ""
    private var didLoadPrivateKey: Bool

    init(
        mode: Mode,
        credentials: CredentialLibraryModel,
        key: SSHKeyRef? = nil,
        defaultStorage: KeyStorage = .iCloud
    ) {
        self.mode = mode
        self.credentials = credentials
        original = key
        savePassphrase = mode != .edit
        originalSavePassphrase = mode != .edit
        label = key?.label ?? ""
        storage = key?.storage ?? defaultStorage
        certificate = key?.certificate ?? ""
        publicKey = key?.publicKey ?? ""
        colorTag = key?.colorTag ?? .none
        let availability = key.map { credentials.keyAvailability(for: $0) }
        let keyIsAvailable = availability == .some(.available)
        let editsPrivateKey =
            mode != .edit
            || (key?.storage != .secureEnclave && keyIsAvailable)
        canEditPrivateKey = editsPrivateKey
        let loadsPrivateKey = mode == .edit && editsPrivateKey
        isLoadingPrivateKey = loadsPrivateKey
        didLoadPrivateKey = !loadsPrivateKey
        if mode == .edit, key?.storage != .secureEnclave, !keyIsAvailable {
            switch availability {
            case .some(.failed(let message)):
                privateKeyLoadError = message
            case .some(.missing), .some(.notConfigured), .none:
                privateKeyLoadError = String(localized: AppStrings.Keychain.thePrivateKeyIsUnavailableOnThisDevice)
            case .some(.available):
                break
            }
        }
    }

    var isDirty: Bool {
        usesWebAuthn || !securityKeyReference.isEmpty || verification != .preferred || label != (original?.label ?? "")
            || storage != (original?.storage ?? .iCloud)
            || publicKey != (original?.publicKey ?? "") || certificate != (original?.certificate ?? "")
            || privateKey != originalPrivateKey
            || passphrase != originalPassphrase
            || savePassphrase != originalSavePassphrase
            || algorithm != .ed25519 || requiresUserPresence || colorTag != (original?.colorTag ?? .none)
            || curveBits != 256 || rsaBits != 3072 || cipher != .aes256 || rounds != 100 || !confirmation.isEmpty
    }
    var canSave: Bool {
        if usesWebAuthn {
            return mode == .generate
                || (mode == .importKey && !securityKeyReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if mode == .edit, let original, original.storage != .secureEnclave, !canEditPrivateKey {
            return !isLoadingPrivateKey && storage == original.storage && privateKey.isEmpty && passphrase.isEmpty
        }
        let encryptionIsValid =
            mode != .generate || storage == .secureEnclave || passphrase.isEmpty
            || (passphrase == confirmation && rounds > 0)
        let privateKeyIsValid =
            mode == .generate || storage == .secureEnclave
            || (!privateKey.isEmpty && (mode != .edit || didLoadPrivateKey))
        return encryptionIsValid && privateKeyIsValid && !isLoadingPrivateKey
            && (storage != .secureEnclave || isEnclave || canUseEnclave)
            && (storage != .thisDevice || canSelectThisDevice)
    }
    var defaultName: String {
        if usesWebAuthn { return String(localized: AppStrings.SecurityKey.title) }
        let selectedAlgorithm: SSHKeyAlgorithm =
            switch algorithm {
            case .ed25519: .ed25519
            case .ecdsa: .ecdsa256
            case .rsa: .rsa
            }
        if mode == .generate || storage == .secureEnclave {
            return SSHKeyRef.defaultName(algorithm: selectedAlgorithm, storage: storage)
        }
        let algorithm =
            inspectedMaterial?.privateKey == privateKey
            ? inspectedMaterial?.algorithm : privateKey == originalPrivateKey ? original?.algorithm : nil
        guard let algorithm else { return "" }
        return SSHKeyRef.defaultName(algorithm: algorithm, storage: storage)
    }
    var resolvedLabel: String {
        SavedName.resolve(label.trimmingCharacters(in: .whitespacesAndNewlines), default: defaultName)
    }
    var certificateWarning: String? {
        guard !certificate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            return try SSHUserCertificate.parse(
                certificate, matching: publicKey.isEmpty ? nil : publicKey
            ).validityWarning
        } catch {
            return error.localizedDescription
        }
    }
    private var generation: SSHKeyMaterial.Generation {
        switch algorithm {
        case .ed25519: .ed25519
        case .ecdsa: .ecdsa(bits: curveBits)
        case .rsa: .rsa(bits: rsaBits)
        }
    }
    var fingerprint: String? { (try? SSHKeyMaterial.publicMaterial(publicKey))?.fingerprint }
    var isEnclave: Bool { original?.storage == .secureEnclave }
    var canSelectThisDevice: Bool { original?.storage != .iCloud }
    var canUseEnclave: Bool { SecureEnclaveKey.isAvailable }
    var replacesPublicKey: Bool {
        guard let original, let inspectedMaterial else { return false }
        return inspectedMaterial.publicKey != original.publicKey
    }
    var validationToken: String { privateKey + "\u{0}" + publicKey }

    func loadPrivateKey() async {
        guard mode == .edit, let original, original.storage != .secureEnclave, !didLoadPrivateKey else { return }
        isLoadingPrivateKey = true
        privateKeyLoadError = nil
        defer { isLoadingPrivateKey = false }
        do {
            guard case .software(let secret)? = try credentials.keyCredential(for: original) else {
                throw TermindSSHError.library(
                    String(localized: AppStrings.Keychain.thePrivateKeyIsUnavailableOnThisDevice)
                )
            }
            privateKey = secret.privateKey
            originalPrivateKey = secret.privateKey
            passphrase = secret.passphrase ?? ""
            originalPassphrase = passphrase
            savePassphrase = !passphrase.isEmpty
            originalSavePassphrase = savePassphrase
            didLoadPrivateKey = true
        } catch {
            privateKeyLoadError = error.localizedDescription
            canEditPrivateKey = false
            privateKey = ""
            originalPrivateKey = ""
        }
    }

    func refreshPublicMaterial() async {
        guard storage != .secureEnclave, !privateKey.isEmpty else {
            inspectedMaterial = nil
            return
        }
        inspectedMaterial = try? SSHKeyMaterial.imported(privateKey: privateKey, publicKey: publicKey)
    }

    func loadFile(_ url: URL) async throws {
        guard canEditPrivateKey else { throw CocoaError(.fileReadNoPermission) }
        if usesWebAuthn {
            securityKeyReference = try WebAuthnSSH.readReferenceFile(url)
            return
        }
        let infersName = SoftwareKeyFileImporter.shouldInferName(from: label)
        let result = try await Task.detached { try SoftwareKeyFileImporter.read(urls: [url], infersName: infersName) }
            .value
        try Task.checkCancellation()
        guard let key = result.privateKey else { throw SoftwareKeyFileImporter.unexpectedFileError() }
        privateKey = key
        if let name = result.inferredName { label = name }
    }

    func loadCertificateFile(_ url: URL) async throws {
        let result = try await Task.detached { try SoftwareKeyFileImporter.read(urls: [url], infersName: false) }.value
        try Task.checkCancellation()
        guard let certificate = result.certificate else { throw SoftwareKeyFileImporter.unexpectedFileError() }
        _ = try SSHUserCertificate.parse(
            certificate, matching: publicKey.isEmpty ? nil : publicKey)
        self.certificate = certificate
    }

    func save(
        registerSecurityKey: ((String, SecurityKeyCredential.UserVerification) async throws -> SecurityKeyCredential)? =
            nil
    ) async throws {
        guard canSave else { throw CocoaError(.coderInvalidValue) }
        if usesWebAuthn {
            var credential: SecurityKeyCredential
            if mode == .generate, let registerSecurityKey {
                credential = try await registerSecurityKey(resolvedLabel, verification)
            } else if mode == .importKey {
                credential = try WebAuthnSSH.importReference(securityKeyReference)
            } else {
                throw CocoaError(.coderInvalidValue)
            }
            credential.userVerification = verification
            try WebAuthnSSH.validate(credential)
            try Task.checkCancellation()
            var key = try WebAuthnSSH.keyReference(
                credential, label: label)
            key.colorTag = colorTag
            key.securityKey = credential
            try credentials.upsert(key)
            clearSensitiveDrafts()
            return
        }
        if var key = original {
            if key.storage == .secureEnclave {
                key.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
                key.colorTag = colorTag
                try credentials.upsert(key)
                return
            }
            if !canEditPrivateKey {
                key.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
                key.colorTag = colorTag
                if publicKey != key.publicKey {
                    let material = publicKey.isEmpty ? nil : try SSHKeyMaterial.publicMaterial(publicKey)
                    key.publicKey = material?.publicKey ?? ""
                    key.fingerprint = material?.fingerprint ?? ""
                    key.algorithm = material?.algorithm ?? key.algorithm
                    key.keySize = material?.keySize ?? key.keySize
                }
                key.certificate = certificate.trimmingCharacters(in: .whitespacesAndNewlines)
                try credentials.upsert(key)
                return
            }
            let input = privateKey
            let enteredPassphrase = passphrase.isEmpty ? nil : passphrase
            let material = try SSHKeyMaterial.imported(privateKey: input, publicKey: publicKey)
            let normalizedCertificate = certificate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedCertificate.isEmpty {
                _ = try SSHUserCertificate.parse(
                    normalizedCertificate, matching: material.publicKey.isEmpty ? nil : material.publicKey)
            }
            key.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
            key.colorTag = colorTag
            key.storage = storage
            key.algorithm = material.algorithm
            key.publicKey = material.publicKey
            key.certificate = normalizedCertificate
            key.fingerprint = material.fingerprint
            key.keySize = material.keySize
            key.hasPassphrase = try SSHKeyMaterial.privateKeyMetadata(input).isEncrypted
            try credentials.upsert(
                key,
                credential: .software(
                    SSHPrivateKeySecret(privateKey: input, passphrase: savePassphrase ? enteredPassphrase : nil))
            )
            clearSensitiveDrafts()
            return
        }
        let comment = "termind"
        let key: SSHKeyRef
        let secret: StoredSSHKeyCredential
        if storage == .secureEnclave {
            let presence = requiresUserPresence
            let material = try await Task.detached(priority: .userInitiated) {
                try SecureEnclaveKey.generate(comment: comment, requiresUserPresence: presence)
            }.value
            try Task.checkCancellation()
            key = SSHKeyRef(
                label: label.trimmingCharacters(in: .whitespacesAndNewlines), algorithm: .ecdsa256,
                publicKey: material.publicKey,
                fingerprint: material.fingerprint, credentialRef: "termind.key.\(UUID())", storage: .secureEnclave,
                keySize: 256, requiresUserPresence: presence, createdAt: .now, colorTag: colorTag)
            secret = .secureEnclave(material.credential)
        } else {
            let input = privateKey
            let passphrase = passphrase.isEmpty ? nil : passphrase
            let generation = generation
            let cipher = cipher
            let rounds = rounds
            let generates = mode == .generate
            let publicKey = publicKey
            let material = try await Task.detached(priority: .userInitiated) {
                if generates {
                    return try SSHKeyMaterial.generate(
                        generation, comment: comment, passphrase: passphrase, cipher: cipher, rounds: rounds)
                }
                return try SSHKeyMaterial.imported(privateKey: input, publicKey: publicKey)
            }.value
            try Task.checkCancellation()
            let normalizedCertificate = certificate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedCertificate.isEmpty {
                _ = try SSHUserCertificate.parse(
                    normalizedCertificate, matching: material.publicKey.isEmpty ? nil : material.publicKey)
            }
            key = SSHKeyRef(
                label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                algorithm: material.algorithm, publicKey: material.publicKey,
                certificate: normalizedCertificate, fingerprint: material.fingerprint,
                credentialRef: "termind.key.\(UUID())", storage: storage, keySize: material.keySize,
                hasPassphrase: try SSHKeyMaterial.privateKeyMetadata(material.privateKey).isEncrypted, createdAt: .now,
                colorTag: colorTag)
            secret = .software(
                SSHPrivateKeySecret(privateKey: material.privateKey, passphrase: savePassphrase ? passphrase : nil))
        }
        try credentials.upsert(key, credential: secret)
        clearSensitiveDrafts()
    }

    func clearSensitiveDrafts() {
        securityKeyReference = ""
        didLoadPrivateKey = mode != .edit
        privateKey = ""
        originalPrivateKey = ""
        passphrase = ""
        confirmation = ""
        originalPassphrase = ""
        inspectedMaterial = nil
    }
}
