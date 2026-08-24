import SwiftUI

/// The right-hand column.
///
/// It shows the conversation belonging to the *selected tab*, which is what makes
/// "talk to the AI from the terminal" work without a separate mode: the thread,
/// its history, and its context chips follow whichever sshSession is in front.
struct ContextPanelView: View {
    let detailCatalog: ContextPanelDetailCatalog

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    var body: some View {
        @Bindable var window = window
        let availableDetails = detailCatalog.availableIDs

        VStack(spacing: 0) {
            Picker("", selection: $window.contextPanelMode) {
                ForEach(availableContextPanelModes) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(Metrics.Space.m)

            Divider()

            switch window.contextPanelMode {
            case .assistant:
                assistant
            case .snippets:
                SSHSessionSnippetsContextPanel()
            case .details:
                DetailContextPanelView(
                    details: activeDetails(available: availableDetails),
                    catalog: detailCatalog,
                    page: window.selectedTopLevelTab == .vault
                        ? window.vaultDestination.page
                        : nil
                )
            }
        }
        // Without a fill frame the VStack sizes to its content and the segmented
        // picker floats in the middle of the column instead of sitting under the
        // toolbar.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .inspectorColumnWidth(
            min: Metrics.ContextPanel.min,
            ideal: Metrics.ContextPanel.ideal,
            max: Metrics.ContextPanel.max
        )
        .onChange(of: availableDetails, initial: true) {
            window.contextPanel.pruneSelections(available: availableDetails)
        }
        .onChange(of: focusedPaneID, initial: true) {
            window.contextPanel.focusedPaneDidChange(to: window.selectedTab?.focusedPane)
            if window.focusedSSHSession == nil, window.contextPanelMode == .snippets {
                window.contextPanelMode = .details
            }
        }
    }

    private var focusedPaneID: Pane.ID? { window.selectedTab?.focusedPaneID }

    private var availableContextPanelModes: [WindowModel.ContextPanelMode] {
        window.focusedSSHSession == nil
            ? [.assistant, .details]
            : [.assistant, .snippets, .details]
    }

    private func activeDetails(
        available: Set<ContextPanelDetailID>
    ) -> [ContextPanelDetailID] {
        window.activeDetailSelection.filter(available.contains)
    }

