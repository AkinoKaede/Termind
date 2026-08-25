import Foundation
import Security

nonisolated struct SSHPrivateKeySecret: Codable, Hashable, Sendable {
    var privateKey: String
    var passphrase: String?
}

nonisolated enum KeychainSecretError: LocalizedError {
    case status(OSStatus)
    case invalidReference
    case unexpectedValue

    var errorDescription: String? {
        switch self {
        case .status(let status):
            (SecCopyErrorMessageString(status, nil) as String?)
                ?? String(localized: "Keychain error \(status)")
        case .invalidReference:
            String(localized: "The Keychain reference has the wrong credential type.")
        case .unexpectedValue:
            String(localized: "The Keychain item does not contain the expected credential type.")
        }
    }
}

/// Typed storage in the macOS Data Protection Keychain. Independent services
/// prevent a damaged reference from reinterpreting one credential as another.
nonisolated struct KeychainSecretStore: Sendable {
    private static let passwordService = "com.akinokaede.termind.passwords.v1"
    private static let softwareKeyService = "com.akinokaede.termind.ssh-software-keys.v1"
    private static let enclaveService = "com.akinokaede.termind.secure-enclave-handles.v1"

    private let accessGroup: String

    init(accessGroup: String = ApplicationIdentity.keychainAccessGroup) {
        self.accessGroup = accessGroup
    }

    /// Local-only compatibility entry point used by AI and MCP secrets.
    func string(for account: String) throws -> String? {
        try string(for: account, storage: .thisDevice)
    }

    func string(for account: String, storage: PasswordStorage) throws -> String? {
        try validateStringReference(account)
        guard
            let data = try data(
                for: account, service: Self.passwordService,
                synchronizable: storage == .iCloudKeychain
            )
        else { return nil }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainSecretError.unexpectedValue
        }
        return value
    }

    /// Local-only compatibility entry point used by AI and MCP secrets.
    func setString(_ value: String?, for account: String) throws {
        try setString(value, for: account, storage: .thisDevice)
    }

    func setString(_ value: String?, for account: String, storage: PasswordStorage) throws {
        try validateStringReference(account)
        try setData(
            value?.data(using: .utf8), for: account, service: Self.passwordService,
            synchronizable: storage == .iCloudKeychain,
            accessible: storage == .iCloudKeychain
                ? kSecAttrAccessibleWhenUnlocked
                : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
    }

    func keyCredential(for account: String, storage: KeyStorage) throws
        -> StoredSSHKeyCredential?
    {
        try validate(account, prefix: "termind.key.")
        guard
            let data = try data(
                for: account, service: service(for: storage),
                synchronizable: storage == .iCloudKeychain
            )
        else { return nil }
        switch storage {
        case .thisDevice, .iCloudKeychain:
            return .software(try JSONDecoder().decode(SSHPrivateKeySecret.self, from: data))
        case .secureEnclave:
            guard !data.isEmpty else { throw KeychainSecretError.unexpectedValue }
            return .secureEnclave(SecureEnclaveKeyCredential(dataRepresentation: data))
        }
    }

    func setKeyCredential(
        _ value: StoredSSHKeyCredential?, for account: String, storage: KeyStorage
    ) throws {
        try validate(account, prefix: "termind.key.")
        let data: Data?
        switch (value, storage) {
        case (.software(let secret), .thisDevice), (.software(let secret), .iCloudKeychain):
            data = try JSONEncoder().encode(secret)
        case (.secureEnclave(let credential), .secureEnclave):
            data = credential.dataRepresentation
        case (nil, _):
            data = nil
        default:
            throw KeychainSecretError.unexpectedValue
        }
        try setData(
            data, for: account, service: service(for: storage),
            synchronizable: storage == .iCloudKeychain,
            accessible: storage == .iCloudKeychain
                ? kSecAttrAccessibleWhenUnlocked
                : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
    }

    func removePassword(
        _ account: String, storage: PasswordStorage = .thisDevice
    ) throws {
        guard !account.isEmpty else { return }
        try validate(account, prefix: "termind.password.")
        try remove(
            account, service: Self.passwordService,
            synchronizable: storage == .iCloudKeychain
        )
    }

    func removeKeyCredential(_ account: String, storage: KeyStorage) throws {
        guard !account.isEmpty else { return }
        try validate(account, prefix: "termind.key.")
        try remove(
            account, service: service(for: storage),
            synchronizable: storage == .iCloudKeychain
        )
    }

    private func data(for account: String, service: String, synchronizable: Bool) throws
        -> Data?
    {
        guard !account.isEmpty else { return nil }
        var query = baseQuery(account, service: service, synchronizable: synchronizable)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainSecretError.status(status) }
        guard let data = result as? Data else { throw KeychainSecretError.unexpectedValue }
        return data
    }

    private func setData(
        _ value: Data?, for account: String, service: String,
        synchronizable: Bool, accessible: CFString
    ) throws {
        guard let value else {
            try remove(account, service: service, synchronizable: synchronizable)
            return
        }
        let match = baseQuery(account, service: service, synchronizable: synchronizable)
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: accessible,
        ]
        let updateStatus = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainSecretError.status(updateStatus)
        }
        var add = match
        for (key, value) in attributes { add[key] = value }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainSecretError.status(addStatus) }
    }

    private func remove(_ account: String, service: String, synchronizable: Bool) throws {
        let query = baseQuery(account, service: service, synchronizable: synchronizable)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainSecretError.status(status)
        }
    }

    private func baseQuery(
        _ account: String, service: String, synchronizable: Bool
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: synchronizable,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func service(for storage: KeyStorage) -> String {
        switch storage {
        case .thisDevice, .iCloudKeychain: Self.softwareKeyService
        case .secureEnclave: Self.enclaveService
        }
    }

    private func validate(_ account: String, prefix: String) throws {
        guard account.hasPrefix(prefix), account.count > prefix.count else {
            throw KeychainSecretError.invalidReference
        }
    }

    private func validateStringReference(_ account: String) throws {
        let prefixes = ["termind.password.", "termind.ai."]
        guard prefixes.contains(where: { account.hasPrefix($0) && account.count > $0.count })
        else { throw KeychainSecretError.invalidReference }
    }
}
