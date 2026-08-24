import SwiftUI

/// Add or edit a host.
///
/// A route inside Vault rather than a dynamic tab or sheet. It edits durable
/// connection data without entering SSH/SFTP Workspace lifecycle state.
struct HostEditorView: View {
    private enum Route: Hashable {
        case identity
        case proxyIdentity
        case group
        case forwarding(PortForwardingRule)
    }

    let hostID: Host.ID?

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    @State private var draft = Host(name: "", host: "")
    @State private var draftForwardings: [PortForwardingRule] = []
    @State private var draftKnownHosts: [KnownHostEntry] = []
    @State private var originalKnownHosts: [KnownHostEntry] = []
    @State private var path: [Route] = []
    @State private var saveError: String?

    var body: some View {
        NavigationStack(path: $path) {
            VaultDetailScaffold(
                title: hostID == nil ? "New Host" : "Edit Host",
                symbol: "server.rack", close: closeTab
            ) {
                form
            } footer: {
                footer
            }
                .navigationDestination(for: Route.self, destination: destination)
        }
    }

    private var form: some View {
        Form {
            Section("Connection") {
                TextField("Name", text: $draft.name, prompt: Text(draft.host))
                TextField("Host", text: $draft.host, prompt: Text("IP address or hostname"))
                TextField("Port", value: $draft.port, format: .number.grouping(.never))
            }

            Section("SFTP") {
                TextField(
                    "Initial Path", text: $draft.sftpSessionInitialPath,
                    prompt: Text("~")
                )
                .font(.body.monospaced())
                Text("Leave blank for the remote home directory, or enter an absolute path.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                    ForEach(app.hosts.identities) { identity in
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
                    TextField("Hostname", text: proxyString(\.hostname))
                        .padding(.leading, Metrics.Space.xxl)
                        .accessibilityLabel("Proxy Hostname")
                    TextField(
                        "Port", value: proxyInt(\.port),
                        format: .number.grouping(.never)
                    )
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
                        TextField("Username", text: proxyString(\.username))
                            .padding(.leading, Metrics.Space.xxl)
                            .accessibilityLabel("Proxy Username")
                    }
                }

                if !draft.host.trimmingCharacters(in: .whitespaces).isEmpty {
                    LabeledContent("Route") {
                        Text(app.hosts.routeSummary(for: draft))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }

            PortForwardingEditorSection(
                host: draft, rules: $draftForwardings,
                openEditor: { path.append(.forwarding($0)) }
            )

            KnownHostsEditorSection(entries: $draftKnownHosts)

            Section("Group & Tags") {
                Picker("Group", selection: groupChoice) {
                    Text("None").tag(Choice<HostGroup.ID>.unset)
                    ForEach(app.hosts.groups) { group in
                        Text(group.name).tag(Choice.existing(group.id))
                    }
                    Divider()
                    Text("New Group").tag(Choice<HostGroup.ID>.new)
                }

                LabeledContent("Color") {
                    ColorTagPicker(selection: $draft.colorTag)
                }

                // Full width rather than a `LabeledContent`, which would squeeze
                // the chips, the field, and the dropdown into the trailing half
                // of the row.
                VStack(alignment: .leading, spacing: Metrics.Space.s) {
                    Text("Tags")
                    TagField(tags: $draft.tags, suggestions: app.hosts.allTags)
                }
            }

            if !draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section("SSH Command") {
                    if let command = app.hosts.sshCommand(for: draft) {
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
        .onAppear(perform: load)
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .identity:
            NewIdentitySheet { identity, passwordUpdate in
                try app.hosts.upsert(identity, passwordUpdate: passwordUpdate)
                draft.identityID = identity.id
            }
        case .group:
            NewGroupSheet { group in
                app.hosts.upsert(group)
                draft.groupID = group.id
            }
        case .proxyIdentity:
            NewIdentitySheet(configuration: .proxy) { identity, passwordUpdate in
                try app.hosts.upsert(identity, passwordUpdate: passwordUpdate)
                draft.proxy?.identityID = identity.id
                draft.proxy?.username = identity.username
            }
        case .forwarding(let rule):
            PortForwardingEditorSheet(
                forwarding: rule, host: draft,
                isNew: !draftForwardings.contains { $0.id == rule.id },
                delete: { draftForwardings.removeAll { $0.id == rule.id } },
                save: upsertForwardingDraft
            )
        }
    }

    private func upsertForwardingDraft(_ rule: PortForwardingRule) {
        if let index = draftForwardings.firstIndex(where: { $0.id == rule.id }) {
            draftForwardings[index] = rule
        } else {
            draftForwardings.append(rule)
        }
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
            case .new: path.append(.identity)
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
            case .new: path.append(.group)
            }
        }
    }

    private var jumpHostChoices: [Host] {
        app.hosts.hosts.filter { candidate in
            candidate.id != draft.id
                && {
                    var proposed = draft
                    proposed.jumpHostID = candidate.id
                    return app.hosts.validatedRoute(for: proposed) != nil
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
            let hosts = app.hosts.hosts(in: group.id).filter { eligibleIDs.contains($0.id) }
            if !hosts.isEmpty {
                result.append(
                    JumpHostSection(id: .group(group.id), title: title, hosts: hosts)
                )
            }
            for child in app.hosts.childGroups(of: group.id) {
                walk(child, prefix: title)
            }
        }

        for group in app.hosts.rootGroups {
            walk(group, prefix: "")
        }

        let ungrouped = app.hosts.hosts(in: nil).filter { eligibleIDs.contains($0.id) }
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
                guard let identity = app.hosts.identity(id) else { return }
                draft.proxy?.username = identity.username
            case .new:
                path.append(.proxyIdentity)
            }
        }
    }

