import AppKit
import ListViewKit
import SwiftUI

struct SnippetExecutionTargetsView: View {
    let request: SnippetHostChooserRequest

    var body: some View {
        HostChooserView(purpose: .snippet(request), presentation: .vaultWork)
    }
}

struct SnippetBatch: Identifiable {
    let id = UUID()
    let snippets: [Snippet]
}

@Observable
final class SnippetsPageState {
    enum ConfirmationRoute: Identifiable {
        case deletePackage(SnippetPackage)
        case deleteSnippets(SnippetBatch)
        case executeDestructive(SnippetBatch)

        var id: String {
            switch self {
            case .deletePackage(let package): "delete-package-\(package.id)"
            case .deleteSnippets(let batch): "delete-snippets-\(batch.id)"
            case .executeDestructive(let batch): "execute-\(batch.id)"
            }
        }
    }

    var query = ""
    var selectedPackageID: SnippetPackage.ID?
    var confirmation: ConfirmationRoute?
}

/// Saved scripts, organised into nested Packages and launched as visible
/// terminal Workspaces. ManagedCardPage owns selection and drag geometry; this
/// page supplies only the Package sections and business actions.
struct SnippetsPageView: ManagedCardPage {
    nonisolated enum SectionID: Hashable {
        case results
        case package(SnippetPackage.ID)
        case ungrouped

        var packageID: SnippetPackage.ID? {
            if case .package(let id) = self { return id }
            return nil
        }
    }

    private struct Section {
        let id: SectionID
        let title: String
        var isExpanded: Bool?
        let snippets: [Snippet]
    }

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    let state: SnippetsPageState

    init(state: SnippetsPageState = SnippetsPageState()) {
        self.state = state
    }

    private var selection: Set<Snippet.ID> {
        Set(
            window.vaultSelection(for: .snippets).compactMap { detail in
                detail.snippetID
            })
    }

    private var isFiltering: Bool { !state.query.isEmpty }

    private var sections: [Section] {
        if isFiltering {
            let matches = app.snippets.searchSnippets(state.query)
            guard !matches.isEmpty else { return [] }
            return [
                Section(
                    id: .results, title: String(localized: "Results"),
                    isExpanded: nil, snippets: matches
                )
            ]
        }

        var result: [Section] = []
        func walk(_ package: SnippetPackage, prefix: String) {
            let title = prefix.isEmpty ? package.name : "\(prefix) / \(package.name)"
            result.append(
                Section(
                    id: .package(package.id), title: title,
                    isExpanded: package.isExpanded,
                    snippets: app.snippets.snippets(in: package.id)
                )
            )
            guard package.isExpanded else { return }
            for child in app.snippets.childSnippetPackages(of: package.id) {
                walk(child, prefix: title)
            }
        }
        for package in app.snippets.rootSnippetPackages { walk(package, prefix: "") }

        let ungrouped = app.snippets.snippets(in: nil)
        if !ungrouped.isEmpty || !app.snippets.snippetPackages.isEmpty {
            result.append(
                Section(
                    id: .ungrouped, title: String(localized: "Ungrouped"),
                    isExpanded: app.snippets.isSnippetsUngroupedExpanded,
                    snippets: ungrouped
                )
            )
        }
        return result
    }

    // MARK: ManagedCardPage

    var managedSections: [ManagedCardSection<SectionID, Snippet>] {
        sections.map {
            ManagedCardSection(
                id: $0.id, title: $0.title, items: $0.snippets,
                isExpanded: $0.isExpanded,
                canAcceptDrop: $0.id != .results
            )
        }
    }

    var managedSelection: ManagedCardSelection<Snippet.ID> {
        ManagedCardSelection(selected: { selection }, update: setSelection)
    }

    var managedCapabilities: ManagedCardCapabilities<SectionID, Snippet.ID> {
        ManagedCardCapabilities(
            selection: .multiple,
            marqueeSelection: true,
            reordering: ManagedCardReordering(
                isEnabled: !isFiltering,
                dropPolicy: .anySection
            ) { ids, destination, next in
                app.snippets.move(
                    snippetIDs: ids, into: destination.packageID, before: next
                )
            }
        )
    }

