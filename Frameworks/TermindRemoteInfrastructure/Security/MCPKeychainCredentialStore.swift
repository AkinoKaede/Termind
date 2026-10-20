// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import Security
import TermindApplication
import TermindDomain

/// Grants and client secrets are deliberately outside `termind.ai.*` and its iCloud migration.
@MainActor
public final class MCPKeychainCredentialStore: MCPAuthorizationStoring {
    private let read: (String) throws -> String?
    private let write: (String?, String) throws -> Void

    public init(accessGroup: String) {
        let keychain = DeviceKeychain(accessGroup: accessGroup)
        read = { try keychain.read($0) }
        write = { try keychain.write($0, account: $1) }
    }

    init(keychain: any SecretStoring) {
        read = { try keychain.string(for: $0, storage: .thisDevice) }
        write = { try keychain.setString($0, for: $1, storage: .thisDevice) }
    }

    public func credentials(for serverID: UUID) throws -> [MCPOAuthCredential] {
        guard let string = try read(key(serverID, "grants")) else { return [] }
        return try JSONDecoder().decode([MCPOAuthCredential].self, from: Data(string.utf8))
    }

    public func setCredentials(_ credentials: [MCPOAuthCredential], for serverID: UUID) throws {
        let value = credentials.isEmpty ? nil : String(decoding: try JSONEncoder().encode(credentials), as: UTF8.self)
        try write(value, key(serverID, "grants"))
    }

    private struct ClientSecret: Codable {
        let url: String
        let configuration: MCPOAuthConfiguration?
        let value: String
    }

    public func clientSecret(for server: MCPServer) throws -> String? {
        guard let string = try read(key(server.id, "client")) else { return nil }
        let value = try JSONDecoder().decode(ClientSecret.self, from: Data(string.utf8))
        guard value.url == server.url, value.configuration == server.oauth else { return nil }
        return value.value
    }

    public func setClientSecret(_ value: String?, for server: MCPServer) throws {
        let string = try value.map {
            String(
                decoding: try JSONEncoder().encode(
                    ClientSecret(url: server.url, configuration: server.oauth, value: $0)), as: UTF8.self)
        }
        try write(string, key(server.id, "client"))
    }

    public func remove(serverID: UUID) throws {
        try write(nil, key(serverID, "grants"))
        try write(nil, key(serverID, "client"))
    }

    private func key(_ id: UUID, _ kind: String) -> String { "termind.mcp.oauth.\(id.uuidString).\(kind)" }
}

/// A separate Data Protection Keychain service; no query can reach synchronized AI or SSH secrets.
private struct DeviceKeychain {
    let accessGroup: String
    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.akinokaede.termind.mcp-oauth.v1",
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func read(_ account: String) throws -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainSecretError.status(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainSecretError.unexpectedValue
        }
        return value
    }

    func write(_ value: String?, account: String) throws {
        let query = query(account)
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainSecretError.status(status)
            }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainSecretError.status(status) }
        let added = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainSecretError.status(added) }
    }
}
