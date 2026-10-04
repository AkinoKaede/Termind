import SwiftUI
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

public enum HostEditorChoice<ID: Hashable>: Hashable {
    case unset
    case custom
    case existing(ID)
    case new
}

public enum HostEditorCreation: Equatable {
    case identity, telnetIdentity, proxyIdentity, telnetProxyIdentity, group
}

/// Shared form projections over an editor's existing drafts. This adapter owns
/// no state; platform editors retain draft lifetimes and creation navigation.
@MainActor
public struct HostEditorBindings {
    @Binding private var draft: Host
    @Binding private var customIdentity: HostCustomIdentityDraft
    private let library: HostLibraryModel
    private let create: (HostEditorCreation) -> Void

    public init(
        host: Binding<Host>, customIdentity: Binding<HostCustomIdentityDraft>,
        library: HostLibraryModel, create: @escaping (HostEditorCreation) -> Void
    ) {
        _draft = host
        _customIdentity = customIdentity
        self.library = library
        self.create = create
    }

    public var identityChoice: Binding<HostEditorChoice<Identity.ID>> {
        Binding {
            guard let id = draft.identityID, library.identity(id)?.isHostCustom != true else { return .unset }
            return .existing(id)
        } set: { choice in
            switch choice {
            case .unset, .custom:
                customIdentity.selectCustomSSH(on: &draft)
            case .existing(let id):
                guard let identity = library.identity(id) else { return }
                customIdentity.selectSSHIdentity(identity, on: &draft)
            case .new: create(.identity)
            }
        }
    }

    public var telnetIdentityChoice: Binding<HostEditorChoice<Identity.ID>> {
        Binding {
            if customIdentity.usesCustomTelnetSelection { return .custom }
            guard let id = draft.telnetIdentityID else { return .unset }
            return library.identity(id)?.isHostCustom == true ? .custom : .existing(id)
        } set: { choice in
            switch choice {
            case .unset:
                customIdentity.clearTelnetIdentity(on: &draft)
            case .custom:
                customIdentity.selectCustomTelnet(on: &draft)
            case .existing(let id):
                guard let identity = library.identity(id) else { return }
                customIdentity.selectTelnetIdentity(identity, on: &draft)
            case .new:
                create(.telnetIdentity)
            }
        }
    }

    public var groupChoice: Binding<HostEditorChoice<HostGroup.ID>> {
        Binding {
            draft.groupID.map(HostEditorChoice.existing) ?? .unset
        } set: { choice in
            switch choice {
            case .unset, .custom: draft.groupID = nil
            case .existing(let id): draft.groupID = id
            case .new: create(.group)
            }
        }
    }

    public var startupSnippetChoice: Binding<Snippet.ID?> {
        Binding {
            draft.startupSnippetID.flatMap { library.snippet($0)?.id }
        } set: {
            draft.startupSnippetID = $0
        }
    }

    public var proxyKind: Binding<HostProxy.ProtocolKind?> {
        Binding {
            draft.proxy?.kind
        } set: { kind in
            draft.proxy = Self.selectProxy(kind, current: draft.proxy)
        }
    }

    public var telnetProxyKind: Binding<HostProxy.ProtocolKind?> {
        Binding {
            draft.telnetProxy?.kind
        } set: { kind in
            draft.telnetProxy = Self.selectProxy(kind, current: draft.telnetProxy)
        }
    }

    public func proxyString(_ keyPath: WritableKeyPath<HostProxy, String>) -> Binding<String> {
        Binding(
            get: { draft.proxy?[keyPath: keyPath] ?? "" },
            set: { draft.proxy?[keyPath: keyPath] = $0 }
        )
    }

    public func proxyInt(_ keyPath: WritableKeyPath<HostProxy, Int>) -> Binding<Int> {
        Binding(
            get: { draft.proxy?[keyPath: keyPath] ?? 0 },
            set: { draft.proxy?[keyPath: keyPath] = $0 }
        )
    }

    public func telnetProxyString(_ keyPath: WritableKeyPath<HostProxy, String>) -> Binding<String> {
        Binding(
            get: { draft.telnetProxy?[keyPath: keyPath] ?? "" },
            set: { draft.telnetProxy?[keyPath: keyPath] = $0 })
    }

    public func telnetProxyInt(_ keyPath: WritableKeyPath<HostProxy, Int>) -> Binding<Int> {
        Binding(
            get: { draft.telnetProxy?[keyPath: keyPath] ?? 0 },
            set: { draft.telnetProxy?[keyPath: keyPath] = $0 })
    }

    public var proxyIdentityChoice: Binding<HostEditorChoice<Identity.ID>> {
        Binding {
            if customIdentity.usesCustomProxy { return .custom }
            return draft.proxy?.identityID.map(HostEditorChoice.existing) ?? .unset
        } set: { choice in
            switch choice {
            case .unset:
                customIdentity.clearProxyIdentity(on: &draft)
            case .custom:
                customIdentity.selectCustomProxy(on: &draft, using: library)
            case .existing(let id):
                guard let identity = library.identity(id) else { return }
                customIdentity.selectProxyIdentity(identity, on: &draft)
            case .new:
                create(.proxyIdentity)
            }
        }
    }

    public var telnetProxyIdentityChoice: Binding<HostEditorChoice<Identity.ID>> {
        Binding {
            if customIdentity.usesCustomTelnetProxy { return .custom }
            return draft.telnetProxy?.identityID.map(HostEditorChoice.existing) ?? .unset
        } set: { choice in
            switch choice {
            case .unset:
                customIdentity.clearTelnetProxyIdentity(on: &draft)
            case .custom:
                customIdentity.selectCustomTelnetProxy(on: &draft, using: library)
            case .existing(let id):
                guard let identity = library.identity(id) else { return }
                customIdentity.selectTelnetProxyIdentity(identity, on: &draft)
            case .new:
                create(.telnetProxyIdentity)
            }
        }
    }

    public static func selectProxy(
        _ kind: HostProxy.ProtocolKind?, current: HostProxy?
    ) -> HostProxy? {
        guard let kind else { return nil }
        guard var proxy = current else {
            return HostProxy(kind: kind, port: kind.defaultPort)
        }
        if proxy.kind != kind {
            let oldDefaultPort = proxy.kind.defaultPort
            proxy.kind = kind
            if proxy.port == oldDefaultPort { proxy.port = kind.defaultPort }
        }
        return proxy
    }
}