    var isManagedSourceEmpty: Bool {
        app.snippets.snippets.isEmpty && app.snippets.snippetPackages.isEmpty
    }

    @ViewBuilder
    func managedHeader(
        for section: ManagedCardSection<SectionID, Snippet>, isDropTarget: Bool
    ) -> some View {
        switch section.id {
        case .package(let id):
            if let package = app.snippets.snippetPackage(id) {
                CardSectionHeader(
                    title: section.title, count: section.items.count,
                    toggle: {
                        app.snippets.setSnippetPackageExpanded(
                            !package.isExpanded, for: package.id
                        )
                    },
                    isCollapsed: !package.isExpanded,
                    select: { selectPackage(package.id) },
                    isSelected: state.selectedPackageID == package.id,
                    isDropTarget: isDropTarget
                )
                .contextMenu {
                    Button("New Subpackage") {
                        openPackageEditor(packageID: nil, parentID: package.id)
                    }
                    Button("Edit") {
                        openPackageEditor(packageID: package.id, parentID: package.parentID)
                    }
                    Divider()
                    DestructiveMenuButton("Delete Package") {
                        state.confirmation = .deletePackage(package)
                    }
                }
            }
        case .ungrouped:
            CardSectionHeader(
                title: section.title, count: section.items.count,
                toggle: {
                    app.snippets.setSnippetsUngroupedExpanded(
                        !app.snippets.isSnippetsUngroupedExpanded
                    )
                },
                isCollapsed: !app.snippets.isSnippetsUngroupedExpanded,
                isDropTarget: isDropTarget
            )
        case .results:
            CardSectionHeader(title: section.title, count: section.items.count)
        }
    }

    func managedCard(
        for snippet: Snippet, context: ManagedCardItemContext<Snippet>
    ) -> some View {
        SnippetCard(
            snippet: snippet,
            isSelected: context.isSelected,
            select: context.select,
            extendSelection: context.extendSelection,
            actionSnippets: context.actionItems,
            execute: requestExecution,
            executeOnHosts: executeOnHosts,
            edit: { openSnippetEditor(snippetID: snippet.id, packageID: snippet.packageID) },
            duplicate: duplicate,
            delete: {
                state.confirmation = .deleteSnippets(SnippetBatch(snippets: $0))
            }
        )
    }

    func managedGhost(for snippet: Snippet) -> some View {
        SnippetGhostCard(snippet: snippet)
    }

    /// Right-clicking inside a package files the new snippet or subpackage
    /// there. Results is a view of matches from everywhere, so it files at the
    /// root rather than guessing which package the user meant.
    func managedBlankAreaMenu(for section: SectionID?) -> [NativeMenuEntry] {
        let packageID = section?.packageID
        return [
            NativeMenuEntry(title: String(localized: "New Snippet")) {
                openSnippetEditor(snippetID: nil, packageID: packageID)
            },
            NativeMenuEntry(title: String(localized: "New Package")) {
                openPackageEditor(packageID: nil, parentID: packageID)
            },
        ]
    }

