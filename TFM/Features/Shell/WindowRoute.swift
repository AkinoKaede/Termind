import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

/// A page inside the fixed Vault workspace. Settings is intentionally absent because
/// it is a native singleton macOS window.
nonisolated enum VaultPage: String, Hashable, Sendable, CaseIterable, Identifiable {
    case welcome
    case hosts
    case keychain
    case portForwarding
    case snippets
    case knownHosts

    nonisolated var id: String { rawValue }

    var label: LocalizedStringResource {
        switch self {
        case .welcome: TermindCopy.Navigation.welcome
        case .hosts: TermindCopy.Vault.hosts
        case .keychain: TermindCopy.Navigation.keychain
        case .portForwarding: TermindCopy.Navigation.portForwarding
        case .snippets: TermindCopy.Navigation.snippets
        case .knownHosts: TermindCopy.Navigation.knownHosts
        }
    }

    func title(locale: Locale = .current) -> String {
        switch self {
        case .welcome: AppLocalization.resolve(TermindCopy.Navigation.welcome, locale: locale)
        case .hosts: AppLocalization.resolve(TermindCopy.Vault.hosts, locale: locale)
        case .keychain: AppLocalization.resolve(TermindCopy.Navigation.keychain, locale: locale)
        case .portForwarding: AppLocalization.resolve(TermindCopy.Navigation.portForwarding, locale: locale)
        case .snippets: AppLocalization.resolve(TermindCopy.Navigation.snippets, locale: locale)
        case .knownHosts: AppLocalization.resolve(TermindCopy.Navigation.knownHosts, locale: locale)
        }
    }

    var symbol: String {
        switch self {
        case .welcome: "house"
        case .hosts: "server.rack"
        case .keychain: "key.fill"
        case .portForwarding: "arrow.left.arrow.right"
        case .snippets: "curlybraces"
        case .knownHosts: "touchid"
        }
    }
}

nonisolated enum VaultDestination: Hashable, Sendable {
    case welcome
    case hosts
    case keychain
    case portForwarding
    case snippets
    case knownHosts

    init(page: VaultPage) {
        switch page {
        case .welcome: self = .welcome
        case .hosts: self = .hosts
        case .keychain: self = .keychain
        case .portForwarding: self = .portForwarding
        case .snippets: self = .snippets
        case .knownHosts: self = .knownHosts
        }
    }

    var page: VaultPage? {
        switch self {
        case .welcome: .welcome
        case .hosts: .hosts
        case .keychain: .keychain
        case .portForwarding: .portForwarding
        case .snippets: .snippets
        case .knownHosts: .knownHosts
        }
    }
}

/// A deliberate task opened in Vault's third column. Card selection remains a
/// middle-column concern; only explicit New, Edit, Export and Execute actions
/// create a work route.
nonisolated enum VaultWorkRoute: Hashable, Sendable {
    case hostEditor(Host.ID?, groupID: HostGroup.ID? = nil)
    case hostGroupEditor(groupID: HostGroup.ID?, parentID: HostGroup.ID?)
    case forwardingEditor(PortForwardingRule.ID?)
    case identityEditor(Identity.ID?)
    case generateKey
    case importKey
    case knownHostEditor(KnownHostEntry.ID?)
    case sshImport(knownHostsOnly: Bool)
    case editKey(SSHKeyRef.ID)
    case exportKeys([SSHKeyRef.ID])
    case snippetEditor(snippetID: Snippet.ID?, packageID: SnippetPackage.ID?)
    case snippetPackageEditor(packageID: SnippetPackage.ID?, parentID: SnippetPackage.ID?)
    case snippetExecutionTargets(SnippetHostChooserRequest)
}

/// The top-level workspace selection for one window. Vault, Assistant, and Settings
/// have no close lifecycle; only Workspace entries are dynamic.
nonisolated enum WindowDestination: Hashable, Sendable {
    case metrics
    case vault
    case assistant
    case settings
    case workspace(Workspace.ID)
}
