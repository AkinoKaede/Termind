import SwiftUI

struct ContextPanelEmptyState {
    let title: LocalizedStringKey
    let symbol: String
    let description: LocalizedStringKey
}

struct ContextPanelDetailPresentation: Identifiable {
    let id: ContextPanelDetailID
    let label: AnyView
    let content: AnyView
}

protocol ContextPanelDetailProvider {
    var kind: String { get }
    var page: VaultPage { get }
    var emptyState: ContextPanelEmptyState { get }
    var availableIDs: Set<ContextPanelDetailID> { get }
    func presentation(for id: ContextPanelDetailID) -> ContextPanelDetailPresentation?
}

/// Type-erased at the feature boundary so DetailSidebarView never imports or
/// switches over Host, Keychain, or Snippet models.
struct AnyContextPanelDetailProvider: ContextPanelDetailProvider {
    let kind: String
    let page: VaultPage
    let emptyState: ContextPanelEmptyState
    private let available: () -> Set<ContextPanelDetailID>
    private let resolve: (ContextPanelDetailID) -> ContextPanelDetailPresentation?

    init<P: ContextPanelDetailProvider>(_ provider: P) {
        kind = provider.kind
        page = provider.page
        emptyState = provider.emptyState
        available = { provider.availableIDs }
        resolve = provider.presentation
    }

    var availableIDs: Set<ContextPanelDetailID> { available() }

    func presentation(for id: ContextPanelDetailID) -> ContextPanelDetailPresentation? {
        guard id.kind == kind else { return nil }
        return resolve(id)
    }
}

struct ContextPanelDetailCatalog {
    private let providers: [AnyContextPanelDetailProvider]

    init(_ providers: [AnyContextPanelDetailProvider]) {
        self.providers = providers
        assert(Set(providers.map(\.kind)).count == providers.count)
    }

    var availableIDs: Set<ContextPanelDetailID> {
        providers.reduce(into: []) { $0.formUnion($1.availableIDs) }
    }

    func presentation(for id: ContextPanelDetailID) -> ContextPanelDetailPresentation? {
        providers.first { $0.kind == id.kind }?.presentation(for: id)
    }

    func emptyState(for page: VaultPage?) -> ContextPanelEmptyState {
        if let page, let state = providers.first(where: { $0.page == page })?.emptyState {
            return state
        }
        return ContextPanelEmptyState(
            title: "No Details", symbol: "sidebar.right",
            description: "Select an item, or open content attached to a host."
        )
    }

    static func standard(store: HostStore) -> Self {
        Self([
            AnyContextPanelDetailProvider(HostContextPanelDetailProvider(store: store)),
            AnyContextPanelDetailProvider(KeyContextPanelDetailProvider(store: store)),
            AnyContextPanelDetailProvider(IdentityContextPanelDetailProvider(store: store)),
            AnyContextPanelDetailProvider(SnippetContextPanelDetailProvider(store: store)),
        ])
    }
}

private struct HostContextPanelDetailProvider: ContextPanelDetailProvider {
    let store: HostStore
    let kind = ContextPanelDetailID.Kind.host
    let page = VaultPage.hosts
    let emptyState = ContextPanelEmptyState(
        title: "No Host Selected", symbol: "server.rack",
        description: "Select one or more hosts to inspect them."
    )

    var availableIDs: Set<ContextPanelDetailID> { Set(store.hosts.map { .host($0.id) }) }

    func presentation(for id: ContextPanelDetailID) -> ContextPanelDetailPresentation? {
        guard let hostID = id.hostID, let host = store.host(hostID) else { return nil }
        return ContextPanelDetailPresentation(
            id: id,
            label: AnyView(
                ContextPanelDetailLabel {
                    StatusDot(status: store.status(of: hostID))
                } title: {
                    ContextPanelDetailTitle(
                        title: host.name, subtitle: store.loginAddress(for: host)
                    )
                }
            ),
            content: AnyView(HostDetailContent(host: host))
        )
    }
}

private struct KeyContextPanelDetailProvider: ContextPanelDetailProvider {
    let store: HostStore
    let kind = ContextPanelDetailID.Kind.key
    let page = VaultPage.keychain
    let emptyState = ContextPanelEmptyState(
        title: "No Key or Identity Selected", symbol: "key.fill",
        description: "Select keys or identities to inspect them."
    )

