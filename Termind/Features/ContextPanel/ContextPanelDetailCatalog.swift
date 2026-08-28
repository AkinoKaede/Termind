import Foundation

protocol ContextPanelDetailProvider {
    var kind: String { get }
    var availableIDs: Set<ContextPanelDetailID> { get }
}

struct AnyContextPanelDetailProvider: ContextPanelDetailProvider {
    let kind: String
    private let available: () -> Set<ContextPanelDetailID>

    init<P: ContextPanelDetailProvider>(_ provider: P) {
        kind = provider.kind
        available = { provider.availableIDs }
    }

    var availableIDs: Set<ContextPanelDetailID> { available() }
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

    static func standard(store: HostLibraryModel) -> Self {
        Self([
            AnyContextPanelDetailProvider(HostContextPanelDetailProvider(store: store)),
            AnyContextPanelDetailProvider(KeyContextPanelDetailProvider(store: store)),
            AnyContextPanelDetailProvider(IdentityContextPanelDetailProvider(store: store)),
            AnyContextPanelDetailProvider(SnippetContextPanelDetailProvider(store: store)),
        ])
    }
}

private struct HostContextPanelDetailProvider: ContextPanelDetailProvider {
    let store: HostLibraryModel
    let kind = ContextPanelDetailID.Kind.host
    var availableIDs: Set<ContextPanelDetailID> { Set(store.hosts.map { .host($0.id) }) }
}

private struct KeyContextPanelDetailProvider: ContextPanelDetailProvider {
    let store: HostLibraryModel
    let kind = ContextPanelDetailID.Kind.key
    var availableIDs: Set<ContextPanelDetailID> { Set(store.keys.map { .key($0.id) }) }
}

private struct IdentityContextPanelDetailProvider: ContextPanelDetailProvider {
    let store: HostLibraryModel
    let kind = ContextPanelDetailID.Kind.identity
    var availableIDs: Set<ContextPanelDetailID> {
        Set(store.identities.map { .identity($0.id) })
    }
}

private struct SnippetContextPanelDetailProvider: ContextPanelDetailProvider {
    let store: HostLibraryModel
    let kind = ContextPanelDetailID.Kind.snippet
    var availableIDs: Set<ContextPanelDetailID> {
        Set(store.snippets.map { .snippet($0.id) })
    }
}