    func managedEmptyState() -> some View {
        ContentUnavailableView {
            Label("No Snippets", systemImage: "curlybraces")
        } description: {
            Text("Save a script and optionally choose its default hosts.")
        } actions: {
            HStack {
                Button("New Package") {
                    openPackageEditor(packageID: nil, parentID: nil)
                }
                Button("New Snippet") {
                    openSnippetEditor(snippetID: nil, packageID: nil)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func managedNoResultsState() -> some View {
        ContentUnavailableView.search(text: state.query)
    }

    var managedPresentation: SnippetsPagePresentation {
        SnippetsPagePresentation(
            state: state,
            actions: SnippetsPagePresentation.Actions(
                store: app.snippets,
                saveSnippet: saveSnippet,
                savePackage: savePackage,
                deletePackage: deletePackage,
                deleteSnippets: deleteSnippets,
                performExecution: performExecution,
                executionMessage: executionMessage
            )
        )
    }

    // MARK: Actions

    private var visibleSnippets: [Snippet] { sections.flatMap(\.snippets) }

    private func setSelection(_ ids: Set<Snippet.ID>) {
        let valid = ids.intersection(Set(app.snippets.snippets.map(\.id)))
        state.selectedPackageID = nil
        let ordered = visibleSnippets.filter { valid.contains($0.id) }
            .map { VaultSelectionID.snippet($0.id) }
        window.setVaultSelection(ordered, for: .snippets)
    }

    private func selectPackage(_ id: SnippetPackage.ID) {
        window.clearVaultSelection(for: .snippets)
        state.selectedPackageID = id
    }

    private func saveSnippet(_ snippet: Snippet) {
        app.snippets.upsert(snippet)
        window.selectVaultItem(.snippet(snippet.id), on: .snippets)
    }

    private func duplicate(_ snippet: Snippet) {
        var copy = snippet
        copy.id = UUID()
        copy.title = String(localized: "\(snippet.title) Copy")
        copy.sortIndex = 0
        saveSnippet(copy)
    }

    private func savePackage(_ package: SnippetPackage) {
        app.snippets.upsert(package)
    }

    private func deletePackage(_ package: SnippetPackage, keepSnippets: Bool) {
        let deletedPackageIDs = Set(
            [package.id] + app.snippets.descendantSnippetPackages(of: package.id).map(\.id)
        )
        app.snippets.delete(snippetPackageID: package.id, keepSnippets: keepSnippets)
        state.confirmation = nil
        if let selectedPackageID = state.selectedPackageID,
            deletedPackageIDs.contains(selectedPackageID)
        {
            state.selectedPackageID = nil
        }
        window.pruneVaultSelections(in: app.snippets)
    }

    private func deleteSnippets(_ snippets: [Snippet]) {
        app.snippets.delete(snippetIDs: snippets.map(\.id))
        state.confirmation = nil
        window.pruneVaultSelections(in: app.snippets)
    }

    private func requestExecution(_ snippets: [Snippet]) {
        guard !snippets.isEmpty else { return }
        if snippets.contains(where: { $0.targetHostIDs.isEmpty }) {
            window.openVaultWork(
                .snippetExecutionTargets(
                    SnippetHostChooserRequest(
                        snippetIDs: snippets.map(\.id), strategy: .fillMissingTargets
                    )
                ),
                on: .snippets
            )
            return
        }
        if snippets.contains(where: {
            CommandRiskClassifier.assess($0.body).risk == .destructive
        }) {
            state.confirmation = .executeDestructive(SnippetBatch(snippets: snippets))
        } else {
            performExecution(snippets)
        }
    }

    private func performExecution(_ snippets: [Snippet]) {
        state.confirmation = nil
        app.execute(snippets, in: window)
    }

    private func executeOnHosts(_ snippets: [Snippet]) {
        guard !snippets.isEmpty else { return }
        window.openVaultWork(
            .snippetExecutionTargets(
                SnippetHostChooserRequest(
                    snippetIDs: snippets.map(\.id), strategy: .overrideAllTargets
                )
            ),
            on: .snippets
        )
    }

    private func executionMessage(_ snippets: [Snippet]) -> String {
        snippets.map { snippet in
            let wanted = Set(snippet.targetHostIDs)
            let targets = app.snippets.searchHosts("").filter { wanted.contains($0.id) }
                .map(\.name).joined(separator: ", ")
            return "• \(snippet.body)\n  \(targets)"
        }.joined(separator: "\n")
    }

    private func openSnippetEditor(
        snippetID: Snippet.ID?, packageID: SnippetPackage.ID?
    ) {
        window.openVaultWork(
            .snippetEditor(snippetID: snippetID, packageID: packageID), on: .snippets
        )
    }

    private func openPackageEditor(
        packageID: SnippetPackage.ID?, parentID: SnippetPackage.ID?
    ) {
        window.openVaultWork(
            .snippetPackageEditor(packageID: packageID, parentID: parentID), on: .snippets
        )
    }
}

struct SnippetsPagePresentation: ManagedCardPresentationModifier {
    struct Actions {
        let store: SnippetLibraryModel
        let saveSnippet: (Snippet) -> Void
        let savePackage: (SnippetPackage) -> Void
        let deletePackage: (SnippetPackage, Bool) -> Void
        let deleteSnippets: ([Snippet]) -> Void
        let performExecution: ([Snippet]) -> Void
        let executionMessage: ([Snippet]) -> String
    }

    let state: SnippetsPageState
    let actions: Actions

    func body(content: Content) -> some View {
        @Bindable var state = state
        content
            .confirmationDialog(
                confirmationTitle,
                isPresented: Binding(
                    get: { state.confirmation != nil },
                    set: { if !$0 { state.confirmation = nil } }
                ),
                titleVisibility: .visible
            ) {
                confirmationActions
                Button("Cancel", role: .cancel) { state.confirmation = nil }
            } message: {
                confirmationMessage
            }
    }

    @ViewBuilder
    private var confirmationActions: some View {
        switch state.confirmation {
        case .deletePackage(let package):
            Button("Delete Package and Snippets", role: .destructive) {
                actions.deletePackage(package, false)
            }
            Button("Keep Snippets") { actions.deletePackage(package, true) }
        case .deleteSnippets(let batch):
            Button(
                batch.snippets.count == 1
                    ? "Delete Snippet" : "Delete \(batch.snippets.count) Snippets",
                role: .destructive
            ) {
                actions.deleteSnippets(batch.snippets)
            }
        case .executeDestructive(let batch):
            Button("Execute", role: .destructive) {
                actions.performExecution(batch.snippets)
            }
        case nil:
            EmptyView()
        }
    }

    private var confirmationTitle: LocalizedStringKey {
        switch state.confirmation {
        case .deletePackage(let package): "Delete “\(package.name)”?"
        case .deleteSnippets(let batch):
            batch.snippets.count == 1 ? "Delete Snippet?" : "Delete Snippets?"
        case .executeDestructive: "Execute destructive scripts?"
        case nil: ""
        }
    }

    private var confirmationMessage: Text {
        switch state.confirmation {
        case .deletePackage(let package):
            let packages = Set(
                [package.id] + actions.store.descendantSnippetPackages(of: package.id).map(\.id)
            )
            let count = actions.store.snippets.filter {
                $0.packageID.map(packages.contains) == true
            }.count
            return count == 1
                ? Text("This package contains 1 snippet.")
                : Text("This package tree contains \(count) snippets.")
        case .executeDestructive(let batch):
            return Text(actions.executionMessage(batch.snippets))
        case .deleteSnippets, nil:
            return Text("")
        }
    }
}

private struct SnippetCard: View {
    let snippet: Snippet
    let isSelected: Bool
    let select: () -> Void
    let extendSelection: () -> Void
    let actionSnippets: [Snippet]
    let execute: ([Snippet]) -> Void
    let executeOnHosts: ([Snippet]) -> Void
    let edit: () -> Void
    let duplicate: (Snippet) -> Void
    let delete: ([Snippet]) -> Void

    var body: some View {
        CardTile(
            selectionID: snippet.id,
            isSelected: isSelected,
            select: select,
            extendSelection: extendSelection,
            activate: { execute(actionSnippets) }
        ) {
            VStack(alignment: .leading, spacing: Metrics.Space.m) {
                HStack(spacing: Metrics.Space.m) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snippet.title).font(.headline).lineLimit(1)
                        Text(targetSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Metrics.Space.xs)
                    RiskBadge(
                        assessment: CommandRiskClassifier.assess(snippet.body),
                        compact: true
                    )
                }

                Text(snippet.body)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3, reservesSpace: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Metrics.Space.s)
                    .background(
                        .quaternary.opacity(0.5),
                        in: .rect(cornerRadius: Metrics.Radius.small)
                    )

            }
        }
        .contextMenu {
            Button("Execute") { execute(actionSnippets) }
            Button("Execute on Hosts") { executeOnHosts(actionSnippets) }
            if actionSnippets.count == 1 {
                Divider()
                Button("Edit", action: edit)
                Button("Duplicate") { duplicate(snippet) }
            }
            Divider()
            DestructiveMenuButton("Delete") { delete(actionSnippets) }
        }
        .help(Text(snippet.body))
    }

    private var targetSummary: String {
        switch snippet.targetHostIDs.count {
        case 0: String(localized: "No targets")
        case 1: String(localized: "1 target")
        default: String(localized: "\(snippet.targetHostIDs.count) targets")
        }
    }
}

private struct SnippetGhostCard: View {
    let snippet: Snippet

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            HStack(spacing: Metrics.Space.m) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(snippet.title).font(.headline).lineLimit(1)
                    Text(targetSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Metrics.Space.xs)
                RiskBadge(
                    assessment: CommandRiskClassifier.assess(snippet.body),
                    compact: true
                )
            }

