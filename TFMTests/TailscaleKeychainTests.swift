import CTailscale
import Foundation
import Security
import TermindRemoteInfrastructure
import Testing

@Suite @MainActor
struct TailscaleKeychainTests {
    @Test func nativeStateUsesDataProtectionAndCleanupErasesOnlyTheSelectedProfile() async throws {
        let profiles = [UUID(), UUID()]
        let scopes = profiles.map { "com.akinokaede.termind.tailscale.\($0.uuidString)" }
        let keys = [
            "_machinekey", "profile-\(UUID().uuidString.prefix(4).lowercased())", "_current-profile", "_profiles",
        ]
        defer {
            for scope in scopes { SecItemDelete(query(scope) as CFDictionary) }
        }
        for scope in scopes {
            for key in keys {
                let status = scope.withCString { scope in
                    key.withCString { key in
                        "synthetic-state".withCString { lt_store_write(scope, key, $0, Int32(strlen($0))) }
                    }
                }
                try #require(status == errSecSuccess)
                var attributesQuery = query(scope)
                attributesQuery[kSecAttrAccount as String] = key
                attributesQuery[kSecReturnAttributes as String] = true
                var raw: CFTypeRef?
                try #require(SecItemCopyMatching(attributesQuery as CFDictionary, &raw) == errSecSuccess)
                let attributes = try #require(raw as? [String: Any])
                #expect(
                    attributes[kSecAttrAccessible as String] as? String
                        == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            }
        }
        try await LibTailscaleNodeSession.profileStorage.erase(profiles[0])
        for (index, scope) in scopes.enumerated() {
            for key in keys {
                var bytes: UnsafeMutableRawPointer?
                var count: Int32 = 0
                let status = scope.withCString { scope in
                    key.withCString { lt_store_read(scope, $0, &bytes, &count) }
                }
                defer { free(bytes) }
                #expect(status == (index == 0 ? errSecItemNotFound : errSecSuccess))
                if index == 1, let bytes {
                    #expect(Data(bytes: bytes, count: Int(count)) == Data("synthetic-state".utf8))
                }
            }
        }
        try await LibTailscaleNodeSession.profileStorage.erase(profiles[0])
        try await LibTailscaleNodeSession.profileStorage.erase(profiles[1])
        #expect(SecItemCopyMatching(query(scopes[1]) as CFDictionary, nil) == errSecItemNotFound)
    }

    private func query(_ scope: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: scope,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
