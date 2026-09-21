import Foundation
import Security
import TermindApplication
import TermindDomain

public nonisolated enum KeychainSecretError: LocalizedError {
    case status(OSStatus)
    case invalidReference
    case unexpectedValue

    public var errorDescription: String? {
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

/// The Vault's typed secret boundary. Keeping the store behind this small
/// interface lets connection tests prove password/passphrase lifetime rules
/// without depending on a signed Keychain-enabled test host.
/// Typed storage in the macOS Data Protection Keychain. Independent services
/// prevent a damaged reference from reinterpreting one credential as another.
public nonisolated struct KeychainSecretStore: SecretStoring, Sendable {
    private static let passwordService = "com.akinokaede.termind.passwords.v1"
    private static let softwareKeyService = "com.akinokaede.termind.ssh-software-keys.v1"
    private static let enclaveService = "com.akinokaede.termind.secure-enclave-handles.v1"
    private static let softwareKeyMagic = Data("termind-ssh-key\0".utf8)
    private static let softwareKeyFormatVersion: UInt8 = 0x01

    private let accessGroup: String

    public init(accessGroup: String) {
        self.accessGroup = accessGroup
    }

    public func string(for account: String, storage: PasswordStorage) throws -> String? {
        try validateStringReference(account)
        guard
            let data = try data(
                for: account, service: Self.passwordService,
                synchronizable: storage == .iCloud
            )
        else { return nil }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainSecretError.unexpectedValue
        }
        return value
    }

    public func containsString(for account: String, storage: PasswordStorage) throws -> Bool {
        try validateStringReference(account)
        return try contains(
            account, service: Self.passwordService,
            synchronizable: storage == .iCloud
        )
    }

    public func sshSecret(for account: String, storage: PasswordStorage) throws -> SSHSecret? {
        try validateStringReference(account)
        guard
            var data = try data(
                for: account, service: Self.passwordService,
                synchronizable: storage == .iCloud
            )
        else { return nil }
        return SSHSecret(consumingUTF8: &data)
    }

    public func setString(_ value: String?, for account: String, storage: PasswordStorage) throws {
        try validateStringReference(account)
        var data = value?.data(using: .utf8)
        defer {
            if data != nil { SecretMemory.clear(&data!) }
        }
        try setData(
            data, for: account, service: Self.passwordService,
            synchronizable: storage == .iCloud,
            accessible: storage == .iCloud
                ? kSecAttrAccessibleWhenUnlocked
                : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
    }

    public func keyCredential(for account: String, storage: KeyStorage) throws
        -> StoredSSHKeyCredential?
    {
        try validate(account, prefix: "termind.key.")
        guard
            var data = try data(
                for: account, service: service(for: storage),
                synchronizable: storage == .iCloud
            )
        else { return nil }
        switch storage {
        case .thisDevice, .iCloud:
            return .software(try Self.decodeSoftwareKey(from: &data))
        case .secureEnclave:
            guard !data.isEmpty else { throw KeychainSecretError.unexpectedValue }
            return .secureEnclave(SecureEnclaveKeyCredential(dataRepresentation: data))
        }
    }

    public func containsKeyCredential(for account: String, storage: KeyStorage) throws -> Bool {
        try validate(account, prefix: "termind.key.")
        return try contains(
            account, service: service(for: storage),
            synchronizable: storage == .iCloud
        )
    }

    public func sshKeyCredential(
        for account: String, storage: KeyStorage
    ) throws -> SSHResolvedKeyCredential? {
        try validate(account, prefix: "termind.key.")
        guard
            var data = try data(
                for: account, service: service(for: storage),
                synchronizable: storage == .iCloud
            )
        else { return nil }
        defer { SecretMemory.clear(&data) }
        switch storage {
        case .thisDevice, .iCloud:
            return .software(try Self.decodeSoftwareKeyRuntimeSecret(from: &data))
        case .secureEnclave:
            guard !data.isEmpty else { throw KeychainSecretError.unexpectedValue }
            return .secureEnclave(SecureEnclaveKeyCredential(dataRepresentation: data))
        }
    }

    public func setKeyCredential(
        _ value: StoredSSHKeyCredential?, for account: String, storage: KeyStorage
    ) throws {
        try validate(account, prefix: "termind.key.")
        var data: Data?
        switch (value, storage) {
        case (.software(let secret), .thisDevice), (.software(let secret), .iCloud):
            data = Self.encodeSoftwareKey(secret)
        case (.secureEnclave(let credential), .secureEnclave):
            data = credential.dataRepresentation
        case (nil, _):
            data = nil
        default:
            throw KeychainSecretError.unexpectedValue
        }
        defer {
            if data != nil { SecretMemory.clear(&data!) }
        }
        try setData(
            data, for: account, service: service(for: storage),
            synchronizable: storage == .iCloud,
            accessible: storage == .iCloud
                ? kSecAttrAccessibleWhenUnlocked
                : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
    }

    static func encodeSoftwareKey(_ secret: SSHPrivateKeySecret) -> Data {
        var data = Data()
        data.reserveCapacity(Self.softwareKeyMagic.count + 1 + secret.privateKey.utf8.count)
        data.append(Self.softwareKeyMagic)
        data.append(Self.softwareKeyFormatVersion)
        data.append(contentsOf: secret.privateKey.utf8)
        return data
    }

    static func decodeSoftwareKey(from data: inout Data) throws -> SSHPrivateKeySecret {
        defer { SecretMemory.clear(&data) }
        if let payload = try currentSoftwareKeyPayload(in: data) {
            guard let privateKey = String(data: data[payload], encoding: .utf8) else {
                throw KeychainSecretError.unexpectedValue
            }
            return SSHPrivateKeySecret(privateKey: privateKey)
        }
        do {
            return try JSONDecoder().decode(SSHPrivateKeySecret.self, from: data)
        } catch {
            throw KeychainSecretError.unexpectedValue
        }
    }

    /// Decodes the current envelope directly into one-shot ownership. The
    /// legacy JSON path remains strict and never materializes the private key as
    /// an immutable Swift `String`.
    static func decodeSoftwareKeyRuntimeSecret(from data: inout Data) throws -> SSHSecret {
        defer { SecretMemory.clear(&data) }
        if let payload = try currentSoftwareKeyPayload(in: data) {
            guard isValidUTF8(data, in: payload) else {
                throw KeychainSecretError.unexpectedValue
            }
            return SSHSecret(consumingUTF8: &data, range: payload)
        }
        return try decodeLegacySoftwareKeyRuntimeSecret(from: &data)
    }

    /// Strictly decodes the legacy single-field JSON envelope without creating
    /// an immutable Swift `String` containing the private key. Corrupted shapes
    /// fail closed instead of being searched for a matching field substring.
    private static func decodeLegacySoftwareKeyRuntimeSecret(from data: inout Data) throws
        -> SSHSecret
    {
        var index = data.startIndex
        func skipWhitespace() {
            while index < data.endIndex, [0x20, 0x09, 0x0A, 0x0D].contains(data[index]) {
                index = data.index(after: index)
            }
        }
        func consume(_ expected: UInt8) throws {
            guard index < data.endIndex, data[index] == expected else {
                throw KeychainSecretError.unexpectedValue
            }
            index = data.index(after: index)
        }

        skipWhitespace()
        try consume(0x7B)
        skipWhitespace()
        for expected in Array("\"privateKey\"".utf8) {
            try consume(expected)
        }
        skipWhitespace()
        try consume(0x3A)
        skipWhitespace()
        try consume(0x22)

        var result = Data()
        defer { SecretMemory.clear(&result) }
        while index < data.endIndex {
            let byte = data[index]
            index = data.index(after: index)
            if byte == 0x22 {
                skipWhitespace()
                try consume(0x7D)
                skipWhitespace()
                guard index == data.endIndex else {
                    throw KeychainSecretError.unexpectedValue
                }
                guard isValidUTF8(result, in: result.startIndex..<result.endIndex) else {
                    throw KeychainSecretError.unexpectedValue
                }
                return SSHSecret(consumingUTF8: &result)
            }
            guard byte == 0x5C else {
                guard byte >= 0x20 else { throw KeychainSecretError.unexpectedValue }
                result.append(byte)
                continue
            }
            guard index < data.endIndex else { throw KeychainSecretError.unexpectedValue }
            let escape = data[index]
            index = data.index(after: index)
            switch escape {
            case 0x22, 0x5C, 0x2F: result.append(escape)
            case 0x62: result.append(0x08)
            case 0x66: result.append(0x0C)
            case 0x6E: result.append(0x0A)
            case 0x72: result.append(0x0D)
            case 0x74: result.append(0x09)
            case 0x75:
                var value: UInt32 = 0
                for _ in 0..<4 {
                    guard index < data.endIndex, let digit = hex(data[index]) else {
                        throw KeychainSecretError.unexpectedValue
                    }
                    value = value * 16 + UInt32(digit)
                    index = data.index(after: index)
                }
                guard let scalar = Unicode.Scalar(value), !(0xD800...0xDFFF).contains(value) else {
                    throw KeychainSecretError.unexpectedValue
                }
                result.append(contentsOf: String(scalar).utf8)
            default:
                throw KeychainSecretError.unexpectedValue
            }
        }
        throw KeychainSecretError.unexpectedValue
    }

    /// Returns `nil` only for a legacy value. Once any complete or truncated
    /// current-format magic is present, malformed data fails closed.
    private static func currentSoftwareKeyPayload(in data: Data) throws -> Range<Data.Index>? {
        if data.starts(with: Self.softwareKeyMagic) {
            let versionIndex = data.index(data.startIndex, offsetBy: Self.softwareKeyMagic.count)
            guard versionIndex < data.endIndex else { throw KeychainSecretError.unexpectedValue }
            guard data[versionIndex] == Self.softwareKeyFormatVersion else {
                throw KeychainSecretError.unexpectedValue
            }
            let payloadStart = data.index(after: versionIndex)
            guard payloadStart < data.endIndex else { throw KeychainSecretError.unexpectedValue }
            return payloadStart..<data.endIndex
        }
        if !data.isEmpty && Self.softwareKeyMagic.starts(with: data) {
            throw KeychainSecretError.unexpectedValue
        }
        return nil
    }

    private static func isValidUTF8(_ data: Data, in range: Range<Data.Index>) -> Bool {
        var index = range.lowerBound
        func continuation() -> UInt8? {
            guard index < range.upperBound else { return nil }
            let byte = data[index]
            guard byte >= 0x80 && byte <= 0xBF else { return nil }
            index = data.index(after: index)
            return byte
        }

        while index < range.upperBound {
            let first = data[index]
            index = data.index(after: index)
            switch first {
            case 0x00...0x7F:
                continue
            case 0xC2...0xDF:
                guard continuation() != nil else { return false }
            case 0xE0:
                guard let second = continuation(), second >= 0xA0, continuation() != nil else {
                    return false
                }
            case 0xE1...0xEC, 0xEE...0xEF:
                guard continuation() != nil, continuation() != nil else { return false }
            case 0xED:
                guard let second = continuation(), second <= 0x9F, continuation() != nil else {
                    return false
                }
            case 0xF0:
                guard
                    let second = continuation(), second >= 0x90,
                    continuation() != nil, continuation() != nil
                else { return false }
            case 0xF1...0xF3:
                guard
                    continuation() != nil, continuation() != nil, continuation() != nil
                else { return false }
            case 0xF4:
                guard
                    let second = continuation(), second <= 0x8F,
                    continuation() != nil, continuation() != nil
                else { return false }
            default:
                return false
            }
        }
        return true
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }

    public func removePassword(
        _ account: String, storage: PasswordStorage = .thisDevice
    ) throws {
        guard !account.isEmpty else { return }
        try validate(account, prefix: "termind.password.")
        try remove(
            account, service: Self.passwordService,
            synchronizable: storage == .iCloud
        )
    }

    public func removeKeyCredential(_ account: String, storage: KeyStorage) throws {
        guard !account.isEmpty else { return }
        try validate(account, prefix: "termind.key.")
        try remove(
            account, service: service(for: storage),
            synchronizable: storage == .iCloud
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

    private func contains(_ account: String, service: String, synchronizable: Bool) throws -> Bool {
        guard !account.isEmpty else { return false }
        var query = baseQuery(account, service: service, synchronizable: synchronizable)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw KeychainSecretError.status(status) }
        return true
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
        case .thisDevice, .iCloud: Self.softwareKeyService
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
