import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

struct MobileHostEditor: View {
    private enum EditorRoute: String, Identifiable {
        case hostIdentity
        case proxyIdentity
        case group

        var id: String { rawValue }
    }

    private enum Choice<ID: Hashable>: Hashable {
        case unset
        case custom
        case existing(ID)
        case new
    }

    let app: MobileAppModel
    private var library: HostLibraryModel { app.library }
    let original: Host
    @State private var draft: Host
    @State private var editorRoute: EditorRoute?
    @State private var customUsername = ""
    @State private var customPassword = ""
    @State private var customKeyID: SSHKeyRef.ID?
    @State private var proxyUsesCustom = false
    @State private var proxyCustomPassword = ""
    @State private var didLoadCustom = false

    init(app: MobileAppModel, host: Host) {
        self.app = app
        original = host
        _draft = State(initialValue: host)
    }

    var body: some View {
        MobileEditorSheet(
            title: String(localized: "Host"),
            isDirty: draft != original || !customUsername.isEmpty || !customPassword.isEmpty || customKeyID != nil,
            canSave: MobileHostEditorPolicy.canSave(draft) && customIsValid && proxyIsValid,
            save: {
                if usesCustomIdentity {
                    let identity = try library.saveCustomIdentity(
                        ownerHostID: draft.id, purpose: .ssh, displayName: draft.name,
                        username: customUsername, password: customPassword, keyID: customKeyID)
                    draft.identityID = identity?.id
                }
                if proxyUsesCustom, let proxy = draft.proxy {
                    let identity = try library.saveCustomIdentity(
                        ownerHostID: draft.id, purpose: .proxy, displayName: "\(draft.name) Proxy",
                        username: proxy.username, password: proxyCustomPassword, keyID: nil)
                    draft.proxy?.identityID = identity?.id
                } else if draft.proxy == nil {
                    _ = try library.saveCustomIdentity(
                        ownerHostID: draft.id, purpose: .proxy, displayName: "",
                        username: "", password: "", keyID: nil)
                }
                library.upsert(draft)
                if let error = library.storageError { throw MobileEditorError.message(error) }
            },
            content: {
                HostConnectionFields(host: $draft)
                Section("Authentication") {
                    Picker("Identity", selection: identityChoice) {
                        Text("Custom").tag(Choice<Identity.ID>.unset)
                        Divider()
                        ForEach(library.reusableIdentities) { identity in
                            Text(identity.name).tag(Choice.existing(identity.id))
                        }
                        Divider()
                        Text("New Identity").tag(Choice<Identity.ID>.new)
                    }
                    if usesCustomIdentity {
                        LabeledContent("Username") {
                            TextField("Username", text: $customUsername.singleLineText)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("Password") {
                            RevealableSecretField("Optional", text: $customPassword)
                                .multilineTextAlignment(.trailing)
                                .disabled(!customPasswordEditable)
                        }
                        Picker("Key", selection: $customKeyID) {
                            Text("None").tag(SSHKeyRef.ID?.none)
                            ForEach(library.keys) { key in Text(key.label).tag(SSHKeyRef.ID?.some(key.id)) }
                        }
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
                            Text("Custom").tag(Choice<Identity.ID>.custom)
                            Divider()
                            ForEach(proxyIdentities) { identity in
                                Text("\(identity.name) · \(identity.username)")
                                    .tag(Choice.existing(identity.id))
                            }
                            Divider()
                            Text("New Identity").tag(Choice<Identity.ID>.new)
                        }
                        .accessibilityLabel("Proxy Identity")
                        if proxyUsesCustom {
                            LabeledContent("Username") {
                                TextField("Username", text: proxyString(\.username).singleLineText)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .multilineTextAlignment(.trailing)
                            }
                            LabeledContent("Password") {
                                RevealableSecretField("Required", text: $proxyCustomPassword)
                                    .multilineTextAlignment(.trailing)
                                    .disabled(!proxyCustomPasswordEditable)
                            }
                        } else if draft.proxy?.identityID != nil {
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
                Section("Organization") {
                    Picker("Group", selection: groupChoice) {
                        Text("None").tag(Choice<HostGroup.ID>.unset)
                        ForEach(library.groups) { group in
                            Text(group.name).tag(Choice.existing(group.id))
                        }
                        Divider()
                        Text("New Group").tag(Choice<HostGroup.ID>.new)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Color")
                        ColorTagPicker(selection: $draft.colorTag, layout: .touch)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tags")
                        MobileTagField(tags: $draft.tags, suggestions: library.allTags)
                    }
                }
                HostIntegrationSection(mode: $draft.shellIntegrationMode)
            }
        )
        .sheet(item: $editorRoute) { route in
            switch route {
            case .hostIdentity:
                MobileIdentityEditor(
                    app: app,
                    identity: Identity(
                        name: "", username: "",
                        passwordStorage: app.newVaultPasswordStorage)
                ) { identity in
                    draft = MobileHostEditorPolicy.selectIdentity(identity, current: draft)
                }
            case .proxyIdentity:
                MobileIdentityEditor(
                    app: app,
                    identity: Identity(
                        name: "", username: "",
                        passwordStorage: app.newVaultPasswordStorage),
                    configuration: .proxy
                ) { identity in
                    draft.proxy = MobileHostEditorPolicy.selectProxyIdentity(identity, current: draft.proxy)
                }
            case .group:
                MobileHostGroupEditor(app: app, group: nil, parentID: nil) { group in
                    draft.groupID = group.id
                }
            }
        }
        .onAppear(perform: loadCustomOnce)
    }

    private var identityChoice: Binding<Choice<Identity.ID>> {
        Binding {
            guard let id = draft.identityID, library.identity(id)?.isHostCustom != true else { return .unset }
            return .existing(id)
        } set: { choice in
            switch choice {
            case .unset, .custom:
                draft.identityID = library.customIdentity(for: draft.id, purpose: .ssh)?.id
            case .existing(let id): draft.identityID = id
            case .new: editorRoute = .hostIdentity
            }
        }
    }

    private var groupChoice: Binding<Choice<HostGroup.ID>> {
        Binding {
            draft.groupID.map(Choice.existing) ?? .unset
        } set: { choice in
            switch choice {
            case .unset, .custom: draft.groupID = nil
            case .existing(let id): draft.groupID = id
            case .new: editorRoute = .group
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
            if proxyUsesCustom { return .custom }
            return draft.proxy?.identityID.map(Choice.existing) ?? .unset
        } set: { choice in
            switch choice {
            case .unset:
                proxyUsesCustom = false
                draft.proxy = MobileHostEditorPolicy.selectProxyIdentity(nil, current: draft.proxy)
            case .custom:
                proxyUsesCustom = true
                let custom = library.customIdentity(for: draft.id, purpose: .proxy)
                draft.proxy = MobileHostEditorPolicy.selectProxyIdentity(custom, current: draft.proxy)
                loadProxyPassword(custom)
            case .existing(let id):
                proxyUsesCustom = false
                draft.proxy = MobileHostEditorPolicy.selectProxyIdentity(library.identity(id), current: draft.proxy)
            case .new:
                editorRoute = .proxyIdentity
            }
        }
    }

    private var proxyIdentities: [Identity] {
        library.reusableIdentities.filter(library.isProxyEligibleOnThisDevice)
    }

    private var usesCustomIdentity: Bool {
        guard let id = draft.identityID else { return true }
        return library.identity(id)?.isHostCustom == true
    }

    private var customPasswordEditable: Bool {
        guard let identity = library.customIdentity(for: draft.id, purpose: .ssh), identity.usesPassword else {
            return true
        }
        return library.passwordAvailability(for: identity) == .available
    }

    private var proxyCustomPasswordEditable: Bool {
        guard let identity = library.customIdentity(for: draft.id, purpose: .proxy), identity.usesPassword else {
            return true
        }
        return library.passwordAvailability(for: identity) == .available
    }

    private var customIsValid: Bool {
        !usesCustomIdentity
            || (!customUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (customPassword.isEmpty && customKeyID == nil))
    }

    private var proxyIsValid: Bool {
        guard let proxy = draft.proxy else { return true }
        guard proxyUsesCustom else { return proxy.isValid }
        let empty =
            proxy.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && proxyCustomPassword.isEmpty
        return !proxy.hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1...65_535).contains(proxy.port)
            && (empty
                || (!proxy.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !proxyCustomPassword.isEmpty))
    }

    private func loadCustomOnce() {
        guard !didLoadCustom else { return }
        didLoadCustom = true
        let custom = library.customIdentity(for: draft.id, purpose: .ssh)
        customUsername = custom?.username ?? ""
        customKeyID = custom?.keyID
        if let custom, case .available = library.passwordAvailability(for: custom) {
            customPassword = (try? library.editablePassword(for: custom)) ?? ""
        }
        if let custom = library.customIdentity(for: draft.id, purpose: .proxy),
            draft.proxy?.identityID == custom.id
        {
            proxyUsesCustom = true
            loadProxyPassword(custom)
        }
    }

    private func loadProxyPassword(_ identity: Identity?) {
        proxyCustomPassword = ""
        guard let identity, case .available = library.passwordAvailability(for: identity) else { return }
        proxyCustomPassword = (try? library.editablePassword(for: identity)) ?? ""
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
