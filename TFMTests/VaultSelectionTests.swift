// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite
@MainActor
struct VaultSelectionTests {
    @Test func forwardingLivesBetweenKeychainAndSnippetsWithIndependentSelectionAndSearch() {
        let pages = VaultPage.allCases
        #expect(pages.firstIndex(of: .portForwarding) == pages.firstIndex(of: .keychain).map { $0 + 1 })
        #expect(pages.firstIndex(of: .snippets) == pages.firstIndex(of: .portForwarding).map { $0 + 1 })
        let window = WindowModel()
        let id = UUID()
        window.selectVaultItem(.forwarding(id), on: .portForwarding)
        window.vaultPages.portForwarding.query = "Database"
        window.openPage(.keychain)
        window.openPage(.portForwarding)
        #expect(window.findKind == .portForwarding)
        #expect(window.findContext()?.query.wrappedValue == "Database")
        #expect(window.vaultSelection(for: .portForwarding) == [.forwarding(id)])
        #expect(window.creationActions(for: .portForwarding).count == 1)
        window.pruneVaultSelections(in: HostLibraryModel())
        #expect(window.vaultSelection(for: .portForwarding).isEmpty)
    }

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
