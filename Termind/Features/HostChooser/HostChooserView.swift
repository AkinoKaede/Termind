import AppKit
import Darwin
import ListViewKit
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
    case serial = "Serial"

    nonisolated var id: Self { self }

    var displayName: String {
        switch self {
        case .ssh: String(localized: "SSH")
        case .sftp: String(localized: "SFTP")
        case .serial: String(localized: "Serial")
        }
    }

    var target: HostOpenTarget? {
        switch self {
        case .ssh: .sshSession
        case .sftp: .sftpSession
        case .serial: nil
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
        case .connect, .batchStartup: "Connect in the same workspace"
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
    /// How this chooser got on screen, and therefore what closing it means.
    ///
    /// The same view is raised two ways: as a sheet over the window, and as
    /// Vault's third column when a Snippet on the Snippets page asks for its
    /// targets. Closing used to be inferred from the front destination, which
    /// got it wrong for the case that is now easy to reach — the Snippets shelf
    /// in the sidebar raises the *sheet* while Vault is the front destination,
    /// so Cancel called `closeVaultWork()` and the sheet stayed up with nothing
    /// to dismiss it.
    enum Presentation {
        case sheet
        case vaultWork
    }

    let purpose: HostChooserPurpose
    let presentation: Presentation

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(\.dismiss) private var dismiss
    @State private var chooser: ManagedChooserState<Host.ID>
    @State private var connectionProtocol = HostConnectionProtocol.ssh
    @State private var serialConfiguration = SerialConnectionConfiguration()
    @State private var serialBaudRate = "115200"
    @State private var serialPorts: [SerialPortDescriptor] = []
    @State private var serialError: String?
    @State private var isConfirmingDestructiveSnippet = false

    init(purpose: HostChooserPurpose, presentation: Presentation = .sheet) {
        self.purpose = purpose
        self.presentation = presentation
        _chooser = State(
            initialValue: ManagedChooserState(
                mode: purpose.allowsMultiple ? .multiple : .single
            )
        )
    }

    /// The protocol-choosing variant carries an extra row of controls above the
    /// list and needs the room; everything else uses the standard picker width.
    private var sheetWidth: CGFloat? {
        guard presentation == .sheet else { return nil }
        return purpose.choosesConnectionProtocol ? 520 : Metrics.HostPicker.width
    }

    private var query: String { chooser.query }
    private var queryBinding: Binding<String> {
        Binding(get: { chooser.query }, set: { chooser.query = $0 })
    }

    private var results: [Host] {
        app.hostLibrary.searchHosts(query)
    }

    var body: some View {
        SheetScaffold {
            header
        } content: {
            content
        } footer: {
            footer
        }
        // A sheet has to name its own size. The host list has no intrinsic
        // height, so without one the panel collapses to its header and footer
        // with no room to show a single host — which is what "choose targets
        // for this Snippet" used to open as. Vault's third column supplies its
        // own geometry, so the chooser fills it instead.
        .frame(
            width: sheetWidth,
            height: presentation == .sheet ? Metrics.HostPicker.height : nil
        )
        .animation(Motion.panel, value: connectionProtocol)
        .onChange(of: chooser.query) {
            let ids = results.map(\.id)
            chooser.queryDidChange(visible: ids, enabled: Set(ids))
        }
        .task(id: connectionProtocol) {
            guard connectionProtocol == .serial else { return }
            for await ports in app.serialPorts.portUpdates() {
                guard !Task.isCancelled else { return }
                serialPorts = ports
            }
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
            showsSearch: connectionProtocol != .serial,
            onSubmit: openSelected,
            moveCursor: move,
            toggleCursor: toggleCursor
        )
    }

    private var connectionProtocolPicker: some View {
        Picker("Connection Protocol", selection: $connectionProtocol) {
            ForEach(availableConnectionProtocols) { connectionProtocol in
                Text(connectionProtocol.displayName).tag(connectionProtocol)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Connection protocol")
    }

    private var availableConnectionProtocols: [HostConnectionProtocol] {
        purpose == .connect ? HostConnectionProtocol.allCases : [.ssh, .sftp]
    }

    @ViewBuilder
    private var content: some View {
        if connectionProtocol == .serial {
            serialForm
        } else if app.hostLibrary.hosts.isEmpty {
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
            HostChooserNativeList(items: hostListItems) { item in
                HostChooserRow(
                    host: item.host,
                    isSelected: item.isCursor,
                    isChecked: item.isChecked
                )
                .onTapGesture(count: 2) {
                    if !purpose.allowsMultiple {
                        open(item.host)
                    }
                }
                .onTapGesture {
                    chooser.activate(item.id)
                }
            }
            .padding(.horizontal, Metrics.Space.l)
            .padding(.bottom, Metrics.Space.s)
        }
    }

    private var serialForm: some View {
        Form {
            Section("Device") {
                SerialEditableComboField(
                    title: "Device Path",
                    value: $serialConfiguration.devicePath,
                    options: serialPorts.map {
                        SerialComboOption(value: $0.path, label: $0.displayName)
                    }
                )
                if serialPorts.isEmpty {
                    Text("No detected serial devices. You can still enter any absolute device path.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Communication") {
                SerialEditableComboField(
                    title: "Baud Rate",
                    value: $serialBaudRate,
                    options: SerialConnectionConfiguration.commonBaudRates.map {
                        SerialComboOption(value: String($0), label: $0.formatted())
                    }
                )
                Picker("Data Bits", selection: $serialConfiguration.dataBits) {
                    ForEach(SerialDataBits.allCases) { Text("\($0.rawValue)").tag($0) }
                }
                Picker("Parity", selection: $serialConfiguration.parity) {
                    ForEach(SerialParity.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Stop Bits", selection: $serialConfiguration.stopBits) {
                    ForEach(SerialStopBits.allCases) { Text("\($0.rawValue)").tag($0) }
                }
                Picker("Flow Control", selection: $serialConfiguration.flowControl) {
                    ForEach(SerialFlowControl.allCases) { Text($0.displayName).tag($0) }
                }
            }

            Section("Terminal Input") {
                Picker("Enter Sends", selection: $serialConfiguration.enterKey) {
                    ForEach(SerialEnterKey.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Local Echo", isOn: $serialConfiguration.localEcho)
            }

            if let serialError {
                Text(serialError).foregroundStyle(.red).font(.caption)
            }
        }
        .formStyle(.grouped)
        .onChange(of: serialConfiguration.devicePath) {
            serialConfiguration.deviceName = serialPorts.first {
                $0.path == serialConfiguration.devicePath
            }?.name
            serialError = nil
        }
        .onChange(of: serialBaudRate) {
            if let rate = Int(serialBaudRate), (1...4_000_000).contains(rate) {
                serialConfiguration.baudRate = rate
                serialError = nil
            }
        }
    }

    private var hostListItems: [HostChooserListItem] {
        results.map { host in
            HostChooserListItem(
                host: host,
                isCursor: chooser.cursor == host.id,
                isChecked: purpose.allowsMultiple
                    ? chooser.selected.contains(host.id) : nil
            )
        }
    }

    private var footer: some View {
        HStack {
            if purpose.allowsMultiple, connectionProtocol != .serial {
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
                .disabled(connectIsDisabled)
        }
        .padding(Metrics.Space.l)
    }

    private var connectIsDisabled: Bool {
        if connectionProtocol == .serial {
            guard let rate = Int(serialBaudRate), (1...4_000_000).contains(rate) else {
                return true
            }
            return !serialConfiguration.isValid
        }
        return purpose.allowsMultiple ? chooser.selected.isEmpty : selectedHost == nil
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
        if connectionProtocol == .serial {
            openSerial()
        } else if purpose.allowsMultiple {
            openChecked()
        } else if let host = selectedHost {
            open(host)
        }
    }

    private func openSerial() {
        guard serialConfiguration.isValid else { return }
        guard let rate = Int(serialBaudRate), (1...4_000_000).contains(rate) else { return }
        serialConfiguration.baudRate = rate
        let path = serialConfiguration.normalizedDevicePath
        var info = stat()
        guard lstat(path, &info) == 0 else {
            serialError = String(localized: "The device path does not exist.")
            return
        }
        guard (info.st_mode & S_IFMT) == S_IFCHR else {
            serialError = String(localized: "The device path is not a character device.")
            return
        }
        serialConfiguration.devicePath = path
        window.openSerialSession(configuration: serialConfiguration, service: app.serialPorts)
        dismiss()
    }

    private func openChecked(as layout: BatchLayout = .separateWorkspaces) {
        let batch = app.hostLibrary.searchHosts("").filter { chooser.selected.contains($0.id) }
        guard !batch.isEmpty else { return }
        if case .snippet = purpose {
            requestSnippetExecution()
        } else {
            guard let target = connectionProtocol.target else { return }
            app.open(batch, as: target, layout: layout, in: window)
            dismiss()
        }
    }

    private var snippetRequest: SnippetHostChooserRequest? {
        if case .snippet(let request) = purpose { return request }
        return nil
    }

    private var requestedSnippets: [Snippet] {
        guard let request = snippetRequest else { return [] }
        return request.snippetIDs.compactMap { app.hostLibrary.snippet($0) }
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
        let ids = app.hostLibrary.searchHosts("").filter { chooser.selected.contains($0.id) }.map(\.id)
        switch request.strategy {
        case .fillMissingTargets:
            app.execute(requestedSnippets, fallbackHostIDs: ids, in: window)
        case .overrideAllTargets:
            app.execute(requestedSnippets, overrideHostIDs: ids, in: window)
        }
        close()
    }

    private var snippetConfirmationMessage: String {
        let selectedIDs = app.hostLibrary.searchHosts("")
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
            let targets = app.hostLibrary.searchHosts("").filter { wanted.contains($0.id) }
                .map(\.name).joined(separator: ", ")
            return "• \(snippet.body)\n  \(targets)"
        }.joined(separator: "\n")
    }

    private func close() {
        switch presentation {
        case .sheet: dismiss()
        case .vaultWork: window.closeVaultWork()
        }
    }

    private var workspaceHelp: Text {
        if chooser.selected.count < 2 {
            Text("Select at least two hosts. A Workspace can contain one or more hosts.")
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
        guard let target = connectionProtocol.target else { return }
        app.open(host, as: target, in: window)
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
nonisolated struct HostChooserListItem: Identifiable, Hashable, Sendable {
    let host: Host
    let isCursor: Bool
    let isChecked: Bool?
    var id: Host.ID { host.id }
}

private struct HostChooserNativeList: NSViewRepresentable {
    typealias NSViewType = ListView<HostChooserListItem>
    typealias Renderer = @MainActor (HostChooserListItem) -> AnyView
    let items: [HostChooserListItem]
    let renderer: Renderer
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme

    init(
        items: [HostChooserListItem],
        @ViewBuilder renderer: @escaping @MainActor (HostChooserListItem) -> some View
    ) {
        self.items = items
        self.renderer = { AnyView(renderer($0)) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSViewType { context.coordinator.makeListView() }
    func updateNSView(_ listView: NSViewType, context: Context) {
        context.coordinator.update(
            listView: listView, items: items, renderer: renderer,
            locale: locale, colorScheme: colorScheme
        )
    }

    @MainActor
    final class Coordinator {
        private var renderer: Renderer?
        private var locale = Locale.current
        private var colorScheme = ColorScheme.light
        private var content: [HostChooserListItem] = []

        func makeListView() -> NSViewType {
            let listView = NSViewType()
            listView.rowAnimator = ListBouncyAnimator(style: .regular)
            listView.estimatedRowHeight = 52
            listView.rows {
                ListRow(HostChooserHostingRow.self)
                    .height { _, _ in 52 }
                    .configure { [weak self] row, item, _ in self?.configure(row, item: item) }
            }
            return listView
        }

        func update(
            listView: NSViewType, items: [HostChooserListItem], renderer: @escaping Renderer,
            locale: Locale, colorScheme: ColorScheme
        ) {
            self.renderer = renderer
            let environmentChanged = self.locale != locale || self.colorScheme != colorScheme
            self.locale = locale
            self.colorScheme = colorScheme
            if content.map(\.id) == items.map(\.id) {
                for (old, new) in zip(content, items) where environmentChanged || old != new {
                    listView.update(new)
                }
            } else {
                listView.apply(items)
            }
            content = items
            if let cursor = items.first(where: \.isCursor) {
                listView.scrollToRow(with: cursor.id, at: .nearest, animated: false)
            }
        }

        private func configure(_ row: HostChooserHostingRow, item: HostChooserListItem) {
            guard let renderer else { return }
            let root = renderer(item)
                .environment(\.locale, locale)
                .environment(\.colorScheme, colorScheme)
            row.configure(rootView: AnyView(root))
        }
    }
}

@MainActor
private final class HostChooserHostingRow: ListRowView {
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    override init(frame: CGRect) {
        super.init(frame: frame)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        hostingView.rootView = AnyView(EmptyView())
    }
    func configure(rootView: AnyView) { hostingView.rootView = rootView }
}

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

            StatusDot(status: app.hostLibrary.status(of: host.id))

            VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                Text(host.name)
                    .lineLimit(1)

                Text(app.hostLibrary.loginAddress(for: host))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            }
        } trailing: {
            if let group = host.groupID.flatMap({ app.hostLibrary.group($0) }) {
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
