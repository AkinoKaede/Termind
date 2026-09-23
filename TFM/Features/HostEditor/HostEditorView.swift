import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

/// Add or edit a host.
///
/// A route inside Vault rather than a dynamic workspace or sheet. It edits durable
/// connection data without entering SSH/SFTP Workspace lifecycle state.
struct HostEditorView: View {
    private struct CustomIdentityState: Equatable {
        let sshUsername: String
        let sshPassword: String
        let sshKeyID: SSHKeyRef.ID?
        let telnetUsername: String
        let telnetPassword: String
        let usesCustomTelnetSelection: Bool
        let usesCustomProxy: Bool
        let proxyPassword: String
        let usesCustomTelnetProxy: Bool
        let telnetProxyPassword: String

        init(_ draft: HostCustomIdentityDraft) {
            sshUsername = draft.sshUsername
            sshPassword = draft.sshPassword
            sshKeyID = draft.sshKeyID
            telnetUsername = draft.telnetUsername
            telnetPassword = draft.telnetPassword
            usesCustomTelnetSelection = draft.usesCustomTelnetSelection
            usesCustomProxy = draft.usesCustomProxy
            proxyPassword = draft.proxyPassword
            usesCustomTelnetProxy = draft.usesCustomTelnetProxy
            telnetProxyPassword = draft.telnetProxyPassword
        }
    }

    private enum Route: Hashable {
        case identity
        case telnetIdentity
        case proxyIdentity
        case telnetProxyIdentity
        case group
        case environmentVariable(Int?)
    }

    let hostID: Host.ID?
    let initialGroupID: HostGroup.ID?

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(VaultWorkEditingSession.self) private var editingSession

    @State private var draft: Host
    @State private var original: Host
    @State private var originalCustomIdentity = CustomIdentityState(HostCustomIdentityDraft())
    @State private var route: Route?
    @State private var saveError: String?
    @State private var didLoad = false
    @State private var customIdentity = HostCustomIdentityDraft()
    @State private var selectedProtocol = HostTerminalProtocol.ssh
    @State private var confirmsDeletion = false
    @State private var editingToken: UUID?

    init(hostID: Host.ID?, initialGroupID: HostGroup.ID? = nil) {
        self.hostID = hostID
        self.initialGroupID = initialGroupID
        let initial = Host(name: "", host: "", groupID: hostID == nil ? initialGroupID : nil)
        _draft = State(initialValue: initial)
        _original = State(initialValue: initial)
    }

