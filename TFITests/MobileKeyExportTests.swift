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
        #expect(editor.canSave && editor.savePassphrase)
        #expect(editor.privateKeyRequiresPassphrase && editor.passphrase.isEmpty)
        try await editor.save()
        #expect(!editor.savePassphrase)
        let key = try #require(library.keys.first)
        #expect(key.hasPassphrase && key.publicKey.isEmpty && key.fingerprint.isEmpty)
        #expect(key.algorithm == .unknown)
        #expect(library.requiresPassphraseEntry(for: key))
        let reopened = MobileKeyEditorModel(
            mode: .edit, credentials: CredentialLibraryModel(library: library), key: key)
        await reopened.loadPrivateKey()
        #expect(!reopened.savePassphrase && reopened.passphrase.isEmpty)
        let export = KeyExportModel(
            key: key, library: library, services: RemoteConnectionCoordinator().keyExportServices())
        #expect(export.needsExportPassphrase && export.authenticationPrompt == nil)
    }

    @Test func clearingASavedPassphraseTurnsSavingOffButKeepsTheKeyEncrypted() async throws {
        let library = HostLibraryModel()
        let credentials = CredentialLibraryModel(library: library)
        let generator = MobileKeyEditorModel(mode: .generate, credentials: credentials)
        generator.passphrase = "secret"
        generator.confirmation = "secret"
        try await generator.save()
        let original = try #require(library.keys.first)
        let editor = MobileKeyEditorModel(mode: .edit, credentials: credentials, key: original)
        await editor.loadPrivateKey()
        #expect(editor.savePassphrase && editor.passphrase == "secret")
        editor.passphrase = ""
        try await editor.save()
        let saved = try #require(library.key(original.id))
        #expect(saved.hasPassphrase && !editor.savePassphrase)
        #expect(!credentials.hasSavedPassphrase(for: saved))
        #expect(library.requiresPassphraseEntry(for: saved))
        let reopened = MobileKeyEditorModel(mode: .edit, credentials: credentials, key: saved)
        await reopened.loadPrivateKey()
        #expect(!reopened.savePassphrase && reopened.passphrase.isEmpty)
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

    @Test(arguments: [false, true])
    func passphraseControlsFollowPrivateKeyEncryptionWhileReplacingKeys(editExisting: Bool) async throws {
        let fixture = try MobileExportFixture(encrypted: true)
        let credentials = CredentialLibraryModel(library: fixture.library)
        let editor = MobileKeyEditorModel(
            mode: editExisting ? .edit : .importKey, credentials: credentials,
            key: editExisting ? fixture.key : nil)
        let encrypted = try #require(try credentials.keyCredential(for: fixture.key))
        guard case .software(let secret) = encrypted else {
            Issue.record("Expected software key")
            return
        }
        if editExisting {
            await editor.loadPrivateKey()
        } else {
            #expect(!editor.privateKeyRequiresPassphrase)
            editor.privateKey = secret.privateKey
        }
        #expect(editor.privateKeyRequiresPassphrase && editor.passphrase.isEmpty)
        let unencrypted = try SSHKeyMaterial.generate(.ed25519, comment: "", passphrase: nil)
        editor.privateKey = unencrypted.privateKey
        #expect(!editor.privateKeyRequiresPassphrase)
        editor.privateKey = secret.privateKey
        editor.publicKey = "invalid public key"
        #expect(editor.privateKeyRequiresPassphrase)
        editor.privateKey = "-----BEGIN OPENSSH PRIVATE KEY-----"
        #expect(!editor.privateKeyRequiresPassphrase)
        editor.privateKey = ""
        #expect(!editor.privateKeyRequiresPassphrase)
    }

    @Test func replacingEncryptedPrivateKeyDoesNotSaveHiddenPassphrase() async throws {
        let library = HostLibraryModel()
        let credentials = CredentialLibraryModel(library: library)
        let encrypted = try SSHKeyMaterial.generate(.ed25519, comment: "", passphrase: "secret")
        let material = try SSHKeyMaterial.generate(.ed25519, comment: "", passphrase: nil)
        let editor = MobileKeyEditorModel(mode: .importKey, credentials: credentials)
        editor.privateKey = encrypted.privateKey
        editor.passphrase = "secret"
        editor.privateKey = material.privateKey
        #expect(!editor.privateKeyRequiresPassphrase)
        try await editor.save()
        let key = try #require(library.keys.first)
        #expect(!key.hasPassphrase && !editor.savePassphrase)
        #expect(!credentials.hasSavedPassphrase(for: key))
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
