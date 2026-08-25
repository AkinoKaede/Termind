import Foundation
import Testing

@testable import Termind

@Suite(.serialized)
struct DataProtectionKeychainTests {
    @Test
    func persistedStorageNamesUseThisDevice() {
        #expect(KeyStorage.thisDevice.rawValue == "thisDevice")
        #expect(PasswordStorage.thisDevice.rawValue == "thisDevice")
        #expect(KeyStorage(rawValue: "local" + "Keychain") == nil)
        #expect(Identity(name: "", username: "").passwordStorage == .iCloudKeychain)
        #expect(SSHKeyRef(label: "").storage == .iCloudKeychain)
    }

    @Test(arguments: [PasswordStorage.thisDevice, .iCloudKeychain])
    func identityPasswordRoundTripUsesExactStorageClass(
        _ storage: PasswordStorage
    ) throws {
        let keychain = KeychainSecretStore()
        let reference = "termind.password.\(UUID().uuidString)"
        defer { try? keychain.removePassword(reference, storage: storage) }

        try keychain.setString("secret", for: reference, storage: storage)
        #expect(try keychain.string(for: reference, storage: storage) == "secret")
        let other: PasswordStorage = storage == .thisDevice ? .iCloudKeychain : .thisDevice
        #expect(try keychain.string(for: reference, storage: other) == nil)
    }
    @Test
    func aiSecretsSurviveAcrossStoreInstances() {
        let reference = "termind.ai.test.\(UUID().uuidString)"
        let writer = AIStore()
        defer { writer.setSecret(nil, for: reference) }

        writer.setSecret("test-token", for: reference)
        #expect(writer.secretStorageError == nil)

        let reader = AIStore()
        #expect(reader.secret(for: reference) == "test-token")
        #expect(reader.secretStorageError == nil)
    }

    @Test(arguments: [KeyStorage.thisDevice, .iCloudKeychain])
    func softwareKeyRoundTripUsesExactStorageClass(_ storage: KeyStorage) throws {
        let keychain = KeychainSecretStore()
        let reference = "termind.key.\(UUID().uuidString)"
        let expected = StoredSSHKeyCredential.software(
            SSHPrivateKeySecret(privateKey: "test-private-key", passphrase: "test-passphrase")
        )
        defer { try? keychain.removeKeyCredential(reference, storage: storage) }

        try keychain.setKeyCredential(expected, for: reference, storage: storage)
        #expect(try keychain.keyCredential(for: reference, storage: storage) == expected)
        try keychain.removeKeyCredential(reference, storage: storage)
        #expect(try keychain.keyCredential(for: reference, storage: storage) == nil)
    }

    @Test
    func secureEnclaveHandleRoundTripIsDeviceBound() throws {
        let keychain = KeychainSecretStore()
        let reference = "termind.key.\(UUID().uuidString)"
        let expected = StoredSSHKeyCredential.secureEnclave(
            SecureEnclaveKeyCredential(dataRepresentation: Data("test-handle".utf8))
        )
        defer { try? keychain.removeKeyCredential(reference, storage: .secureEnclave) }

        try keychain.setKeyCredential(expected, for: reference, storage: .secureEnclave)
        #expect(
            try keychain.keyCredential(for: reference, storage: .secureEnclave) == expected
        )
        try keychain.removeKeyCredential(reference, storage: .secureEnclave)
        #expect(try keychain.keyCredential(for: reference, storage: .secureEnclave) == nil)
    }
}
