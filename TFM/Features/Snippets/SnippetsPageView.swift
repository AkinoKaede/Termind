import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

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
    var confirmation: ConfirmationRoute?
}

/// Saved scripts, organised into nested Packages and launched as visible
/// terminal Workspaces. ManagedCardPage owns selection and drag geometry; this
/// page supplies only the Package sections and business actions.
struct SnippetsPageView: ManagedCardPage {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(VaultWorkEditingSession.self) private var editingSession

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

    private var sections: [SnippetLibrarySection] {
        SnippetLibrarySectionLayout.sections(library: app.snippets, query: state.query)
    }

    // MARK: ManagedCardPage

    var managedSections: [ManagedCardSection<SnippetLibrarySection.ID, Snippet>] {
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

    var managedCapabilities: ManagedCardCapabilities<SnippetLibrarySection.ID, Snippet.ID> {
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
        for section: ManagedCardSection<SnippetLibrarySection.ID, Snippet>, isDropTarget: Bool
    ) -> some View {
        switch section.id {
        case .package(let id):
            if let package = app.snippets.snippetPackage(id) {
                let isExpanded = app.snippets.isSnippetPackageExpanded(id)
                let toggle = {
                    app.snippets.setSnippetPackageExpanded(!isExpanded, for: package.id)
                }
                CardSectionHeader(
                    title: section.title, count: section.items.count,
                    toggle: toggle,
                    isCollapsed: !isExpanded,
                    isDropTarget: isDropTarget
                )
                .contextMenu {
                    Button(AppStrings.Snippets.newSnippet.swiftUIKey, systemImage: MenuSymbol.newSnippet) {
                        openSnippetEditor(snippetID: nil, packageID: package.id)
                    }
                    Button(AppStrings.Snippets.newSubpackage.swiftUIKey, systemImage: MenuSymbol.newPackage) {
                        openPackageEditor(packageID: nil, parentID: package.id)
                    }
                    Button(AppStrings.Common.edit.swiftUIKey, systemImage: MenuSymbol.edit) {
                        openPackageEditor(packageID: package.id, parentID: package.parentID)
                    }
                    Divider()
                    DestructiveMenuButton(AppStrings.Snippets.deletePackage) {
                        state.confirmation = .deletePackage(package)
                    }
                }
            }
        case .ungrouped:
            let isExpanded = app.snippets.isSnippetsUngroupedExpanded
            let toggle = { app.snippets.setSnippetsUngroupedExpanded(!isExpanded) }
            CardSectionHeader(
                title: section.title, count: section.items.count,
                toggle: toggle,
                isCollapsed: !isExpanded,
                isDropTarget: isDropTarget
            )
            .contextMenu {
                Button(AppStrings.Snippets.newSnippet.swiftUIKey, systemImage: MenuSymbol.newSnippet) {
                    openSnippetEditor(snippetID: nil, packageID: nil)
                }
                Button(AppStrings.Snippets.newPackage.swiftUIKey, systemImage: MenuSymbol.newPackage) {
                    openPackageEditor(packageID: nil, parentID: nil)
                }
            }
        case .results:
            CardSectionHeader(title: section.title, count: section.items.count)
        }
    }

    func managedCard(
        for snippet: Snippet, context: ManagedCardItemContext<Snippet>
    ) -> some View {
        SnippetCard(
            snippet: snippet,
            content: cardContent(for: snippet),
            isSelected: context.isSelected,
            select: { select(snippet, action: context.select) },
            extendSelection: context.extendSelection,
            actionSnippets: context.actionItems,
            execute: requestExecution,
            edit: { edit(snippet, action: context.select) },
            duplicate: duplicate,
            delete: {
                state.confirmation = .deleteSnippets(SnippetBatch(snippets: $0))
            }
        )
    }

    func managedGhost(for snippet: Snippet) -> some View {
        SnippetGhostCard(content: cardContent(for: snippet))
    }

    private func cardContent(for snippet: Snippet) -> SnippetCardContent {
        SnippetCardContent(
            snippet: snippet,
            validTargetCount: app.snippets.validTargetIDs(for: snippet).count,
            packagePath: isFiltering ? app.snippets.snippetPackagePath(snippet.packageID) : nil,
            modifiedAt: app.snippetModifiedAt(for: snippet.id))
    }

    /// Right-clicking inside a package files the new snippet or subpackage
    /// there. Results is a view of matches from everywhere, so it files at the
    /// root rather than guessing which package the user meant.
    func managedBlankAreaMenu(for section: SnippetLibrarySection.ID?) -> [NativeMenuEntry] {
        let packageID = section?.packageID
        return [
            NativeMenuEntry(
                title: AppStrings.Snippets.newSnippet, symbol: MenuSymbol.newSnippet
            ) {
                openSnippetEditor(snippetID: nil, packageID: packageID)
            },
            NativeMenuEntry(
                title: AppStrings.Snippets.newPackage, symbol: MenuSymbol.newPackage
            ) {
                openPackageEditor(packageID: nil, parentID: packageID)
            },
        ]
    }

    func managedBlankAreaPrimaryAction() {
        guard let route = window.vaultWorkRoute, case .snippetEditor = route else { return }
        editingSession.requestTransition(route: route, action: window.closeVaultWork)
    }

    func managedEmptyState() -> some View {
        ContentUnavailableView {
            Label(AppStrings.Snippets.noSnippets.swiftUIKey, systemImage: "curlybraces")
        } description: {
            Text(AppStrings.Snippets.emptyDescription)
        } actions: {
            HStack {
                Button(AppStrings.Snippets.newPackage.swiftUIKey) {
                    openPackageEditor(packageID: nil, parentID: nil)
                }
                Button(AppStrings.Snippets.newSnippet.swiftUIKey) {
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
        let ordered = visibleSnippets.filter { valid.contains($0.id) }
            .map { VaultSelectionID.snippet($0.id) }
        window.setVaultSelection(ordered, for: .snippets)
    }

    private func saveSnippet(_ snippet: Snippet) {
        app.snippets.upsert(snippet)
        window.selectVaultItem(.snippet(snippet.id), on: .snippets)
    }

    private func select(_ snippet: Snippet, action: @escaping () -> Void) {
        guard let route = window.vaultWorkRoute,
            case .snippetEditor(let editingID, _) = route,
            editingID != snippet.id
        else {
            action()
            return
        }
        editingSession.requestTransition(route: route) {
            action()
            openSnippetEditor(snippetID: snippet.id, packageID: snippet.packageID)
        }
    }

    private func edit(_ snippet: Snippet, action: @escaping () -> Void) {
        let target = VaultWorkRoute.snippetEditor(snippetID: snippet.id, packageID: snippet.packageID)
        guard let route = window.vaultWorkRoute,
            case .snippetEditor = route,
            route != target
        else {
            action()
            openSnippetEditor(snippetID: snippet.id, packageID: snippet.packageID)
            return
        }
        editingSession.requestTransition(route: route) {
            action()
            openSnippetEditor(snippetID: snippet.id, packageID: snippet.packageID)
        }
    }

    private func duplicate(_ snippet: Snippet) {
        saveSnippet(snippet.duplicated())
    }

    private func deletePackage(_ package: SnippetPackage, keepSnippets: Bool) {
        app.snippets.delete(snippetPackageID: package.id, keepSnippets: keepSnippets)
        state.confirmation = nil
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
                )
            ) {
                confirmationActions
                Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) { state.confirmation = nil }
            } message: {
                confirmationMessage
            }
    }

    @ViewBuilder
    private var confirmationActions: some View {
        switch state.confirmation {
        case .deletePackage(let package):
            Button(AppStrings.Snippets.deletePackageAndSnippets.swiftUIKey, role: .destructive) {
                actions.deletePackage(package, false)
            }
            Button(AppStrings.Snippets.keepSnippets.swiftUIKey) { actions.deletePackage(package, true) }
        case .deleteSnippets(let batch):
            Button(AppStrings.Common.delete.swiftUIKey, role: .destructive) {
                actions.deleteSnippets(batch.snippets)
            }
        case .executeDestructive(let batch):
            Button(AppStrings.Common.run.swiftUIKey, role: .destructive) {
                actions.performExecution(batch.snippets)
            }
        case nil:
            EmptyView()
        }
    }

    private var confirmationTitle: Text {
        switch state.confirmation {
        case .deletePackage(let package): Text(AppStrings.Common.deleteNamedConfirmation(package.name))
        case .deleteSnippets(let batch):
            batch.snippets.count == 1
                ? Text(AppStrings.Snippets.deleteSnippetConfirmation)
                : Text(AppStrings.Snippets.deleteSnippetsConfirmation(batch.snippets.count))
        case .executeDestructive: Text(AppStrings.Snippets.runDestructiveScriptsConfirmation)
        case nil: Text("")
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
            return Text(AppStrings.Snippets.packageDeletionMessage(snippetCount: count))
        case .executeDestructive(let batch):
            return Text(actions.executionMessage(batch.snippets))
        case .deleteSnippets:
            return Text(AppStrings.Snippets.thisActionCannotBeUndone)
        case nil:
            return Text("")
        }
    }
}

private struct SnippetCard: View {
    let snippet: Snippet
    let content: SnippetCardContent
    let isSelected: Bool
    let select: () -> Void
    let extendSelection: () -> Void
    let actionSnippets: [Snippet]
    let execute: ([Snippet]) -> Void
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
            content
        }
        .contextMenu {
            Button(AppStrings.Common.run.swiftUIKey, systemImage: MenuSymbol.execute) { execute(actionSnippets) }
            if actionSnippets.count == 1 {
                Divider()
                Button(AppStrings.Common.edit.swiftUIKey, systemImage: MenuSymbol.edit, action: edit)
                Button(AppStrings.Common.duplicate.swiftUIKey, systemImage: MenuSymbol.duplicate) {
                    duplicate(snippet)
                }
            }
            Divider()
            DestructiveMenuButton(AppStrings.Common.delete) { delete(actionSnippets) }
        }
        .help(Text(snippet.body))
    }
}