    @ViewBuilder
    private var assistant: some View {
        if let tab = window.selectedTab {
            ConversationView(conversation: tab.conversation, isCompact: true)
        } else {
            ContentUnavailableView(
                "No Session",
                systemImage: "sparkles",
                description: Text("Open a tab to start a conversation about it.")
            )
            // `ContentUnavailableView` has a wide intrinsic width; unclamped, it
            // pushes the Context Panel past its ideal and squeezes the other columns.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Session Snippets

/// The compact command shelf shown only while a terminal pane has focus.
/// Commands are sent straight to that pane, deliberately bypassing Workspace
/// broadcast and the snippet's saved Targets.
private struct SSHSessionSnippetsContextPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    @State private var query = ""
    @State private var snippetToEdit: Snippet?
    @State private var destructiveSnippet: Snippet?

    var body: some View {
        VStack(spacing: 0) {
            TermindSearchField(text: $query, prompt: "Search Snippets", density: .compact)
                .padding(.horizontal, Metrics.Space.m)
                .padding(.bottom, Metrics.Space.s)

            if displayedSnippets.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if query.isEmpty {
                        ForEach(packageSections, id: \.package.id) { section in
                            if !section.snippets.isEmpty {
                                Section(section.path) {
                                    snippetRows(section.snippets)
                                }
                            }
                        }
                        if !ungrouped.isEmpty {
                            Section("Ungrouped") { snippetRows(ungrouped) }
                        }
                    } else {
                        Section("Results") { snippetRows(displayedSnippets) }
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()
            Text("Click to insert · Double-click to execute")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.vertical, Metrics.Space.s)
        }
        .sheet(item: $snippetToEdit) { snippet in
            SnippetEditorSheet(snippet: snippet) { app.hosts.upsert($0) }
        }
        .confirmationDialog(
            "Execute a destructive script?",
            isPresented: Binding(
                get: { destructiveSnippet != nil },
                set: { if !$0 { destructiveSnippet = nil } }
            ),
            titleVisibility: .visible,
            presenting: destructiveSnippet
        ) { snippet in
            Button("Execute", role: .destructive) { executeNow(snippet) }
            Button("Cancel", role: .cancel) { destructiveSnippet = nil }
        } message: { snippet in
            let assessment = CommandRiskClassifier.assess(snippet.body)
            Text(([snippet.body] + assessment.reasons).joined(separator: "\n"))
        }
    }

    @ViewBuilder
    private func snippetRows(_ snippets: [Snippet]) -> some View {
        ForEach(snippets) { snippet in
            SSHSessionSnippetRow(snippet: snippet)
                .contentShape(.rect)
                .onTapGesture(count: 2) { execute(snippet) }
                .onTapGesture { insert(snippet) }
                .contextMenu {
                    Button("Insert") { insert(snippet) }
                    Button("Execute") { execute(snippet) }
                    Divider()
                    Button("Copy") { copyToPasteboard(snippet.body) }
                    Button("Show Details") { window.showSnippetDetails(snippet.id) }
                    Button("Edit") { snippetToEdit = snippet }
                }
        }
    }

    private var displayedSnippets: [Snippet] {
        query.isEmpty ? app.hosts.snippets : app.hosts.searchSnippets(query)
    }

    private var ungrouped: [Snippet] { app.hosts.snippets(in: nil) }

    private var packageSections: [(package: SnippetPackage, path: String, snippets: [Snippet])] {
        flattenPackages(app.hosts.rootSnippetPackages)
    }

    private func flattenPackages(
        _ packages: [SnippetPackage]
    ) -> [(package: SnippetPackage, path: String, snippets: [Snippet])] {
        packages.flatMap { package in
            let current = (
                package: package,
                path: app.hosts.snippetPackagePath(package.id) ?? package.name,
                snippets: app.hosts.snippets(in: package.id)
            )
            return [current] + flattenPackages(app.hosts.childSnippetPackages(of: package.id))
        }
    }

    private func insert(_ snippet: Snippet) {
        guard let tab = window.selectedTab, let sshSession = tab.focusedPane.sshSession else { return }
        tab.deliver(snippet.body, from: sshSession)
    }

    private func execute(_ snippet: Snippet) {
        if CommandRiskClassifier.assess(snippet.body).requiresSecondConfirmation {
            destructiveSnippet = snippet
        } else {
            executeNow(snippet)
        }
    }

    private func executeNow(_ snippet: Snippet) {
        guard let tab = window.selectedTab, let sshSession = tab.focusedPane.sshSession else { return }
        tab.deliver(snippet.body, from: sshSession, submit: true)
        destructiveSnippet = nil
    }
}

private struct SSHSessionSnippetRow: View {
    let snippet: Snippet

    private var assessment: RiskAssessment { CommandRiskClassifier.assess(snippet.body) }

    var body: some View {
        HStack(spacing: Metrics.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(snippet.body)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Metrics.Space.s)
            RiskBadge(assessment: assessment, compact: true)
        }
        .padding(.vertical, 2)
        .help(Text(snippet.body))
    }
}

/// A conversation rendered as chips + transcript + composer.
///
/// Shared by the Context Panel and the full-tab chat so the two can never drift; only
/// the padding and the provider header differ.
struct ConversationView: View {
    let conversation: ConversationModel
    var isCompact: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            ModelProviderBar(conversation: conversation)
            Divider()
            ContextChipsView(conversation: conversation)
            Divider()
            transcript
            Divider()
            ComposerView(conversation: conversation)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if conversation.isEmpty {
                        emptyState
                    } else {
                        ForEach(conversation.messages) { message in
                            MessageView(message: message)
                                .id(message.id)
                            Divider().opacity(0.4)
                        }
                    }
                }
                .frame(maxWidth: isCompact ? .infinity : 760)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: conversation.messages.count) {
                guard let last = conversation.messages.last else { return }
                withAnimation(Motion.tabSwitch) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            Text("Ask About This Session")
                .font(.headline)
            Text(
                "Only the context shown above is sent. Select terminal output and press ⌃⌘A to add it."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Metrics.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Which endpoint the key is being spent against. Shown on every conversation
/// because with BYOK the user is the one paying, and "which model answered this"
/// is not a detail to bury in settings.
private struct ModelProviderBar: View {
    let conversation: ConversationModel

    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings

    /// The conversation's own choice, or whatever the Chat role currently
    /// resolves to. Resolved on every draw rather than cached, so a model
    /// deleted in Settings stops being displayed here immediately instead of
    /// naming something that no longer exists.
    private var resolved: (provider: ModelProvider, model: AIModel)? {
        app.ai.resolve(conversation: conversation.model)
    }

    private var modelProviders: [ModelProvider] {
        app.ai.enabledModelProviders.filter { !$0.chatModels.isEmpty }
    }

    var body: some View {
        HStack(spacing: Metrics.Space.s) {
            Menu {
                ForEach(modelProviders) { provider in
                    Section(provider.name) {
                        ForEach(provider.chatModels) { model in
                            Button(model.label) { select(model, on: provider) }
                        }
                    }
                }
                if !modelProviders.isEmpty { Divider() }
                Button("Configure Model Providers") { openSettings() }
            } label: {
                HStack(spacing: Metrics.Space.xs) {
                    Image(systemName: "sparkles")
                    Text(resolved?.model.label ?? String(localized: "No model")).lineLimit(1)
                }
                .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            if let provider = resolved?.provider {
                Text(provider.name)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    // The name here, the address in the tooltip. Two providers
                    // of the same kind are told apart by what the user called
                    // them — "Work OpenAI" answers "whose key is this" at a
                    // glance, where `api.openai.com` does not.
                    .help(Text("Requests go from this Mac directly to \(provider.resolvedBaseURL)"))
            }
        }
        .padding(.horizontal, Metrics.Space.l)
        .padding(.vertical, Metrics.Space.s)
    }

    /// Sets this conversation's model, and records the choice as the app-wide
    /// default.
    ///
    /// Both, deliberately. Picking a model here is the most common way anyone
    /// will ever choose one — far more common than opening Settings — so it
    /// would be strange for the next new conversation to forget it. `select`
    /// feeds the resolution chain without overwriting an explicit Chat role, so
    /// a decision made in Settings still wins.
    private func select(_ model: AIModel, on provider: ModelProvider) {
        let ref = AIModelRef(modelProviderID: provider.id, modelID: model.id)
        conversation.model = ref
        app.ai.select(ref)
    }
}

// MARK: - Details

/// The Context Panel's second job: describe every selected object without inventing
/// a primary item. Disclosure groups keep a large selection scannable while
/// still allowing several records to be read side by side.
struct DetailContextPanelView: View {
    let details: [ContextPanelDetailID]
    let catalog: ContextPanelDetailCatalog
    let page: VaultPage?

    @State private var expanded: Set<ContextPanelDetailID> = []

    var body: some View {
        Group {
            if details.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Metrics.Space.l) {
                        Text(selectionSummary)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)

                        ForEach(details) { detail in
                            if let presentation = catalog.presentation(for: detail) {
                                DisclosureGroup(isExpanded: expansionBinding(for: detail)) {
                                    presentation.content
                                        .padding(.top, Metrics.Space.l)
                                        .padding(.leading, Metrics.Space.xl)
                                } label: {
                                    presentation.label
                                }
                                .padding(Metrics.Space.l)
                                .background(
                                    .quaternary.opacity(0.28),
                                    in: .rect(cornerRadius: Metrics.Radius.large)
                                )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Metrics.Space.xl)
                }
            }
        }
        .labeledContentStyle(.automatic)
        .onChange(of: details, initial: true) { _, current in
            expanded.formIntersection(current)
            if expanded.isEmpty, let first = current.first { expanded.insert(first) }
            if current.count == 1, let only = current.first { expanded.insert(only) }
        }
    }

    private var selectionSummary: String {
        details.count == 1
            ? String(localized: "1 item selected")
            : String(localized: "\(details.count) items selected")
    }

    private func expansionBinding(for detail: ContextPanelDetailID) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(detail) },
            set: { isExpanded in
                if isExpanded { expanded.insert(detail) } else { expanded.remove(detail) }
            }
        )
    }

    private var emptyState: some View {
        let content = catalog.emptyState(for: page)
        return ContentUnavailableView {
            Label(content.title, systemImage: content.symbol)
        } description: {
            Text(content.description)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HostDetailContent: View {
    let host: Host

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xl) {
            HStack(spacing: Metrics.Space.s) {
                Button("Quick Connect") { app.open(host, as: .sshSession, in: window) }
                    .buttonStyle(.borderedProminent)
                HostConnectMenu(hosts: [host])
                Button("Edit") { window.openHostEditor(host: host) }
            }
            .controlSize(.small)

            LabeledContent("Status", value: app.hosts.status(of: host.id).label)
            LabeledContent("Port") { Text(host.port, format: .number.grouping(.never)) }
            LabeledContent("Identity") {
                if let identity = app.hosts.identity(for: host) {
                    Text("\(identity.name) · \(identity.username)")
                } else {
                    Text("Not set").foregroundStyle(.secondary)
                }
            }
            if host.jumpHostID != nil || host.proxy != nil {
                LabeledContent("Route") {
                    Text(app.hosts.routeSummary(for: host))
                        .font(.caption.monospaced())
                        .multilineTextAlignment(.trailing)
                }
            }
            LabeledContent("Last used") {
                Text(
                    host.lastUsedAt.map { $0.formatted(.relative(presentation: .named)) }
                        ?? String(localized: "Never"))
            }

            if !host.tags.isEmpty {
                DetailSection(title: "Tags") {
                    FlowLayout(spacing: Metrics.Space.xs) {
                        ForEach(host.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption)
                                .padding(.horizontal, Metrics.Space.s)
                                .padding(.vertical, 2)
                                .background(.quaternary.opacity(0.5), in: .capsule)
                        }
                    }
                }
            }

            hostKey

            let portForwardings = app.hosts.portForwardings(for: host.id)
            if !portForwardings.isEmpty {
                DetailSection(title: "Port Forwarding") {
                    ForEach(portForwardings, id: \.id) { portForwarding in
                        HStack(spacing: Metrics.Space.s) {
                            Image(systemName: portForwarding.kind.symbol)
                                .foregroundStyle(
                                    app.forwarding.isEnabled(portForwarding.id) ? .green : .secondary
                                )
                            Text(portForwarding.summary)
                                .font(.caption.monospaced())
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var hostKey: some View {
        let entries = app.hosts.knownHosts(for: host)
        DetailSection(title: "Host Key") {
            if !entries.isEmpty {
                if entries.contains(where: \.isMismatched) {
                    Label(
                        "This server recently presented a key that is not in the trusted set.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: Metrics.Space.s) {
                        Text(entry.fingerprint)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: Metrics.Space.s) {
                            CardChip(text: entry.algorithm.displayName, symbol: "lock.shield")
                            Text(entry.addedAt, format: .relative(presentation: .named))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        HStack(spacing: Metrics.Space.s) {
                            Button("Copy Fingerprint") { copyToPasteboard(entry.fingerprint) }
                        }
                        .controlSize(.small)
                    }
                    if entry.id != entries.last?.id { Divider() }
                }
            } else {
                Text(
                    "No key saved yet. Termind saves it on first connection and warns if it changes."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct KeyDetailContent: View {
    let key: SSHKeyRef
    let rename: () -> Void
    let export: () -> Void

    @Environment(AppModel.self) private var app

    private var identities: [Identity] { app.hosts.identities(using: key.id) }

    private var algorithm: String {
        if key.algorithm == .rsa, let bits = key.keySize { return "RSA \(bits)" }
        if let bits = key.keySize { return "\(key.algorithm.displayName) · \(bits) bit" }
        return key.algorithm.displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xl) {
            Menu("Actions") {
                KeyObjectActions(key: key, rename: rename, export: export)
            }
            .menuStyle(.button)
            .controlSize(.small)

            LabeledContent("Algorithm", value: algorithm)
            LabeledContent("Stored in", value: key.storage.displayName)
            LabeledContent("Created") { Text(key.createdAt, format: .dateTime) }
            LabeledContent("Passphrase") {
                Text(
                    !key.hasPassphrase
                        ? String(localized: "None")
                        : key.storesPassphrase
                            ? String(localized: "Saved") : String(localized: "Required at use")
                )
            }
            LabeledContent("Authentication") {
                Text(key.requiresUserPresence ? String(localized: "Required") : String(localized: "Not required"))
            }

            DetailTextBlock(title: "Fingerprint", text: key.fingerprint)
            DetailTextBlock(
                title: "Public Key",
                text: key.publicKey.isEmpty ? String(localized: "Not available") : key.publicKey
            )

            DetailSection(title: "Used by Identities") {
                if identities.isEmpty {
                    Text("None").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(identities) { identity in
                        Label("\(identity.name) · \(identity.username)", systemImage: "person.badge.key.fill")
                            .font(.caption)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct IdentityDetailContent: View {
    let identity: Identity
    let edit: () -> Void

    @Environment(AppModel.self) private var app

    private var key: SSHKeyRef? { identity.keyID.flatMap { app.hosts.key($0) } }
    private var hosts: [Host] { app.hosts.hosts(using: identity.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xl) {
            Button("Edit", action: edit)
                .controlSize(.small)

            LabeledContent("Username", value: identity.username)
            LabeledContent("Password") {
                Text(identity.usesPassword ? String(localized: "Configured") : String(localized: "Not configured"))
            }
            LabeledContent("Key") {
                if let key {
                    Text(key.label)
                } else if identity.usesKey {
                    Text("Missing").foregroundStyle(.orange)
                } else {
                    Text("Not configured").foregroundStyle(.secondary)
                }
            }
            LabeledContent("Last used") {
                Text(
                    identity.lastUsedAt.map { $0.formatted(.relative(presentation: .named)) }
                        ?? String(localized: "Never"))
            }

            if !identity.notes.isEmpty { DetailTextBlock(title: "Notes", text: identity.notes, monospaced: false) }

            DetailSection(title: "Used by Hosts") {
                if hosts.isEmpty {
                    Text("None").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(hosts) { host in
                        Label(host.name, systemImage: "server.rack")
                            .font(.caption)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SnippetDetailContent: View {
    let snippet: Snippet
    let edit: () -> Void

    @Environment(AppModel.self) private var app

    private var assessment: RiskAssessment { CommandRiskClassifier.assess(snippet.body) }
    private var targets: [Host] { snippet.targetHostIDs.compactMap { app.hosts.host($0) } }
    private var packagePath: String {
        app.hosts.snippetPackagePath(snippet.packageID) ?? String(localized: "Ungrouped")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xl) {
            Button("Edit", action: edit)
                .controlSize(.small)

            LabeledContent("Package", value: packagePath)
            LabeledContent("Risk") { RiskBadge(assessment: assessment) }

            DetailTextBlock(title: "Scripts", text: snippet.body)

            if !assessment.reasons.isEmpty {
                DetailSection(title: "Risk Assessment") {
                    ForEach(assessment.reasons, id: \.self) { reason in
                        Text("• \(reason)")
                            .font(.caption)
                            .foregroundStyle(assessment.risk.tint)
                    }
                }
            }

            DetailSection(title: "Targets") {
                if targets.isEmpty {
                    Text("Choose hosts when you execute this snippet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(targets) { host in
                        VStack(alignment: .leading, spacing: 1) {
                            Label(host.name, systemImage: "server.rack")
                            Text(app.hosts.loginAddress(for: host))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .padding(.leading, 20)
                        }
                        .font(.caption)
                    }
                }
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DetailSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DetailTextBlock: View {
    let title: LocalizedStringKey
    let text: String
    var monospaced = true

    var body: some View {
        DetailSection(title: title) {
            Text(text)
                .font(monospaced ? .caption.monospaced() : .caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
