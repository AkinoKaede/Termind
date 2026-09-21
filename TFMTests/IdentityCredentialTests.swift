import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind

@Suite(.serialized)
@MainActor
struct IdentityCredentialTests {
    @Test
    func passwordUpdatesKeepReplaceAndRemoveTheKeychainItem() throws {
        let keychain = InMemorySecretStore()
        let reference = "termind.password.\(UUID().uuidString)"
        let id = UUID()
        let keyID = UUID()
        let original = Identity(
            id: id, name: "Deploy", username: "deploy",
            credentialRef: reference, passwordStorage: .thisDevice, keyID: keyID
        )
        let store = HostLibraryModel(identities: [original], secrets: keychain)
        defer { try? keychain.removePassword(reference, storage: .thisDevice) }

        try keychain.setString("old", for: reference, storage: .thisDevice)

        var renamed = original
        renamed.name = "Production"
        try store.upsert(renamed, passwordUpdate: .keep)
        #expect(store.identity(id)?.credentialRef == reference)
        #expect(try keychain.string(for: reference, storage: .thisDevice) == "old")

        try store.upsert(renamed, passwordUpdate: .replace("new"))
        #expect(store.identity(id)?.credentialRef == reference)
        #expect(try keychain.string(for: reference, storage: .thisDevice) == "new")

        try store.upsert(renamed, passwordUpdate: .remove)
        #expect(store.identity(id)?.credentialRef == "")
        #expect(store.identity(id)?.keyID == keyID)
        #expect(try keychain.string(for: reference, storage: .thisDevice) == nil)
    }

