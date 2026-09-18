import SwiftUI
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
    }

    let hostID: Host.ID?

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    @State private var draft = Host(name: "", host: "")
    @State private var route: Route?
    @State private var saveError: String?
    @State private var didLoad = false

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
                    Text("None").tag(Choice<Identity.ID>.unset)
                    ForEach(app.hostLibrary.identities) { identity in
                        Text("\(identity.name) · \(identity.username)")
                            .tag(Choice.existing(identity.id))
                    }
                    Divider()
                    Text("New Identity").tag(Choice<Identity.ID>.new)
                }

                Text(
                    "An identity keeps a username and its credentials together. Secrets stay in the Keychain."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
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
                        ForEach(proxyIdentities) { identity in
                            Text("\(identity.name) · \(identity.username)")
                                .tag(Choice.existing(identity.id))
                        }
                        Divider()
                        Text("New Identity").tag(Choice<Identity.ID>.new)
                    }
                    .padding(.leading, Metrics.Space.xxl)
                    .accessibilityLabel("Proxy Identity")
                    if draft.proxy?.identityID != nil {
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

            Section("Group & Tags") {
                Picker("Group", selection: groupChoice) {
                    Text("None").tag(Choice<HostGroup.ID>.unset)
                    ForEach(app.hostLibrary.groups) { group in
                        Text(group.name).tag(Choice.existing(group.id))
                    }
                    Divider()
                    Text("New Group").tag(Choice<HostGroup.ID>.new)
                }

                LabeledContent("Color") {
                    ColorTagPicker(selection: $draft.colorTag, layout: .compact)
                }

                // Full width rather than a `LabeledContent`, which would squeeze
                // the chips, the field, and the dropdown into the trailing half
                // of the row.
                VStack(alignment: .leading, spacing: Metrics.Space.s) {
                    Text("Tags")
                    TagField(tags: $draft.tags, suggestions: app.hostLibrary.allTags)
                }
            }

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
            NewIdentitySheet(back: closeNestedEditor) { identity, passwordUpdate in
                try app.hostLibrary.upsert(identity, passwordUpdate: passwordUpdate)
                draft.identityID = identity.id
            }
        case .group:
            NewGroupSheet(back: closeNestedEditor) { group in
                app.hostLibrary.upsert(group)
                draft.groupID = group.id
            }
        case .proxyIdentity:
            NewIdentitySheet(configuration: .proxy, back: closeNestedEditor) {
                identity, passwordUpdate in
                try app.hostLibrary.upsert(identity, passwordUpdate: passwordUpdate)
                draft.proxy?.identityID = identity.id
                draft.proxy?.username = identity.username
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
        case existing(ID)
        case new
    }

    /// `.new` deliberately leaves the draft alone. Nothing is written until the
    /// sheet hands back something to point at, which is what makes Cancel a
    /// no-op: the getter still reads the old value, so the picker snaps back to
    /// it on the next pass.
    private var identityChoice: Binding<Choice<Identity.ID>> {
        Binding {
            draft.identityID.map(Choice.existing) ?? .unset
        } set: { choice in
            switch choice {
            case .unset: draft.identityID = nil
            case .existing(let id): draft.identityID = id
            case .new: route = .identity
            }
        }
    }

    private var groupChoice: Binding<Choice<HostGroup.ID>> {
        Binding {
            draft.groupID.map(Choice.existing) ?? .unset
        } set: { choice in
            switch choice {
            case .unset: draft.groupID = nil
            case .existing(let id): draft.groupID = id
            case .new: route = .group
            }
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
            draft.proxy?.identityID.map(Choice.existing) ?? .unset
        } set: { choice in
            switch choice {
            case .unset:
                draft.proxy?.identityID = nil
                draft.proxy?.username = ""
            case .existing(let id):
                draft.proxy?.identityID = id
                guard let identity = app.hostLibrary.identity(id) else { return }
                draft.proxy?.username = identity.username
            case .new:
                route = .proxyIdentity
            }
        }
    }

    private var proxyIdentities: [Identity] {
        app.hostLibrary.identities.filter(app.hostLibrary.isProxyEligibleOnThisDevice)
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
            && (draft.proxy?.isValid ?? true)
            && (draft.sftpSessionInitialPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || draft.sftpSessionInitialPath.hasPrefix("/"))
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
    }

    /// No tag bookkeeping here: `TagField` writes chips straight into
    /// `draft.tags`, so there is never a half-typed word left to flush.
    private func save() {
        let initialPath = draft.sftpSessionInitialPath.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.sftpSessionInitialPath = initialPath.isEmpty ? "" : RemotePath.normalized(initialPath)
        if app.hostLibrary.saveHost(draft) {
            closeTab()
        } else {
            saveError = app.hostLibrary.storageError ?? String(localized: "The host could not be saved.")
        }
    }

    private func cancel() {
        closeTab()
    }

    /// Return to Hosts so the saved or retained record is immediately visible.
    private func closeTab() {
        window.openPage(.hosts)
    }
}
