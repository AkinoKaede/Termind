import Foundation

nonisolated struct SSHPrivateKeySecret: Codable, Hashable, Sendable {
    var privateKey: String
}

nonisolated protocol SecretStoring: Sendable {
    func string(for account: String, storage: PasswordStorage) throws -> String?
    func setString(_ value: String?, for account: String, storage: PasswordStorage) throws
    func keyCredential(
        for account: String, storage: KeyStorage
    ) throws -> StoredSSHKeyCredential?
    func setKeyCredential(
        _ value: StoredSSHKeyCredential?, for account: String, storage: KeyStorage
    ) throws
    func removePassword(_ account: String, storage: PasswordStorage) throws
    func removeKeyCredential(_ account: String, storage: KeyStorage) throws
}

nonisolated final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var strings: [String: String] = [:]
    private var keys: [String: StoredSSHKeyCredential] = [:]

    func string(for account: String, storage: PasswordStorage) throws -> String? {
        lock.withLock { strings[account] }
    }

    func setString(_ value: String?, for account: String, storage: PasswordStorage) throws {
        lock.withLock { strings[account] = value }
    }

    func keyCredential(
        for account: String, storage: KeyStorage
    ) throws -> StoredSSHKeyCredential? {
        lock.withLock { keys[account] }
    }

    func setKeyCredential(
        _ value: StoredSSHKeyCredential?, for account: String, storage: KeyStorage
    ) throws {
        lock.withLock { keys[account] = value }
    }

    func removePassword(_ account: String, storage: PasswordStorage) throws {
        lock.withLock { strings[account] = nil }
    }

    func removeKeyCredential(_ account: String, storage: KeyStorage) throws {
        lock.withLock { keys[account] = nil }
    }
}
