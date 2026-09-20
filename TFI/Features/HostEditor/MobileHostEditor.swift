import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

struct MobileHostEditor: View {
    private enum IdentityEditorRoute: String, Identifiable {
        case host
        case proxy

        var id: String { rawValue }
    }

    private enum Choice<ID: Hashable>: Hashable {
        case unset
        case existing(ID)
        case new
    }

    let app: MobileAppModel
    private var library: HostLibraryModel { app.library }
    let original: Host
    @State private var draft: Host
    @State private var identityEditorRoute: IdentityEditorRoute?

    init(app: MobileAppModel, host: Host) {
        self.app = app
        original = host
        _draft = State(initialValue: host)
    }

    var body: some View {
        MobileEditorSheet(
            title: String(localized: "Host"), isDirty: draft != original,
            canSave: MobileHostEditorPolicy.canSave(draft),
            save: {
                library.upsert(draft)
                if let error = library.storageError { throw MobileEditorError.message(error) }
            },
            content: {
                HostConnectionFields(host: $draft)
                Section("Authentication") {
                    Picker("Identity", selection: identityChoice) {
                        Text("None").tag(Choice<Identity.ID>.unset)
                        ForEach(library.identities) { identity in
                            Text(identity.name).tag(Choice.existing(identity.id))
                        }
                        Divider()
                        Text("New Identity").tag(Choice<Identity.ID>.new)
                    }
                }
                Section("Routing") {
                    Picker("Jump Host", selection: $draft.jumpHostID) {
                        Text("None").tag(UUID?.none)
                        ForEach(library.hosts.filter { $0.id != draft.id }) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Picker("Proxy", selection: proxyKind) {
                        Text("None").tag(HostProxy.ProtocolKind?.none)
                        ForEach(HostProxy.ProtocolKind.allCases) { kind in
                            Text(kind.displayName).tag(HostProxy.ProtocolKind?.some(kind))
                        }
                    }
                    if draft.proxy != nil {
                        LabeledContent("Hostname") {
                            TextField("Hostname", text: proxyString(\.hostname).singleLineText, axis: .horizontal)
                                .singleLinePaste()
                                .lineLimit(1)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .multilineTextAlignment(.trailing)
                        }
                        .accessibilityLabel("Proxy Hostname")
                        LabeledContent("Port") {
                            TextField("Port", value: proxyInt(\.port), format: .number.grouping(.never)).lineLimit(1)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                        .accessibilityLabel("Proxy Port")
                        Picker("Identity", selection: proxyIdentityChoice) {
                            Text("None").tag(Choice<Identity.ID>.unset)
                            ForEach(proxyIdentities) { identity in
                                Text("\(identity.name) · \(identity.username)")
                                    .tag(Choice.existing(identity.id))
                            }
                            Divider()
                            Text("New Identity").tag(Choice<Identity.ID>.new)
                        }
                        .accessibilityLabel("Proxy Identity")
                        if draft.proxy?.identityID != nil {
                            LabeledContent("Username") {
                                TextField("Username", text: proxyString(\.username).singleLineText, axis: .horizontal)
                                    .singleLinePaste()
                                    .lineLimit(1)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .multilineTextAlignment(.trailing)
                            }
                            .accessibilityLabel("Proxy Username")
                        }
                    }
                }
                Section("Color") {
                    ColorTagPicker(selection: $draft.colorTag, layout: .touch)
                }
                Section("Group") {
                    Picker("Group", selection: $draft.groupID) {
                        Text("None").tag(UUID?.none)
                        ForEach(library.groups) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                HostIntegrationSection(mode: $draft.shellIntegrationMode)
            }
        )
        .sheet(item: $identityEditorRoute) { route in
            switch route {
            case .host:
                MobileIdentityEditor(
                    app: app, identity: Identity(name: "", username: "")
                ) { identity in
                    draft = MobileHostEditorPolicy.selectIdentity(identity, current: draft)
                }
            case .proxy:
                MobileIdentityEditor(
                    app: app, identity: Identity(name: "", username: ""),
                    configuration: .proxy
                ) { identity in
                    draft.proxy = MobileHostEditorPolicy.selectProxyIdentity(identity, current: draft.proxy)
                }
            }
        }
    }

    private var identityChoice: Binding<Choice<Identity.ID>> {
        Binding {
            draft.identityID.map(Choice.existing) ?? .unset
        } set: { choice in
            switch choice {
            case .unset: draft.identityID = nil
            case .existing(let id): draft.identityID = id
            case .new: identityEditorRoute = .host
            }
        }
    }

    private var proxyKind: Binding<HostProxy.ProtocolKind?> {
        Binding {
            draft.proxy?.kind
        } set: { kind in
            draft.proxy = MobileHostEditorPolicy.selectProxy(kind, current: draft.proxy)
        }
    }

    private func proxyString(_ keyPath: WritableKeyPath<HostProxy, String>) -> Binding<String> {
        Binding(
            get: { draft.proxy?[keyPath: keyPath] ?? "" },
            set: { draft.proxy?[keyPath: keyPath] = $0 }
        )
    }

    private func proxyInt(_ keyPath: WritableKeyPath<HostProxy, Int>) -> Binding<Int> {
        Binding(
            get: { draft.proxy?[keyPath: keyPath] ?? 0 },
            set: { draft.proxy?[keyPath: keyPath] = $0 }
        )
    }

    private var proxyIdentityChoice: Binding<Choice<Identity.ID>> {
        Binding {
            draft.proxy?.identityID.map(Choice.existing) ?? .unset
        } set: { choice in
            switch choice {
            case .unset:
                draft.proxy = MobileHostEditorPolicy.selectProxyIdentity(nil, current: draft.proxy)
            case .existing(let id):
                draft.proxy = MobileHostEditorPolicy.selectProxyIdentity(library.identity(id), current: draft.proxy)
            case .new:
                identityEditorRoute = .proxy
            }
        }
    }

    private var proxyIdentities: [Identity] {
        library.identities.filter(library.isProxyEligibleOnThisDevice)
    }

}

nonisolated enum MobileHostEditorPolicy {
    static func selectIdentity(_ identity: Identity, current: Host) -> Host {
        var host = current
        host.identityID = identity.id
        return host
    }

    static func canSave(_ host: Host) -> Bool {
        !host.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1...65_535).contains(host.port)
            && (host.proxy?.isValid ?? true)
    }

    static func selectProxy(
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

    static func selectProxyIdentity(_ identity: Identity?, current: HostProxy?) -> HostProxy? {
        guard var proxy = current else { return nil }
        proxy.identityID = identity?.id
        proxy.username = identity?.username ?? ""
        return proxy
    }
}

nonisolated enum MobileEditorError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let value): value
        }
    }
}