    @Test
    func addingAPasswordMintsAReference() throws {
        let keychain = InMemorySecretStore()
        let identity = Identity(name: "Deploy", username: "deploy")
        let store = HostLibraryModel(secrets: keychain)

        try store.upsert(identity, passwordUpdate: .replace("secret"))
        let saved = try #require(store.identity(identity.id))
        defer {
            try? keychain.removePassword(
                saved.credentialRef, storage: saved.passwordStorage
            )
        }

        #expect(!saved.credentialRef.isEmpty)
        #expect(
            try keychain.string(
                for: saved.credentialRef, storage: saved.passwordStorage
            ) == "secret"
        )
    }

    @Test
    func missingPasswordAllowsMetadataOnlyEditWithoutChangingItsReference() throws {
        let reference = "termind.password.\(UUID().uuidString)"
        let identity = Identity(
            name: "Remote", username: "deploy", credentialRef: reference,
            passwordStorage: .thisDevice)
        let store = HostLibraryModel(identities: [identity], secrets: InMemorySecretStore())

        var renamed = identity
        renamed.name = "Renamed Remote"
        renamed.colorTag = .orange
        try store.upsert(renamed, passwordUpdate: .keep)

        let updated = try #require(store.identity(identity.id))
        #expect(updated.name == "Renamed Remote")
        #expect(updated.colorTag == .orange)
        #expect(updated.credentialRef == reference)
        #expect(store.passwordAvailability(for: updated) == .missing)
    }

    @Test
    func iCloudPasswordCannotMoveToThisDevice() throws {
        let keychain = InMemorySecretStore()
        let reference = "termind.password.\(UUID().uuidString)"
        let original = Identity(
            name: "Deploy", username: "deploy", credentialRef: reference,
            passwordStorage: .iCloud
        )
        let store = HostLibraryModel(identities: [original], secrets: keychain)
        try keychain.setString("secret", for: reference, storage: .iCloud)

        var moved = original
        moved.passwordStorage = .thisDevice
        #expect(throws: (any Error).self) {
            try store.upsert(moved, passwordUpdate: .keep)
        }
        #expect(!store.upsert(moved))

        #expect(store.identity(original.id)?.passwordStorage == .iCloud)
        #expect(try keychain.string(for: reference, storage: .iCloud) == "secret")
    }

    @Test
    func iCloudKeyCannotMoveToThisDevice() throws {
        let keychain = InMemorySecretStore()
        let reference = "termind.key.\(UUID().uuidString)"
        let original = SSHKeyRef(
            label: "Deploy", publicKey: "ssh-ed25519 test", fingerprint: "SHA256:test",
            credentialRef: reference, storage: .iCloud
        )
        let secret = StoredSSHKeyCredential.software(
            SSHPrivateKeySecret(privateKey: "private")
        )
        let store = HostLibraryModel(keys: [original], secrets: keychain)
        try keychain.setKeyCredential(secret, for: reference, storage: .iCloud)

        var moved = original
        moved.storage = .thisDevice
        #expect(throws: (any Error).self) {
            try store.upsert(moved)
        }

        #expect(store.key(original.id)?.storage == .iCloud)
        #expect(try keychain.keyCredential(for: reference, storage: .iCloud) == secret)
    }

    @Test
    func missingKeyDoesNotSuppressAnAvailablePassword() throws {
        let keychain = InMemorySecretStore()
        let passwordReference = "termind.password.\(UUID().uuidString)"
        let missingKeyReference = "termind.key.\(UUID().uuidString)"
        defer {
            try? keychain.removePassword(passwordReference, storage: .thisDevice)
            try? keychain.removeKeyCredential(missingKeyReference, storage: .thisDevice)
        }

        let key = SSHKeyRef(
            label: "Missing", algorithm: .ed25519, publicKey: "",
            fingerprint: "", credentialRef: missingKeyReference
        )
        let identity = Identity(
            name: "Deploy", username: "deploy",
            credentialRef: passwordReference, passwordStorage: .thisDevice,
            keyID: key.id
        )
        try keychain.setString("fallback", for: passwordReference, storage: .thisDevice)
        let store = HostLibraryModel(keys: [key], identities: [identity], secrets: keychain)

        let resolution = store.sshCredentials(for: identity)
        #expect(resolution.hasConfiguredCredential)
        #expect(resolution.failures.count == 1)
        #expect(resolution.credentials.count == 1)
        guard case .password(let password) = resolution.credentials.first else {
            Issue.record("Expected the available password credential")
            return
        }
        #expect(password == "fallback")
    }

    @Test
    func encryptedKeyPersistsOnlyPrivateMaterialAndRequiresPassphraseAtUse() throws {
        let keychain = InMemorySecretStore()
        let reference = "termind.key.\(UUID().uuidString)"
        defer { try? keychain.removeKeyCredential(reference, storage: .thisDevice) }
        let material = try SSHKeyMaterial.generate(
            .ed25519, comment: "termind-tests", passphrase: "one-use", rounds: 100
        )

        let key = SSHKeyRef(
            label: "Protected", algorithm: .ed25519, publicKey: material.publicKey,
            fingerprint: material.fingerprint, credentialRef: reference,
            storage: .thisDevice, hasPassphrase: true
        )
        let identity = Identity(name: "Deploy", username: "deploy", keyID: key.id)
        let store = HostLibraryModel(identities: [identity], secrets: keychain)

        try store.upsert(
            key,
            credential: .software(SSHPrivateKeySecret(privateKey: material.privateKey))
        )

        guard
            case .software(let stored)? = try keychain.keyCredential(
                for: reference, storage: .thisDevice
            )
        else {
            Issue.record("Expected the encrypted private-key material")
            return
        }
        #expect(stored.privateKey == material.privateKey)
        #expect(store.key(key.id)?.requiresPassphraseEntry == true)
        #expect(store.sshCredentials(for: identity).requiredPassphraseKeyID == key.id)
    }

    @Test
    func protectedKeyWithoutSavedPassphraseRequestsItBeforeUse() throws {
        let keychain = InMemorySecretStore()
        let reference = "termind.key.\(UUID().uuidString)"
        defer { try? keychain.removeKeyCredential(reference, storage: .thisDevice) }

        let key = SSHKeyRef(
            label: "Protected", algorithm: .ed25519, publicKey: "ssh-ed25519 test",
            fingerprint: "SHA256:test", credentialRef: reference,
            storage: .thisDevice,
            hasPassphrase: true
        )
        let identity = Identity(name: "Deploy", username: "deploy", keyID: key.id)
        let store = HostLibraryModel(keys: [key], identities: [identity], secrets: keychain)
        try keychain.setKeyCredential(
            .software(SSHPrivateKeySecret(privateKey: "encrypted")),
            for: reference, storage: .thisDevice
        )

        let resolution = store.sshCredentials(for: identity)
        #expect(resolution.requiredPassphraseKeyID == key.id)
        #expect(resolution.credentials.isEmpty)
        #expect(resolution.hasConfiguredCredential)
    }

    @Test(arguments: SSHKeyMaterial.Cipher.allCases)
    func generatedKeyCanBeReadWithEveryCipher(_ cipher: SSHKeyMaterial.Cipher) throws {
        let material = try SSHKeyMaterial.generate(
            .ed25519, comment: "termind-tests", passphrase: "secret",
            cipher: cipher, rounds: 100
        )

        #expect(material.privateKey.contains("BEGIN ENCRYPTED PRIVATE KEY"))
        let inspected = try SSHKeyMaterial.inspect(
            privateKey: material.privateKey, passphrase: "secret"
        )
        #expect(inspected.fingerprint == material.fingerprint)
    }

    @Test
    func generatedKeyRejectsNonPositiveRounds() {
        #expect(throws: (any Error).self) {
            try SSHKeyMaterial.generate(
                .ed25519, comment: "termind-tests", passphrase: "secret",
                rounds: 0
            )
        }
    }

    @Test
    func onlyAuthenticationErrorsRequestAnotherCredential() {
        #expect(TermindSSHError.authenticationFailed("Rejected").shouldRequestAuthentication)
        #expect(!TermindSSHError.socket("Offline").shouldRequestAuthentication)
        #expect(!TermindSSHError.library("Handshake").shouldRequestAuthentication)
        #expect(
            !TermindSSHError.hostKeyChanged(expected: ["a"], received: "b")
                .shouldRequestAuthentication)
    }
}
