import SwiftUI

/// A page inside the fixed Vault workspace. Settings is intentionally absent because
/// it is a native singleton macOS window.
nonisolated enum VaultPage: String, Hashable, Sendable, CaseIterable, Identifiable {
    case welcome
    case hosts
    case keychain
    case snippets

    nonisolated var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .welcome: "Welcome"
        case .hosts: "Hosts"
        case .keychain: "Keychain"
        case .snippets: "Snippets"
        }
    }

    func title(locale: Locale = .current) -> String {
        switch self {
        case .welcome: AppLocalization.string("Welcome", locale: locale)
        case .hosts: AppLocalization.string("Hosts", locale: locale)
        case .keychain: AppLocalization.string("Keychain", locale: locale)
        case .snippets: AppLocalization.string("Snippets", locale: locale)
        }
    }

    var symbol: String {
        switch self {
        case .welcome: "house"
        case .hosts: "server.rack"
        case .keychain: "key.fill"
        case .snippets: "curlybraces"
        }
    }
}

nonisolated enum VaultDestination: Hashable, Sendable {
    case welcome
    case hosts
    case keychain
    case snippets

    init(page: VaultPage) {
        switch page {
        case .welcome: self = .welcome
        case .hosts: self = .hosts
        case .keychain: self = .keychain
        case .snippets: self = .snippets
        }
    }

    var page: VaultPage? {
        switch self {
        case .welcome: .welcome
        case .hosts: .hosts
        case .keychain: .keychain
        case .snippets: .snippets
        }
    }
}

/// A deliberate task opened in Vault's third column. Card selection remains a
/// middle-column concern; only explicit New, Edit, Export and Execute actions
/// create a work route.
nonisolated enum VaultWorkRoute: Hashable, Sendable {
    case hostEditor(Host.ID?)
    case hostGroupEditor(groupID: HostGroup.ID?, parentID: HostGroup.ID?)
    case identityEditor(Identity.ID?)
    case generateKey
    case importKey
    case editKey(SSHKeyRef.ID)
    case exportKeys([SSHKeyRef.ID])
    case snippetEditor(snippetID: Snippet.ID?, packageID: SnippetPackage.ID?)
    case snippetPackageEditor(packageID: SnippetPackage.ID?, parentID: SnippetPackage.ID?)
    case snippetExecutionTargets(SnippetHostChooserRequest)
}

/// The top-level workspace selection for one window. Vault, Assistant, and Settings
/// have no close lifecycle; only Workspace entries are dynamic.
nonisolated enum WindowDestination: Hashable, Sendable {
    case vault
    case assistant
    case settings
    case workspace(Workspace.ID)
}
