import Darwin
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

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

    func displayName(locale: Locale = .current) -> String {
        switch self {
        case .ssh: AppLocalization.string("SSH", locale: locale)
        case .sftp: AppLocalization.string("SFTP", locale: locale)
        case .serial: AppLocalization.string("Serial", locale: locale)
        }
    }

    var target: HostOpenTarget? {
        switch self {
        case .ssh: .sshSession
        case .sftp: .sftpChannel
        case .serial: nil
        }
    }
}

nonisolated enum HostChooserPurpose: Hashable, Sendable, Identifiable {
    case connect
    case batchStartup
    case metrics
    case snippet(SnippetHostChooserRequest)

    nonisolated var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .connect: "Connect"
        case .batchStartup: "Batch Startup"
        case .metrics: "Add Server"
        case .snippet: "Execute on Hosts"
        }
    }

    var symbol: String {
        switch self {
        case .connect: "network"
        case .batchStartup: MenuSymbol.batchStartup
        case .metrics: "waveform.path.ecg"
        case .snippet: "text.badge.play"
        }
    }

    /// Named for what it does, not "OK". The footer keeps this explicit action
    /// in every mode, while clicking a host also performs the single-selection case.
    var confirmLabel: LocalizedStringKey {
        switch self {
        case .connect, .batchStartup: "Connect"
        case .metrics: "Add Server"
        case .snippet: "Execute"
        }
    }

    /// Whether the sheet ticks boxes instead of picking one row. The only thing
    /// the view branches on.
    var allowsMultiple: Bool {
        switch self {
        case .connect: false
        case .batchStartup, .snippet, .metrics: true
        }
    }

    /// A single host is the complete answer, matching the mobile picker. Batch
    /// purposes keep collecting rows until their explicit confirmation action.
    var activatesHostImmediately: Bool {
        switch self {
        case .connect: true
        case .batchStartup, .snippet, .metrics: false
        }
    }

    var choosesConnectionProtocol: Bool {
        switch self {
        case .connect, .batchStartup: true
        case .snippet, .metrics: false
        }
    }
}

