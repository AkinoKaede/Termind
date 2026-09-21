import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

struct MobileHostEditor: View {
    private enum EditorRoute: Hashable, Identifiable {
        case hostIdentity
        case proxyIdentity
        case group
        case environmentVariable(Int?)

        var id: Self { self }
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
    @State private var customIdentity = HostCustomIdentityDraft()
    @State private var didLoadCustom = false

    init(app: MobileAppModel, host: Host) {
        self.app = app
        original = host
        _draft = State(initialValue: host)
    }

    var body: some View {
        MobileEditorSheet(
            title: String(localized: "Host"),
            isDirty: draft != original || !customIdentity.sshUsername.isEmpty
                || !customIdentity.sshPassword.isEmpty || customIdentity.sshKeyID != nil,
            canSave: !draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (1...65_535).contains(draft.port)
                && customIdentity.isSSHValid(for: draft)
                && customIdentity.isProxyValid(for: draft)
                && draft.environmentVariablesAreValid,
            save: {
                try customIdentity.save(into: &draft, using: library)
            },
            content: {
                HostOrganizationSection(host: $draft) {
                    Picker("Group", selection: groupChoice) {
                        Text("None").tag(Choice<HostGroup.ID>.unset)
                        ForEach(library.groups) { group in
                            Text(group.name).tag(Choice.existing(group.id))
                        }
                        Divider()
                        Text("New Group").tag(Choice<HostGroup.ID>.new)
                    }
                } tagsField: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tags")
                        MobileTagField(tags: $draft.tags, suggestions: library.allTags)
                    }
                }
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
                            TextField("Username", text: $customIdentity.sshUsername.singleLineText)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("Password") {
                            RevealableSecretField("Optional", text: $customIdentity.sshPassword)
                                .multilineTextAlignment(.trailing)
                                .disabled(!customIdentity.sshPasswordIsEditable)
                        }
                        Picker("Key", selection: $customIdentity.sshKeyID) {
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
                        if customIdentity.usesCustomProxy {
                            LabeledContent("Username") {
                                TextField("Username", text: proxyString(\.username).singleLineText)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .multilineTextAlignment(.trailing)
                            }
                            LabeledContent("Password") {
                                RevealableSecretField("Required", text: $customIdentity.proxyPassword)
                                    .multilineTextAlignment(.trailing)
                                    .disabled(!customIdentity.proxyPasswordIsEditable)
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
                HostSessionSection(
                    sftpInitialPath: $draft.sftpChannelInitialPath,
                    startupSnippetID: startupSnippetChoice,
                    environmentVariables: $draft.environmentVariables,
                    snippets: library.snippets,
                    snippetPackagePath: library.snippetPackagePath,
                    editEnvironmentVariable: { editorRoute = .environmentVariable($0) }
                )
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
                    customIdentity.selectSSHIdentity(identity, on: &draft)
                }
            case .proxyIdentity:
                MobileIdentityEditor(
                    app: app,
                    identity: Identity(
                        name: "", username: "",
                        passwordStorage: app.newVaultPasswordStorage),
                    configuration: .proxy
                ) { identity in
                    customIdentity.selectProxyIdentity(identity, on: &draft)
                }
            case .group:
                MobileHostGroupEditor(app: app, group: nil, parentID: nil) { group in
                    draft.groupID = group.id
                }
            case .environmentVariable(let index):
                MobileHostEnvironmentVariableEditor(
                    variable: index.map { draft.environmentVariables[$0] },
                    usedVariables: Set(
                        draft.environmentVariables.indices.compactMap {
                            $0 == index ? nil : draft.environmentVariables[$0].variable
                        })
                ) { variable in
                    if let index {
                        draft.environmentVariables[index] = variable
                    } else {
                        draft.environmentVariables.append(variable)
                    }
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
                customIdentity.selectCustomSSH(on: &draft)
            case .existing(let id):
                guard let identity = library.identity(id) else { return }
                customIdentity.selectSSHIdentity(identity, on: &draft)
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

    private var startupSnippetChoice: Binding<Snippet.ID?> {
        Binding {
            draft.startupSnippetID.flatMap { library.snippet($0)?.id }
        } set: {
            draft.startupSnippetID = $0
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
            if customIdentity.usesCustomProxy { return .custom }
            return draft.proxy?.identityID.map(Choice.existing) ?? .unset
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
                editorRoute = .proxyIdentity
            }
        }
    }

    private var proxyIdentities: [Identity] {
        library.reusableIdentities.filter(library.isProxyEligibleOnThisDevice)
    }

    private var usesCustomIdentity: Bool {
        customIdentity.usesCustomSSH(for: draft)
    }

    private func loadCustomOnce() {
        guard !didLoadCustom else { return }
        didLoadCustom = true
        customIdentity = HostCustomIdentityDraft(host: draft, library: library)
    }

}

private struct MobileHostEnvironmentVariableEditor: View {
    let original: HostEnvironmentVariable
    let isNew: Bool
    let usedVariables: Set<String>
    let didSave: (HostEnvironmentVariable) -> Void
    @State private var draft: HostEnvironmentVariable

    init(
        variable: HostEnvironmentVariable?, usedVariables: Set<String>,
        didSave: @escaping (HostEnvironmentVariable) -> Void
    ) {
        let initial = variable ?? HostEnvironmentVariable(variable: "", value: "")
        original = initial
        isNew = variable == nil
        self.usedVariables = usedVariables
        self.didSave = didSave
        _draft = State(initialValue: initial)
    }

    var body: some View {
        MobileEditorSheet(
            title: String(localized: isNew ? "New Environment Variable" : "Edit Environment Variable"),
            isDirty: draft != original,
            canSave: draft.isValid && !usedVariables.contains(draft.variable),
            compact: true,
            save: { didSave(draft) },
            content: {
                LabeledContent("Variable") {
                    TextField("Variable", text: $draft.variable.singleLineText)
                        .singleLinePaste()
                        .lineLimit(1)
                        .labelsHidden()
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospaced())
                }
                LabeledContent("Value") {
                    TextField("Value", text: $draft.value.singleLineText)
                        .singleLinePaste()
                        .lineLimit(1)
                        .labelsHidden()
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospaced())
                }
            }
        )
    }
}

nonisolated enum MobileHostEditorPolicy {
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

}

nonisolated enum MobileEditorError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let value): value
        }
    }
}
