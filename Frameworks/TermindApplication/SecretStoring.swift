import Foundation
import TermindDomain

public nonisolated struct SSHPrivateKeySecret: Codable, Hashable, Sendable {
    public var privateKey: String
    public init(privateKey: String) {
        self.privateKey = privateKey
    }

}

public nonisolated protocol SSHRuntimeSecretResolving: Sendable {
    func sshSecret(for account: String, storage: PasswordStorage) throws -> SSHSecret?
    func sshKeyCredential(
        for account: String, storage: KeyStorage
    ) throws -> SSHResolvedKeyCredential?
}

public nonisolated protocol SecretStoring: SSHRuntimeSecretResolving {
    func string(for account: String, storage: PasswordStorage) throws -> String?
    func containsString(for account: String, storage: PasswordStorage) throws -> Bool
    func setString(_ value: String?, for account: String, storage: PasswordStorage) throws
    func keyCredential(
        for account: String, storage: KeyStorage
    ) throws -> StoredSSHKeyCredential?
    func containsKeyCredential(for account: String, storage: KeyStorage) throws -> Bool
    func setKeyCredential(
        _ value: StoredSSHKeyCredential?, for account: String, storage: KeyStorage
    ) throws
    func removePassword(_ account: String, storage: PasswordStorage) throws
    func removeKeyCredential(_ account: String, storage: KeyStorage) throws
}

nonisolated extension SecretStoring {
    public func containsString(for account: String, storage: PasswordStorage) throws -> Bool {
        try string(for: account, storage: storage) != nil
    }

    public func containsKeyCredential(for account: String, storage: KeyStorage) throws -> Bool {
        try keyCredential(for: account, storage: storage) != nil
    }

    public func sshSecret(for account: String, storage: PasswordStorage) throws -> SSHSecret? {
        try string(for: account, storage: storage).map(SSHSecret.init)
    }

    public func sshKeyCredential(
        for account: String, storage: KeyStorage
    ) throws -> SSHResolvedKeyCredential? {
        switch try keyCredential(for: account, storage: storage) {
        case .software(let secret): .software(SSHSecret(secret.privateKey))
        case .secureEnclave(let credential): .secureEnclave(credential)
        case nil: nil
        }
    }
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
