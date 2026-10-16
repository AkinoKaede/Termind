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
    case terminal = "SSH"
    case sftp = "SFTP"
    case serial = "Serial"

    nonisolated var id: Self { self }

    func displayName(locale: Locale = .current) -> String {
        switch self {
        case .terminal: AppLocalization.resolve(AppStrings.Vault.ssh, locale: locale)
        case .sftp: AppLocalization.resolve(AppStrings.SFTP.sftp, locale: locale)
        case .serial: AppLocalization.resolve(AppStrings.Vault.serial, locale: locale)
        }
    }

    var target: HostOpenTarget? {
        switch self {
        case .terminal: .preferredTerminal
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

    var title: LocalizedStringResource {
        switch self {
        case .connect: AppStrings.Common.connect
        case .batchStartup: AppStrings.Vault.batchStartup
        case .metrics: AppStrings.Common.selectHosts
        case .snippet: AppStrings.Common.run
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

    /// Named for what it does, not "OK". Multi-selection and Serial use this
    /// explicit action, while clicking a host performs the ordinary Connect case.
    var confirmLabel: LocalizedStringResource {
        switch self {
        case .connect, .batchStartup: AppStrings.Common.connect
        case .metrics: AppStrings.Common.done
        case .snippet: AppStrings.Common.run
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

    var availableConnectionProtocols: [HostConnectionProtocol] {
        switch self {
        case .connect: HostConnectionProtocol.allCases
        case .batchStartup: [.terminal, .sftp]
        case .metrics, .snippet: []
        }
    }

    func formShowsConfirmation(for connectionProtocol: HostConnectionProtocol) -> Bool {
        switch self {
        case .connect: connectionProtocol == .serial
        case .batchStartup, .metrics: true
        case .snippet: false
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
    @State private var initialMetricsHostIDs: Set<Host.ID> = []
    @State private var connectionProtocol = HostConnectionProtocol.terminal
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

    private var sheetWidth: CGFloat? {
        guard presentation == .sheet else { return nil }
        switch purpose {
        case .connect, .batchStartup, .metrics: return 520
        case .snippet: return Metrics.HostPicker.width
        }
    }

    private var query: String { chooser.query }
    private var queryBinding: Binding<String> {
        $chooser.query
    }

    private var results: [Host] {
        let useCase: HostUseCase =
            switch purpose {
            case .metrics: .metrics
            case .snippet: .snippetExecution
            case .connect, .batchStartup:
                connectionProtocol == .sftp ? .sftp : .preferredTerminal
            }
        return app.hostLibrary.hosts(matching: query, for: useCase)
    }

    var body: some View {
        Group {
            switch purpose {
            case .connect, .batchStartup, .metrics:
                formChooser
            case .snippet:
                managedChooser
            }
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
        .onAppear {
            if purpose == .metrics {
                let available = Set(app.hostLibrary.hosts(matching: "", for: .metrics).map(\.id))
                chooser.selected = Set(app.serverMetrics.selections.map(\.id)).intersection(available)
                initialMetricsHostIDs = chooser.selected
            }
        }
        .task(id: connectionProtocol) {
            guard connectionProtocol == .serial else { return }
            for await ports in app.serialPorts.portUpdates() {
                guard !Task.isCancelled else { return }
                serialPorts = ports
            }
        }
        .confirmationDialog(
            AppStrings.Snippets.runADestructiveScriptConfirmation,
            isPresented: $isConfirmingDestructiveSnippet,
            titleVisibility: .visible
        ) {
            Button(
                chooser.selected.count == 1
                    ? AppStrings.Snippets.runOn1Host.swiftUIKey
                    : AppStrings.Snippets.runOnHosts(chooser.selected.count).swiftUIKey,
                role: .destructive
            ) {
                performSnippetExecution()
            }
            Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) {}
        } message: {
            Text(snippetConfirmationMessage)
        }
    }

    // MARK: - Pieces

    private var managedChooser: some View {
        SheetScaffold {
            managedHeader
        } content: {
            hostList
        } footer: {
            managedFooter
        }
    }

    private var formChooser: some View {
        VStack(spacing: 0) {
            formTopBar

            if connectionProtocol == .serial {
                serialForm
            } else {
                VStack(spacing: Metrics.Space.m) {
                    ConnectionChooserSearchField(
                        prompt: AppStrings.Vault.searchHosts,
                        query: queryBinding,
                        onSubmit: openSelected,
                        moveCursor: move,
                        toggleCursor: toggleCursor
                    )
                    .padding(.horizontal, Metrics.Space.xl)

                    multiSelectionHostList
                }
                .padding(.top, Metrics.Space.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TermindColor.windowSurface)
    }

    private var formTopBar: some View {
        HStack {
            glassActionButton(
                AppStrings.Common.cancel,
                symbol: "xmark",
                identifier: "host-chooser.cancel",
                action: close
            )
            .keyboardShortcut(.cancelAction)

            Spacer()

            if showsTopConfirmation {
                glassActionButton(
                    purpose.confirmLabel,
                    symbol: "checkmark",
                    identifier: "host-chooser.confirm",
                    action: openSelected
                )
                .keyboardShortcut(.defaultAction)
                .disabled(connectIsDisabled)
            } else {
                Color.clear.frame(width: 30, height: 30)
            }
        }
        .frame(maxWidth: .infinity)
        .overlay {
            if purpose.choosesConnectionProtocol {
                connectionProtocolPicker
                    .termindGlassSurface(cornerRadius: Metrics.Radius.medium, isInteractive: true)
                    .frame(width: protocolPickerWidth, height: 30)
            } else {
                Text(purpose.title).font(.headline)
            }
        }
        .padding(.horizontal, Metrics.Space.xl)
        .padding(.top, Metrics.Space.l)
        .padding(.bottom, Metrics.Space.s)
        .accessibilityElement(children: .contain)
    }

    private var protocolPickerWidth: CGFloat {
        purpose.availableConnectionProtocols.count == 3 ? 240 : 180
    }

    private func glassActionButton(
        _ label: LocalizedStringResource,
        symbol: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: symbol)
                .labelStyle(.iconOnly)
                .frame(width: 30, height: 30)
                .contentShape(.circle)
                .accessibilityIdentifier(identifier)
        }
        .accessibilityIdentifier(identifier)
        .buttonStyle(.plain)
        .termindGlassCircle(isInteractive: true)
        .help(label)
        .accessibilityLabel(Text(label))
    }

    private var showsTopConfirmation: Bool {
        purpose.formShowsConfirmation(for: connectionProtocol)
    }

    private var managedHeader: some View {
        ManagedChooserHeader(
            title: purpose.title,
            symbol: purpose.symbol,
            prompt: AppStrings.Vault.searchHosts,
            query: queryBinding,
            onSubmit: openSelected,
            moveCursor: move,
            toggleCursor: toggleCursor
        )
    }

    private var connectionProtocolPicker: some View {
        Picker(AppStrings.Vault.connectionProtocol.swiftUIKey, selection: $connectionProtocol) {
            ForEach(purpose.availableConnectionProtocols) { connectionProtocol in
                Text(connectionProtocol.displayName(locale: locale)).tag(connectionProtocol)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(AppStrings.Vault.connectionProtocolLabel.swiftUIKey)
    }

    private var multiSelectionHostList: some View {
        VStack(spacing: 0) {
            if purpose.allowsMultiple {
                Button(selectAllLabel) {
                    toggleAllResults()
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metrics.Space.xl)
                .padding(.vertical, Metrics.Space.m)
                .contentShape(.rect)
                .disabled(results.isEmpty)
                .accessibilityIdentifier("host-chooser.select-all")

                Divider()
            }

            hostList
        }
    }

    @ViewBuilder
    private var hostList: some View {
        if app.hostLibrary.hosts.isEmpty {
            ContentUnavailableView {
                Label(AppStrings.Vault.noHosts.swiftUIKey, systemImage: "server.rack")
            } description: {
                Text(AppStrings.Vault.addAHostToConnectToIt)
            } actions: {
                Button(AppStrings.Vault.newHost.swiftUIKey) {
                    close()
                    window.openHostEditor(host: nil)
                }
            }
            .frame(maxHeight: .infinity)
        } else if results.isEmpty {
            ContentUnavailableView.search(text: query)
                .frame(maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(results) { host in
                        hostButton(host)
                    }
                }
                .listStyle(.inset)
                .onAppear { scrollCursorIntoView(using: proxy) }
                .onChange(of: chooser.cursor) { _, _ in scrollCursorIntoView(using: proxy) }
                .onChange(of: results.map(\.id)) { _, _ in scrollCursorIntoView(using: proxy) }
            }
        }
    }

    private func hostButton(_ host: Host) -> some View {
        Button {
            activate(host)
        } label: {
            HostChooserRow(
                host: host,
                isCursor: chooser.cursor == host.id,
                isChecked: purpose.allowsMultiple
                    ? chooser.selected.contains(host.id) : nil,
                connectionProtocol: connectionProtocol
            )
            .accessibilityIdentifier("host-chooser.host.\(host.id)")
        }
        .accessibilityIdentifier("host-chooser.host.\(host.id)")
        .buttonStyle(.plain)
        .id(host.id)
        .listRowBackground(
            chooser.cursor == host.id
                ? Color.accentColor.opacity(0.11) : Color.clear
        )
    }

    private func scrollCursorIntoView(using proxy: ScrollViewProxy) {
        guard let cursor = chooser.cursor else { return }
        proxy.scrollTo(cursor)
    }

    private var serialForm: some View {
        Form {
            Section(AppStrings.Vault.device.swiftUIKey) {
                SerialEditableComboField(
                    title: AppStrings.Vault.devicePath,
                    value: $serialConfiguration.devicePath,
                    options: serialPorts.map {
                        SerialComboOption(value: $0.path, label: $0.displayName)
                    }
                )
                if serialPorts.isEmpty {
                    Text(AppStrings.Vault.noSerialDevicesExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(AppStrings.Vault.communication.swiftUIKey) {
                SerialEditableComboField(
                    title: AppStrings.Vault.baudRate,
                    value: $serialBaudRate,
                    options: SerialConnectionConfiguration.commonBaudRates.map {
                        SerialComboOption(value: String($0), label: $0.formatted())
                    }
                )
                Picker(AppStrings.Vault.dataBits.swiftUIKey, selection: $serialConfiguration.dataBits) {
                    ForEach(SerialDataBits.allCases) { Text("\($0.rawValue)").tag($0) }
                }
                Picker(AppStrings.Vault.parity.swiftUIKey, selection: $serialConfiguration.parity) {
                    ForEach(SerialParity.allCases) { Text($0.displayName).tag($0) }
                }
                Picker(AppStrings.Vault.stopBits.swiftUIKey, selection: $serialConfiguration.stopBits) {
                    ForEach(SerialStopBits.allCases) { Text("\($0.rawValue)").tag($0) }
                }
                Picker(AppStrings.Vault.flowControl.swiftUIKey, selection: $serialConfiguration.flowControl) {
                    ForEach(SerialFlowControl.allCases) { Text($0.displayName).tag($0) }
                }
            }

            Section(AppStrings.Settings.terminal.swiftUIKey) {
                Picker(AppStrings.Vault.charset.swiftUIKey, selection: $serialConfiguration.charset) {
                    ForEach(RemoteCharset.allCases) { charset in
                        Text(charset.displayName).tag(charset)
                    }
                }
                Picker(AppStrings.Vault.enterSends.swiftUIKey, selection: $serialConfiguration.enterKey) {
                    ForEach(SerialEnterKey.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle(AppStrings.Vault.localEcho.swiftUIKey, isOn: $serialConfiguration.localEcho)
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

    private var managedFooter: some View {
        HStack {
            if purpose.allowsMultiple, connectionProtocol != .serial {
                Text(
                    AppLocalization.resolve(
                        AppStrings.Common.selected(chooser.selected.count), locale: locale
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

            Button(AppStrings.Common.cancel.swiftUIKey, action: close)
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
        if purpose == .metrics { return false }
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
            serialError = AppLocalization.resolve(
                AppStrings.Vault.theDevicePathDoesNotExist, locale: locale
            )
            return
        }
        guard (info.st_mode & S_IFMT) == S_IFCHR else {
            serialError = AppLocalization.resolve(
                AppStrings.Vault.theDevicePathIsNotACharacterDevice, locale: locale
            )
            return
        }
        serialConfiguration.devicePath = path
        window.openSerialSession(configuration: serialConfiguration, service: app.serialPorts)
        dismiss()
    }

    private func openChecked() {
        if purpose == .metrics {
            let editable = app.hostLibrary.hosts(matching: "", for: .metrics)
            window.pendingMetricsHostIDs = editable.filter { chooser.selected.contains($0.id) }.map(\.id)
            window.pendingMetricsEditableHostIDs = initialMetricsHostIDs.union(chooser.selected)
            dismiss()
            return
        }
        let batch = app.hostLibrary.searchHosts("").filter { chooser.selected.contains($0.id) }
        guard !batch.isEmpty else { return }
        if case .snippet = purpose {
            requestSnippetExecution()
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
        AppLocalization.resolve(
            allResultsChecked ? AppStrings.Common.deselectAll : AppStrings.Common.selectAll, locale: locale
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

private struct ConnectionChooserSearchField: View {
    let prompt: LocalizedStringResource
    @Binding var query: String
    var onSubmit: () -> Void = {}
    var moveCursor: (Int) -> KeyPress.Result = { _ in .ignored }
    var toggleCursor: () -> KeyPress.Result = { .ignored }

    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: Metrics.Space.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $query.singleLineText, axis: .horizontal).singleLinePaste().lineLimit(1)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit(onSubmit)
                .onKeyPress(.upArrow) { moveCursor(-1) }
                .onKeyPress(.downArrow) { moveCursor(1) }
                .onKeyPress(.space, action: toggleCursor)

            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(AppStrings.Common.clearSearch))
            }
        }
        .padding(Metrics.Space.s)
        .background(
            .quaternary.opacity(0.5),
            in: .rect(cornerRadius: Metrics.Radius.medium)
        )
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                searchFocused = true
            }
        }
    }
}

// MARK: - Row

/// One host, as the chooser lists it. The shared piece between the verbs: what
/// you need to recognise a machine is the same whether you are about to type on
/// it or copy files to it.
///
/// `isChecked` is nil outside batch mode. Multi-selection reveals the native
/// trailing checkmark only for rows that will be acted on.
struct HostChooserRow: View {
    let host: Host
    let isCursor: Bool
    var isChecked: Bool?
    var connectionProtocol: HostConnectionProtocol = .terminal

    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: Metrics.Space.m) {
            HostDistributionIcon(host: host)

            VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                Text(host.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(
                    connectionProtocol == .terminal
                        ? app.hostLibrary.preferredTerminalLoginAddress(for: host)
                        : app.hostLibrary.loginAddress(for: host)
                )
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }

            Spacer(minLength: Metrics.Space.s)

            if isChecked == true {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
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
}

#Preview("Connect") {
    HostChooserView(purpose: .connect)
        .environment(AppModel(hosts: .demo()))
        .environment(WindowModel())
}

/// Batch Startup uses the same continuous picker, with a confirmation action
/// opposite Cancel and a Select All row above the hosts.
#Preview("Batch Startup") {
    HostChooserView(purpose: .batchStartup)
        .environment(AppModel(hosts: .demo()))
        .environment(WindowModel())
}
