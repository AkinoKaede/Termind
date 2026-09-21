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
    private enum Route: Hashable {
        case identity
        case proxyIdentity
        case group
        case environmentVariable(Int?)
    }

    let hostID: Host.ID?
    let initialGroupID: HostGroup.ID?

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    @State private var draft: Host
    @State private var route: Route?
    @State private var saveError: String?
    @State private var didLoad = false
    @State private var customIdentity = HostCustomIdentityDraft()

    init(hostID: Host.ID?, initialGroupID: HostGroup.ID? = nil) {
        self.hostID = hostID
        self.initialGroupID = initialGroupID
        _draft = State(
            initialValue: Host(
                name: "", host: "",
                groupID: hostID == nil ? initialGroupID : nil
            ))
    }

    var body: some View {
        ZStack {
            if let route {
                destination(route)
                    .transition(.move(edge: .trailing))
            } else {
                VaultDetailScaffold(
                    title: hostID == nil ? "New Host" : "Edit Host",
                    symbol: "server.rack", close: cancel
                ) {
                    form
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
    }

    private var form: some View {
        Form {
            HostOrganizationSection(host: $draft) {
                Picker("Group", selection: groupChoice) {
                    Text("None").tag(Choice<HostGroup.ID>.unset)
                    ForEach(app.hostLibrary.groups) { group in
                        Text(group.name).tag(Choice.existing(group.id))
                    }
                    Divider()
                    Text("New Group").tag(Choice<HostGroup.ID>.new)
                }
            } tagsField: {
                // Full width rather than a `LabeledContent`, which would squeeze
                // the chips, the field, and the dropdown into the trailing half
                // of the row.
                VStack(alignment: .leading, spacing: Metrics.Space.s) {
                    Text("Tags")
                    TagField(tags: $draft.tags, suggestions: app.hostLibrary.allTags)
                }
            }

            HostConnectionFields(host: $draft)

            Section("Authentication") {
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
                Picker("Identity", selection: identityChoice) {
                    Text("Custom").tag(Choice<Identity.ID>.unset)
                    Divider()
                    ForEach(app.hostLibrary.reusableIdentities) { identity in
                        Text("\(identity.name) · \(identity.username)")
                            .tag(Choice.existing(identity.id))
                    }
                    Divider()
                    Text("New Identity").tag(Choice<Identity.ID>.new)
                }

                if usesCustomIdentity {
                    TextField("Username", text: $customIdentity.sshUsername.singleLineText, axis: .horizontal)
                        .singleLinePaste().lineLimit(1)
                        .padding(.leading, Metrics.Space.xxl)
                    RevealableSecretField("Password", text: $customIdentity.sshPassword, prompt: Text("Optional"))
                        .padding(.leading, Metrics.Space.xxl)
                        .disabled(!customIdentity.sshPasswordIsEditable)
                    Picker("Key", selection: $customIdentity.sshKeyID) {
                        Text("None").tag(SSHKeyRef.ID?.none)
                        ForEach(app.hostLibrary.keys) { key in
                            Text(key.label).tag(SSHKeyRef.ID?.some(key.id))
                        }
                    }
                    .padding(.leading, Metrics.Space.xxl)
                }

            }

            Section("Routing") {
                Picker("Jump Host", selection: $draft.jumpHostID) {
                    Text("None").tag(Host.ID?.none)
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

                Picker("Proxy", selection: proxyKind) {
                    Text("None").tag(HostProxy.ProtocolKind?.none)
                    ForEach(HostProxy.ProtocolKind.allCases) { kind in
                        Text(kind.displayName).tag(HostProxy.ProtocolKind?.some(kind))
                    }
                }

                if draft.proxy != nil {
                    TextField("Hostname", text: proxyString(\.hostname).singleLineText, axis: .horizontal)
                        .singleLinePaste().lineLimit(1)
                        .padding(.leading, Metrics.Space.xxl)
                        .accessibilityLabel("Proxy Hostname")
                    TextField(
                        "Port", value: proxyInt(\.port),
                        format: .number.grouping(.never)
                    ).lineLimit(1)
                        .padding(.leading, Metrics.Space.xxl)
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
                    .padding(.leading, Metrics.Space.xxl)
                    .accessibilityLabel("Proxy Identity")
                    if customIdentity.usesCustomProxy {
                        TextField("Username", text: proxyString(\.username).singleLineText, axis: .horizontal)
                            .singleLinePaste().lineLimit(1)
                            .padding(.leading, Metrics.Space.xxl)
                            .accessibilityLabel("Proxy Username")
                        RevealableSecretField("Password", text: $customIdentity.proxyPassword, prompt: Text("Required"))
                            .padding(.leading, Metrics.Space.xxl)
                            .disabled(!customIdentity.proxyPasswordIsEditable)
                    } else if draft.proxy?.identityID != nil {
                        TextField("Username", text: proxyString(\.username).singleLineText, axis: .horizontal)
                            .singleLinePaste()
                            .lineLimit(1)
                            .padding(.leading, Metrics.Space.xxl)
                            .accessibilityLabel("Proxy Username")
                    }
                }

                if !draft.host.trimmingCharacters(in: .whitespaces).isEmpty {
                    LabeledContent("Route") {
                        Text(app.hostLibrary.routeSummary(for: draft))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }

            HostSessionSection(
                charset: $draft.charset,
                sftpInitialPath: $draft.sftpChannelInitialPath,
                startupSnippetID: startupSnippetChoice,
                environmentVariables: $draft.environmentVariables,
                snippets: app.hostLibrary.snippets,
                snippetPackagePath: app.hostLibrary.snippetPackagePath,
                editEnvironmentVariable: { route = .environmentVariable($0) }
            )

            Section("Port Forwarding") {
                Stepper(
                    value: $draft.portForwardingMaxConnections,
                    in: Host.portForwardingMaxConnectionsRange
                ) {
                    HStack {
                        Text("Max Connections")
                        Spacer()
                        Text(draft.portForwardingMaxConnections, format: .number).monospacedDigit()
                    }
                }
                Text("Local and dynamic forwards share this connection pool. Changes apply after restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HostIntegrationSection(mode: $draft.shellIntegrationMode)

            if !draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section("SSH Command") {
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
                            .accessibilityLabel("Copy SSH Command")
                        }
                    } else {
                        Label(
                            "OpenSSH commands are unavailable for routes using an HTTP or SOCKS5 proxy.",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadOnce)
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
                    title: String(localized: "Ungrouped"),
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
                customIdentity.selectCustomProxy(on: &draft, using: app.hostLibrary)
            case .existing(let id):
                guard let identity = app.hostLibrary.identity(id) else { return }
                customIdentity.selectProxyIdentity(identity, on: &draft)
            case .new:
                route = .proxyIdentity
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
                Button("Delete", role: .destructive) {
                    guard let hostID else { return }
                    app.requestHostDeletion(hostID)
                    closeTab()
                }
            }
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
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
            && (1...65_535).contains(draft.port)
            && customIdentity.isProxyValid(for: draft)
            && customIdentity.isSSHValid(for: draft)
            && draft.environmentVariablesAreValid
            && (draft.sftpChannelInitialPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || draft.sftpChannelInitialPath.hasPrefix("/"))
            && app.hostLibrary.validatedRoute(for: draft) != nil
    }

    private func load() {
        guard let hostID, let existing = app.hostLibrary.host(hostID) else { return }
        draft = existing
    }

    private func loadOnce() {
        guard !didLoad else { return }
        didLoad = true
        load()
        customIdentity = HostCustomIdentityDraft(host: draft, library: app.hostLibrary)
    }

    /// No tag bookkeeping here: `TagField` writes chips straight into
    /// `draft.tags`, so there is never a half-typed word left to flush.
    private func save() {
        let initialPath = draft.sftpChannelInitialPath.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.sftpChannelInitialPath = initialPath.isEmpty ? "" : RemotePath.normalized(initialPath)
        do {
            try customIdentity.save(into: &draft, using: app.hostLibrary)
        } catch {
            saveError = error.localizedDescription
            return
        }
        closeTab()
    }

    private func cancel() {
        closeTab()
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
            title: original == nil ? "New Environment Variable" : "Edit Environment Variable",
            symbol: "text.line.first.and.arrowtriangle.forward", close: back,
            closeLabel: "Back", closeSymbol: "chevron.backward"
        ) {
            Form {
                Section {
                    LabeledContent("Variable") {
                        TextField("Variable", text: $draft.variable.singleLineText)
                            .singleLinePaste()
                            .lineLimit(1)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .font(.body.monospaced())
                    }
                    LabeledContent("Value") {
                        TextField("Value", text: $draft.value.singleLineText)
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
                Button("Cancel", action: back).keyboardShortcut(.cancelAction)
                Button(original == nil ? "Add" : "Save") {
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
