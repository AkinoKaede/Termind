import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

struct MobileHostEditor: View {
    private enum EditorRoute: Hashable, Identifiable {
        case hostIdentity
        case telnetIdentity
        case proxyIdentity
        case telnetProxyIdentity
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
    @State private var tailscaleUsername = ""
    @State private var originalTailscaleUsername = ""
    @State private var draft: Host
    @State private var editorRoute: EditorRoute?
    @State private var customIdentity = HostCustomIdentityDraft()
    @State private var didLoadCustom = false
    @State private var selectedProtocol: HostTerminalProtocol

    init(app: MobileAppModel, host: Host) {
        self.app = app
        original = host
        _draft = State(initialValue: host)
        _selectedProtocol = State(initialValue: host.sshEnabled ? .ssh : .telnet)
    }

    var editorTitle: String {
        app.library.host(original.id) == nil
            ? String(localized: AppStrings.Vault.addHost)
            : String(localized: AppStrings.Vault.editHost)
    }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        MobileEditorSheet(
            title: editorTitle,
            isDirty: tailscaleUsername != originalTailscaleUsername || draft != original
                || !customIdentity.sshUsername.isEmpty
                || !customIdentity.sshPassword.isEmpty || customIdentity.sshKeyID != nil
                || !customIdentity.telnetUsername.isEmpty || !customIdentity.telnetPassword.isEmpty
                || !customIdentity.telnetProxyPassword.isEmpty,
            canSave: !draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && draft.preferredTerminalProtocol != nil
                && (!draft.sshEnabled || (1...65_535).contains(draft.sshPort))
                && (!draft.telnetEnabled || (1...65_535).contains(draft.telnetPort))
                && (draft.isTailscaleManaged || customIdentity.isSSHValid(for: draft))
                && customIdentity.isProxyValid(for: draft)
                && customIdentity.isTelnetValid(for: draft)
                && customIdentity.isTelnetProxyValid(for: draft)
                && (!draft.sshEnabled || draft.environmentVariablesAreValid),
            topBar: AnyView(
                HostProtocolProfileControls(protocol: $selectedProtocol).disabled(draft.isTailscaleManaged)),
            save: {
                if draft.isTailscaleManaged {
                    guard library.saveTailscaleHost(draft, username: tailscaleUsername) else {
                        throw MobileEditorError.message(
                            library.storageError ?? TailscaleConfigurationError.unavailable.localizedDescription)
                    }
                } else {
                    try customIdentity.save(into: &draft, using: library)
                }
            },
            content: {
                HostOrganizationSection(host: $draft) {
                    Picker(AppStrings.Vault.group.swiftUIKey, selection: groupChoice) {
                        Text(AppStrings.Common.none).tag(Choice<HostGroup.ID>.unset)
                        ForEach(library.groups) { group in
                            Text(group.name).tag(Choice.existing(group.id))
                        }
                        Divider()
                        Text(AppStrings.Vault.newGroup).tag(Choice<HostGroup.ID>.new)
                    }
                } tagsField: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(AppStrings.Vault.tags)
                        MobileTagField(tags: $draft.tags, suggestions: library.allTags)
                    }
                }
                HostConnectionFields(host: $draft, protocol: $selectedProtocol).disabled(draft.isTailscaleManaged)
                if selectedProtocol == .ssh && draft.sshEnabled {
                    if draft.isTailscaleManaged {
                        Section(AppStrings.Vault.authentication.swiftUIKey) {
                            TextField(AppStrings.Vault.username.swiftUIKey, text: $tailscaleUsername)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                    } else {
                        Section(AppStrings.Vault.authentication.swiftUIKey) {
                            Picker(AppStrings.Vault.identity.swiftUIKey, selection: identityChoice) {
                                Text(AppStrings.Vault.custom).tag(Choice<Identity.ID>.unset)
                                Divider()
                                ForEach(library.reusableIdentities) { identity in
                                    Text(identity.name).tag(Choice.existing(identity.id))
                                }
                                Divider()
                                Text(AppStrings.Keychain.newIdentity).tag(Choice<Identity.ID>.new)
                            }
                            if usesCustomIdentity {
                                LabeledContent(AppStrings.Vault.username.swiftUIKey) {
                                    TextField(
                                        AppStrings.Vault.username.swiftUIKey,
                                        text: $customIdentity.sshUsername.singleLineText
                                    )
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .multilineTextAlignment(.trailing)
                                }
                                LabeledContent(AppStrings.Vault.password.swiftUIKey) {
                                    RevealableSecretField(AppStrings.Common.optional, text: $customIdentity.sshPassword)
                                        .multilineTextAlignment(.trailing)
                                        .disabled(!customIdentity.sshPasswordIsEditable)
                                }
                                Picker(AppStrings.Vault.key.swiftUIKey, selection: $customIdentity.sshKeyID) {
                                    Text(AppStrings.Common.none).tag(SSHKeyRef.ID?.none)
                                    ForEach(library.keys) { key in Text(key.label).tag(SSHKeyRef.ID?.some(key.id)) }
                                }
                            }
                        }
                        Section(AppStrings.Vault.routing.swiftUIKey) {
                            Picker(AppStrings.Vault.jumpHost.swiftUIKey, selection: $draft.jumpHostID) {
                                Text(AppStrings.Common.none).tag(UUID?.none)
                                ForEach(library.hosts.filter { $0.id != draft.id && $0.sshEnabled }) {
                                    Text($0.name).tag(Optional($0.id))
                                }
                            }
                            Picker(AppStrings.Vault.proxy.swiftUIKey, selection: proxyKind) {
                                Text(AppStrings.Common.none).tag(HostProxy.ProtocolKind?.none)
                                ForEach(HostProxy.ProtocolKind.allCases) { kind in
                                    Text(kind.displayName).tag(HostProxy.ProtocolKind?.some(kind))
                                }
                            }
                            if draft.proxy != nil {
                                LabeledContent(AppStrings.Vault.hostname.swiftUIKey) {
                                    TextField(
                                        AppStrings.Vault.hostname.swiftUIKey,
                                        text: proxyString(\.hostname).singleLineText, axis: .horizontal
                                    )
                                    .singleLinePaste()
                                    .lineLimit(1)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .keyboardType(.URL)
                                    .multilineTextAlignment(.trailing)
                                }
                                .accessibilityLabel(AppStrings.Vault.proxyHostname.swiftUIKey)
                                LabeledContent(AppStrings.Common.port.swiftUIKey) {
                                    TextField(
                                        AppStrings.Common.port.swiftUIKey, value: proxyInt(\.port),
                                        format: .number.grouping(.never)
                                    ).lineLimit(
                                        1
                                    )
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                }
                                .accessibilityLabel(AppStrings.Vault.proxyPort.swiftUIKey)
                                Picker(AppStrings.Vault.identity.swiftUIKey, selection: proxyIdentityChoice) {
                                    Text(AppStrings.Common.none).tag(Choice<Identity.ID>.unset)
                                    Text(AppStrings.Vault.custom).tag(Choice<Identity.ID>.custom)
                                    Divider()
                                    ForEach(proxyIdentities) { identity in
                                        Text("\(identity.name) · \(identity.username)")
                                            .tag(Choice.existing(identity.id))
                                    }
                                    Divider()
                                    Text(AppStrings.Keychain.newIdentity).tag(Choice<Identity.ID>.new)
                                }
                                .accessibilityLabel(AppStrings.Vault.proxyIdentity.swiftUIKey)
                                if customIdentity.usesCustomProxy {
                                    LabeledContent(AppStrings.Vault.username.swiftUIKey) {
                                        TextField(
                                            AppStrings.Vault.username.swiftUIKey,
                                            text: proxyString(\.username).singleLineText
                                        )
                                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                                        .multilineTextAlignment(.trailing)
                                    }
                                    LabeledContent(AppStrings.Vault.password.swiftUIKey) {
                                        RevealableSecretField(
                                            AppStrings.Vault.required, text: $customIdentity.proxyPassword
                                        )
                                        .multilineTextAlignment(.trailing)
                                        .disabled(!customIdentity.proxyPasswordIsEditable)
                                    }
                                } else if draft.proxy?.identityID != nil {
                                    LabeledContent(AppStrings.Vault.username.swiftUIKey) {
                                        TextField(
                                            AppStrings.Vault.username.swiftUIKey,
                                            text: proxyString(\.username).singleLineText, axis: .horizontal
                                        )
                                        .singleLinePaste()
                                        .lineLimit(1)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .multilineTextAlignment(.trailing)
                                    }
                                    .accessibilityLabel(AppStrings.Vault.proxyUsername.swiftUIKey)
                                }
                            }
                        }
                    }
                    HostSessionSection(
                        charset: $draft.sshCharset,
                        sftpInitialPath: $draft.sftpChannelInitialPath,
                        startupSnippetID: startupSnippetChoice,
                        agentForwardingEnabled: $draft.agentForwardingEnabled,
                        allowsAgentForwarding: !draft.isTailscaleManaged,
                        environmentVariables: $draft.environmentVariables,
                        snippets: library.snippets,
                        snippetPackagePath: library.snippetPackagePath,
                        editEnvironmentVariable: { editorRoute = .environmentVariable($0) }
                    )
                    HostIntegrationSection(mode: $draft.shellIntegrationMode)
                } else if selectedProtocol == .telnet && draft.telnetEnabled {
                    telnetAuthenticationSection
                    telnetRoutingSection
                    Section(AppStrings.Vault.session.swiftUIKey) {
                        Picker(AppStrings.Vault.charset.swiftUIKey, selection: $draft.telnetCharset) {
                            ForEach(RemoteCharset.allCases) { charset in
                                Text(charset.displayName).tag(charset)
                            }
                        }
                    }
                    telnetCommandSection
                }
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
            case .telnetIdentity:
                MobileIdentityEditor(
                    app: app,
                    identity: Identity(
                        name: "", username: "",
                        passwordStorage: app.newVaultPasswordStorage),
                    configuration: .proxy
                ) { identity in
                    customIdentity.selectTelnetIdentity(identity, on: &draft)
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
            case .telnetProxyIdentity:
                MobileIdentityEditor(
                    app: app,
                    identity: Identity(
                        name: "", username: "",
                        passwordStorage: app.newVaultPasswordStorage),
                    configuration: .proxy
                ) { identity in
                    customIdentity.selectTelnetProxyIdentity(identity, on: &draft)
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

    private var telnetAuthenticationSection: some View {
        Section(AppStrings.Vault.authentication.swiftUIKey) {
            Picker(AppStrings.Vault.identity.swiftUIKey, selection: telnetIdentityChoice) {
                Text(AppStrings.Common.none).tag(Choice<Identity.ID>.unset)
                Text(AppStrings.Vault.custom).tag(Choice<Identity.ID>.custom)
                Divider()
                ForEach(telnetIdentities) { identity in
                    Text(identity.name).tag(Choice.existing(identity.id))
                }
                Divider()
                Text(AppStrings.Keychain.newIdentity).tag(Choice<Identity.ID>.new)
            }
            if customIdentity.usesCustomTelnet(for: draft) {
                LabeledContent(AppStrings.Vault.username.swiftUIKey) {
                    TextField(
                        AppStrings.Vault.username.swiftUIKey, text: $customIdentity.telnetUsername.singleLineText
                    )
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                }
                LabeledContent(AppStrings.Vault.password.swiftUIKey) {
                    RevealableSecretField(AppStrings.Vault.required, text: $customIdentity.telnetPassword)
                        .multilineTextAlignment(.trailing)
                        .disabled(!customIdentity.telnetPasswordIsEditable)
                }
            }
        }
    }

    @ViewBuilder
    private var telnetRoutingSection: some View {
        Section(AppStrings.Vault.routing.swiftUIKey) {
            Picker(AppStrings.Vault.proxy.swiftUIKey, selection: telnetProxyKind) {
                Text(AppStrings.Common.none).tag(HostProxy.ProtocolKind?.none)
                ForEach(HostProxy.ProtocolKind.allCases) { kind in
                    Text(kind.displayName).tag(HostProxy.ProtocolKind?.some(kind))
                }
            }
            if draft.telnetProxy != nil {
                LabeledContent(AppStrings.Vault.hostname.swiftUIKey) {
                    TextField(
                        AppStrings.Vault.hostname.swiftUIKey, text: telnetProxyString(\.hostname).singleLineText
                    )
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                }
                LabeledContent(AppStrings.Common.port.swiftUIKey) {
                    TextField(
                        AppStrings.Common.port.swiftUIKey, value: telnetProxyInt(\.port),
                        format: .number.grouping(.never)
                    )
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
                Picker(AppStrings.Vault.identity.swiftUIKey, selection: telnetProxyIdentityChoice) {
                    Text(AppStrings.Common.none).tag(Choice<Identity.ID>.unset)
                    Text(AppStrings.Vault.custom).tag(Choice<Identity.ID>.custom)
                    Divider()
                    ForEach(telnetIdentities) { identity in
                        Text(identity.name).tag(Choice.existing(identity.id))
                    }
                    Divider()
                    Text(AppStrings.Keychain.newIdentity).tag(Choice<Identity.ID>.new)
                }
                if customIdentity.usesCustomTelnetProxy {
                    LabeledContent(AppStrings.Vault.username.swiftUIKey) {
                        TextField(
                            AppStrings.Vault.username.swiftUIKey, text: telnetProxyString(\.username).singleLineText
                        )
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                    }
                    LabeledContent(AppStrings.Vault.password.swiftUIKey) {
                        RevealableSecretField(AppStrings.Vault.required, text: $customIdentity.telnetProxyPassword)
                            .multilineTextAlignment(.trailing)
                            .disabled(!customIdentity.telnetProxyPasswordIsEditable)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var telnetCommandSection: some View {
        if !draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Section(AppStrings.Vault.telnetCommand.swiftUIKey) {
                Text(library.telnetCommand(for: draft))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
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

    private var telnetIdentityChoice: Binding<Choice<Identity.ID>> {
        Binding {
            if customIdentity.usesCustomTelnetSelection { return .custom }
            guard let id = draft.telnetIdentityID else { return .unset }
            return library.identity(id)?.isHostCustom == true ? .custom : .existing(id)
        } set: { choice in
            switch choice {
            case .unset: customIdentity.clearTelnetIdentity(on: &draft)
            case .custom: customIdentity.selectCustomTelnet(on: &draft)
            case .existing(let id):
                guard let identity = library.identity(id) else { return }
                customIdentity.selectTelnetIdentity(identity, on: &draft)
            case .new: editorRoute = .telnetIdentity
            }
        }
    }

    private var telnetIdentities: [Identity] {
        library.reusableIdentities.filter(library.isProxyEligibleOnThisDevice)
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

    private var telnetProxyKind: Binding<HostProxy.ProtocolKind?> {
        Binding {
            draft.telnetProxy?.kind
        } set: { kind in
            draft.telnetProxy = MobileHostEditorPolicy.selectProxy(kind, current: draft.telnetProxy)
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

    private func telnetProxyString(_ keyPath: WritableKeyPath<HostProxy, String>) -> Binding<String> {
        Binding(
            get: { draft.telnetProxy?[keyPath: keyPath] ?? "" },
            set: { draft.telnetProxy?[keyPath: keyPath] = $0 })
    }

    private func telnetProxyInt(_ keyPath: WritableKeyPath<HostProxy, Int>) -> Binding<Int> {
        Binding(
            get: { draft.telnetProxy?[keyPath: keyPath] ?? 0 },
            set: { draft.telnetProxy?[keyPath: keyPath] = $0 })
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

    private var telnetProxyIdentityChoice: Binding<Choice<Identity.ID>> {
        Binding {
            if customIdentity.usesCustomTelnetProxy { return .custom }
            return draft.telnetProxy?.identityID.map(Choice.existing) ?? .unset
        } set: { choice in
            switch choice {
            case .unset: customIdentity.clearTelnetProxyIdentity(on: &draft)
            case .custom: customIdentity.selectCustomTelnetProxy(on: &draft, using: library)
            case .existing(let id):
                guard let identity = library.identity(id) else { return }
                customIdentity.selectTelnetProxyIdentity(identity, on: &draft)
            case .new: editorRoute = .telnetProxyIdentity
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
        if draft.isTailscaleManaged {
            tailscaleUsername = library.tailscaleUsername(for: draft)
            originalTailscaleUsername = tailscaleUsername
        } else {
            customIdentity = HostCustomIdentityDraft(host: draft, library: library)
        }
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
            title: String(
                localized: isNew ? AppStrings.Vault.newEnvironmentVariable : AppStrings.Vault.editEnvironmentVariable),
            isDirty: draft != original,
            canSave: draft.isValid && !usedVariables.contains(draft.variable),
            compact: true,
            save: { didSave(draft) },
            content: {
                LabeledContent(AppStrings.Vault.variable.swiftUIKey) {
                    TextField(AppStrings.Vault.variable.swiftUIKey, text: $draft.variable.singleLineText)
                        .singleLinePaste()
                        .lineLimit(1)
                        .labelsHidden()
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospaced())
                }
                LabeledContent(AppStrings.Common.value.swiftUIKey) {
                    TextField(AppStrings.Common.value.swiftUIKey, text: $draft.value.singleLineText)
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
