import Foundation
import TermindDomain

import struct TermindDomain.Host

/// Stable identity for the ordered selections owned by the Vault manager pages.
nonisolated struct VaultSelectionID: Hashable, Sendable, Identifiable {
    nonisolated enum Kind {
        static let host = "host"
        static let key = "key"
        static let identity = "identity"
        static let forwarding = "forwarding"
        static let snippet = "snippet"
        static let knownHost = "knownHost"
    }

    let kind: String
    let rawID: UUID
    let page: VaultPage

    nonisolated var id: Self { self }
    nonisolated func belongs(to page: VaultPage) -> Bool { self.page == page }

    nonisolated static func host(_ id: Host.ID) -> Self {
        Self(kind: Kind.host, rawID: id, page: .hosts)
    }

    nonisolated static func key(_ id: SSHKeyRef.ID) -> Self {
        Self(kind: Kind.key, rawID: id, page: .keychain)
    }

    nonisolated static func identity(_ id: Identity.ID) -> Self {
        Self(kind: Kind.identity, rawID: id, page: .keychain)
    }

    nonisolated static func snippet(_ id: Snippet.ID) -> Self {
        Self(kind: Kind.snippet, rawID: id, page: .snippets)
    }

    nonisolated static func knownHost(_ id: KnownHostEntry.ID) -> Self {
        Self(kind: Kind.knownHost, rawID: id, page: .knownHosts)
    }

    nonisolated static func forwarding(_ id: PortForwardingRule.ID) -> Self {
        Self(kind: Kind.forwarding, rawID: id, page: .portForwarding)
    }

    var forwardingID: PortForwardingRule.ID? { kind == Kind.forwarding ? rawID : nil }
    var knownHostID: KnownHostEntry.ID? { kind == Kind.knownHost ? rawID : nil }
    var hostID: Host.ID? { kind == Kind.host ? rawID : nil }
    var keyID: SSHKeyRef.ID? { kind == Kind.key ? rawID : nil }
    var identityID: Identity.ID? { kind == Kind.identity ? rawID : nil }
    var snippetID: Snippet.ID? { kind == Kind.snippet ? rawID : nil }
}

@Observable
final class VaultSelectionState {
    private var selections: [VaultPage: [VaultSelectionID]] = [:]

    func selection(for page: VaultPage) -> [VaultSelectionID] { selections[page] ?? [] }

    func set(_ items: [VaultSelectionID], for page: VaultPage) {
        var seen: Set<VaultSelectionID> = []
        selections[page] = items.filter {
            $0.belongs(to: page) && seen.insert($0).inserted
        }
    }

    func select(_ item: VaultSelectionID, on page: VaultPage) { set([item], for: page) }

    func toggle(_ item: VaultSelectionID, on page: VaultPage) {
        var items = selection(for: page)
        if let index = items.firstIndex(of: item) {
            items.remove(at: index)
        } else {
            items.append(item)
        }
        set(items, for: page)
    }

    func prune(available: Set<VaultSelectionID>, pages: Set<VaultPage> = Set(VaultPage.allCases)) {
        for page in pages {
            let valid = selection(for: page).filter(available.contains)
            if valid != selection(for: page) { selections[page] = valid }
        }
    }
}

/// The manager pages' query and confirmation state, held for the life of
/// the window rather than of the view.
///
/// Vault pages are torn down and rebuilt every time the destination changes, so
/// a `@State` inside the page loses its query the moment you look at something
/// else and come back. `HostsPageState` was already hoisted for that reason; the
/// window's one Find field makes the same true of Keychain and Snippets, because
/// the field lives in the titlebar and outlives every page under it.
@Observable
final class VaultPageStates {
    let hosts = HostsPageState()
    let keychain = KeychainPageState()
    let portForwarding = PortForwardingPageState()
    let snippets = SnippetsPageState()
    let knownHosts = KnownHostsPageState()
    let selection = VaultSelectionState()

    /// The query belonging to a page, or nil for Welcome, which searches hosts
    /// with its own in-page field.
    func query(for page: VaultPage) -> String {
        switch page {
        case .welcome: ""
        case .hosts: hosts.query
        case .keychain: keychain.query
        case .portForwarding: portForwarding.query
        case .snippets: snippets.query
        case .knownHosts: knownHosts.query
        }
    }
}