    private var proxyIdentities: [Identity] {
        app.hosts.identities.filter(\.isProxyEligible)
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
            Button("Cancel") { closeTab() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
        }
        .padding(Metrics.Space.l)
        .background(.bar)
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
            && app.hosts.validatedRoute(for: draft) != nil
            && draftForwardings.allSatisfy(\.isValid)
            && knownHostsAreValid
    }

    private var knownHostsAreValid: Bool {
        let normalized = draftKnownHosts.map { entry in
            SSHHostKeyIdentity(
                algorithm: entry.algorithm,
                fingerprint: entry.fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return normalized.allSatisfy { !$0.fingerprint.isEmpty }
            && Set(normalized).count == normalized.count
    }

    private func load() {
        guard let hostID, let existing = app.hosts.host(hostID) else { return }
        draft = existing
        draftForwardings = app.hosts.portForwardings(for: hostID)
        originalKnownHosts = app.hosts.knownHosts(for: existing)
        draftKnownHosts = originalKnownHosts
    }

    /// No tag bookkeeping here: `TagField` writes chips straight into
    /// `draft.tags`, so there is never a half-typed word left to flush.
    private func save() {
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
            draft.name = draft.host
        }
        let initialPath = draft.sftpSessionInitialPath.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.sftpSessionInitialPath = initialPath.isEmpty ? "" : RemotePath.normalized(initialPath)
        for index in draftForwardings.indices { draftForwardings[index].hostID = draft.id }
        if app.hosts.upsert(
            draft,
            replacingPortForwardings: draftForwardings,
            replacingKnownHosts: knownHostsForSave
        ) {
            closeTab()
        } else {
            saveError = app.hosts.storageError ?? String(localized: "The host could not be saved.")
        }
    }

    private var knownHostsForSave: [KnownHostEntry] {
        let originals = Dictionary(uniqueKeysWithValues: originalKnownHosts.map { ($0.id, $0) })
        return draftKnownHosts.map { entry in
            var normalized = entry
            normalized.fingerprint = entry.fingerprint.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if let original = originals[entry.id],
                original.algorithm == normalized.algorithm,
                original.fingerprint == normalized.fingerprint
            {
                return normalized
            }
            normalized.addedAt = Date()
            normalized.isMismatched = false
            return normalized
        }
    }

    /// Return to Hosts so the saved or retained record is immediately visible.
    private func closeTab() {
        window.openPage(.hosts)
    }
}

/// Known Hosts is part of the Host draft, including during creation. Nothing is
/// trusted or forgotten until the editor's Save commits the entire collection.
private struct KnownHostsEditorSection: View {
    @Binding var entries: [KnownHostEntry]
    @State private var newAlgorithm: SSHKeyAlgorithm = .ed25519
    @State private var newFingerprint = ""

