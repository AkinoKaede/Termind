import Foundation

/// The three manager pages' query and confirmation state, held for the life of
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
    let snippets = SnippetsPageState()

    /// The query belonging to a page, or nil for Welcome, which searches hosts
    /// with its own in-page field.
    func query(for page: VaultPage) -> String {
        switch page {
        case .welcome: ""
        case .hosts: hosts.query
        case .keychain: keychain.query
        case .snippets: snippets.query
        }
    }
}