private struct SnippetGhostCard: View {
    let content: SnippetCardContent

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.Space.l)
            .frame(minHeight: Metrics.Card.minHeight, alignment: .top)
            .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: Metrics.Radius.large))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.Radius.large)
                    .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
    }
}

struct SnippetEditorView: View {
    let existing: Snippet?
    let save: (Snippet) -> Void
    let close: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(VaultWorkEditingSession.self) private var editingSession
    @State private var title: String
    @State private var colorTag: TagColor
    @State private var bodyText: String
    @State private var packageID: SnippetPackage.ID?
    @State private var targets: Set<Host.ID>
    @State private var showsTargetPicker = false
    @State private var error: String?
    @State private var confirmsDeletion = false
    @State private var editingToken: UUID?

    init(
        snippet: Snippet? = nil, packageID: SnippetPackage.ID? = nil,
        save: @escaping (Snippet) -> Void,
        close: @escaping () -> Void
    ) {
        existing = snippet
        self.save = save
        self.close = close
        _title = State(initialValue: snippet?.title ?? "")
        _colorTag = State(initialValue: snippet?.colorTag ?? .none)
        _bodyText = State(initialValue: snippet?.body ?? "")
        _packageID = State(initialValue: snippet?.packageID ?? packageID)
        _targets = State(initialValue: Set(snippet?.targetHostIDs ?? []))
    }

