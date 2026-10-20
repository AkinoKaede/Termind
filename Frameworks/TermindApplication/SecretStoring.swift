// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

public nonisolated struct SSHPrivateKeySecret: Codable, Hashable, Sendable {
    public var privateKey: String
    public var passphrase: String?
    public init(privateKey: String, passphrase: String? = nil) {
        self.privateKey = privateKey
        self.passphrase = passphrase
    }

}

public nonisolated protocol SSHRuntimeSecretResolving: Sendable {
    func sshSecret(for account: String, storage: PasswordStorage) throws -> SSHSecret?
    func sshKeyCredential(
        for account: String, storage: KeyStorage
    ) throws -> SSHResolvedKeyCredential?
}

nonisolated extension SSHRuntimeSecretResolving {
    /// Hardware references are Vault metadata and must never be looked up in Keychain.
    public func sshKeyCredential(for key: SSHKeyRef) throws -> SSHResolvedKeyCredential? {
        if key.algorithm == .securityKey { return key.securityKey.map(SSHResolvedKeyCredential.securityKey) }
        return try sshKeyCredential(for: key.credentialRef, storage: key.storage)
    }
}

public nonisolated protocol SecretStoring: SSHRuntimeSecretResolving {
    func string(for account: String, storage: PasswordStorage) throws -> String?
    func containsString(for account: String, storage: PasswordStorage) throws -> Bool
    func setString(_ value: String?, for account: String, storage: PasswordStorage) throws
    func keyCredential(
        for account: String, storage: KeyStorage
    ) throws -> StoredSSHKeyCredential?
    func setKeyPassphrase(_ passphrase: SSHSecret?, for account: String, storage: KeyStorage) throws
    func containsKeyCredential(for account: String, storage: KeyStorage) throws -> Bool
    func setKeyCredential(
        _ value: StoredSSHKeyCredential?, for account: String, storage: KeyStorage
    ) throws
    func setResolvedKeyCredential(_ credential: SSHResolvedKeyCredential, for account: String, storage: KeyStorage)
        throws
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

    /// Default for in-memory/test stores. The Keychain adapter overrides this
    /// to update its JSON envelope entirely through wipeable byte buffers.
    public func setKeyPassphrase(_ passphrase: SSHSecret?, for account: String, storage: KeyStorage) throws {
        defer { passphrase?.clear() }
        guard case .software(var secret)? = try keyCredential(for: account, storage: storage) else {
            throw TermindSSHError.missingCredential
        }
        secret.passphrase = try passphrase?.withUnsafeCStringAndConsume { bytes, count in
            String(decoding: UnsafeRawBufferPointer(start: bytes, count: count), as: UTF8.self)
        }
        try setKeyCredential(.software(secret), for: account, storage: storage)
    }

    /// Test/in-memory fallback; persistent adapters must write the wipeable
    /// credential directly, without first materializing String secrets.
    public func setResolvedKeyCredential(
        _ credential: SSHResolvedKeyCredential, for account: String, storage: KeyStorage
    ) throws {
        defer { credential.clearSecrets() }
        switch credential {
        case .securityKey:
            throw CocoaError(.coderInvalidValue)
        case .software(let key, let passphrase):
            let text = try key.withUnsafeCStringAndConsume { bytes, count in
                String(decoding: UnsafeRawBufferPointer(start: bytes, count: count), as: UTF8.self)
            }
            let phrase = try passphrase?.withUnsafeCStringAndConsume { bytes, count in
                String(decoding: UnsafeRawBufferPointer(start: bytes, count: count), as: UTF8.self)
            }
            try setKeyCredential(.software(.init(privateKey: text, passphrase: phrase)), for: account, storage: storage)
        case .secureEnclave(let key):
            try setKeyCredential(.secureEnclave(key), for: account, storage: storage)
        }
    }

    public func sshSecret(for account: String, storage: PasswordStorage) throws -> SSHSecret? {
        try string(for: account, storage: storage).map(SSHSecret.init)
    }

    public func sshKeyCredential(
        for account: String, storage: KeyStorage
    ) throws -> SSHResolvedKeyCredential? {
        switch try keyCredential(for: account, storage: storage) {
        case .software(let secret):
            .software(SSHSecret(secret.privateKey), passphrase: secret.passphrase.map(SSHSecret.init))
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