    var availableIDs: Set<ContextPanelDetailID> { Set(store.keys.map { .key($0.id) }) }

    func presentation(for id: ContextPanelDetailID) -> ContextPanelDetailPresentation? {
        guard let keyID = id.keyID, let key = store.key(keyID) else { return nil }
        return ContextPanelDetailPresentation(
            id: id,
            label: AnyView(
                ContextPanelDetailLabel {
                    Image(systemName: "key.fill").foregroundStyle(.orange)
                } title: {
                    ContextPanelDetailTitle(title: key.label, subtitle: key.fingerprint)
                }
            ),
            content: AnyView(KeyContextPanelDetailView(key: key))
        )
    }
}

private struct IdentityContextPanelDetailProvider: ContextPanelDetailProvider {
    let store: HostStore
    let kind = ContextPanelDetailID.Kind.identity
    let page = VaultPage.keychain
    let emptyState = ContextPanelEmptyState(
        title: "No Key or Identity Selected", symbol: "key.fill",
        description: "Select keys or identities to inspect them."
    )

    var availableIDs: Set<ContextPanelDetailID> {
        Set(store.identities.map { .identity($0.id) })
    }

    func presentation(for id: ContextPanelDetailID) -> ContextPanelDetailPresentation? {
        guard let identityID = id.identityID, let identity = store.identity(identityID) else {
            return nil
        }
        return ContextPanelDetailPresentation(
            id: id,
            label: AnyView(
                ContextPanelDetailLabel {
                    Image(systemName: "person.badge.key.fill").foregroundStyle(.accent)
                } title: {
                    ContextPanelDetailTitle(title: identity.name, subtitle: identity.username)
                }
            ),
            content: AnyView(IdentityContextPanelDetailView(identity: identity))
        )
    }
}

private struct SnippetContextPanelDetailProvider: ContextPanelDetailProvider {
    let store: HostStore
    let kind = ContextPanelDetailID.Kind.snippet
    let page = VaultPage.snippets
    let emptyState = ContextPanelEmptyState(
        title: "No Snippet Selected", symbol: "text.badge.plus",
        description: "Select a snippet to inspect it."
    )

    var availableIDs: Set<ContextPanelDetailID> {
        Set(store.snippets.map { .snippet($0.id) })
    }

    func presentation(for id: ContextPanelDetailID) -> ContextPanelDetailPresentation? {
        guard let snippetID = id.snippetID, let snippet = store.snippet(snippetID) else {
            return nil
        }
        return ContextPanelDetailPresentation(
            id: id,
            label: AnyView(
                ContextPanelDetailLabel {
                    Image(systemName: "text.badge.plus").foregroundStyle(.accent)
                } title: {
                    ContextPanelDetailTitle(title: snippet.title, subtitle: snippet.body)
                }
            ),
            content: AnyView(SnippetContextPanelDetailView(snippet: snippet))
        )
    }
}

private struct ContextPanelDetailLabel<Icon: View, Title: View>: View {
    @ViewBuilder let icon: Icon
    @ViewBuilder let title: Title

    var body: some View {
        HStack(spacing: Metrics.Space.m) {
            icon
            title
        }
    }
}

private struct ContextPanelDetailTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.headline).lineLimit(1)
            Text(subtitle)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct KeyContextPanelDetailView: View {
    let key: SSHKeyRef
    @Environment(WindowModel.self) private var window
    @State private var isExporting = false

    var body: some View {
        KeyDetailContent(
            key: key,
            edit: { window.openVaultWork(.editKey(key.id), on: .keychain) },
            export: { isExporting = true }
        )
        .sheet(isPresented: $isExporting) { ExportKeyToHostsSheet(keys: [key]) }
    }
}

private struct IdentityContextPanelDetailView: View {
    let identity: Identity
    @Environment(AppModel.self) private var app
    @State private var isEditing = false

    var body: some View {
        IdentityDetailContent(identity: identity) { isEditing = true }
            .sheet(isPresented: $isEditing) {
                NewIdentitySheet(identity: identity) { updated, passwordUpdate in
                    try app.hosts.upsert(updated, passwordUpdate: passwordUpdate)
                }
            }
    }
}

private struct SnippetContextPanelDetailView: View {
    let snippet: Snippet

    var body: some View {
        SnippetDetailContent(snippet: snippet)
    }
}