/// The sheet ⌘T raises: click a host, or highlight one with the keyboard and
/// press Return.
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
/// The rows live in a native `List`, but they are buttons rather than
/// `List(selection:)`: the search field keeps focus while the arrow-key cursor
/// remains visibly highlighted. In single mode the row is the action and opens
/// immediately; no second click or footer confirmation is required.
///
/// Batch Startup raises this same sheet with `purpose.allowsMultiple`. There,
/// rows carry trailing checkmarks and `cursor` stops being the answer — it is
/// only the keyboard position, while `selected` is what Connect acts on.
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
    @Environment(\.locale) private var locale
    @State private var chooser: ManagedChooserState<Host.ID>
    @State private var connectionProtocol = HostConnectionProtocol.ssh
    @State private var serialConfiguration = SerialConnectionConfiguration()
    @State private var serialBaudRate = "9600"
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
        let matches = app.hostLibrary.searchHosts(query)
        guard purpose == .metrics else { return matches }
        let monitored = Set(app.serverMetrics.selections.map(\.id))
        return matches.filter { !monitored.contains($0.id) }
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
            aboveSearch: chooserOptions,
            showsSearch: connectionProtocol != .serial,
            onSubmit: openSelected,
            moveCursor: move,
            toggleCursor: toggleCursor
        )
    }

    private var chooserOptions: AnyView? {
        if purpose.choosesConnectionProtocol { return AnyView(connectionProtocolPicker) }
        if purpose == .metrics, app.serverMetrics.remainingCardSlots != nil {
            return AnyView(
                Text("Free includes up to 3 monitoring cards. Upgrade to Pro for more.")
                    .font(.caption).foregroundStyle(.secondary))
        }
        return nil
    }

    private var connectionProtocolPicker: some View {
        Picker("Connection Protocol", selection: $connectionProtocol) {
            ForEach(availableConnectionProtocols) { connectionProtocol in
                Text(connectionProtocol.displayName(locale: locale)).tag(connectionProtocol)
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
            ScrollViewReader { proxy in
                List {
                    ForEach(results) { host in
                        Button {
                            activate(host)
                        } label: {
                            HostChooserRow(
                                host: host,
                                isCursor: chooser.cursor == host.id,
                                isChecked: purpose.allowsMultiple
                                    ? chooser.selected.contains(host.id) : nil
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("host-chooser.host.\(host.id)")
                        .id(host.id)
                        .listRowBackground(
                            chooser.cursor == host.id
                                ? Color.accentColor.opacity(0.11) : Color.clear
                        )
                    }
                }
                .listStyle(.inset)
                .onAppear { scrollCursorIntoView(using: proxy) }
                .onChange(of: chooser.cursor) { _, _ in scrollCursorIntoView(using: proxy) }
                .onChange(of: results.map(\.id)) { _, _ in scrollCursorIntoView(using: proxy) }
            }
        }
    }

    private func scrollCursorIntoView(using proxy: ScrollViewProxy) {
        guard let cursor = chooser.cursor else { return }
        proxy.scrollTo(cursor)
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
            serialConfiguration.deviceName =
                serialPorts.first {
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

    private var footer: some View {
        HStack {
            if purpose.allowsMultiple, connectionProtocol != .serial {
                Text(
                    AppLocalization.string(
                        "\(chooser.selected.count) selected", locale: locale
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

                Button(selectAllLabel) {
                    toggleAllResults()
                }
                .disabled(results.isEmpty)
            }

            Spacer()

            Button("Cancel", action: close)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("host-chooser.cancel")

            Button(purpose.confirmLabel, action: openSelected)
                .keyboardShortcut(.defaultAction)
                .disabled(connectIsDisabled)
                .accessibilityIdentifier("host-chooser.confirm")
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

    private var allResultsChecked: Bool { chooser.allChecked(in: results.map(\.id)) }

    private func toggleAllResults() {
        chooser.toggleAll(in: results.map(\.id))
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
            serialError = AppLocalization.string(
                "The device path does not exist.", locale: locale
            )
            return
        }
        guard (info.st_mode & S_IFMT) == S_IFCHR else {
            serialError = AppLocalization.string(
                "The device path is not a character device.", locale: locale
            )
            return
        }
        serialConfiguration.devicePath = path
        window.openSerialSession(configuration: serialConfiguration, service: app.serialPorts)
        dismiss()
    }

    private func openChecked() {
        let batch = app.hostLibrary.searchHosts("").filter { chooser.selected.contains($0.id) }
        guard !batch.isEmpty else { return }
        if case .snippet = purpose {
            requestSnippetExecution()
        } else if purpose == .metrics {
            // The parent admits the complete batch after this sheet has closed,
            // so a limit paywall never competes with the chooser presentation.
            window.pendingMetricsHostIDs = batch.map(\.id)
            dismiss()
        } else {
            guard let target = connectionProtocol.target else { return }
            app.open(batch, as: target, layout: .oneWorkspace, in: window)
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

    private var selectAllLabel: String {
        AppLocalization.string(
            allResultsChecked ? "Deselect All" : "Select All", locale: locale
        )
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

    private func activate(_ host: Host) {
        chooser.activate(host.id)
        if purpose.activatesHostImmediately { open(host) }
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
/// `isChecked` is nil outside batch mode. Multi-selection reserves a trailing
/// slot and only reveals the native checkmark for rows that will be acted on.
struct HostChooserRow: View {
    let host: Host
    let isCursor: Bool
    var isChecked: Bool?

    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: Metrics.Space.m) {
            HostSystemIcon(asset: distributionEntry?.asset, size: 32)
                .tint(iconTint)

            VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                Text(host.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(app.hostLibrary.loginAddress(for: host))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Metrics.Space.s)

            if let isChecked {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .opacity(isChecked ? 1 : 0)
                    .frame(width: 16)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        // In batch mode "selected" has to mean ticked, not where the cursor sits
        // — the tick is what Connect acts on, so it is what VoiceOver must read.
        .accessibilityAddTraits((isChecked ?? isCursor) ? .isSelected : [])
    }

    private var distributionEntry: LinuxDistributionIconEntry? {
        LinuxDistributionIconCatalog.entry(for: host.detectedDistribution)
    }

    private var iconTint: Color {
        host.colorTag.color
            ?? distributionEntry.flatMap {
                LinuxDistributionBrandColor.color(hex: $0.hex, colorScheme: colorScheme)
            }
            ?? .accentColor
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
