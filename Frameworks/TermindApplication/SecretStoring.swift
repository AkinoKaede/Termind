import Foundation
import TermindDomain

public nonisolated struct SSHPrivateKeySecret: Codable, Hashable, Sendable {
    public var privateKey: String
    public init(privateKey: String) {
        self.privateKey = privateKey
    }

}

public nonisolated protocol SecretStoring: Sendable {
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

public nonisolated final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    public init() {}

    private let lock = NSLock()
    private var strings: [String: String] = [:]
    private var keys: [String: StoredSSHKeyCredential] = [:]

    public func string(for account: String, storage: PasswordStorage) throws -> String? {
        lock.withLock { strings[account] }
    }

    public func setString(_ value: String?, for account: String, storage: PasswordStorage) throws {
        lock.withLock { strings[account] = value }
    }

    public func keyCredential(
        for account: String, storage: KeyStorage
    ) throws -> StoredSSHKeyCredential? {
        lock.withLock { keys[account] }
    }

    public func setKeyCredential(
        _ value: StoredSSHKeyCredential?, for account: String, storage: KeyStorage
    ) throws {
        lock.withLock { keys[account] = value }
    }

    public func removePassword(_ account: String, storage: PasswordStorage) throws {
        lock.withLock { strings[account] = nil }
    }

    public func removeKeyCredential(_ account: String, storage: KeyStorage) throws {
        lock.withLock { keys[account] = nil }
    }
}
