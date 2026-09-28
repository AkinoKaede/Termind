import AgentKit
import Foundation
import Security
import TermindApplication
import TermindRemoteInfrastructure
import Testing

@testable import Termind

@Suite @MainActor
struct MCPAuthorizationKeychainTests {
    @Test func nativeKeychainKeepsOAuthInAnIndependentDeviceOnlyService() throws {
        let server = MCPServer(name: "Keychain fixture", url: "https://keychain-fixture.invalid/mcp")
        let store = MCPKeychainCredentialStore(accessGroup: ApplicationIdentity.keychainAccessGroup)
        defer { try? store.remove(serverID: server.id) }
        var grant = MCPOAuthCredential(
            resource: server.url, issuer: "https://keychain-fixture.invalid", configuration: .init(),
            clientID: "fixture",
            tokenEndpoint: URL(string: "https://keychain-fixture.invalid/token")!, accessToken: "synthetic-access",
            refreshToken: "synthetic-refresh")
        try store.setCredentials([grant], for: server.id)
        try store.setClientSecret("synthetic-client-secret", for: server)
        #expect(try store.credentials(for: server.id) == [grant])
        #expect(try store.clientSecret(for: server) == "synthetic-client-secret")
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.akinokaede.termind.mcp-oauth.v1",
            kSecAttrAccount as String: "termind.mcp.oauth.\(server.id.uuidString).grants",
            kSecAttrAccessGroup as String: ApplicationIdentity.keychainAccessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
        ]
        var raw: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &raw) == errSecSuccess)
        let attributes = try #require(raw as? [String: Any])
        #expect(
            attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                as String)
        query[kSecAttrSynchronizable as String] = true
        #expect(SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound)
        grant.refreshToken = "synthetic-rotated"
        try store.setCredentials([grant], for: server.id)
        #expect(try store.credentials(for: server.id).first?.refreshToken == "synthetic-rotated")
        try store.remove(serverID: server.id)
        #expect(try store.credentials(for: server.id).isEmpty)
        #expect(try store.clientSecret(for: server) == nil)
    }
}
