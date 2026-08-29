import Foundation
import Testing

@testable import Termind

@Suite
@MainActor
struct VaultSelectionTests {
    @Test
    func selectionsAreOrderedDeduplicatedAndScopedPerPage() {
        let window = WindowModel()
        let first = VaultSelectionID.host(UUID())
        let second = VaultSelectionID.host(UUID())

        window.setVaultSelection([first, second, first, .key(UUID())], for: .hosts)
        window.selectVaultItem(.key(UUID()), on: .keychain)

        #expect(window.vaultSelection(for: .hosts) == [first, second])
        #expect(window.vaultSelection(for: .keychain).count == 1)
    }

    @Test
    func toggleSupportsMixedCredentialSelection() {
        let window = WindowModel()
        let key = VaultSelectionID.key(UUID())
        let identity = VaultSelectionID.identity(UUID())

        window.selectVaultItem(key, on: .keychain)
        window.toggleVaultItem(identity, on: .keychain)
        window.toggleVaultItem(key, on: .keychain)

        #expect(window.vaultSelection(for: .keychain) == [identity])
    }

    @Test
    func pruningRemovesDeletedObjectsAndKeepsValidSelection() {
        let host = Host(name: "Host", host: "host.example")
        let store = HostLibraryModel(hosts: [host])
        let window = WindowModel()
        window.setVaultSelection([.host(host.id), .host(UUID())], for: .hosts)

        window.pruneVaultSelections(in: store)

        #expect(window.vaultSelection(for: .hosts) == [.host(host.id)])
    }
}