            Text(snippet.body)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(3, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Metrics.Space.s)
                .background(
                    .quaternary.opacity(0.5),
                    in: .rect(cornerRadius: Metrics.Radius.small)
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.Space.l)
        .frame(minHeight: Metrics.Card.minHeight, alignment: .top)
        .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: Metrics.Radius.large))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.Radius.large)
                .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }

    private var targetSummary: String {
        switch snippet.targetHostIDs.count {
        case 0: String(localized: "No targets")
        case 1: String(localized: "1 target")
        default: String(localized: "\(snippet.targetHostIDs.count) targets")
        }
    }
}

struct SnippetEditorSheet: View {
    private enum Route: Hashable { case targets }

    let existing: Snippet?
    let save: (Snippet) -> Void
    var requestedClose: (() -> Void)?

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var bodyText: String
    @State private var packageID: SnippetPackage.ID?
    @State private var targets: Set<Host.ID>
    @State private var path: [Route] = []

    init(
        snippet: Snippet? = nil, packageID: SnippetPackage.ID? = nil,
        save: @escaping (Snippet) -> Void,
        close: (() -> Void)? = nil
    ) {
        existing = snippet
        self.save = save
        requestedClose = close
        _title = State(initialValue: snippet?.title ?? "")
        _bodyText = State(initialValue: snippet?.body ?? "")
        _packageID = State(initialValue: snippet?.packageID ?? packageID)
        _targets = State(initialValue: Set(snippet?.targetHostIDs ?? []))
    }

