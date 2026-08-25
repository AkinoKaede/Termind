import AppKit
import SwiftUI

/// The window's one left-hand column.
///
/// Navigation, assistant, snippets, history and contextual details replace one another
/// inside a stable container, so changing tools never closes or resizes the
/// sidebar. The available modes follow the selected top-level tab.
struct SidebarView: View {
    let detailCatalog: ContextPanelDetailCatalog

    @Environment(WindowModel.self) private var window

    var body: some View {
        @Bindable var window = window
        let availableDetails = detailCatalog.availableIDs

        VStack(spacing: 0) {
            if window.availableSidebarModes.count > 1 {
                HStack(spacing: Metrics.Space.xs) {
                    ForEach(window.availableSidebarModes) { mode in
                        sidebarModeButton(mode)
                    }
                }
                .padding(Metrics.Space.m)

                Divider()
            }

            switch window.sidebarMode {
            case .navigation:
                navigation
            case .assistant:
                assistant
            case .snippets:
                SSHSessionSnippetsSidebar()
            case .history:
                SSHSessionHistorySidebar()
            case .details:
                DetailSidebarView(
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
        .onChange(of: availableDetails, initial: true) {
            window.sidebar.pruneSelections(available: availableDetails)
        }
        .onChange(of: focusedPaneID, initial: true) {
            window.sidebar.focusedPaneDidChange(to: window.selectedTab?.focusedPane)
            window.reconcileSidebarMode()
        }
        .onChange(of: window.selectedTopLevelTab, initial: true) {
            window.reconcileSidebarMode()
        }
    }

    private var focusedPaneID: Pane.ID? { window.selectedTab?.focusedPaneID }

    private func sidebarModeButton(_ mode: WindowSidebarState.Mode) -> some View {
        let isSelected = window.sidebarMode == mode
        let isEnabled = window.isSidebarModeEnabled(mode)
        return Button {
            window.sidebarMode = mode
        } label: {
            Image(systemName: mode.symbol)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 28)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .background(
                    isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
                    in: .rect(cornerRadius: Metrics.Radius.small)
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.38)
        .help(Text(mode.label))
        .accessibilityLabel(Text(mode.label))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var navigation: some View {
        switch window.selectedTopLevelTab {
        case .vault:
            VaultSidebarView()
        case .assistant:
            AssistantSidebarView()
        case .workspace:
            EmptyView()
        }
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
            // would otherwise push the shared Sidebar past its ideal width.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Session Snippets

/// The compact command shelf shown only while a terminal pane has focus.
/// Commands are sent straight to that pane, deliberately bypassing Workspace
/// broadcast and the snippet's saved Targets.
private struct SSHSessionSnippetsSidebar: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    @State private var query = ""
    @State private var snippetToEdit: Snippet?
    @State private var destructiveSnippet: Snippet?

    var body: some View {
        VStack(spacing: 0) {
            TermindSearchField(text: $query, prompt: "Search Snippets", density: .compact)
                .padding(.horizontal, Metrics.Space.m)
                .padding(.vertical, Metrics.Space.s)

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

// MARK: - Session History

private struct SSHSessionHistorySidebar: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    @State private var query = ""
    @State private var destructiveEntry: CommandHistoryEntry?
    @State private var confirmsClear = false
    @State private var namingEntryID: CommandHistoryEntry.ID?
    @State private var snippetName = ""

    private var sshSession: SSHSessionModel? {
        window.selectedTab?.focusedPane.sshSession
    }

    private var isSavedHost: Bool {
        guard let hostID = sshSession?.hostID else { return false }
        return app.hosts.host(hostID) != nil
    }

    private var allEntries: [CommandHistoryEntry] {
        guard let sshSession else { return [] }
        _ = app.commandHistory.revision
        if isSavedHost {
            return app.commandHistory.entries(for: sshSession.hostID, matching: query)
        }
        let entries = sshSession.transientCommandHistory
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.command.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TermindSearchField(text: $query, prompt: "Search History", density: .compact)
                .padding(.horizontal, Metrics.Space.m)
                .padding(.vertical, Metrics.Space.s)

            if allEntries.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section(query.isEmpty ? "Recent" : "Results") {
                        ForEach(allEntries) { entry in
                            historyRow(entry)
                        }
                    }
                }
                .listStyle(.sidebar)
            }

            if sshSession?.status.isLive == true,
                sshSession?.shellIntegrationAvailable == false
            {
                Text("This session is not recording history. Enable Shell Integration and use bash, zsh, or fish.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Metrics.Space.m)
                    .padding(.vertical, Metrics.Space.s)
            }

            Divider()
            HStack(spacing: Metrics.Space.s) {
                Text("Click to insert · Double-click to execute")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Clear", role: .destructive) { confirmsClear = true }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .disabled(historyIsEmpty)
            }
            .padding(.horizontal, Metrics.Space.m)
            .padding(.vertical, Metrics.Space.s)
        }
        .confirmationDialog(
            "Clear command history for this Host?",
            isPresented: $confirmsClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive, action: clearHistory)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes all saved commands for the current Host.")
        }
        .confirmationDialog(
            "Execute a destructive command?",
            isPresented: Binding(
                get: { destructiveEntry != nil },
                set: { if !$0 { destructiveEntry = nil } }
            ),
            titleVisibility: .visible,
            presenting: destructiveEntry
        ) { entry in
            Button("Execute", role: .destructive) { executeNow(entry) }
            Button("Cancel", role: .cancel) { destructiveEntry = nil }
        } message: { entry in
            let assessment = CommandRiskClassifier.assess(entry.command)
            Text(([entry.command] + assessment.reasons).joined(separator: "\n"))
        }
    }

    @ViewBuilder
    private func historyRow(_ entry: CommandHistoryEntry) -> some View {
        if namingEntryID == entry.id {
            VStack(alignment: .leading, spacing: 3) {
                SidebarInlineTextField(
                    text: $snippetName,
                    prompt: "Snippet Name",
                    onSubmit: { saveSnippet(from: entry) },
                    onCancel: cancelSnippetNaming
                )
                .frame(height: 18)
                .padding(.horizontal, Metrics.Space.s)
                .padding(.vertical, 4)
                .background(
                    Color.primary.opacity(0.055),
                    in: .rect(cornerRadius: Metrics.Radius.small)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.Radius.small)
                        .strokeBorder(Color.accentColor.opacity(0.55))
                }
                Text(entry.command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 2)
        } else {
            CommandHistoryRow(entry: entry, delete: { delete(entry) })
                .contentShape(.rect)
                .onTapGesture(count: 2) { execute(entry) }
                .onTapGesture { insert(entry) }
                .contextMenu {
                    Button("Copy") { copyToPasteboard(entry.command) }
                    Button("Save as Snippet") { beginSnippetNaming(entry) }
                    Divider()
                    Button("Clear History", role: .destructive) { confirmsClear = true }
                }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ContentUnavailableView(
                "No Command History", systemImage: "clock.arrow.circlepath",
                description: Text("Commands confirmed by the remote shell appear here.")
            )
        }
    }

    private var historyIsEmpty: Bool {
        guard let sshSession else { return true }
        if isSavedHost {
            return app.commandHistory.entries(for: sshSession.hostID).isEmpty
        }
        return sshSession.transientCommandHistory.isEmpty
    }

    private func insert(_ entry: CommandHistoryEntry) {
        guard let tab = window.selectedTab, let sshSession = tab.focusedPane.sshSession else { return }
        tab.deliver(entry.command, from: sshSession)
    }

    private func execute(_ entry: CommandHistoryEntry) {
        if CommandRiskClassifier.assess(entry.command).requiresSecondConfirmation {
            destructiveEntry = entry
        } else {
            executeNow(entry)
        }
    }

    private func executeNow(_ entry: CommandHistoryEntry) {
        guard let tab = window.selectedTab, let sshSession = tab.focusedPane.sshSession else { return }
        tab.deliver(entry.command, from: sshSession, submit: true)
        destructiveEntry = nil
    }

    private func delete(_ entry: CommandHistoryEntry) {
        if isSavedHost {
            app.commandHistory.delete(entry.id)
        } else {
            sshSession?.deleteTransientHistory(entry.id)
        }
    }

    private func clearHistory() {
        guard let sshSession else { return }
        if isSavedHost {
            app.commandHistory.clear(for: sshSession.hostID)
        } else {
            sshSession.clearTransientHistory()
        }
    }

    private func beginSnippetNaming(_ entry: CommandHistoryEntry) {
        snippetName = ""
        namingEntryID = entry.id
    }

    private func cancelSnippetNaming() {
        namingEntryID = nil
        snippetName = ""
    }

    private func saveSnippet(from entry: CommandHistoryEntry) {
        let name = snippetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        app.hosts.upsert(Snippet(title: name, body: entry.command))
        cancelSnippetNaming()
    }
}

private struct CommandHistoryRow: View {
    let entry: CommandHistoryEntry
    let delete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Metrics.Space.s) {
            Text(entry.command)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                if isHovering {
                    Button(action: delete) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Delete from History")
                    .accessibilityLabel("Delete from History")
                } else {
                    RiskBadge(
                        assessment: CommandRiskClassifier.assess(entry.command),
                        compact: true
                    )
                }
            }
            .frame(width: 18, height: 18, alignment: .center)
        }
        .padding(.vertical, 2)
        .onHover { isHovering = $0 }
        .help(Text(entry.command))
    }
}

/// A native borderless field whose editor remains transparent inside a Sidebar
/// list. SwiftUI's focused `TextField` paints an opaque control background here,
/// which looks like a white strip in light mode and ignores the row material.
private struct SidebarInlineTextField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        field.stringValue = text
        field.placeholderString = prompt
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.preferredFont(forTextStyle: .body)
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.requestFocus(for: field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var text: Binding<String>
        private let onSubmit: () -> Void
        private let onCancel: () -> Void
        private var didRequestFocus = false

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        func requestFocus(for field: NSTextField) {
            guard !didRequestFocus else { return }
            didRequestFocus = true
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else {
                return false
            }
            onCancel()
            return true
        }

        @objc func submit() {
            onSubmit()
        }
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
/// Shared by the session Assistant sidebar and full Assistant tab so the two can never drift; only
/// the padding and the provider header differ.
struct ConversationView: View {
    let conversation: ConversationModel
    var isCompact: Bool = false

    var body: some View {
        VStack(spacing: 0) {
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
            Text("Only the chips above the prompt are sent.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Metrics.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Details

/// The Sidebar's Details mode describes every selected object without inventing
/// a primary item. Disclosure groups keep a large selection scannable while
/// still allowing several records to be read side by side.
struct DetailSidebarView: View {
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
            LabeledContent("Last Used") {
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
            LabeledContent("Last Used") {
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
