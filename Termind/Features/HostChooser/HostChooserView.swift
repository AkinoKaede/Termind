import SwiftUI

/// Which verb the chooser was raised for.
///
/// One sheet, four verbs. "Which machine?" is the same question whether the
/// answer opens a terminal or a file browser, and whether it wants one machine
/// or a dozen; the list, the search, the keyboard handling, and the row are the
/// same work in every case — so the difference is carried as data rather than as
/// a second view.
///
/// The two batch cases both title themselves "Batch Startup", after the Rayon
/// row they came from. What tells them apart is the confirm button, which is the
/// last thing read before anything happens anyway.
nonisolated struct SnippetHostChooserRequest: Hashable, Sendable {
    enum Strategy: Hashable, Sendable {
        case fillMissingTargets
        case overrideAllTargets
    }

    var snippetIDs: [Snippet.ID]
    var strategy: Strategy
}

nonisolated enum HostConnectionProtocol: String, CaseIterable, Identifiable, Sendable {
    case ssh = "SSH"
    case sftp = "SFTP"

    nonisolated var id: Self { self }

    var target: HostOpenTarget {
        switch self {
        case .ssh: .sshSession
        case .sftp: .sftpSession
        }
    }
}

nonisolated enum HostChooserPurpose: Hashable, Sendable, Identifiable {
    case connect
    case batchStartup
    case snippet(SnippetHostChooserRequest)

    nonisolated var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .connect: "Connect"
        case .batchStartup: "Batch Startup"
        case .snippet: "Execute on Hosts"
        }
    }

    var symbol: String {
        switch self {
        case .connect: "network"
        case .batchStartup: "wind"
        case .snippet: "text.badge.play"
        }
    }

    /// Named for what it does, not "OK" — the button is the last thing read
    /// before something connects, and it should say which thing.
    var confirmLabel: LocalizedStringKey {
        switch self {
        case .connect, .batchStartup: "Connect"
        case .snippet: "Execute"
        }
    }

    /// The batch sheet's second verb. Spelled out the same way as
    /// `confirmLabel`: the button is the last thing read before something
    /// connects, so it says which thing *and* where it lands.
    var workspaceConfirmLabel: LocalizedStringKey {
        switch self {
        case .connect, .batchStartup: "Connect in Workspace"
        case .snippet: "Execute"
        }
    }

    /// Whether the sheet ticks boxes instead of picking one row. The only thing
    /// the view branches on.
    var allowsMultiple: Bool {
        switch self {
        case .connect: false
        case .batchStartup, .snippet: true
        }
    }

    var showsWorkspaceChoice: Bool {
        switch self {
        case .batchStartup: true
        case .connect, .snippet: false
        }
    }

    var choosesConnectionProtocol: Bool {
        switch self {
        case .connect, .batchStartup: true
        case .snippet: false
        }
    }
}

/// The sheet ⌘T raises: pick a host, press Return.
///
/// A sheet rather than a page because it is one question with one answer, and
/// the window behind it is what you were looking at when you asked — navigating
/// away to the Hosts page to run one command threw that context away and moved
/// the sidebar highlight as a side effect.
///
/// The sheet opens with nothing preselected, on purpose. A command that inherits
/// a selection made earlier on another screen is how a keystroke meant for
/// staging lands on production; the same rule is written on
/// `AppModel.newSession`. Typing is different — it narrows the list to something
/// the user is looking at, so the top match highlights and Return opens it.
///
/// Selection is drawn by hand rather than by `List(selection:)`, which is what
/// this sheet used to do. Two reasons, and the first is a bug: a row carrying a
/// double-click gesture never commits its single click, so nothing highlighted
/// and the confirm button stayed disabled. The second is that the search field
/// holds focus for the sheet's whole life, so a list selection would paint in
/// AppKit's faint unemphasized gray. Every other selectable surface here already
/// draws its own — see `CardTile` and `SidebarRow`.
///
/// Batch Startup raises this same sheet with `purpose.allowsMultiple`. There,
/// rows carry checkboxes and `selection` stops being the answer — it demotes to
/// the keyboard cursor, and `checked` is what Connect acts on.
struct HostChooserView: View {
    let purpose: HostChooserPurpose

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var chooser: ManagedChooserState<Host.ID>
    @State private var connectionProtocol = HostConnectionProtocol.ssh
    @State private var isConfirmingDestructiveSnippet = false

    init(purpose: HostChooserPurpose) {
        self.purpose = purpose
        _chooser = State(
            initialValue: ManagedChooserState(
                mode: purpose.allowsMultiple ? .multiple : .single
            )
        )
    }

