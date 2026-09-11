import Foundation
import Observation
import TermindApplication
import TermindDomain
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
    var algorithm: Algorithm = .ed25519
    var colorTag = TagColor.none
    var curveBits = 256
    var rsaBits = 3072
    var cipher = SSHKeyMaterial.Cipher.aes256
    var rounds = 100
    var confirmation = ""
    var privateKey = ""
    var passphrase = ""
    var certificate: String
    var requiresUserPresence = false

    init(mode: Mode, credentials: CredentialLibraryModel, key: SSHKeyRef? = nil) {
        self.mode = mode
        self.credentials = credentials
        original = key
        label = key?.label ?? ""
        storage = key?.storage ?? .iCloud
        certificate = key?.certificate ?? ""
        colorTag = key?.colorTag ?? .none
    }

    var isDirty: Bool {
        label != (original?.label ?? "") || storage != (original?.storage ?? .iCloud)
            || certificate != (original?.certificate ?? "") || !privateKey.isEmpty || !passphrase.isEmpty
            || algorithm != .ed25519 || requiresUserPresence || colorTag != (original?.colorTag ?? .none)
            || curveBits != 256 || rsaBits != 3072 || cipher != .aes256 || rounds != 100 || !confirmation.isEmpty
    }
    var canSave: Bool {
        let nameIsValid = mode == .generate || !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let encryptionIsValid =
            mode != .generate || storage == .secureEnclave || passphrase.isEmpty
            || (passphrase == confirmation && rounds > 0)
        return nameIsValid && encryptionIsValid && (mode != .importKey || !privateKey.isEmpty)
            && (storage != .secureEnclave || canUseEnclave)
    }
    var defaultName: String { storage == .secureEnclave ? "Secure Enclave" : algorithm.rawValue }
    var resolvedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultName : label.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var certificateWarning: String? {
        guard !certificate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do { return try SSHUserCertificate.parse(certificate, matching: original?.publicKey).validityWarning } catch {
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
    var publicKey: String? { original?.publicKey }
    var fingerprint: String? { original?.fingerprint }
    var isEnclave: Bool { original?.storage == .secureEnclave }
    var canUseEnclave: Bool { SecureEnclaveKey.isAvailable }

    func loadFile(_ url: URL) async throws {
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
        _ = try SSHUserCertificate.parse(certificate, matching: original?.publicKey)
        self.certificate = certificate
    }

    func save() async throws {
        guard canSave else { throw CocoaError(.coderInvalidValue) }
        if var key = original {
            key.label = resolvedLabel
            key.colorTag = colorTag
            key.storage = storage
            key.certificate = certificate.trimmingCharacters(in: .whitespacesAndNewlines)
            try credentials.upsert(key)
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
                label: resolvedLabel, algorithm: .ecdsa256, publicKey: material.publicKey,
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
            let material = try await Task.detached(priority: .userInitiated) {
                if generates {
                    return try SSHKeyMaterial.generate(
                        generation, comment: comment, passphrase: passphrase, cipher: cipher, rounds: rounds)
                }
                return try SSHKeyMaterial.inspect(privateKey: input, passphrase: passphrase, comment: comment)
            }.value
            try Task.checkCancellation()
            key = SSHKeyRef(
                label: resolvedLabel, algorithm: material.algorithm, publicKey: material.publicKey,
                certificate: certificate, fingerprint: material.fingerprint, credentialRef: "termind.key.\(UUID())",
                storage: storage, keySize: material.keySize, hasPassphrase: passphrase != nil, createdAt: .now,
                colorTag: colorTag)
            secret = .software(SSHPrivateKeySecret(privateKey: material.privateKey))
        }
        try credentials.upsert(key, credential: secret)
        privateKey = ""
        passphrase = ""
        confirmation = ""
    }
}
