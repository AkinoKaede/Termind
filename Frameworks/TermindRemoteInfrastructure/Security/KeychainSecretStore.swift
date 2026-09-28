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
        defer { SecretMemory.clear(&data) }
        switch storage {
        case .thisDevice, .iCloud:
            return .software(try JSONDecoder().decode(SSHPrivateKeySecret.self, from: data))
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
            return try Self.decodeKeySecrets(from: &data)
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
            data = try JSONEncoder().encode(secret)
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

    public func setResolvedKeyCredential(
        _ credential: SSHResolvedKeyCredential, for account: String, storage: KeyStorage
    ) throws {
        defer { credential.clearSecrets() }
        try validate(account, prefix: "termind.key.")
        var encoded: Data
        switch (credential, storage) {
        case (.software(let key, let passphrase), .thisDevice), (.software(let key, let passphrase), .iCloud):
            encoded = try Self.encodeKeySecrets(privateKey: key, passphrase: passphrase)
        case (.secureEnclave(let key), .secureEnclave): encoded = key.dataRepresentation
        default: throw KeychainSecretError.unexpectedValue
        }
        defer { SecretMemory.clear(&encoded) }
        try setData(
            encoded, for: account, service: service(for: storage), synchronizable: storage == .iCloud,
            accessible: storage == .iCloud
                ? kSecAttrAccessibleWhenUnlocked : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
    }

    public func setKeyPassphrase(_ passphrase: SSHSecret?, for account: String, storage: KeyStorage) throws {
        defer { passphrase?.clear() }
        guard storage != .secureEnclave,
            let credential = try sshKeyCredential(for: account, storage: storage),
            case .software(let privateKey, _) = credential
        else { throw KeychainSecretError.unexpectedValue }
        defer { credential.clearSecrets() }
        var encoded = try Self.encodeKeySecrets(privateKey: privateKey, passphrase: passphrase)
        defer { SecretMemory.clear(&encoded) }
        try setData(
            encoded, for: account, service: service(for: storage), synchronizable: storage == .iCloud,
            accessible: storage == .iCloud
                ? kSecAttrAccessibleWhenUnlocked : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
    }

    /// The editor's legacy envelope and the runtime reader share the same wire
    /// format. Secret values never become immutable Strings in the runtime path.
    static func encodeKeySecrets(privateKey: SSHSecret, passphrase: SSHSecret?) throws -> Data {
        defer {
            privateKey.clear()
            passphrase?.clear()
        }
        var output = Data()
        var succeeded = false
        defer { if !succeeded { SecretMemory.clear(&output) } }
        func append(_ secret: SSHSecret) throws {
            output.append(0x22)
            try secret.withUnsafeCStringAndConsume { pointer, count in
                for byte in UnsafeRawBufferPointer(start: pointer, count: count) {
                    switch byte {
                    case 0x22, 0x5C: output.append(contentsOf: [0x5C, byte])
                    case 0..<0x20:
                        let digits = Array("0123456789abcdef".utf8)
                        output.append(contentsOf: [
                            0x5C, 0x75, 0x30, 0x30, digits[Int(byte >> 4)], digits[Int(byte & 15)],
                        ])
                    default: output.append(byte)
                    }
                }
            }
            output.append(0x22)
        }
        // Reserve an upper bound before writing any plaintext, avoiding Data
        // reallocation while appending escaped secret bytes.
        output.reserveCapacity(64 + 6 * (privateKey.byteCount + (passphrase?.byteCount ?? 0)))
        output.append(contentsOf: "{\"privateKey\":".utf8)
        try append(privateKey)
        if let passphrase {
            output.append(contentsOf: ",\"passphrase\":".utf8)
            try append(passphrase)
        }
        output.append(0x7D)
        succeeded = true
        return output
    }

    static func decodePrivateKeySecret(from data: inout Data) throws -> SSHSecret {
        let credential = try decodeKeySecrets(from: &data)
        guard case .software(let key, let passphrase) = credential else {
            throw KeychainSecretError.unexpectedValue
        }
        passphrase?.clear()
        return key
    }

    static func decodeKeySecrets(
        from data: inout Data, observeSecret: ((SSHSecret) -> Void)? = nil
    ) throws -> SSHResolvedKeyCredential {
        defer { SecretMemory.clear(&data) }
        var index = data.startIndex
        var privateKey: SSHSecret?
        var passphrase: SSHSecret?
        var succeeded = false
        defer {
            if !succeeded {
                privateKey?.clear()
                passphrase?.clear()
            }
        }
        func skipWhitespace() {
            while index < data.endIndex, [0x20, 0x09, 0x0A, 0x0D].contains(data[index]) { index += 1 }
        }
        func consume(_ expected: UInt8) throws {
            guard index < data.endIndex, data[index] == expected else { throw KeychainSecretError.unexpectedValue }
            index += 1
        }
        func hexUnit() throws -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard index < data.endIndex else { throw KeychainSecretError.unexpectedValue }
                let byte = data[index]
                let digit: UInt8
                switch byte {
                case 0x30...0x39: digit = byte - 0x30
                case 0x41...0x46: digit = byte - 0x41 + 10
                case 0x61...0x66: digit = byte - 0x61 + 10
                default: throw KeychainSecretError.unexpectedValue
                }
                value = value * 16 + UInt32(digit)
                index += 1
            }
            return value
        }
        func readString() throws -> SSHSecret {
            try consume(0x22)
            var bytes = Data()
            bytes.reserveCapacity(data.count)
            defer { SecretMemory.clear(&bytes) }
            while index < data.endIndex {
                let byte = data[index]
                index += 1
                if byte == 0x22 {
                    func validateUTF8() throws {
                        var decoder = Unicode.UTF8()
                        var iterator = bytes.makeIterator()
                        while true {
                            switch decoder.decode(&iterator) {
                            case .scalarValue: continue
                            case .emptyInput: return
                            case .error: throw KeychainSecretError.unexpectedValue
                            }
                        }
                    }
                    try validateUTF8()
                    let secret = SSHSecret(consumingUTF8: &bytes)
                    observeSecret?(secret)
                    return secret
                }
                guard byte == 0x5C else {
                    guard byte >= 0x20 else { throw KeychainSecretError.unexpectedValue }
                    bytes.append(byte)
                    continue
                }
                guard index < data.endIndex else { throw KeychainSecretError.unexpectedValue }
                let escape = data[index]
                index += 1
                switch escape {
                case 0x22, 0x5C, 0x2F: bytes.append(escape)
                case 0x62: bytes.append(0x08)
                case 0x66: bytes.append(0x0C)
                case 0x6E: bytes.append(0x0A)
                case 0x72: bytes.append(0x0D)
                case 0x74: bytes.append(0x09)
                case 0x75:
                    var scalar = try hexUnit()
                    if (0xD800...0xDBFF).contains(scalar) {
                        try consume(0x5C)
                        try consume(0x75)
                        let low = try hexUnit()
                        guard (0xDC00...0xDFFF).contains(low) else { throw KeychainSecretError.unexpectedValue }
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + low - 0xDC00
                    }
                    guard let value = Unicode.Scalar(scalar) else { throw KeychainSecretError.unexpectedValue }
                    Unicode.UTF8.encode(value) { bytes.append($0) }
                default: throw KeychainSecretError.unexpectedValue
                }
            }
            throw KeychainSecretError.unexpectedValue
        }
        skipWhitespace()
        try consume(0x7B)
        var sawPassphrase = false
        while true {
            skipWhitespace()
            let name = try readString()
            defer { name.clear() }
            skipWhitespace()
            try consume(0x3A)
            skipWhitespace()
            if name.matches("privateKey"), privateKey == nil {
                privateKey = try readString()
            } else if name.matches("passphrase"), !sawPassphrase {
                sawPassphrase = true
                if index < data.endIndex, data[index] == 0x6E {
                    for byte in Array("null".utf8) { try consume(byte) }
                } else {
                    passphrase = try readString()
                    if passphrase?.byteCount == 0 {
                        passphrase?.clear()
                        passphrase = nil
                    }
                }
            } else {
                throw KeychainSecretError.unexpectedValue
            }
            skipWhitespace()
            if index < data.endIndex, data[index] == 0x2C {
                index += 1
                continue
            }
            try consume(0x7D)
            skipWhitespace()
            guard index == data.endIndex, let privateKey else { throw KeychainSecretError.unexpectedValue }
            succeeded = true
            return .software(privateKey, passphrase: passphrase)
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
