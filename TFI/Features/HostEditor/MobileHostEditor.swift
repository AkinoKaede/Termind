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
            discardQuestion: app.library.host(original.id) == nil
                ? AppStrings.Common.discardNewHostQuestion : AppStrings.Common.discardChangesQuestion,
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
                    Picker(AppStrings.Vault.group.swiftUIKey, selection: fields.groupChoice) {
                        Text(AppStrings.Common.none).tag(HostEditorChoice<HostGroup.ID>.unset)
                        ForEach(library.groups) { group in
                            Text(group.name).tag(HostEditorChoice.existing(group.id))
                        }
                        Divider()
                        Text(AppStrings.Vault.newGroup).tag(HostEditorChoice<HostGroup.ID>.new)
                    }
                } tagsField: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(AppStrings.Vault.tags)
                        MobileTagField(tags: $draft.tags, suggestions: library.allTags)
                    }
                }
                HostConnectionFields(host: $draft, protocol: selectedProtocol).disabled(draft.isTailscaleManaged)
                if selectedProtocol == .ssh && draft.sshEnabled {
                    if draft.isTailscaleManaged {
                        Section(AppStrings.Vault.authentication.swiftUIKey) {
                            TextField(AppStrings.Vault.username.swiftUIKey, text: $tailscaleUsername)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                    } else {
                        Section(AppStrings.Vault.authentication.swiftUIKey) {
                            Picker(AppStrings.Vault.identity.swiftUIKey, selection: fields.identityChoice) {
                                Text(AppStrings.Vault.custom).tag(HostEditorChoice<Identity.ID>.unset)
                                Divider()
                                ForEach(library.reusableIdentities) { identity in
                                    Text(identity.name).tag(HostEditorChoice.existing(identity.id))
                                }
                                Divider()
                                Text(AppStrings.Keychain.newIdentity).tag(HostEditorChoice<Identity.ID>.new)
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
                            Picker(AppStrings.Vault.proxy.swiftUIKey, selection: fields.proxyKind) {
                                Text(AppStrings.Common.none).tag(HostProxy.ProtocolKind?.none)
                                ForEach(HostProxy.ProtocolKind.allCases) { kind in
                                    Text(kind.displayName).tag(HostProxy.ProtocolKind?.some(kind))
                                }
                            }
                            if draft.proxy != nil {
                                LabeledContent(AppStrings.Vault.hostname.swiftUIKey) {
                                    TextField(
                                        AppStrings.Vault.hostname.swiftUIKey,
                                        text: fields.proxyString(\.hostname).singleLineText, axis: .horizontal
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
                                        AppStrings.Common.port.swiftUIKey, value: fields.proxyInt(\.port),
                                        format: .number.grouping(.never)
                                    ).lineLimit(
                                        1
                                    )
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                }
                                .accessibilityLabel(AppStrings.Vault.proxyPort.swiftUIKey)
                                Picker(AppStrings.Vault.identity.swiftUIKey, selection: fields.proxyIdentityChoice) {
                                    Text(AppStrings.Common.none).tag(HostEditorChoice<Identity.ID>.unset)
                                    Text(AppStrings.Vault.custom).tag(HostEditorChoice<Identity.ID>.custom)
                                    Divider()
                                    ForEach(proxyIdentities) { identity in
                                        Text("\(identity.name) · \(identity.username)")
                                            .tag(HostEditorChoice.existing(identity.id))
                                    }
                                    Divider()
                                    Text(AppStrings.Keychain.newIdentity).tag(HostEditorChoice<Identity.ID>.new)
                                }
                                .accessibilityLabel(AppStrings.Vault.proxyIdentity.swiftUIKey)
                                if customIdentity.usesCustomProxy {
                                    LabeledContent(AppStrings.Vault.username.swiftUIKey) {
                                        TextField(
                                            AppStrings.Vault.username.swiftUIKey,
                                            text: fields.proxyString(\.username).singleLineText
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
                                            text: fields.proxyString(\.username).singleLineText, axis: .horizontal
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
                        startupSnippetID: fields.startupSnippetChoice,
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
            Picker(AppStrings.Vault.identity.swiftUIKey, selection: fields.telnetIdentityChoice) {
                Text(AppStrings.Common.none).tag(HostEditorChoice<Identity.ID>.unset)
                Text(AppStrings.Vault.custom).tag(HostEditorChoice<Identity.ID>.custom)
                Divider()
                ForEach(telnetIdentities) { identity in
                    Text(identity.name).tag(HostEditorChoice.existing(identity.id))
                }
                Divider()
                Text(AppStrings.Keychain.newIdentity).tag(HostEditorChoice<Identity.ID>.new)
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
            Picker(AppStrings.Vault.proxy.swiftUIKey, selection: fields.telnetProxyKind) {
                Text(AppStrings.Common.none).tag(HostProxy.ProtocolKind?.none)
                ForEach(HostProxy.ProtocolKind.allCases) { kind in
                    Text(kind.displayName).tag(HostProxy.ProtocolKind?.some(kind))
                }
            }
            if draft.telnetProxy != nil {
                LabeledContent(AppStrings.Vault.hostname.swiftUIKey) {
                    TextField(
                        AppStrings.Vault.hostname.swiftUIKey, text: fields.telnetProxyString(\.hostname).singleLineText
                    )
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                }
                LabeledContent(AppStrings.Common.port.swiftUIKey) {
                    TextField(
                        AppStrings.Common.port.swiftUIKey, value: fields.telnetProxyInt(\.port),
                        format: .number.grouping(.never)
                    )
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
                Picker(AppStrings.Vault.identity.swiftUIKey, selection: fields.telnetProxyIdentityChoice) {
                    Text(AppStrings.Common.none).tag(HostEditorChoice<Identity.ID>.unset)
                    Text(AppStrings.Vault.custom).tag(HostEditorChoice<Identity.ID>.custom)
                    Divider()
                    ForEach(telnetIdentities) { identity in
                        Text(identity.name).tag(HostEditorChoice.existing(identity.id))
                    }
                    Divider()
                    Text(AppStrings.Keychain.newIdentity).tag(HostEditorChoice<Identity.ID>.new)
                }
                if customIdentity.usesCustomTelnetProxy {
                    LabeledContent(AppStrings.Vault.username.swiftUIKey) {
                        TextField(
                            AppStrings.Vault.username.swiftUIKey,
                            text: fields.telnetProxyString(\.username).singleLineText
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

    private var telnetIdentities: [Identity] {
        library.reusableIdentities.filter(library.isProxyEligibleOnThisDevice)
    }

    private var proxyIdentities: [Identity] {
        library.reusableIdentities.filter(library.isProxyEligibleOnThisDevice)
    }

    private var fields: HostEditorBindings {
        HostEditorBindings(host: $draft, customIdentity: $customIdentity, library: library) { creation in
            switch creation {
            case .identity: editorRoute = .hostIdentity
            case .telnetIdentity: editorRoute = .telnetIdentity
            case .proxyIdentity: editorRoute = .proxyIdentity
            case .telnetProxyIdentity: editorRoute = .telnetProxyIdentity
            case .group: editorRoute = .group
            }
        }
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
            discardQuestion: isNew
                ? AppStrings.Common.discardNewEnvironmentVariableQuestion : AppStrings.Common.discardChangesQuestion,
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

nonisolated enum MobileEditorError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let value): value
        }
    }
}
