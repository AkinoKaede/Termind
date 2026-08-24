import SwiftUI

struct SnippetBatch: Identifiable {
    let id = UUID()
    let snippets: [Snippet]
}

@Observable
final class SnippetsPageState {
    enum SheetRoute: Identifiable {
        case newSnippet(packageID: SnippetPackage.ID?)
        case editSnippet(Snippet)
        case newPackage(parentID: SnippetPackage.ID?)
        case editPackage(SnippetPackage)

        var id: String {
            switch self {
            case .newSnippet(let id): "new-snippet-\(id?.uuidString ?? "root")"
            case .editSnippet(let snippet): "edit-snippet-\(snippet.id)"
            case .newPackage(let id): "new-package-\(id?.uuidString ?? "root")"
            case .editPackage(let package): "edit-package-\(package.id)"
            }
        }
    }

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
    var sheet: SheetRoute?
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

    @State private var state = SnippetsPageState()

    private var selection: Set<Snippet.ID> {
        Set(
            window.detailSelection(for: .snippets).compactMap { detail in
                detail.snippetID
            })
    }

    private var isFiltering: Bool { !state.query.isEmpty }

    private var sections: [Section] {
        if isFiltering {
            let matches = app.hosts.searchSnippets(state.query)
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
                    snippets: app.hosts.snippets(in: package.id)
                )
            )
            guard package.isExpanded else { return }
            for child in app.hosts.childSnippetPackages(of: package.id) {
                walk(child, prefix: title)
            }
        }
        for package in app.hosts.rootSnippetPackages { walk(package, prefix: "") }

        let ungrouped = app.hosts.snippets(in: nil)
        if !ungrouped.isEmpty || !app.hosts.snippetPackages.isEmpty {
            result.append(
                Section(
                    id: .ungrouped, title: String(localized: "Ungrouped"),
                    isExpanded: app.hosts.isSnippetsUngroupedExpanded,
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
            marqueeSelection: false,
            reordering: ManagedCardReordering(
                isEnabled: !isFiltering,
                dropPolicy: .anySection
            ) { ids, destination, next in
                app.hosts.move(
                    snippetIDs: ids, into: destination.packageID, before: next
                )
            }
        )
    }

    var isManagedSourceEmpty: Bool {
        app.hosts.snippets.isEmpty && app.hosts.snippetPackages.isEmpty
    }

    @ViewBuilder
    func managedHeader(
        for section: ManagedCardSection<SectionID, Snippet>, isDropTarget: Bool
    ) -> some View {
        switch section.id {
        case .package(let id):
            if let package = app.hosts.snippetPackage(id) {
                CardSectionHeader(
                    title: section.title, count: section.items.count,
                    toggle: {
                        app.hosts.setSnippetPackageExpanded(
                            !package.isExpanded, for: package.id
                        )
                    },
                    isCollapsed: !package.isExpanded,
                    isDropTarget: isDropTarget
                )
                .contextMenu {
                    Button("New Subpackage") {
                        state.sheet = .newPackage(parentID: package.id)
                    }
                    Button("Edit") { state.sheet = .editPackage(package) }
                    Divider()
                    Button("Delete Package", role: .destructive) {
                        state.confirmation = .deletePackage(package)
                    }
                }
            }
        case .ungrouped:
            CardSectionHeader(
                title: section.title, count: section.items.count,
                toggle: {
                    app.hosts.setSnippetsUngroupedExpanded(
                        !app.hosts.isSnippetsUngroupedExpanded
                    )
                },
                isCollapsed: !app.hosts.isSnippetsUngroupedExpanded,
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
            edit: { state.sheet = .editSnippet(snippet) },
            duplicate: duplicate,
            delete: {
                state.confirmation = .deleteSnippets(SnippetBatch(snippets: $0))
            }
        )
    }

    func managedGhost(for snippet: Snippet) -> some View {
        SnippetGhostCard(snippet: snippet)
    }

    @ViewBuilder
    func managedSupplementaryContent(for section: SectionID) -> some View {
        if section != .results {
            AddCardTile(title: "New Snippet") {
                state.sheet = .newSnippet(packageID: section.packageID)
            }
        }
    }

    func managedToolbar() -> some View {
        PageToolbar(
            query: Binding(get: { state.query }, set: { state.query = $0 }),
            prompt: "Filter snippets"
        ) {
            let selected = selectedSnippets
            if !selected.isEmpty {
                Button("Execute") { requestExecution(selected) }
                    .buttonStyle(.borderedProminent)
                Button("Execute on Hosts") { executeOnHosts(selected) }
            }
            Button("New Package") {
                state.sheet = .newPackage(parentID: nil)
            }
            Button("New Snippet") {
                state.sheet = .newSnippet(packageID: nil)
            }
        }
    }

    func managedEmptyState() -> some View {
        ContentUnavailableView {
            Label("No Snippets", systemImage: "text.badge.plus")
        } description: {
            Text("Save a script and optionally choose its default hosts.")
        } actions: {
            HStack {
                Button("New Package") {
                    state.sheet = .newPackage(parentID: nil)
                }
                Button("New Snippet") {
                    state.sheet = .newSnippet(packageID: nil)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func managedNoResultsState() -> some View {
        ContentUnavailableView.search(text: state.query)
    }

    func managedFootnote() -> some View { EmptyView() }

    var managedPresentation: SnippetsPagePresentation {
        SnippetsPagePresentation(
            state: state,
            actions: SnippetsPagePresentation.Actions(
                store: app.hosts,
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

    private var selectedSnippets: [Snippet] {
        visibleSnippets.filter { selection.contains($0.id) }
    }

    private func setSelection(_ ids: Set<Snippet.ID>) {
        let valid = ids.intersection(Set(app.hosts.snippets.map(\.id)))
        let ordered = visibleSnippets.filter { valid.contains($0.id) }
            .map { ContextPanelDetailID.snippet($0.id) }
        window.setDetailSelection(ordered, for: .snippets)
    }

    private func saveSnippet(_ snippet: Snippet) {
        app.hosts.upsert(snippet)
        window.selectDetail(.snippet(snippet.id), on: .snippets)
    }

    private func duplicate(_ snippet: Snippet) {
        var copy = snippet
        copy.id = UUID()
        copy.title = String(localized: "\(snippet.title) Copy")
        copy.sortIndex = 0
        saveSnippet(copy)
    }

    private func savePackage(_ package: SnippetPackage) {
        app.hosts.upsert(package)
    }

    private func deletePackage(_ package: SnippetPackage, keepSnippets: Bool) {
        app.hosts.delete(snippetPackageID: package.id, keepSnippets: keepSnippets)
        state.confirmation = nil
        window.pruneDetailSelections(in: app.hosts)
    }

    private func deleteSnippets(_ snippets: [Snippet]) {
        app.hosts.delete(snippetIDs: snippets.map(\.id))
        state.confirmation = nil
        window.pruneDetailSelections(in: app.hosts)
    }

    private func requestExecution(_ snippets: [Snippet]) {
        guard !snippets.isEmpty else { return }
        if snippets.contains(where: { $0.targetHostIDs.isEmpty }) {
            window.hostChooser = .snippet(
                SnippetHostChooserRequest(
                    snippetIDs: snippets.map(\.id), strategy: .fillMissingTargets
                )
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
        window.hostChooser = .snippet(
            SnippetHostChooserRequest(
                snippetIDs: snippets.map(\.id), strategy: .overrideAllTargets
            )
        )
    }

    private func executionMessage(_ snippets: [Snippet]) -> String {
        snippets.map { snippet in
            let wanted = Set(snippet.targetHostIDs)
            let targets = app.hosts.searchHosts("").filter { wanted.contains($0.id) }
                .map(\.name).joined(separator: ", ")
            return "• \(snippet.body)\n  \(targets)"
        }.joined(separator: "\n")
    }
}

struct SnippetsPagePresentation: ManagedCardPresentationModifier {
    struct Actions {
        let store: HostStore
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
            .sheet(item: $state.sheet, content: sheetContent)
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
    private func sheetContent(_ route: SnippetsPageState.SheetRoute) -> some View {
        switch route {
        case .newSnippet(let packageID):
            SnippetEditorSheet(packageID: packageID, save: actions.saveSnippet)
        case .editSnippet(let snippet):
            SnippetEditorSheet(snippet: snippet, save: actions.saveSnippet)
        case .newPackage(let parentID):
            SnippetPackageSheet(parentID: parentID, save: actions.savePackage)
        case .editPackage(let package):
            SnippetPackageSheet(package: package, save: actions.savePackage)
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
            Button("Delete", role: .destructive) { delete(actionSnippets) }
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
    let existing: Snippet?
    let save: (Snippet) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var bodyText: String
    @State private var packageID: SnippetPackage.ID?
    @State private var targets: Set<Host.ID>
    @State private var isChoosingTargets = false

    init(
        snippet: Snippet? = nil, packageID: SnippetPackage.ID? = nil,
        save: @escaping (Snippet) -> Void
    ) {
        existing = snippet
        self.save = save
        _title = State(initialValue: snippet?.title ?? "")
        _bodyText = State(initialValue: snippet?.body ?? "")
        _packageID = State(initialValue: snippet?.packageID ?? packageID)
        _targets = State(initialValue: Set(snippet?.targetHostIDs ?? []))
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(existing == nil ? "New Snippet" : "Edit Snippet")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Metrics.Space.xl)
            Divider()
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
                            app.hosts.hosts.isEmpty
                                ? String(localized: "No saved hosts")
                                : String(localized: "No targets selected")
                        )
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(selectedHosts) { host in
                            HStack(spacing: Metrics.Space.m) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(host.name)
                                    Text(app.hosts.loginAddress(for: host))
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
                            isChoosingTargets = true
                        } label: {
                            Label("Add Hosts", systemImage: "plus")
                        }
                        .disabled(app.hosts.hosts.isEmpty)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Add" : "Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedTitle.isEmpty || trimmedBody.isEmpty)
            }
            .padding(Metrics.Space.l)
        }
        .frame(width: 520, height: 620)
        .sheet(isPresented: $isChoosingTargets) {
            SnippetTargetPickerSheet(selected: targets) { targets = $0 }
        }
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedBody: String { bodyText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var packageChoices: [(package: SnippetPackage, path: String)] {
        app.hosts.snippetPackages.compactMap { package in
            app.hosts.snippetPackagePath(package.id).map { (package, $0) }
        }.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private var selectedHosts: [Host] {
        app.hosts.searchHosts("").filter { targets.contains($0.id) }
    }

    private func commit() {
        let orderedTargets = app.hosts.searchHosts("").filter { targets.contains($0.id) }.map(\.id)
        save(
            Snippet(
                id: existing?.id ?? UUID(), title: trimmedTitle, body: trimmedBody,
                packageID: packageID, targetHostIDs: orderedTargets,
                sortIndex: existing?.sortIndex ?? 0
            )
        )
        dismiss()
    }
}

private struct SnippetTargetPickerSheet: View {
    let save: (Set<Host.ID>) -> Void
    let initialSelection: Set<Host.ID>

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        SheetScaffold {
            header
        } content: {
            content
        } footer: {
            footer
        }
        .frame(width: Metrics.HostPicker.width, height: Metrics.HostPicker.height)
        .onAppear {
            let available = Set(app.hosts.hosts.map(\.id))
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
        if app.hosts.hosts.isEmpty {
            ContentUnavailableView {
                Label("No Hosts", systemImage: "server.rack")
            } description: {
                Text("Add a host before choosing default targets.")
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
                                isChecked: chooser.selected.contains(host.id)
                            )
                            .id(host.id)
                            .onTapGesture { chooser.activate(host.id) }
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

    private var results: [Host] { app.hosts.searchHosts(query) }

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

private struct SnippetPackageSheet: View {
    let existing: SnippetPackage?
    let save: (SnippetPackage) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var parentID: SnippetPackage.ID?

    init(
        package: SnippetPackage? = nil, parentID: SnippetPackage.ID? = nil,
        save: @escaping (SnippetPackage) -> Void
    ) {
        existing = package
        self.save = save
        _name = State(initialValue: package?.name ?? "")
        _parentID = State(initialValue: package?.parentID ?? parentID)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(existing == nil ? "New Package" : "Edit Package")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Metrics.Space.xl)
            Divider()
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
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Add" : "Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
            .padding(Metrics.Space.l)
        }
        .frame(width: Metrics.CreateSheet.width)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var parentChoices: [(package: SnippetPackage, path: String)] {
        let forbidden: Set<SnippetPackage.ID>
        if let existing {
            forbidden = Set(
                [existing.id] + app.hosts.descendantSnippetPackages(of: existing.id).map(\.id)
            )
        } else {
            forbidden = []
        }
        return app.hosts.snippetPackages.filter { !forbidden.contains($0.id) }
            .compactMap { package in
                app.hosts.snippetPackagePath(package.id).map { (package, $0) }
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
        dismiss()
    }
}

#Preview {
    SnippetsPageView()
        .environment(AppModel(hosts: .demo()))
        .environment(WindowModel(vaultDestination: .snippets))
}