    var body: some View {
        Section("Known Hosts") {
            if entries.contains(where: \.isMismatched) {
                Label(
                    "This server recently presented a key that is not in the trusted set.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if entries.isEmpty {
                Text(
                    "Add a trusted server key now, or let Termind save it on first connection."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                ForEach($entries) { $entry in
                    knownHostRow($entry)
                }
            }

            newHostKeyComposer

            Text("Changes take effect only after you save this Host.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func knownHostRow(_ entry: Binding<KnownHostEntry>) -> some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            HStack {
                Label("Host Key", systemImage: "key.horizontal")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) {
                    let id = entry.wrappedValue.id
                    entries.removeAll { $0.id == id }
                } label: {
                    Label("Delete Host Key", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Delete this Host Key")
            }

            LabeledContent("Key Type") {
                algorithmPicker(selection: entry.algorithm)
            }

            LabeledContent("Fingerprint") {
                TextField(
                    "Fingerprint", text: entry.fingerprint,
                    prompt: Text("SHA256:…")
                )
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.body.monospaced())
                .multilineTextAlignment(.trailing)
            }

            if entry.wrappedValue.isMismatched {
                Label("Previously marked as mismatched", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(Metrics.Space.m)
        .background(Color.primary.opacity(0.045), in: .rect(cornerRadius: Metrics.Radius.medium))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.Radius.medium)
                .strokeBorder(.separator.opacity(0.7))
        }
    }

    private var newHostKeyComposer: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            Label("Add Host Key", systemImage: "plus.circle.fill")
                .font(.headline)
                .foregroundStyle(.secondary)

            LabeledContent("Key Type") {
                algorithmPicker(selection: $newAlgorithm)
            }

            LabeledContent("Fingerprint") {
                TextField(
                    "Fingerprint", text: $newFingerprint,
                    prompt: Text("SHA256:…")
                )
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.body.monospaced())
                .multilineTextAlignment(.trailing)
                .onSubmit(addHostKey)
            }

            HStack {
                if isDuplicateDraft {
                    Text("This host key is already in the list.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Add", systemImage: "plus", action: addHostKey)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAddHostKey)
            }
        }
        .padding(Metrics.Space.m)
        .background(Color.primary.opacity(0.045), in: .rect(cornerRadius: Metrics.Radius.medium))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.Radius.medium)
                .strokeBorder(.separator.opacity(0.7))
        }
    }

    private func algorithmPicker(selection: Binding<SSHKeyAlgorithm>) -> some View {
        Picker("Key Type", selection: selection) {
            ForEach(SSHKeyAlgorithm.allCases) { algorithm in
                Text(algorithm.displayName).tag(algorithm)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }

    private var normalizedNewFingerprint: String {
        newFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var draftIdentity: SSHHostKeyIdentity {
        SSHHostKeyIdentity(algorithm: newAlgorithm, fingerprint: normalizedNewFingerprint)
    }

    private var isDuplicateDraft: Bool {
        !normalizedNewFingerprint.isEmpty && entries.contains { $0.identity == draftIdentity }
    }

    private var canAddHostKey: Bool {
        !normalizedNewFingerprint.isEmpty && !isDuplicateDraft
    }

    private func addHostKey() {
        guard canAddHostKey else { return }
        entries.append(
            KnownHostEntry(
                hostname: "", algorithm: newAlgorithm,
                fingerprint: normalizedNewFingerprint, addedAt: Date()
            )
        )
        newFingerprint = ""
    }
}
