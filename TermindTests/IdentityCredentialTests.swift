import Foundation
import Testing

@testable import Termind

@Suite(.serialized)
@MainActor
struct IdentityCredentialTests {
    @Test
    func passwordUpdatesKeepReplaceAndRemoveTheKeychainItem() throws {
        let keychain = KeychainSecretStore()
        let reference = "termind.password.\(UUID().uuidString)"
        let id = UUID()
        let keyID = UUID()
        let original = Identity(
            id: id, name: "Deploy", username: "deploy",
            credentialRef: reference, passwordStorage: .thisDevice, keyID: keyID
        )
        let store = HostStore(identities: [original], keychain: keychain)
        defer { try? keychain.removePassword(reference) }

        try keychain.setString("old", for: reference)

        var renamed = original
        renamed.name = "Production"
        try store.upsert(renamed, passwordUpdate: .keep)
        #expect(store.identity(id)?.credentialRef == reference)
        #expect(try keychain.string(for: reference) == "old")

        try store.upsert(renamed, passwordUpdate: .replace("new"))
        #expect(store.identity(id)?.credentialRef == reference)
        #expect(try keychain.string(for: reference) == "new")

        try store.upsert(renamed, passwordUpdate: .remove)
        #expect(store.identity(id)?.credentialRef == "")
        #expect(store.identity(id)?.keyID == keyID)
        #expect(try keychain.string(for: reference) == nil)
    }

    @Test
    func addingAPasswordMintsAReference() throws {
        let keychain = KeychainSecretStore()
        let identity = Identity(name: "Deploy", username: "deploy")
        let store = HostStore(keychain: keychain)

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
    func missingKeyDoesNotSuppressAnAvailablePassword() throws {
        let keychain = KeychainSecretStore()
        let passwordReference = "termind.password.\(UUID().uuidString)"
        let missingKeyReference = "termind.key.\(UUID().uuidString)"
        defer {
            try? keychain.removePassword(passwordReference)
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
        try keychain.setString("fallback", for: passwordReference)
        let store = HostStore(keys: [key], identities: [identity], keychain: keychain)

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
    func protectedKeyWithoutSavedPassphraseRequestsItBeforeUse() throws {
        let keychain = KeychainSecretStore()
        let reference = "termind.key.\(UUID().uuidString)"
        defer { try? keychain.removeKeyCredential(reference, storage: .thisDevice) }

        let key = SSHKeyRef(
            label: "Protected", algorithm: .ed25519, publicKey: "ssh-ed25519 test",
            fingerprint: "SHA256:test", credentialRef: reference,
            hasPassphrase: true, storesPassphrase: false
        )
        let identity = Identity(name: "Deploy", username: "deploy", keyID: key.id)
        let store = HostStore(keys: [key], identities: [identity], keychain: keychain)
        try keychain.setKeyCredential(
            .software(SSHPrivateKeySecret(privateKey: "encrypted", passphrase: nil)),
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