    var body: some View {
        NavigationStack(path: $path) {
            editor
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .targets:
                        SnippetTargetPickerSheet(selected: targets) { targets = $0 }
                    }
                }
        }
    }

    private var editor: some View {
        VaultDetailScaffold(
            title: existing == nil ? "New Snippet" : "Edit Snippet",
            symbol: "curlybraces", close: close
        ) {
            Form {
                Section {
                    TextField("Name", text: $title)
                    VStack(alignment: .leading, spacing: Metrics.Space.s) {
                        Text("Script")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $bodyText)
                            .font(.body.monospaced())
                            .frame(minHeight: 180)
                    }
                    RiskBadge(assessment: CommandRiskClassifier.assess(bodyText))
                }
                Section("Package") {
                    Picker("Package", selection: $packageID) {
                        Text("Ungrouped").tag(SnippetPackage.ID?.none)
                        ForEach(packageChoices, id: \.package.id) { choice in
                            Text(choice.path).tag(SnippetPackage.ID?.some(choice.package.id))
                        }
                    }
                }
                Section {
                    if selectedHosts.isEmpty {
                        Text(
                            app.snippets.hosts.isEmpty
                                ? String(localized: "No saved hosts")
                                : String(localized: "No targets selected")
                        )
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(selectedHosts) { host in
                            HStack(spacing: Metrics.Space.m) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(host.name)
                                    Text(app.snippets.loginAddress(for: host))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    targets.remove(host.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help(Text("Remove \(host.name)"))
                                .accessibilityLabel(Text("Remove \(host.name)"))
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Targets")
                        Spacer()
                        Button {
                            path.append(.targets)
                        } label: {
                            Label("Add Hosts", systemImage: "plus")
                        }
                        .disabled(app.snippets.hosts.isEmpty)
                    }
                }
            }
            .formStyle(.grouped)
        } footer: {
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Add" : "Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedTitle.isEmpty || trimmedBody.isEmpty)
            }
            .padding(Metrics.Space.l)
        }
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedBody: String { bodyText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var packageChoices: [(package: SnippetPackage, path: String)] {
        app.snippets.snippetPackages.compactMap { package in
            app.snippets.snippetPackagePath(package.id).map { (package, $0) }
        }.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private var selectedHosts: [Host] {
        app.snippets.searchHosts("").filter { targets.contains($0.id) }
    }

    private func close() {
        if let requestedClose { requestedClose() } else { dismiss() }
    }

    private func commit() {
        let orderedTargets = app.snippets.searchHosts("").filter { targets.contains($0.id) }.map(\.id)
        save(
            Snippet(
                id: existing?.id ?? UUID(), title: trimmedTitle, body: trimmedBody,
                packageID: packageID, targetHostIDs: orderedTargets,
                sortIndex: existing?.sortIndex ?? 0
            )
        )
        close()
    }
}

private struct SnippetTargetPickerSheet: View {
    let save: (Set<Host.ID>) -> Void
    let initialSelection: Set<Host.ID>

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var chooser: ManagedChooserState<Host.ID>

    init(selected: Set<Host.ID>, save: @escaping (Set<Host.ID>) -> Void) {
        self.save = save
        initialSelection = selected
        _chooser = State(
            initialValue: ManagedChooserState(mode: .multiple, selected: selected)
        )
    }

    private var query: String { chooser.query }
    private var queryBinding: Binding<String> {
        Binding(get: { chooser.query }, set: { chooser.query = $0 })
    }

    var body: some View {
        VaultDetailScaffold(
            title: "Add Hosts", symbol: "server.rack", close: { dismiss() },
            closeLabel: "Back", closeSymbol: "chevron.backward"
        ) {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.7)
                content
            }
        } footer: {
            footer
        }
        .onAppear {
            let available = Set(app.snippets.hosts.map(\.id))
            chooser.selected = initialSelection.intersection(available)
        }
        .onChange(of: chooser.query) {
            let ids = results.map(\.id)
            chooser.queryDidChange(visible: ids, enabled: Set(ids))
        }
    }

    private var header: some View {
        ManagedChooserHeader(
            title: "Add Hosts",
            symbol: "server.rack",
            prompt: "Search hosts",
            query: queryBinding,
            onSubmit: commit,
            moveCursor: moveCursor,
            toggleCursor: toggleCursor
        )
    }

    @ViewBuilder
    private var content: some View {
        if app.snippets.hosts.isEmpty {
            ContentUnavailableView {
                Label("No Hosts", systemImage: "server.rack")
            } description: {
                Text("Add a host before choosing default targets.")
            }
        } else if results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            SnippetTargetNativeList(items: targetListItems) { item in
                HostChooserRow(
                    host: item.host,
                    isSelected: item.isCursor,
                    isChecked: item.isChecked
                )
                .onTapGesture { chooser.activate(item.id) }
                }
            .padding(.horizontal, Metrics.Space.l)
            .padding(.bottom, Metrics.Space.s)
        }
    }

    private var targetListItems: [SnippetTargetListItem] {
        results.map {
            SnippetTargetListItem(
                host: $0,
                isCursor: chooser.cursor == $0.id,
                isChecked: chooser.selected.contains($0.id)
            )
        }
    }

    private var footer: some View {
        HStack {
            Text("\(chooser.selected.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button(allResultsChecked ? "Deselect All" : "Select All") {
                toggleAllResults()
            }
            .disabled(results.isEmpty)

            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Done", action: commit)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(Metrics.Space.l)
    }

    private var results: [Host] { app.snippets.searchHosts(query) }

    private var allResultsChecked: Bool {
        !results.isEmpty && results.allSatisfy { chooser.selected.contains($0.id) }
    }

    private func toggleAllResults() {
        let ids = results.map(\.id)
        chooser.toggleAll(visible: ids, enabled: Set(ids))
    }

    private func moveCursor(_ delta: Int) -> KeyPress.Result {
        chooser.moveCursor(by: delta, through: results.map(\.id))
        return results.isEmpty ? .ignored : .handled
    }

    private func toggleCursor() -> KeyPress.Result {
        guard let cursor = chooser.cursor else { return .ignored }
        chooser.toggle(cursor)
        return .handled
    }

    private func commit() {
        save(chooser.selected)
        dismiss()
    }
}

