import Foundation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobileKeyExportTests {
    @Test func encryptedImportCanSaveWithoutPassphraseOrPublicKey() async throws {
        let library = HostLibraryModel()
        let material = try SSHKeyMaterial.generate(.ed25519, comment: "", passphrase: "secret")
        let editor = MobileKeyEditorModel(mode: .importKey, credentials: CredentialLibraryModel(library: library))
        editor.privateKey = material.privateKey
        #expect(editor.canSave)
        try await editor.save()
        let key = try #require(library.keys.first)
        #expect(key.hasPassphrase && key.publicKey.isEmpty && key.fingerprint.isEmpty)
        #expect(key.algorithm == .unknown)
        #expect(library.requiresPassphraseEntry(for: key))
        let export = KeyExportModel(
            key: key, library: library, services: RemoteConnectionCoordinator().keyExportServices())
        #expect(export.needsExportPassphrase && export.authenticationPrompt == nil)
    }

    @Test func manuallyEnteredPublicKeyCanBeChangedAndClearedWithoutUnlocking() async throws {
        let library = HostLibraryModel()
        let credentials = CredentialLibraryModel(library: library)
        let material = try SSHKeyMaterial.generate(.ed25519, comment: "", passphrase: "secret")
        let importer = MobileKeyEditorModel(mode: .importKey, credentials: credentials)
        importer.privateKey = material.privateKey
        importer.publicKey = material.publicKey
        try await importer.save()
        let original = try #require(library.keys.first)
        #expect(original.publicKey == material.publicKey && original.fingerprint == material.fingerprint)
        let export = KeyExportModel(
            key: original, library: library, services: RemoteConnectionCoordinator().keyExportServices())
        #expect(!export.needsExportPassphrase)
        let editor = MobileKeyEditorModel(mode: .edit, credentials: credentials, key: original)
        await editor.loadPrivateKey()
        editor.publicKey = "malformed"
        await #expect(throws: (any Error).self) { try await editor.save() }
        #expect(library.key(original.id) == original)
        editor.publicKey = ""
        try await editor.save()
        let cleared = try #require(library.key(original.id))
        #expect(cleared.publicKey.isEmpty && cleared.fingerprint.isEmpty && cleared.hasPassphrase)
    }

    @Test func typedPassphraseDoesNotMakeAnUnencryptedKeyEncrypted() async throws {
        let library = HostLibraryModel()
        let material = try SSHKeyMaterial.generate(.ed25519, comment: "", passphrase: nil)
        let editor = MobileKeyEditorModel(mode: .importKey, credentials: CredentialLibraryModel(library: library))
        editor.privateKey = material.privateKey
        editor.passphrase = "not-encryption"
        try await editor.save()
        #expect(library.keys.first?.hasPassphrase == false)
    }

    @Test func replacingPrivateKeyPreservesANewManuallyEnteredPublicKey() async throws {
        let library = HostLibraryModel()
        let credentials = CredentialLibraryModel(library: library)
        let generator = MobileKeyEditorModel(mode: .generate, credentials: credentials)
        try await generator.save()
        let original = try #require(library.keys.first)
        let replacement = try SSHKeyMaterial.generate(.ed25519, comment: "replacement", passphrase: "secret")
        let editor = MobileKeyEditorModel(mode: .edit, credentials: credentials, key: original)
        await editor.loadPrivateKey()
        editor.publicKey = replacement.publicKey
        editor.privateKey = replacement.privateKey
        #expect(editor.publicKey == replacement.publicKey)
        try await editor.save()
        let saved = try #require(library.key(original.id))
        #expect(saved.publicKey == replacement.publicKey && saved.fingerprint == replacement.fingerprint)
        #expect(saved.hasPassphrase && library.requiresPassphraseEntry(for: saved))
    }
}

@MainActor
struct MobileExportFixture {
    let key: SSHKeyRef
    let library: HostLibraryModel
    let host: TermindDomain.Host
    init(encrypted: Bool = false) throws {
        let material = try SSHKeyMaterial.generate(.ed25519, comment: "", passphrase: encrypted ? "secret" : nil)
        key = SSHKeyRef(
            label: "Deployment Key", algorithm: encrypted ? .unknown : material.algorithm,
            publicKey: encrypted ? "" : material.publicKey,
            credentialRef: "key", hasPassphrase: encrypted)
        let identity = Identity(name: "Deploy", username: "deploy")
        host = TermindDomain.Host(name: "Production", host: "server.example.com", identityID: identity.id)
        library = HostLibraryModel(hosts: [host], keys: [key], identities: [identity])
        try library.upsert(key, credential: .software(SSHPrivateKeySecret(privateKey: material.privateKey)))
    }
    func model() -> KeyExportModel {
        KeyExportModel(key: key, library: library, services: RemoteConnectionCoordinator().keyExportServices())
    }
}