    var body: some View {
        ZStack {
            if showsTargetPicker {
                SnippetTargetPickerView(selected: targets, back: { showsTargetPicker = false }) {
                    targets = $0
                }
                .transition(.move(edge: .trailing))
            } else {
                editor
                    .transition(.move(edge: .leading))
            }
        }
        // Keep the target picker inside the Snippet work column. A NavigationStack
        // here is promoted by macOS into the enclosing NavigationSplitView's
        // detail, which makes its destination cover the Snippets collection too.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(.snappy(duration: 0.2), value: showsTargetPicker)
        .onAppear {
            editingToken = editingSession.register(
                route: .snippetEditor(snippetID: existing?.id, packageID: packageID), isDirty: { isDirty }
            ) {
                commitChanges()
            }
        }
        .onDisappear {
            guard let editingToken else { return }
            editingSession.unregister(editingToken)
        }
        .confirmationDialog(
            AppStrings.Snippets.deleteSnippetConfirmation, isPresented: $confirmsDeletion,
            titleVisibility: .visible
        ) {
            Button(AppStrings.Snippets.deleteSnippet.swiftUIKey, role: .destructive, action: delete)
            Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) {}
        } message: {
            Text(AppStrings.Snippets.thisActionCannotBeUndone)
        }
    }

    private var editor: some View {
        VaultDetailScaffold(
            title: existing == nil ? AppStrings.Snippets.newSnippet : AppStrings.Snippets.editSnippet,
            symbol: "curlybraces", close: cancelEditing, closeLabel: AppStrings.Common.cancel
        ) {
            Form {
                SnippetOrganizationSection(name: $title, color: $colorTag) {
                    Picker(AppStrings.Snippets.package.swiftUIKey, selection: $packageID) {
                        Text(AppStrings.Snippets.unpackaged).tag(SnippetPackage.ID?.none)
                        ForEach(packageChoices, id: \.package.id) { choice in
                            Text(choice.path).tag(SnippetPackage.ID?.some(choice.package.id))
                        }
                    }
                }
                SnippetScriptSection(script: $bodyText, minHeight: 180) {
                    RiskBadge(assessment: CommandRiskClassifier.assess(bodyText))
                }
                Section {
                    if selectedHosts.isEmpty {
                        Text(
                            app.snippets.hosts.isEmpty
                                ? String(localized: AppStrings.Snippets.noSavedHosts)
                                : String(localized: AppStrings.Snippets.noTargetsSelected)
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
                                .help(Text(AppStrings.Common.removeNamed(host.name)))
                                .accessibilityLabel(Text(AppStrings.Common.removeNamed(host.name)))
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(AppStrings.Snippets.targets)
                        Spacer()
                        Button {
                            showsTargetPicker = true
                        } label: {
                            Label(AppStrings.Common.addHosts.swiftUIKey, systemImage: "plus")
                        }
                        .disabled(app.snippets.hosts.isEmpty)
                        .accessibilityIdentifier("snippet-editor.add-hosts")
                        .help(AppStrings.Common.addHosts.swiftUIKey)
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
        } footer: {
            HStack(spacing: Metrics.Space.m) {
                if existing != nil {
                    Button(AppStrings.Common.delete.swiftUIKey, role: .destructive) { confirmsDeletion = true }
                }
                Spacer()
                Button(AppStrings.Common.cancel.swiftUIKey, action: cancelEditing)
                Button(AppStrings.Common.save.swiftUIKey, action: saveAndClose)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedTitle.isEmpty || trimmedBody.isEmpty)
                    .accessibilityIdentifier("snippet-editor.save")
            }
            .padding(Metrics.Space.l)
        }
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedBody: String { bodyText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isDirty: Bool {
        title != (existing?.title ?? "") || bodyText != (existing?.body ?? "")
            || packageID != existing?.packageID
            || targets != Set(existing?.targetHostIDs ?? [])
            || colorTag != (existing?.colorTag ?? .none)
    }

    private var packageChoices: [(package: SnippetPackage, path: String)] {
        app.snippets.snippetPackages.compactMap { package in
            app.snippets.snippetPackagePath(package.id).map { (package, $0) }
        }.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private var selectedHosts: [Host] {
        app.snippets.searchHosts("").filter { targets.contains($0.id) }
    }

    private func cancelEditing() {
        editingSession.requestTransition(
            route: .snippetEditor(snippetID: existing?.id, packageID: packageID), action: close)
    }

    private func commitChanges() -> Bool {
        guard isDirty else { return true }
        guard !trimmedTitle.isEmpty, !trimmedBody.isEmpty else {
            error = String(localized: AppStrings.Common.completeAllRequiredFieldsBeforeSaving)
            return false
        }
        let orderedTargets = app.snippets.searchHosts("").filter { targets.contains($0.id) }.map(\.id)
        save(
            Snippet(
                id: existing?.id ?? UUID(), title: trimmedTitle, body: trimmedBody,
                packageID: packageID, targetHostIDs: orderedTargets,
                sortIndex: existing?.sortIndex ?? 0, colorTag: colorTag
            )
        )
        error = nil
        return true
    }

    private func saveAndClose() {
        guard commitChanges() else { return }
        close()
    }

    private func delete() {
        guard let existing else { return }
        app.snippets.delete(snippetIDs: [existing.id])
        window.pruneVaultSelections(in: app.snippets)
        close()
    }
}

struct SnippetTargetPickerView: View {
    let save: (Set<Host.ID>) -> Void
    let initialSelection: Set<Host.ID>
    let back: () -> Void

    @Environment(AppModel.self) private var app
    @State private var chooser: ManagedChooserState<Host.ID>
    @State private var isClosing = false

    init(
        selected: Set<Host.ID>, back: @escaping () -> Void,
        save: @escaping (Set<Host.ID>) -> Void
    ) {
        self.save = save
        initialSelection = selected
        self.back = back
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
            title: AppStrings.Common.selectHosts, symbol: "server.rack", close: close,
            closeLabel: AppStrings.Common.back, closeSymbol: "chevron.backward"
        ) {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.7)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            title: AppStrings.Common.selectHosts,
            symbol: "server.rack",
            prompt: AppStrings.Vault.searchHosts,
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
                Label(AppStrings.Vault.noHosts.swiftUIKey, systemImage: "server.rack")
            } description: {
                Text(AppStrings.Snippets.addAHostBeforeChoosingDefaultTargets)
            }
        } else if results.isEmpty {
            ContentUnavailableView.search(text: query)
                .accessibilityIdentifier("snippet-target-picker.no-results")
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(results) { host in
                        Button {
                            chooser.activate(host.id)
                        } label: {
                            HostChooserRow(
                                host: host,
                                isCursor: chooser.cursor == host.id,
                                isChecked: chooser.selected.contains(host.id)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("snippet-target-picker.host.\(host.id)")
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

    private var footer: some View {
        HStack {
            Button(
                allResultsChecked ? AppStrings.Common.deselectAll.swiftUIKey : AppStrings.Common.selectAll.swiftUIKey
            ) {
                toggleAllResults()
            }
            .disabled(results.isEmpty)

            Spacer()
            Button(AppStrings.Common.cancel.swiftUIKey, action: close)
                .accessibilityIdentifier("snippet-target-picker.cancel")
            Button(AppStrings.Common.done.swiftUIKey, action: commit)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("snippet-target-picker.done")
        }
        .padding(Metrics.Space.l)
    }

    private var results: [Host] { app.snippets.searchHosts(query) }

    private var allResultsChecked: Bool { chooser.allChecked(in: results.map(\.id)) }

    private func toggleAllResults() {
        chooser.toggleAll(in: results.map(\.id))
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
        guard !isClosing else { return }
        save(chooser.selected)
        close()
    }

    private func close() {
        guard !isClosing else { return }
        isClosing = true
        back()
    }
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
            title: existing == nil ? AppStrings.Snippets.newPackage : AppStrings.Snippets.editPackage,
            symbol: "folder.fill", close: close
        ) {
            Form {
                TextField(AppStrings.Common.name.swiftUIKey, text: $name.singleLineText, axis: .horizontal)
                    .singleLinePaste().lineLimit(1)
                Picker(AppStrings.Common.inside.swiftUIKey, selection: $parentID) {
                    Text(AppStrings.Common.topLevel).tag(SnippetPackage.ID?.none)
                    ForEach(parentChoices, id: \.package.id) { choice in
                        Text(choice.path).tag(SnippetPackage.ID?.some(choice.package.id))
                    }
                }
            }
            .formStyle(.grouped)
        } footer: {
            HStack {
                Spacer()
                Button(AppStrings.Common.cancel.swiftUIKey, action: close).keyboardShortcut(.cancelAction)
                Button(
                    existing == nil ? AppStrings.Common.add.swiftUIKey : AppStrings.Common.save.swiftUIKey,
                    action: commit
                )
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
        .environment(VaultWorkEditingSession())
}