nonisolated private struct SnippetTargetListItem: Identifiable, Hashable, Sendable {
    let host: Host
    let isCursor: Bool
    let isChecked: Bool
    var id: Host.ID { host.id }
}

private struct SnippetTargetNativeList: NSViewRepresentable {
    typealias NSViewType = ListView<SnippetTargetListItem>
    typealias Renderer = @MainActor (SnippetTargetListItem) -> AnyView
    let items: [SnippetTargetListItem]
    let renderer: Renderer
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme

    init(
        items: [SnippetTargetListItem],
        @ViewBuilder renderer: @escaping @MainActor (SnippetTargetListItem) -> some View
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
        private var content: [SnippetTargetListItem] = []

        func makeListView() -> NSViewType {
            let listView = NSViewType()
            listView.rowAnimator = ListBouncyAnimator(style: .regular)
            listView.estimatedRowHeight = 52
            listView.rows {
                ListRow(SnippetTargetHostingRow.self)
                    .height { _, _ in 52 }
                    .configure { [weak self] row, item, _ in self?.configure(row, item: item) }
            }
            return listView
        }

        func update(
            listView: NSViewType, items: [SnippetTargetListItem], renderer: @escaping Renderer,
            locale: Locale, colorScheme: ColorScheme
        ) {
            self.renderer = renderer
            let environmentChanged = self.locale != locale || self.colorScheme != colorScheme
            self.locale = locale
            self.colorScheme = colorScheme
            if content.map(\.id) == items.map(\.id) {
                for (old, new) in zip(content, items) where old != new {
                    listView.update(new)
                }
                if environmentChanged { listView.reloadData() }
            } else {
                listView.apply(items, animated: !content.isEmpty)
            }
            content = items
            if let cursor = items.first(where: \.isCursor) {
                listView.scrollToRow(with: cursor.id, at: .nearest, animated: false)
            }
        }

        private func configure(_ row: SnippetTargetHostingRow, item: SnippetTargetListItem) {
            guard let renderer else { return }
            let root = renderer(item)
                .id(item.id)
                .environment(\.locale, locale)
                .environment(\.colorScheme, colorScheme)
            row.configure(rootView: AnyView(root))
        }
    }
}