    var body: some View {
        ZStack {
            if let route {
                destination(route)
                    .transition(.move(edge: .trailing))
            } else {
                VaultDetailScaffold(
                    title: hostID == nil ? AppStrings.Vault.newHost : AppStrings.Vault.editHost,
                    symbol: "server.rack", close: cancel, closeLabel: AppStrings.Common.cancel
                ) {
                    VStack(spacing: 0) {
                        HostProtocolProfileControls(protocol: $selectedProtocol)
                            .padding(.horizontal, Metrics.Space.l)
                            .padding(.vertical, Metrics.Space.m)
                            .termindGlassBar()
                        Divider().opacity(0.25)
                        form
                    }
                } footer: {
                    footer
                }
                .transition(.move(edge: .leading))
            }
        }
        // Keep nested editors inside the Host work column. A NavigationStack
        // here is promoted by macOS into the enclosing NavigationSplitView's
        // detail, which makes its destination cover the Hosts collection too.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(.snappy(duration: 0.2), value: route)
        .onAppear {
            loadOnce()
            original = draft
            originalCustomIdentity = CustomIdentityState(customIdentity)
            editingToken = editingSession.register(
                route: .hostEditor(hostID, groupID: initialGroupID), isDirty: { isDirty }
            ) { commitChanges() }
        }
        .onDisappear {
            guard let editingToken else { return }
            editingSession.unregister(editingToken)
        }
        .confirmationDialog(
            AppStrings.Vault.deleteHostConfirmation.swiftUIKey, isPresented: $confirmsDeletion,
            titleVisibility: .visible
        ) {
            Button(AppStrings.Common.delete.swiftUIKey, role: .destructive) {
                guard let hostID else { return }
                app.requestHostDeletion(hostID)
                closeTab()
            }
            Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) {}
        } message: {
            Text(AppStrings.Vault.deleteHostWarning)
        }
    }

    private var form: some View {
        Form {
            HostOrganizationSection(host: $draft) {
                Picker(AppStrings.Vault.group.swiftUIKey, selection: groupChoice) {
                    Text(AppStrings.Common.none).tag(Choice<HostGroup.ID>.unset)
                    ForEach(app.hostLibrary.groups) { group in
                        Text(group.name).tag(Choice.existing(group.id))
                    }
                    Divider()
                    Text(AppStrings.Vault.newGroup).tag(Choice<HostGroup.ID>.new)
                }
            } tagsField: {
                // Full width rather than a `LabeledContent`, which would squeeze
                // the chips, the field, and the dropdown into the trailing half
                // of the row.
                VStack(alignment: .leading, spacing: Metrics.Space.s) {
                    Text(AppStrings.Vault.tags)
                    TagField(tags: $draft.tags, suggestions: app.hostLibrary.allTags)
                }
            }

            HostConnectionFields(host: $draft, protocol: $selectedProtocol)

            if selectedProtocol == .ssh && draft.sshEnabled {
                Section(AppStrings.Vault.authentication.swiftUIKey) {
                    // One control, because a host says *where* and an identity says
                    // *who*. The login name and the secret travel together — a
                    // fleet shares one `deploy` account, and typing that name into
                    // eight host forms is eight places to fix when it changes.
                    //
                    // No SSH Agent option, and there will not be one: reaching
                    // `SSH_AUTH_SOCK` means opening a UNIX socket outside the
                    // container, which the App Sandbox does not grant. Offering the
                    // mode and then failing at connect time would be worse than not
                    // offering it.
                    Picker(AppStrings.Vault.identity.swiftUIKey, selection: identityChoice) {
                        Text(AppStrings.Vault.custom).tag(Choice<Identity.ID>.unset)
                        Divider()
                        ForEach(app.hostLibrary.reusableIdentities) { identity in
                            Text("\(identity.name) · \(identity.username)")
                                .tag(Choice.existing(identity.id))
                        }
                        Divider()
                        Text(AppStrings.Keychain.newIdentity).tag(Choice<Identity.ID>.new)
                    }

                    if usesCustomIdentity {
                        TextField(
                            AppStrings.Vault.username.swiftUIKey, text: $customIdentity.sshUsername.singleLineText,
                            axis: .horizontal
                        )
                        .singleLinePaste().lineLimit(1)
                        .padding(.leading, Metrics.Space.xxl)
                        RevealableSecretField(
                            AppStrings.Vault.password, text: $customIdentity.sshPassword,
                            prompt: Text(AppStrings.Common.optional)
                        )
                        .padding(.leading, Metrics.Space.xxl)
                        .disabled(!customIdentity.sshPasswordIsEditable)
                        Picker(AppStrings.Vault.key.swiftUIKey, selection: $customIdentity.sshKeyID) {
                            Text(AppStrings.Common.none).tag(SSHKeyRef.ID?.none)
                            ForEach(app.hostLibrary.keys) { key in
                                Text(key.label).tag(SSHKeyRef.ID?.some(key.id))
                            }
                        }
                        .padding(.leading, Metrics.Space.xxl)
                    }

                }

                Section(AppStrings.Vault.routing.swiftUIKey) {
                    Picker(AppStrings.Vault.jumpHost.swiftUIKey, selection: $draft.jumpHostID) {
                        Text(AppStrings.Common.none).tag(Host.ID?.none)
                        Divider()
                        ForEach(jumpHostSections) { section in
                            Section(section.title) {
                                ForEach(section.hosts) { host in
                                    Text(host.name)
                                        .tag(Host.ID?.some(host.id))
                                }
                            }
                        }
                    }

                    Picker(AppStrings.Vault.proxy.swiftUIKey, selection: proxyKind) {
                        Text(AppStrings.Common.none).tag(HostProxy.ProtocolKind?.none)
                        ForEach(HostProxy.ProtocolKind.allCases) { kind in
                            Text(kind.displayName).tag(HostProxy.ProtocolKind?.some(kind))
                        }
                    }

                    if draft.proxy != nil {
                        TextField(
                            AppStrings.Vault.hostname.swiftUIKey, text: proxyString(\.hostname).singleLineText,
                            axis: .horizontal
                        )
                        .singleLinePaste().lineLimit(1)
                        .padding(.leading, Metrics.Space.xxl)
                        .accessibilityLabel(AppStrings.Vault.proxyHostname.swiftUIKey)
                        TextField(
                            AppStrings.Common.port.swiftUIKey, value: proxyInt(\.port),
                            format: .number.grouping(.never)
                        ).lineLimit(1)
                            .padding(.leading, Metrics.Space.xxl)
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
                        .padding(.leading, Metrics.Space.xxl)
                        .accessibilityLabel(AppStrings.Vault.proxyIdentity.swiftUIKey)
                        if customIdentity.usesCustomProxy {
                            TextField(
                                AppStrings.Vault.username.swiftUIKey, text: proxyString(\.username).singleLineText,
                                axis: .horizontal
                            )
                            .singleLinePaste().lineLimit(1)
                            .padding(.leading, Metrics.Space.xxl)
                            .accessibilityLabel(AppStrings.Vault.proxyUsername.swiftUIKey)
                            RevealableSecretField(
                                AppStrings.Vault.password, text: $customIdentity.proxyPassword,
                                prompt: Text(AppStrings.Vault.required)
                            )
                            .padding(.leading, Metrics.Space.xxl)
                            .disabled(!customIdentity.proxyPasswordIsEditable)
                        } else if draft.proxy?.identityID != nil {
                            TextField(
                                AppStrings.Vault.username.swiftUIKey, text: proxyString(\.username).singleLineText,
                                axis: .horizontal
                            )
                            .singleLinePaste()
                            .lineLimit(1)
                            .padding(.leading, Metrics.Space.xxl)
                            .accessibilityLabel(AppStrings.Vault.proxyUsername.swiftUIKey)
                        }
                    }

                    if !draft.host.trimmingCharacters(in: .whitespaces).isEmpty {
                        LabeledContent(AppStrings.Vault.route.swiftUIKey) {
                            Text(app.hostLibrary.routeSummary(for: draft))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                HostSessionSection(
                    charset: $draft.sshCharset,
                    sftpInitialPath: $draft.sftpChannelInitialPath,
                    startupSnippetID: startupSnippetChoice,
                    environmentVariables: $draft.environmentVariables,
                    snippets: app.hostLibrary.snippets,
                    snippetPackagePath: app.hostLibrary.snippetPackagePath,
                    editEnvironmentVariable: { route = .environmentVariable($0) }
                )

                Section(AppStrings.Navigation.portForwarding.swiftUIKey) {
                    Stepper(
                        value: $draft.portForwardingMaxConnections,
                        in: Host.portForwardingMaxConnectionsRange
                    ) {
                        HStack {
                            Text(AppStrings.Vault.maxConnections)
                            Spacer()
                            Text(draft.portForwardingMaxConnections, format: .number).monospacedDigit()
                        }
                    }
                    Text(AppStrings.Vault.forwardingPoolExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HostIntegrationSection(mode: $draft.shellIntegrationMode)

                if !draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section(AppStrings.Vault.sshCommand.swiftUIKey) {
                        if let command = app.hostLibrary.sshCommand(for: draft) {
                            HStack(spacing: Metrics.Space.s) {
                                Text(command)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    copyToPasteboard(command)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(AppStrings.Vault.copySshCommand.swiftUIKey)
                            }
                        } else {
                            Label(
                                AppStrings.Vault.unsupportedProxyCommand.swiftUIKey,
                                systemImage: "info.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if selectedProtocol == .telnet && draft.telnetEnabled {
                telnetAuthenticationSection
                telnetRoutingSection
                Section(AppStrings.Vault.session.swiftUIKey) {
                    Picker(AppStrings.Vault.charset.swiftUIKey, selection: $draft.telnetCharset) {
                        ForEach(RemoteCharset.allCases) { charset in
                            Text(charset.displayName).tag(charset)
                        }
                    }
                    .pickerStyle(.menu)
                    .menuOrder(.fixed)
                }
                telnetCommandSection
            }
        }
        .formStyle(.grouped)
    }

    private var telnetAuthenticationSection: some View {
        Section(AppStrings.Vault.authentication.swiftUIKey) {
            Picker(AppStrings.Vault.identity.swiftUIKey, selection: telnetIdentityChoice) {
                Text(AppStrings.Common.none).tag(Choice<Identity.ID>.unset)
                Text(AppStrings.Vault.custom).tag(Choice<Identity.ID>.custom)
                Divider()
                ForEach(telnetIdentities) { identity in
                    Text("\(identity.name) · \(identity.username)").tag(Choice.existing(identity.id))
                }
                Divider()
                Text(AppStrings.Keychain.newIdentity).tag(Choice<Identity.ID>.new)
            }
            if customIdentity.usesCustomTelnet(for: draft) {
                TextField(
                    AppStrings.Vault.username.swiftUIKey, text: $customIdentity.telnetUsername.singleLineText,
                    axis: .horizontal
                )
                .singleLinePaste().lineLimit(1).padding(.leading, Metrics.Space.xxl)
                RevealableSecretField(
                    AppStrings.Vault.password, text: $customIdentity.telnetPassword,
                    prompt: Text(AppStrings.Vault.required)
                )
                .padding(.leading, Metrics.Space.xxl)
                .disabled(!customIdentity.telnetPasswordIsEditable)
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
                TextField(AppStrings.Vault.hostname.swiftUIKey, text: telnetProxyString(\.hostname).singleLineText)
                    .singleLinePaste().lineLimit(1).padding(.leading, Metrics.Space.xxl)
                TextField(
                    AppStrings.Common.port.swiftUIKey, value: telnetProxyInt(\.port), format: .number.grouping(.never)
                )
                .lineLimit(1).padding(.leading, Metrics.Space.xxl)
                Picker(AppStrings.Vault.identity.swiftUIKey, selection: telnetProxyIdentityChoice) {
                    Text(AppStrings.Common.none).tag(Choice<Identity.ID>.unset)
                    Text(AppStrings.Vault.custom).tag(Choice<Identity.ID>.custom)
                    Divider()
                    ForEach(telnetIdentities) { identity in
                        Text("\(identity.name) · \(identity.username)").tag(Choice.existing(identity.id))
                    }
                    Divider()
                    Text(AppStrings.Keychain.newIdentity).tag(Choice<Identity.ID>.new)
                }
                .padding(.leading, Metrics.Space.xxl)
                if customIdentity.usesCustomTelnetProxy {
                    TextField(AppStrings.Vault.username.swiftUIKey, text: telnetProxyString(\.username).singleLineText)
                        .singleLinePaste().lineLimit(1).padding(.leading, Metrics.Space.xxl)
                    RevealableSecretField(
                        AppStrings.Vault.password, text: $customIdentity.telnetProxyPassword,
                        prompt: Text(AppStrings.Vault.required)
                    )
                    .padding(.leading, Metrics.Space.xxl)
                    .disabled(!customIdentity.telnetProxyPasswordIsEditable)
                }
            }
        }
    }

    @ViewBuilder
    private var telnetCommandSection: some View {
        if !draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Section(AppStrings.Vault.telnetCommand.swiftUIKey) {
                let command = app.hostLibrary.telnetCommand(for: draft)
                HStack(spacing: Metrics.Space.s) {
                    Text(command)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        copyToPasteboard(command)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless).accessibilityLabel(AppStrings.Vault.copyTelnetCommand.swiftUIKey)
                }
            }
        }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .identity:
            NewIdentitySheet(
                defaultPasswordStorage: app.newVaultPasswordStorage,
                back: closeNestedEditor
            ) { identity, passwordUpdate in
                try app.hostLibrary.upsert(identity, passwordUpdate: passwordUpdate)
                draft.identityID = identity.id
            }
        case .telnetIdentity:
            NewIdentitySheet(
                configuration: .proxy,
                defaultPasswordStorage: app.newVaultPasswordStorage,
                back: closeNestedEditor
            ) { identity, passwordUpdate in
                try app.hostLibrary.upsert(identity, passwordUpdate: passwordUpdate)
                customIdentity.selectTelnetIdentity(identity, on: &draft)
            }
        case .group:
            NewGroupSheet(back: closeNestedEditor) { group in
                app.hostLibrary.upsert(group)
                draft.groupID = group.id
            }
        case .proxyIdentity:
            NewIdentitySheet(
                configuration: .proxy,
                defaultPasswordStorage: app.newVaultPasswordStorage,
                back: closeNestedEditor
            ) {
                identity, passwordUpdate in
                try app.hostLibrary.upsert(identity, passwordUpdate: passwordUpdate)
                customIdentity.selectProxyIdentity(identity, on: &draft)
            }
        case .telnetProxyIdentity:
            NewIdentitySheet(
                configuration: .proxy,
                defaultPasswordStorage: app.newVaultPasswordStorage,
                back: closeNestedEditor
            ) { identity, passwordUpdate in
                try app.hostLibrary.upsert(identity, passwordUpdate: passwordUpdate)
                customIdentity.selectTelnetProxyIdentity(identity, on: &draft)
            }
        case .environmentVariable(let index):
            HostEnvironmentVariableEditor(
                variable: index.map { draft.environmentVariables[$0] },
                usedVariables: Set(
                    draft.environmentVariables.indices.compactMap {
                        $0 == index ? nil : draft.environmentVariables[$0].variable
                    }),
                back: closeNestedEditor
            ) { variable in
                if let index {
                    draft.environmentVariables[index] = variable
                } else {
                    draft.environmentVariables.append(variable)
                }
            }

        }
    }

    private func closeNestedEditor() {
        route = nil
    }

    // MARK: - Picking, and making

    /// What a picker row means: nothing, one of the saved records, or the row
    /// that makes a new one.
    ///
    /// A row in a picker is a *value*, not a button — so "New Identity" has to
    /// be a third case rather than an action, and the binding below is what
    /// turns choosing it back into one. Generic over the id because Identity and
    /// HostGroup need the same three answers; both ids are `UUID`, so a single
    /// non-generic enum would let a group id be selected into the identity
    /// picker and still compile.
    private enum Choice<ID: Hashable>: Hashable {
        case unset
        case custom
        case existing(ID)
        case new
    }

    /// `.new` deliberately leaves the draft alone. Nothing is written until the
    /// sheet hands back something to point at, which is what makes Cancel a
    /// no-op: the getter still reads the old value, so the picker snaps back to
    /// it on the next pass.
    private var identityChoice: Binding<Choice<Identity.ID>> {
        Binding {
            guard let id = draft.identityID, app.hostLibrary.identity(id)?.isHostCustom != true else { return .unset }
            return .existing(id)
        } set: { choice in
            switch choice {
            case .unset, .custom:
                customIdentity.selectCustomSSH(on: &draft)
            case .existing(let id):
                guard let identity = app.hostLibrary.identity(id) else { return }
                customIdentity.selectSSHIdentity(identity, on: &draft)
            case .new: route = .identity
            }
        }
    }

    private var telnetIdentityChoice: Binding<Choice<Identity.ID>> {
        Binding {
            if customIdentity.usesCustomTelnetSelection { return .custom }
            guard let id = draft.telnetIdentityID else { return .unset }
            return app.hostLibrary.identity(id)?.isHostCustom == true ? .custom : .existing(id)
        } set: { choice in
            switch choice {
            case .unset:
                customIdentity.clearTelnetIdentity(on: &draft)
            case .custom:
                customIdentity.selectCustomTelnet(on: &draft)
            case .existing(let id):
                guard let identity = app.hostLibrary.identity(id) else { return }
                customIdentity.selectTelnetIdentity(identity, on: &draft)
            case .new:
                route = .telnetIdentity
            }
        }
    }

    private var telnetIdentities: [Identity] {
        app.hostLibrary.reusableIdentities.filter(app.hostLibrary.isProxyEligibleOnThisDevice)
    }

    private var groupChoice: Binding<Choice<HostGroup.ID>> {
        Binding {
            draft.groupID.map(Choice.existing) ?? .unset
        } set: { choice in
            switch choice {
            case .unset, .custom: draft.groupID = nil
            case .existing(let id): draft.groupID = id
            case .new: route = .group
            }
        }
    }

    private var startupSnippetChoice: Binding<Snippet.ID?> {
        Binding {
            draft.startupSnippetID.flatMap { app.hostLibrary.snippet($0)?.id }
        } set: {
            draft.startupSnippetID = $0
        }
    }

    private var jumpHostChoices: [Host] {
        app.hostLibrary.hosts.filter { candidate in
            candidate.id != draft.id
                && {
                    var proposed = draft
                    proposed.jumpHostID = candidate.id
                    return app.hostLibrary.validatedRoute(for: proposed) != nil
                }()
        }
    }

    private struct JumpHostSection: Identifiable {
        enum ID: Hashable {
            case group(HostGroup.ID)
            case ungrouped
        }

        let id: ID
        let title: String
        let hosts: [Host]
    }

    private var jumpHostSections: [JumpHostSection] {
        let eligibleIDs = Set(jumpHostChoices.map(\.id))
        var result: [JumpHostSection] = []

        func walk(_ group: HostGroup, prefix: String) {
            let title = prefix.isEmpty ? group.name : "\(prefix) / \(group.name)"
            let hosts = app.hostLibrary.hosts(in: group.id).filter { eligibleIDs.contains($0.id) }
            if !hosts.isEmpty {
                result.append(
                    JumpHostSection(id: .group(group.id), title: title, hosts: hosts)
                )
            }
            for child in app.hostLibrary.childGroups(of: group.id) {
                walk(child, prefix: title)
            }
        }

        for group in app.hostLibrary.rootGroups {
            walk(group, prefix: "")
        }

        let ungrouped = app.hostLibrary.hosts(in: nil).filter { eligibleIDs.contains($0.id) }
        if !ungrouped.isEmpty {
            result.append(
                JumpHostSection(
                    id: .ungrouped,
                    title: String(localized: AppStrings.Common.ungrouped),
                    hosts: ungrouped
                )
            )
        }

        return result
    }

    private var proxyKind: Binding<HostProxy.ProtocolKind?> {
        Binding {
            draft.proxy?.kind
        } set: { kind in
            guard let kind else {
                draft.proxy = nil
                return
            }
            if draft.proxy == nil {
                draft.proxy = HostProxy(kind: kind, port: kind.defaultPort)
            } else if draft.proxy?.kind != kind {
                let oldDefault = draft.proxy?.kind.defaultPort
                draft.proxy?.kind = kind
                if draft.proxy?.port == oldDefault { draft.proxy?.port = kind.defaultPort }
            }
        }
    }

    private var telnetProxyKind: Binding<HostProxy.ProtocolKind?> {
        Binding {
            draft.telnetProxy?.kind
        } set: { kind in
            guard let kind else {
                draft.telnetProxy = nil
                return
            }
            if draft.telnetProxy == nil {
                draft.telnetProxy = HostProxy(kind: kind, port: kind.defaultPort)
            } else if draft.telnetProxy?.kind != kind {
                let oldDefault = draft.telnetProxy?.kind.defaultPort
                draft.telnetProxy?.kind = kind
                if draft.telnetProxy?.port == oldDefault { draft.telnetProxy?.port = kind.defaultPort }
            }
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
                customIdentity.selectCustomProxy(on: &draft, using: app.hostLibrary)
            case .existing(let id):
                guard let identity = app.hostLibrary.identity(id) else { return }
                customIdentity.selectProxyIdentity(identity, on: &draft)
            case .new:
                route = .proxyIdentity
            }
        }
    }

    private var telnetProxyIdentityChoice: Binding<Choice<Identity.ID>> {
        Binding {
            if customIdentity.usesCustomTelnetProxy { return .custom }
            return draft.telnetProxy?.identityID.map(Choice.existing) ?? .unset
        } set: { choice in
            switch choice {
            case .unset:
                customIdentity.clearTelnetProxyIdentity(on: &draft)
            case .custom:
                customIdentity.selectCustomTelnetProxy(on: &draft, using: app.hostLibrary)
            case .existing(let id):
                guard let identity = app.hostLibrary.identity(id) else { return }
                customIdentity.selectTelnetProxyIdentity(identity, on: &draft)
            case .new:
                route = .telnetProxyIdentity
            }
        }
    }

    private var proxyIdentities: [Identity] {
        app.hostLibrary.reusableIdentities.filter(app.hostLibrary.isProxyEligibleOnThisDevice)
    }

    private var usesCustomIdentity: Bool {
        customIdentity.usesCustomSSH(for: draft)
    }

    private var footer: some View {
        HStack(spacing: Metrics.Space.m) {
            if hostID != nil {
                Button(AppStrings.Common.delete.swiftUIKey, role: .destructive) {
                    confirmsDeletion = true
                }
            }
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Spacer()
            Button(AppStrings.Common.cancel.swiftUIKey, action: cancel)
            Button(AppStrings.Common.save.swiftUIKey) { saveAndClose() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
        }
        .padding(Metrics.Space.l)
        .termindGlassBar()
    }

    /// An identity is not required. A host can be filed before it is known how
    /// to get into it, and forcing a login to be chosen here would mean either
    /// inventing one or refusing to save the address.
    private var isValid: Bool {
        !draft.host.trimmingCharacters(in: .whitespaces).isEmpty
            && draft.preferredTerminalProtocol != nil
            && (!draft.sshEnabled || (1...65_535).contains(draft.sshPort))
            && (!draft.telnetEnabled || (1...65_535).contains(draft.telnetPort))
            && customIdentity.isProxyValid(for: draft)
            && customIdentity.isSSHValid(for: draft)
            && customIdentity.isTelnetValid(for: draft)
            && customIdentity.isTelnetProxyValid(for: draft)
            && (!draft.sshEnabled || draft.environmentVariablesAreValid)
            && (!draft.sshEnabled
                || draft.sftpChannelInitialPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || draft.sftpChannelInitialPath.hasPrefix("/"))
            && (!draft.sshEnabled || app.hostLibrary.validatedRoute(for: draft) != nil)
    }

    private func load() {
        guard let hostID, let existing = app.hostLibrary.host(hostID) else { return }
        draft = existing
        selectedProtocol = existing.sshEnabled ? .ssh : .telnet
    }

    private func loadOnce() {
        guard !didLoad else { return }
        didLoad = true
        load()
        customIdentity = HostCustomIdentityDraft(host: draft, library: app.hostLibrary)
    }

    /// No tag bookkeeping here: `TagField` writes chips straight into
    /// `draft.tags`, so there is never a half-typed word left to flush.
    private var isDirty: Bool {
        draft != original || CustomIdentityState(customIdentity) != originalCustomIdentity
    }

    private func commitChanges() -> Bool {
        guard isDirty else { return true }
        guard isValid else {
            saveError = String(localized: AppStrings.Common.completeAllRequiredFieldsBeforeSaving)
            return false
        }
        let initialPath = draft.sftpChannelInitialPath.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.sftpChannelInitialPath = initialPath.isEmpty ? "" : RemotePath.normalized(initialPath)
        do {
            try customIdentity.save(into: &draft, using: app.hostLibrary)
        } catch {
            saveError = error.localizedDescription
            return false
        }
        original = draft
        originalCustomIdentity = CustomIdentityState(customIdentity)
        saveError = nil
        window.selectVaultItem(.host(draft.id), on: .hosts)
        return true
    }

    private func saveAndClose() {
        guard commitChanges() else { return }
        closeTab()
    }

    private func cancel() {
        editingSession.requestTransition(
            route: .hostEditor(hostID, groupID: initialGroupID), action: closeTab)
    }

    /// Return to Hosts so the saved or retained record is immediately visible.
    private func closeTab() {
        window.openPage(.hosts)
    }
}

private struct HostEnvironmentVariableEditor: View {
    let original: HostEnvironmentVariable?
    let usedVariables: Set<String>
    let back: () -> Void
    let save: (HostEnvironmentVariable) -> Void

    @State private var draft: HostEnvironmentVariable

    init(
        variable: HostEnvironmentVariable?, usedVariables: Set<String>, back: @escaping () -> Void,
        save: @escaping (HostEnvironmentVariable) -> Void
    ) {
        original = variable
        self.usedVariables = usedVariables
        self.back = back
        self.save = save
        _draft = State(initialValue: variable ?? HostEnvironmentVariable(variable: "", value: ""))
    }

    var body: some View {
        VaultDetailScaffold(
            title: original == nil
                ? AppStrings.Vault.newEnvironmentVariable : AppStrings.Vault.editEnvironmentVariable,
            symbol: "text.line.first.and.arrowtriangle.forward", close: back,
            closeLabel: AppStrings.Common.back, closeSymbol: "chevron.backward"
        ) {
            Form {
                Section {
                    LabeledContent(AppStrings.Vault.variable.swiftUIKey) {
                        TextField(AppStrings.Vault.variable.swiftUIKey, text: $draft.variable.singleLineText)
                            .singleLinePaste()
                            .lineLimit(1)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .font(.body.monospaced())
                    }
                    LabeledContent(AppStrings.Common.value.swiftUIKey) {
                        TextField(AppStrings.Common.value.swiftUIKey, text: $draft.value.singleLineText)
                            .singleLinePaste()
                            .lineLimit(1)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .font(.body.monospaced())
                    }
                }
            }
            .formStyle(.grouped)
        } footer: {
            HStack {
                Spacer()
                Button(AppStrings.Common.cancel.swiftUIKey, action: back).keyboardShortcut(.cancelAction)
                Button(original == nil ? AppStrings.Common.add.swiftUIKey : AppStrings.Common.save.swiftUIKey) {
                    save(draft)
                    back()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(Metrics.Space.l)
        }
    }

    private var isValid: Bool {
        draft.isValid && !usedVariables.contains(draft.variable)
    }
}
