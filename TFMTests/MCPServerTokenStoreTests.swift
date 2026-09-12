import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import Termind

@Suite
struct MCPServerTokenStoreTests {
    @Test
    func savesNewTokensOnlyOnThisDevice() throws {
        let secrets = MCPServerTokenTestSecrets()
        let store = MCPServerTokenStore(secrets: secrets)

        try store.save("local-token")

        #expect(secrets.value(storage: .thisDevice) == "local-token")
        #expect(secrets.value(storage: .iCloud) == nil)
        #expect(secrets.synchronizedValuesWritten.isEmpty)
    }

    @Test
    func migratesACloudTokenOnlyAfterVerifyingTheLocalCopy() throws {
        let secrets = MCPServerTokenTestSecrets(cloud: "legacy-token")
        let store = MCPServerTokenStore(secrets: secrets)

        #expect(try store.load() == "legacy-token")
        #expect(secrets.value(storage: .thisDevice) == "legacy-token")
        #expect(secrets.value(storage: .iCloud) == nil)
    }

    @Test
    func localTokenWinsWhenBothLocationsContainValues() throws {
        let secrets = MCPServerTokenTestSecrets(local: "device-token", cloud: "shared-token")
        let store = MCPServerTokenStore(secrets: secrets)

        #expect(try store.load() == "device-token")
        #expect(secrets.value(storage: .thisDevice) == "device-token")
        #expect(secrets.value(storage: .iCloud) == nil)
    }

    @Test
    func failedLocalCopyKeepsTheOnlyCloudToken() {
        let secrets = MCPServerTokenTestSecrets(cloud: "legacy-token")
        secrets.failLocalWrites = true
        let store = MCPServerTokenStore(secrets: secrets)

        #expect(throws: (any Error).self) { try store.load() }
        #expect(secrets.value(storage: .thisDevice) == nil)
        #expect(secrets.value(storage: .iCloud) == "legacy-token")
    }

    @Test
    func failedCloudCleanupRetainsBothCopiesAndCanRetry() throws {
        let secrets = MCPServerTokenTestSecrets(cloud: "legacy-token")
        secrets.failCloudDeletes = true
        let store = MCPServerTokenStore(secrets: secrets)

        #expect(throws: (any Error).self) { try store.load() }
        #expect(secrets.value(storage: .thisDevice) == "legacy-token")
        #expect(secrets.value(storage: .iCloud) == "legacy-token")

        secrets.failCloudDeletes = false
        #expect(try store.load() == "legacy-token")
        #expect(secrets.value(storage: .iCloud) == nil)
    }
}

private nonisolated final class MCPServerTokenTestSecrets: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PasswordStorage: String] = [:]
    private(set) var synchronizedValuesWritten: [String] = []
    var failLocalWrites = false
    var failCloudDeletes = false

    init(local: String? = nil, cloud: String? = nil) {
        values[.thisDevice] = local
        values[.iCloud] = cloud
    }

    func value(storage: PasswordStorage) -> String? {
        lock.withLock { values[storage] }
    }

    func string(for account: String, storage: PasswordStorage) throws -> String? {
        lock.withLock { values[storage] }
    }

    func setString(_ value: String?, for account: String, storage: PasswordStorage) throws {
        try lock.withLock {
            if storage == .thisDevice, value != nil, failLocalWrites {
                throw CocoaError(.fileWriteNoPermission)
            }
            if storage == .iCloud, value == nil, failCloudDeletes {
                throw CocoaError(.fileWriteNoPermission)
            }
            values[storage] = value
            if storage == .iCloud, let value { synchronizedValuesWritten.append(value) }
        }
    }

    func keyCredential(for account: String, storage: KeyStorage) throws -> StoredSSHKeyCredential? { nil }
    func setKeyCredential(_ value: StoredSSHKeyCredential?, for account: String, storage: KeyStorage) throws {}
    func removePassword(_ account: String, storage: PasswordStorage) throws {
        try setString(nil, for: account, storage: storage)
    }
    func removeKeyCredential(_ account: String, storage: KeyStorage) throws {}
}