@MainActor
private final class SnippetTargetHostingRow: ListRowView {
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

struct SnippetPackageSheet: View {
    let existing: SnippetPackage?
    let save: (SnippetPackage) -> Void
    var requestedClose: (() -> Void)?

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var parentID: SnippetPackage.ID?

    init(
        package: SnippetPackage? = nil, parentID: SnippetPackage.ID? = nil,
        save: @escaping (SnippetPackage) -> Void,
        close: (() -> Void)? = nil
    ) {
        existing = package
        self.save = save
        requestedClose = close
        _name = State(initialValue: package?.name ?? "")
        _parentID = State(initialValue: package?.parentID ?? parentID)
    }

    var body: some View {
        VaultDetailScaffold(
            title: existing == nil ? "New Package" : "Edit Package",
            symbol: "folder.fill", close: close
        ) {
            Form {
                TextField("Name", text: $name)
                Picker("Inside", selection: $parentID) {
                    Text("Top Level").tag(SnippetPackage.ID?.none)
                    ForEach(parentChoices, id: \.package.id) { choice in
                        Text(choice.path).tag(SnippetPackage.ID?.some(choice.package.id))
                    }
                }
            }
            .formStyle(.grouped)
        } footer: {
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Add" : "Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
            .padding(Metrics.Space.l)
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func close() {
        if let requestedClose { requestedClose() } else { dismiss() }
    }

    private var parentChoices: [(package: SnippetPackage, path: String)] {
        let forbidden: Set<SnippetPackage.ID>
        if let existing {
            forbidden = Set(
                [existing.id] + app.snippets.descendantSnippetPackages(of: existing.id).map(\.id)
            )
        } else {
            forbidden = []
        }
        return app.snippets.snippetPackages.filter { !forbidden.contains($0.id) }
            .compactMap { package in
                app.snippets.snippetPackagePath(package.id).map { (package, $0) }
            }
            .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private func commit() {
        save(
            SnippetPackage(
                id: existing?.id ?? UUID(), name: trimmedName,
                parentID: parentID, sortIndex: existing?.sortIndex ?? 0,
                isExpanded: existing?.isExpanded ?? true
            )
        )
        close()
    }
}

#Preview {
    SnippetsPageView()
        .environment(AppModel(hosts: .demo()))
        .environment(WindowModel(vaultDestination: .snippets))
}
