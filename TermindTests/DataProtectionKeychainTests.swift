import Foundation
import Testing

@testable import Termind

@Suite(.serialized)
struct DataProtectionKeychainTests {
    @Test
    func persistedStorageNamesUseThisDevice() {
        #expect(KeyStorage.thisDevice.rawValue == "thisDevice")
        #expect(PasswordStorage.thisDevice.rawValue == "thisDevice")
        #expect(KeyStorage.iCloud.rawValue == "iCloud")
        #expect(PasswordStorage.iCloud.rawValue == "iCloud")
        #expect(KeyStorage(rawValue: "local" + "Keychain") == nil)
        #expect(Identity(name: "", username: "").passwordStorage == .iCloud)
        #expect(SSHKeyRef(label: "").storage == .iCloud)
    }

    @Test(arguments: [PasswordStorage.thisDevice, .iCloud])
    func identityPasswordRoundTripUsesExactStorageClass(
        _ storage: PasswordStorage
    ) throws {
        let keychain = KeychainSecretStore()
        let reference = "termind.password.\(UUID().uuidString)"
        defer { try? keychain.removePassword(reference, storage: storage) }

        try keychain.setString("secret", for: reference, storage: storage)
        #expect(try keychain.string(for: reference, storage: storage) == "secret")
        let other: PasswordStorage = storage == .thisDevice ? .iCloud : .thisDevice
        #expect(try keychain.string(for: reference, storage: other) == nil)
    }
    @Test
    func aiSecretsSurviveAcrossStoreInstances() {
        let reference = "termind.ai.test.\(UUID().uuidString)"
        let secrets = InMemorySecretStore()
        let writer = AIConfigurationModel(secrets: secrets)
        defer { writer.setSecret(nil, for: reference) }

        writer.setSecret("test-token", for: reference)
        #expect(writer.secretStorageError == nil)

        let reader = AIConfigurationModel(secrets: secrets)
        #expect(reader.secret(for: reference) == "test-token")
        #expect(reader.secretStorageError == nil)
    }

    @Test(arguments: [KeyStorage.thisDevice, .iCloud])
    func softwareKeyRoundTripUsesExactStorageClass(_ storage: KeyStorage) throws {
        let keychain = KeychainSecretStore()
        let reference = "termind.key.\(UUID().uuidString)"
        let expected = StoredSSHKeyCredential.software(
            SSHPrivateKeySecret(privateKey: "test-private-key")
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
