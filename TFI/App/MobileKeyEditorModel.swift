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
        case ecdsa = "ECDSA P-256"
        case rsa = "RSA 4096"
        var id: Self { self }
        var generation: SSHKeyMaterial.Generation {
            switch self {
            case .ed25519: .ed25519
            case .ecdsa: .ecdsa(bits: 256)
            case .rsa: .rsa(bits: 4096)
            }
        }
    }
    let id = UUID()
    let mode: Mode
    private let original: SSHKeyRef?
    private let credentials: CredentialLibraryModel
    var label: String
    var storage: KeyStorage
    var algorithm: Algorithm = .ed25519
    var privateKey = ""
    var passphrase = ""
    var certificate: String
    var requiresUserPresence = false

    init(mode: Mode, credentials: CredentialLibraryModel, key: SSHKeyRef? = nil) {
        self.mode = mode
        self.credentials = credentials
        original = key
        label = key?.label ?? ""
        storage = key?.storage ?? .thisDevice
        certificate = key?.certificate ?? ""
    }

    var isDirty: Bool {
        label != (original?.label ?? "") || storage != (original?.storage ?? .thisDevice)
            || certificate != (original?.certificate ?? "") || !privateKey.isEmpty || !passphrase.isEmpty
            || algorithm != .ed25519 || requiresUserPresence
    }
    var canSave: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (mode != .importKey || !privateKey.isEmpty)
    }
    var publicKey: String? { original?.publicKey }
    var fingerprint: String? { original?.fingerprint }
    var isEnclave: Bool { original?.storage == .secureEnclave }
    var canUseEnclave: Bool { SecureEnclaveKey.isAvailable }

    func loadFile(_ url: URL) async throws {
        let text = try await Task.detached {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= 8 * 1024 * 1024 else {
                throw CocoaError(.fileReadTooLarge)
            }
            return try String(contentsOf: url, encoding: .utf8)
        }.value
        try Task.checkCancellation()
        privateKey = text
        if label.isEmpty { label = url.deletingPathExtension().lastPathComponent }
    }

    func save() async throws {
        guard canSave else { throw CocoaError(.coderInvalidValue) }
        if var key = original {
            key.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
            key.storage = storage
            key.certificate = certificate
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
                label: label, algorithm: .ecdsa256, publicKey: material.publicKey,
                fingerprint: material.fingerprint, credentialRef: "termind.key.\(UUID())", storage: .secureEnclave,
                keySize: 256, requiresUserPresence: presence, createdAt: .now)
            secret = .secureEnclave(material.credential)
        } else {
            let input = privateKey
            let passphrase = passphrase.isEmpty ? nil : passphrase
            let generation = algorithm.generation
            let generates = mode == .generate
            let material = try await Task.detached(priority: .userInitiated) {
                if generates {
                    return try SSHKeyMaterial.generate(generation, comment: comment, passphrase: passphrase)
                }
                return try SSHKeyMaterial.inspect(privateKey: input, passphrase: passphrase, comment: comment)
            }.value
            try Task.checkCancellation()
            key = SSHKeyRef(
                label: label, algorithm: material.algorithm, publicKey: material.publicKey,
                certificate: certificate, fingerprint: material.fingerprint, credentialRef: "termind.key.\(UUID())",
                storage: storage, keySize: material.keySize, hasPassphrase: passphrase != nil, createdAt: .now)
            secret = .software(SSHPrivateKeySecret(privateKey: material.privateKey))
        }
        try credentials.upsert(key, credential: secret)
        privateKey = ""
        passphrase = ""
    }
}