    private var query: String { chooser.query }
    private var queryBinding: Binding<String> {
        Binding(get: { chooser.query }, set: { chooser.query = $0 })
    }

    private var results: [Host] {
        app.hosts.searchHosts(query)
    }

    var body: some View {
        SheetScaffold {
            header
        } content: {
            content
        } footer: {
            footer
        }
        .frame(
            width: purpose.choosesConnectionProtocol ? 520 : nil,
            height: purpose.choosesConnectionProtocol ? Metrics.HostPicker.height : nil
        )
        .onChange(of: chooser.query) {
            let ids = results.map(\.id)
            chooser.queryDidChange(visible: ids, enabled: Set(ids))
        }
        .confirmationDialog(
            "Execute a destructive script?",
            isPresented: $isConfirmingDestructiveSnippet,
            titleVisibility: .visible
        ) {
            Button(
                chooser.selected.count == 1
                    ? "Execute on 1 Host" : "Execute on \(chooser.selected.count) Hosts",
                role: .destructive
            ) {
                performSnippetExecution()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(snippetConfirmationMessage)
        }
    }

    // MARK: - Pieces

    private var header: some View {
        ManagedChooserHeader(
            title: purpose.title,
            symbol: purpose.symbol,
            prompt: "Search hosts",
            query: queryBinding,
            aboveSearch: purpose.choosesConnectionProtocol
                ? AnyView(connectionProtocolPicker) : nil,
            onSubmit: openSelected,
            moveCursor: move,
            toggleCursor: toggleCursor
        )
    }

    private var connectionProtocolPicker: some View {
        Picker("Connection Protocol", selection: $connectionProtocol) {
            ForEach(HostConnectionProtocol.allCases) { connectionProtocol in
                Text(connectionProtocol.rawValue).tag(connectionProtocol)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Connection protocol")
    }

    @ViewBuilder
    private var content: some View {
        if app.hosts.hosts.isEmpty {
            ContentUnavailableView {
                Label("No Hosts", systemImage: "server.rack")
            } description: {
                Text("Add a host to connect to it.")
            } actions: {
                Button("New Host") {
                    close()
                    window.openHostEditor(host: nil)
                }
            }
        } else if results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Metrics.Space.xxs) {
                        ForEach(results) { host in
                            HostChooserRow(
                                host: host,
                                isSelected: chooser.cursor == host.id,
                                isChecked: purpose.allowsMultiple
                                    ? chooser.selected.contains(host.id) : nil
                            )
                            .id(host.id)
                            .onTapGesture(count: 2) {
                                if !purpose.allowsMultiple {
                                    open(host)
                                }
                            }
                            .onTapGesture {
                                chooser.activate(host.id)
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.Space.l)
                    .padding(.bottom, Metrics.Space.s)
                }
                .onChange(of: chooser.cursor) { _, id in
                    guard let id else { return }
                    withAnimation(reduceMotion ? nil : Motion.tabSwitch) {
                        proxy.scrollTo(id)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if purpose.allowsMultiple {
                Text("\(chooser.selected.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Button(allResultsChecked ? "Deselect All" : "Select All") {
                    toggleAllResults()
                }
                .disabled(results.isEmpty)
            }

            Spacer()

            Button("Cancel", action: close)
                .keyboardShortcut(.cancelAction)

            if purpose.showsWorkspaceChoice {
                Button(purpose.workspaceConfirmLabel) { openChecked(as: .oneWorkspace) }
                    .disabled(chooser.selected.count < 2)
                    .help(workspaceHelp)
            }

            Button(purpose.confirmLabel, action: openSelected)
                .keyboardShortcut(.defaultAction)
                .disabled(purpose.allowsMultiple ? chooser.selected.isEmpty : selectedHost == nil)
        }
        .padding(Metrics.Space.l)
    }

    // MARK: - Checking

    private var allResultsChecked: Bool {
        !results.isEmpty && results.allSatisfy { chooser.selected.contains($0.id) }
    }

    private func toggleAllResults() {
        let ids = results.map(\.id)
        chooser.toggleAll(visible: ids, enabled: Set(ids))
    }

    // MARK: - Opening

    private var selectedHost: Host? {
        chooser.cursor.flatMap { id in results.first { $0.id == id } }
    }

    private func openSelected() {
        if purpose.allowsMultiple {
            openChecked()
        } else if let host = selectedHost {
            open(host)
        }
    }

    private func openChecked(as layout: BatchLayout = .separateTabs) {
        let batch = app.hosts.searchHosts("").filter { chooser.selected.contains($0.id) }
        guard !batch.isEmpty else { return }
        if case .snippet = purpose {
            requestSnippetExecution()
        } else {
            app.open(batch, as: connectionProtocol.target, layout: layout, in: window)
            dismiss()
        }
    }

    private var snippetRequest: SnippetHostChooserRequest? {
        if case .snippet(let request) = purpose { return request }
        return nil
    }

    private var requestedSnippets: [Snippet] {
        guard let request = snippetRequest else { return [] }
        return request.snippetIDs.compactMap { app.hosts.snippet($0) }
    }

    private func requestSnippetExecution() {
        if requestedSnippets.contains(where: {
            CommandRiskClassifier.assess($0.body).risk == .destructive
        }) {
            isConfirmingDestructiveSnippet = true
        } else {
            performSnippetExecution()
        }
    }

    private func performSnippetExecution() {
        guard let request = snippetRequest else { return }
        let ids = app.hosts.searchHosts("").filter { chooser.selected.contains($0.id) }.map(\.id)
        switch request.strategy {
        case .fillMissingTargets:
            app.execute(requestedSnippets, fallbackHostIDs: ids, in: window)
        case .overrideAllTargets:
            app.execute(requestedSnippets, overrideHostIDs: ids, in: window)
        }
        close()
    }

    private var snippetConfirmationMessage: String {
        let selectedIDs = app.hosts.searchHosts("")
            .filter { chooser.selected.contains($0.id) }.map(\.id)
        return requestedSnippets.map { snippet in
            let ids: [Host.ID]
            switch snippetRequest?.strategy {
            case .fillMissingTargets:
                ids = snippet.targetHostIDs.isEmpty ? selectedIDs : snippet.targetHostIDs
            case .overrideAllTargets, nil:
                ids = selectedIDs
            }
            let wanted = Set(ids)
            let targets = app.hosts.searchHosts("").filter { wanted.contains($0.id) }
                .map(\.name).joined(separator: ", ")
            return "• \(snippet.body)\n  \(targets)"
        }.joined(separator: "\n")
    }

    private func close() {
        if case .snippet = purpose, window.selectedTopLevelTab == .vault {
            window.closeVaultWork()
        } else {
            dismiss()
        }
    }

    private var workspaceHelp: Text {
        if chooser.selected.count < 2 {
            Text("Select at least two hosts. A workspace with one host is a tab.")
        } else {
            Text("Open \(chooser.selected.count) hosts as panes in one workspace.")
        }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .ignored }
        chooser.moveCursor(by: delta, through: results.map(\.id))
        return .handled
    }

    private func toggleCursor() -> KeyPress.Result {
        guard purpose.allowsMultiple, let id = chooser.cursor else { return .ignored }
        chooser.toggle(id)
        return .handled
    }

    private func open(_ host: Host) {
        app.open(host, as: connectionProtocol.target, in: window)
        dismiss()
    }
}

// MARK: - Row

/// One host, as the chooser lists it. The shared piece between the verbs: what
/// you need to recognise a machine is the same whether you are about to type on
/// it or copy files to it.
///
/// `isChecked` is nil outside batch mode, and then nothing is drawn — a single
/// pick has one visual channel and does not need two.
struct HostChooserRow: View {
    let host: Host
    let isSelected: Bool
    var isChecked: Bool?

    @Environment(AppModel.self) private var app

    var body: some View {
        SelectableRow(
            isCursor: isSelected,
            isSelected: isChecked ?? isSelected
        ) {
            HStack(spacing: Metrics.Space.m) {
            // Two channels on purpose, and they mean different things: the box
            // says what you have chosen, the row's background says where the
            // arrow keys are. Conflating them would make the cursor look like a
            // pick you had not made.
            if let isChecked {
                SelectionMark(mode: .multiple, isSelected: isChecked)
            }

            StatusDot(status: app.hosts.status(of: host.id))

            VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                Text(host.name)
                    .lineLimit(1)

                Text(app.hosts.loginAddress(for: host))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            }
        } trailing: {
            if let group = host.groupID.flatMap({ app.hosts.group($0) }) {
                Text(group.name)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        // In batch mode "selected" has to mean ticked, not where the cursor sits
        // — the tick is what Connect acts on, so it is what VoiceOver must read.
        .accessibilityAddTraits((isChecked ?? isSelected) ? [.isSelected, .isButton] : .isButton)
    }
}

#Preview("Connect") {
    HostChooserView(purpose: .connect)
        .environment(AppModel(hosts: .demo()))
        .environment(WindowModel())
}

/// The batch footer carries two more controls than the single one, and this is
/// the sheet's fixed width — worth its own preview to see them fit.
#Preview("Batch Startup") {
    HostChooserView(purpose: .batchStartup)
        .environment(AppModel(hosts: .demo()))
        .environment(WindowModel())
}
