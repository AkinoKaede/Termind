import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

struct MobileSnippetsView: View {
    @Environment(\.locale) private var locale

    private struct SnippetEditorRequest: Identifiable {
        let id = UUID()
        let snippetID: Snippet.ID?
        let packageID: SnippetPackage.ID?
    }

    private struct PackageEditorRequest: Identifiable {
        let id = UUID()
        let packageID: SnippetPackage.ID?
        let parentID: SnippetPackage.ID?
    }

    private struct TargetRequest: Identifiable {
        let id = UUID()
        let snippetID: Snippet.ID
    }

    private struct ExecutionRequest: Identifiable {
        let id = UUID()
        let snippetID: Snippet.ID
        let hostIDs: [Host.ID]
    }

    let app: MobileAppModel
    let execute: (Snippet, [Host.ID]) -> Void
    @State private var query: String
    @State private var selectedSnippetID: Snippet.ID?
    @State private var editorRequest: SnippetEditorRequest?
    @State private var packageEditorRequest: PackageEditorRequest?
    @State private var deletingSnippetID: Snippet.ID?
    @State private var deletingPackage: SnippetPackage?
    @State private var targetRequest: TargetRequest?
    @State private var pendingTargetExecution: ExecutionRequest?
    @State private var destructiveRequest: ExecutionRequest?

    init(
        app: MobileAppModel, initialQuery: String = "",
        execute: @escaping (Snippet, [Host.ID]) -> Void = { _, _ in }
    ) {
        self.app = app
        self.execute = execute
        _query = State(initialValue: initialQuery)
    }

    private var sections: [SnippetLibrarySection] {
        SnippetLibrarySectionLayout.sections(library: app.snippets, query: query)
    }

    var body: some View {
        MobileCardPage {
            if app.snippets.snippets.isEmpty && app.snippets.snippetPackages.isEmpty {
                emptyState
            } else if sections.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader(section)
                        if section.isExpanded != false {
                            MobileCardGrid {
                                ForEach(section.snippets) { snippet in
                                    snippetCard(snippet, showsPackage: !query.isEmpty)
                                }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $query.singleLineText)
        .navigationTitle(AppStrings.Navigation.snippets.swiftUIKey)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(AppStrings.Snippets.newSnippet.swiftUIKey, systemImage: "curlybraces") {
                        editorRequest = SnippetEditorRequest(snippetID: nil, packageID: nil)
                    }
                    Button(AppStrings.Snippets.newPackage.swiftUIKey, systemImage: "folder.badge.plus") {
                        packageEditorRequest = PackageEditorRequest(packageID: nil, parentID: nil)
                    }
                } label: {
                    Label(AppStrings.Common.add.swiftUIKey, systemImage: "plus").labelStyle(.iconOnly)
                }
            }
        }
        .navigationDestination(item: $selectedSnippetID) { id in
            MobileSnippetDetailView(
                app: app, snippetID: id,
                execute: { requestExecution($0, overrideTargets: false) },
                edit: {
                    editorRequest = SnippetEditorRequest(snippetID: id, packageID: nil)
                },
                duplicate: duplicate,
                delete: { deletingSnippetID = id })
        }
        .sheet(item: $editorRequest) { request in
            MobileSnippetEditor(
                app: app,
                snippet: request.snippetID.flatMap(snippet),
                packageID: request.packageID
            ) { saved in
                selectedSnippetID = saved.id
            }
        }
        .sheet(item: $packageEditorRequest) { request in
            MobileSnippetPackageEditor(
                app: app,
                package: request.packageID.flatMap(app.snippets.snippetPackage),
                parentID: request.parentID)
        }
        .sheet(item: $targetRequest, onDismiss: completeTargetSelection) { request in
            MobileSnippetHostPicker(
                app: app, selected: [], title: AppStrings.Common.run, actionTitle: AppStrings.Common.run,
                requiresSelection: true
            ) { ids in
                pendingTargetExecution = ExecutionRequest(snippetID: request.snippetID, hostIDs: ids)
            }
        }
        .confirmationDialog(
            AppStrings.Snippets.deleteSnippetConfirmation,
            isPresented: Binding(
                get: { deletingSnippetID != nil },
                set: { if !$0 { deletingSnippetID = nil } }),
            titleVisibility: .visible
        ) {
            Button(AppStrings.Snippets.deleteSnippet.swiftUIKey, role: .destructive, action: deleteSnippet)
            Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) { deletingSnippetID = nil }
        } message: {
            Text(AppStrings.Snippets.thisActionCannotBeUndone)
        }
        .confirmationDialog(
            packageDeletionTitle,
            isPresented: Binding(
                get: { deletingPackage != nil },
                set: { if !$0 { deletingPackage = nil } }),
            titleVisibility: .visible
        ) {
            Button(AppStrings.Snippets.deletePackageAndSnippets.swiftUIKey, role: .destructive) {
                deletePackage(keepingSnippets: false)
            }
            Button(AppStrings.Snippets.keepSnippets.swiftUIKey) { deletePackage(keepingSnippets: true) }
            Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) { deletingPackage = nil }
        } message: {
            Text(packageDeletionMessage)
        }
        .confirmationDialog(
            AppStrings.Snippets.runADestructiveScriptConfirmation,
            isPresented: Binding(
                get: { destructiveRequest != nil },
                set: { if !$0 { destructiveRequest = nil } }),
            titleVisibility: .visible
        ) {
            Button(destructiveExecuteTitle, role: .destructive) {
                guard let request = destructiveRequest else { return }
                destructiveRequest = nil
                performExecution(request)
            }
            Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) { destructiveRequest = nil }
        } message: {
            Text(destructiveMessage)
        }
        .onChange(of: app.snippets.snippets.map(\.id)) {
            guard let selectedSnippetID,
                !app.snippets.snippets.contains(where: { $0.id == selectedSnippetID })
            else { return }
            self.selectedSnippetID = nil
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(AppStrings.Snippets.noSnippets.swiftUIKey, systemImage: "curlybraces")
        } description: {
            Text(AppStrings.Snippets.emptyDescription)
        } actions: {
            HStack {
                Button(AppStrings.Snippets.newPackage.swiftUIKey) {
                    packageEditorRequest = PackageEditorRequest(packageID: nil, parentID: nil)
                }
                Button(AppStrings.Snippets.newSnippet.swiftUIKey) {
                    editorRequest = SnippetEditorRequest(snippetID: nil, packageID: nil)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func sectionHeader(_ section: SnippetLibrarySection) -> some View {
        HStack(spacing: 8) {
            if let isExpanded = section.isExpanded {
                Button {
                    toggle(section, expanded: !isExpanded)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Text(section.title).font(.headline)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            } else {
                Text(section.title).font(.headline)
            }
            Text(section.snippets.count, format: .number)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            if case .package(let id) = section.id,
                let package = app.snippets.snippetPackage(id)
            {
                Menu {
                    Button(AppStrings.Snippets.newSnippet.swiftUIKey, systemImage: "curlybraces") {
                        editorRequest = SnippetEditorRequest(snippetID: nil, packageID: package.id)
                    }
                    Button(AppStrings.Snippets.newSubpackage.swiftUIKey, systemImage: "folder.badge.plus") {
                        packageEditorRequest = PackageEditorRequest(packageID: nil, parentID: package.id)
                    }
                    Button(AppStrings.Common.edit.swiftUIKey, systemImage: "pencil") {
                        packageEditorRequest = PackageEditorRequest(
                            packageID: package.id, parentID: package.parentID)
                    }
                    Divider()
                    Button(AppStrings.Snippets.deletePackage.swiftUIKey, systemImage: "trash", role: .destructive) {
                        deletingPackage = package
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(AppStrings.Common.more.swiftUIKey)
            } else if case .ungrouped = section.id {
                Menu {
                    Button(AppStrings.Snippets.newSnippet.swiftUIKey, systemImage: "curlybraces") {
                        editorRequest = SnippetEditorRequest(snippetID: nil, packageID: nil)
                    }
                    Button(AppStrings.Snippets.newPackage.swiftUIKey, systemImage: "folder.badge.plus") {
                        packageEditorRequest = PackageEditorRequest(packageID: nil, parentID: nil)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(AppStrings.Common.more.swiftUIKey)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func snippetCard(_ snippet: Snippet, showsPackage: Bool) -> some View {
        MobileActionCard {
            selectedSnippetID = snippet.id
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    MobileCardIcon(symbol: "curlybraces")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snippet.title).font(.headline).lineLimit(1)
                        MobileSnippetMetadataChips(
                            target: targetSummary(snippet),
                            assessment: CommandRiskClassifier.assess(snippet.body))
                    }
                }
                HStack(spacing: 6) {
                    if showsPackage, let path = app.snippets.snippetPackagePath(snippet.packageID) {
                        Label(path, systemImage: "folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Text(
                        app.snippetModifiedAt(for: snippet.id)
                            .formatted(.relative(presentation: .numeric).locale(locale))
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
        } actions: {
            Button(AppStrings.Common.run.swiftUIKey, systemImage: "play.fill") {
                requestExecution(snippet.id, overrideTargets: false)
            }
            .disabled(app.snippets.hosts.isEmpty)
            Divider()
            Button(AppStrings.Common.edit.swiftUIKey, systemImage: "pencil") {
                editorRequest = SnippetEditorRequest(snippetID: snippet.id, packageID: nil)
            }
            Button(AppStrings.Common.duplicate.swiftUIKey, systemImage: "plus.square.on.square") {
                duplicate(snippet.id)
            }
            Divider()
            Button(AppStrings.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) {
                deletingSnippetID = snippet.id
            }
        }
    }

    private func toggle(_ section: SnippetLibrarySection, expanded: Bool) {
        switch section.id {
        case .package(let id): app.snippets.setSnippetPackageExpanded(expanded, for: id)
        case .ungrouped: app.snippets.setSnippetsUngroupedExpanded(expanded)
        case .results: break
        }
    }

    private func snippet(_ id: Snippet.ID) -> Snippet? {
        app.snippets.snippets.first { $0.id == id }
    }

    private func duplicate(_ id: Snippet.ID) {
        guard let snippet = snippet(id) else { return }
        let copy = snippet.duplicated()
        app.snippets.upsert(copy)
        reportStorageError()
        selectedSnippetID = copy.id
    }

    private func deleteSnippet() {
        guard let id = deletingSnippetID else { return }
        app.snippets.delete(snippetIDs: [id])
        deletingSnippetID = nil
        if selectedSnippetID == id { selectedSnippetID = nil }
        reportStorageError()
    }

    private var packageDeletionTitle: String {
        deletingPackage.map { String(localized: AppStrings.Common.deleteNamedConfirmation($0.name)) } ?? ""
    }

    private var packageDeletionMessage: String {
        guard let package = deletingPackage else { return "" }
        let packageIDs = Set(
            [package.id] + app.snippets.descendantSnippetPackages(of: package.id).map(\.id))
        let count = app.snippets.snippets.filter { $0.packageID.map(packageIDs.contains) == true }.count
        return AppLocalization.resolve(AppStrings.Snippets.packageDeletionMessage(snippetCount: count), locale: locale)
    }

    private func deletePackage(keepingSnippets: Bool) {
        guard let package = deletingPackage else { return }
        app.snippets.delete(snippetPackageID: package.id, keepSnippets: keepingSnippets)
        deletingPackage = nil
        reportStorageError()
    }

    private func requestExecution(_ id: Snippet.ID, overrideTargets: Bool) {
        guard let snippet = snippet(id) else { return }
        let targets = validTargets(for: snippet)
        handle(
            MobileSnippetOperations.executionDecision(
                for: snippet, hostIDs: targets,
                requiresHostSelection: overrideTargets || targets.isEmpty),
            snippetID: id)
    }

    private func handle(_ decision: MobileSnippetExecutionDecision, snippetID: Snippet.ID) {
        switch decision {
        case .chooseHosts:
            pendingTargetExecution = nil
            targetRequest = TargetRequest(snippetID: snippetID)
        case .confirmDestructive(let hostIDs):
            destructiveRequest = ExecutionRequest(snippetID: snippetID, hostIDs: hostIDs)
        case .execute(let hostIDs):
            performExecution(ExecutionRequest(snippetID: snippetID, hostIDs: hostIDs))
        }
    }

    private func validTargets(for snippet: Snippet) -> [Host.ID] {
        let wanted = Set(snippet.targetHostIDs)
        return app.snippets.searchHosts("").filter { wanted.contains($0.id) }.map(\.id)
    }

    private func stageExecution(snippetID: Snippet.ID, hostIDs: [Host.ID]) {
        guard let snippet = snippet(snippetID), !hostIDs.isEmpty else { return }
        handle(
            MobileSnippetOperations.executionDecision(
                for: snippet, hostIDs: hostIDs, requiresHostSelection: false),
            snippetID: snippetID)
    }

    private func completeTargetSelection() {
        guard let request = pendingTargetExecution else { return }
        pendingTargetExecution = nil
        stageExecution(snippetID: request.snippetID, hostIDs: request.hostIDs)
    }

    private func performExecution(_ request: ExecutionRequest) {
        guard let snippet = snippet(request.snippetID) else { return }
        execute(snippet, request.hostIDs)
    }

    private var destructiveExecuteTitle: String {
        guard let request = destructiveRequest else { return String(localized: AppStrings.Common.run) }
        return request.hostIDs.count == 1
            ? String(localized: AppStrings.Snippets.runOn1Host)
            : String(localized: AppStrings.Snippets.runOnHosts(request.hostIDs.count))
    }

    private var destructiveMessage: String {
        guard let request = destructiveRequest, let snippet = snippet(request.snippetID) else { return "" }
        let wanted = Set(request.hostIDs)
        let names = app.snippets.searchHosts("").filter { wanted.contains($0.id) }.map(\.name)
            .joined(separator: ", ")
        return "\(snippet.body)\n\(names)"
    }

    private func targetSummary(_ snippet: Snippet) -> String {
        AppLocalization.resolve(
            AppStrings.Snippets.targetSummary(count: validTargets(for: snippet).count), locale: locale)
    }

    private func reportStorageError() {
        if let error = app.library.storageError { app.error = error }
    }
}

struct MobileSnippetDetailView: View {
    let app: MobileAppModel
    let snippetID: Snippet.ID
    let execute: (Snippet.ID) -> Void
    let edit: () -> Void
    let duplicate: (Snippet.ID) -> Void
    let delete: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var snippet: Snippet? { app.snippets.snippets.first { $0.id == snippetID } }

    var body: some View {
        Group {
            if let snippet {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        MobileSnippetDetailPanel(title: String(localized: AppStrings.Snippets.script)) {
                            Text(snippet.body).font(.body.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        riskPanel(snippet)
                        packagePanel(snippet)
                        targetPanel(snippet)
                        Button {
                            execute(snippet.id)
                        } label: {
                            Label(AppStrings.Common.run.swiftUIKey, systemImage: "play.fill")
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(app.snippets.hosts.isEmpty)
                    }
                    .padding(16)
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle(snippet.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button(AppStrings.Common.edit.swiftUIKey, systemImage: "pencil", action: edit).labelStyle(
                            .iconOnly)
                    }
                    .mobileProminentAction()
                    MobileToolbarOverflow {
                        Button(AppStrings.Common.duplicate.swiftUIKey, systemImage: "plus.square.on.square") {
                            duplicate(snippet.id)
                        }
                        Divider()
                        Button(
                            AppStrings.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive,
                            action: delete)
                    }
                }
            } else {
                ContentUnavailableView(AppStrings.Snippets.noSnippets.swiftUIKey, systemImage: "curlybraces")
            }
        }
        .onChange(of: app.snippets.snippets.map(\.id)) {
            if snippet == nil { dismiss() }
        }
    }

    private func riskPanel(_ snippet: Snippet) -> some View {
        let assessment = CommandRiskClassifier.assess(snippet.body)
        return MobileSnippetDetailPanel(title: String(localized: AppStrings.Snippets.risk)) {
            MobileSnippetRiskChip(assessment: assessment)
            ForEach(assessment.reasons, id: \.self) { reason in
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func packagePanel(_ snippet: Snippet) -> some View {
        MobileSnippetDetailPanel(title: String(localized: AppStrings.Snippets.package)) {
            Label(
                app.snippets.snippetPackagePath(snippet.packageID) ?? String(localized: AppStrings.Common.ungrouped),
                systemImage: "folder")
        }
    }

    private func targetPanel(_ snippet: Snippet) -> some View {
        let wanted = Set(snippet.targetHostIDs)
        let hosts = app.snippets.searchHosts("").filter { wanted.contains($0.id) }
        return MobileSnippetDetailPanel(title: String(localized: AppStrings.Snippets.targets)) {
            if hosts.isEmpty {
                Text(AppStrings.Snippets.noTargetsSelected).foregroundStyle(.secondary)
            } else {
                ForEach(hosts) { host in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.name)
                            Text(app.snippets.loginAddress(for: host))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "server.rack")
                    }
                }
            }
        }
    }
}

private struct MobileSnippetDetailPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .mobileCardSurface()
    }
}

private struct MobileSnippetRiskChip: View {
    let assessment: RiskAssessment

    var body: some View {
        MobileCardChip(
            text: assessment.risk.label, symbol: assessment.risk.symbol,
            tint: assessment.risk.mobileTint)
    }
}

private struct MobileSnippetMetadataChips: View {
    let target: String
    let assessment: RiskAssessment

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            VStack(alignment: .leading, spacing: 6) { chips }
        }
    }

    @ViewBuilder private var chips: some View {
        MobileCardChip(text: target, symbol: "server.rack")
        MobileSnippetRiskChip(assessment: assessment)
    }
}

extension CommandRisk {
    fileprivate var mobileTint: Color {
        switch self {
        case .safe: .green
        case .caution: .orange
        case .destructive: .red
        }
    }
}

struct MobileSnippetEditor: View {
    private enum PackageChoice: Hashable {
        case ungrouped
        case existing(SnippetPackage.ID)
        case new
    }

    let app: MobileAppModel
    let original: Snippet
    let existing: Bool
    let didSave: (Snippet) -> Void
    @State private var draft: Snippet
    @State private var choosingTargets = false
    @State private var creatingPackage = false
    @Environment(\.dismiss) private var dismiss

    init(
        app: MobileAppModel, snippet: Snippet?, packageID: SnippetPackage.ID?,
        didSave: @escaping (Snippet) -> Void
    ) {
        self.app = app
        let initial = snippet ?? Snippet(title: "", body: "", packageID: packageID)
        original = initial
        existing = snippet != nil
        self.didSave = didSave
        _draft = State(initialValue: initial)
    }

    private var trimmedTitle: String { draft.title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedBody: String { draft.body.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        MobileEditorSheet(
            title: existing
                ? String(localized: AppStrings.Snippets.editSnippet)
                : String(localized: AppStrings.Snippets.newSnippet),
            isDirty: draft != original,
            canSave: !trimmedTitle.isEmpty && !trimmedBody.isEmpty,
            save: save
        ) {
            SnippetOrganizationSection(name: $draft.title) {
                Picker(AppStrings.Snippets.package.swiftUIKey, selection: packageChoice) {
                    Text(AppStrings.Common.ungrouped).tag(PackageChoice.ungrouped)
                    ForEach(packageChoices, id: \.package.id) { choice in
                        Text(choice.path).tag(PackageChoice.existing(choice.package.id))
                    }
                    Divider()
                    Text(AppStrings.Snippets.newPackage).tag(PackageChoice.new)
                }
            }
            SnippetScriptSection(script: $draft.body, minHeight: 220) {
                let assessment = CommandRiskClassifier.assess(draft.body)
                MobileSnippetRiskChip(assessment: assessment)
                ForEach(assessment.reasons, id: \.self) { reason in
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(AppStrings.Snippets.targets.swiftUIKey) {
                Button {
                    choosingTargets = true
                } label: {
                    Label(AppStrings.Snippets.addHosts.swiftUIKey, systemImage: "server.rack")
                }
                .disabled(app.snippets.hosts.isEmpty)
                if selectedHosts.isEmpty {
                    Text(
                        app.snippets.hosts.isEmpty
                            ? String(localized: AppStrings.Snippets.noSavedHosts)
                            : String(localized: AppStrings.Snippets.noTargetsSelected)
                    )
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(selectedHosts) { host in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.name)
                                Text(app.snippets.loginAddress(for: host))
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                draft.targetHostIDs.removeAll { $0 == host.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(AppStrings.Common.removeNamed(host.name)))
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $choosingTargets) {
            MobileSnippetHostPicker(
                app: app, selected: Set(draft.targetHostIDs), title: AppStrings.Snippets.addHosts,
                actionTitle: AppStrings.Common.done, requiresSelection: false
            ) { ids in
                draft.targetHostIDs = ids
                choosingTargets = false
            }
        }
        .sheet(isPresented: $creatingPackage) {
            MobileSnippetPackageEditor(app: app, package: nil, parentID: nil) { package in
                draft.packageID = package.id
            }
        }
        .onChange(of: app.snippets.snippets.map(\.id)) {
            if existing && !app.snippets.snippets.contains(where: { $0.id == original.id }) {
                dismiss()
            }
        }
    }

    private var packageChoices: [(package: SnippetPackage, path: String)] {
        app.snippets.snippetPackages.compactMap { package in
            app.snippets.snippetPackagePath(package.id).map { (package, $0) }
        }.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private var packageChoice: Binding<PackageChoice> {
        Binding {
            draft.packageID.map(PackageChoice.existing) ?? .ungrouped
        } set: { choice in
            switch choice {
            case .ungrouped: draft.packageID = nil
            case .existing(let id): draft.packageID = id
            case .new: creatingPackage = true
            }
        }
    }

    private var selectedHosts: [Host] {
        let selected = Set(draft.targetHostIDs)
        return app.snippets.searchHosts("").filter { selected.contains($0.id) }
    }

    private func save() async throws {
        draft.title = trimmedTitle
        draft.body = trimmedBody
        draft.targetHostIDs = selectedHosts.map(\.id)
        app.snippets.upsert(draft)
        if let error = app.library.storageError { throw MobileEditorError.message(error) }
        didSave(draft)
    }
}

struct MobileSnippetPackageEditor: View {
    let app: MobileAppModel
    let original: SnippetPackage
    let existing: Bool
    let didSave: (SnippetPackage) -> Void
    @State private var draft: SnippetPackage
    @Environment(\.dismiss) private var dismiss

    init(
        app: MobileAppModel, package: SnippetPackage?, parentID: SnippetPackage.ID?,
        didSave: @escaping (SnippetPackage) -> Void = { _ in }
    ) {
        self.app = app
        let initial = package ?? SnippetPackage(name: "", parentID: parentID)
        original = initial
        existing = package != nil
        self.didSave = didSave
        _draft = State(initialValue: initial)
    }

    private var trimmedName: String { draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        MobileEditorSheet(
            title: existing
                ? String(localized: AppStrings.Snippets.editPackage)
                : String(localized: AppStrings.Snippets.newPackage),
            isDirty: draft != original, canSave: !trimmedName.isEmpty, compact: true,
            save: save
        ) {
            TextField(AppStrings.Common.name.swiftUIKey, text: $draft.name.singleLineText, axis: .horizontal)
                .singleLinePaste().lineLimit(1)
                .multilineTextAlignment(
                    .leading)
            Picker(AppStrings.Common.inside.swiftUIKey, selection: $draft.parentID) {
                Text(AppStrings.Common.topLevel).tag(SnippetPackage.ID?.none)
                ForEach(parentChoices, id: \.package.id) { choice in
                    Text(choice.path).tag(SnippetPackage.ID?.some(choice.package.id))
                }
            }
        }
        .onChange(of: app.snippets.snippetPackages.map(\.id)) {
            if existing && !app.snippets.snippetPackages.contains(where: { $0.id == original.id }) {
                dismiss()
            }
        }
    }

    private var parentChoices: [(package: SnippetPackage, path: String)] {
        let forbidden = Set(
            [draft.id] + app.snippets.descendantSnippetPackages(of: draft.id).map(\.id))
        return app.snippets.snippetPackages.filter { !forbidden.contains($0.id) }
            .compactMap { package in
                app.snippets.snippetPackagePath(package.id).map { (package, $0) }
            }
            .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private func save() async throws {
        draft.name = trimmedName
        app.snippets.upsert(draft)
        if let error = app.library.storageError { throw MobileEditorError.message(error) }
        didSave(draft)
    }
}

struct MobileSnippetHostPicker: View {
    let app: MobileAppModel
    let title: LocalizedStringResource
    let actionTitle: LocalizedStringResource
    let requiresSelection: Bool
    let save: ([Host.ID]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: Set<Host.ID>

    init(
        app: MobileAppModel, selected: Set<Host.ID>, title: LocalizedStringResource,
        actionTitle: LocalizedStringResource, requiresSelection: Bool,
        save: @escaping ([Host.ID]) -> Void
    ) {
        self.app = app
        self.title = title
        self.actionTitle = actionTitle
        self.requiresSelection = requiresSelection
        self.save = save
        _selected = State(initialValue: selected)
    }

    private var results: [Host] { app.snippets.searchHosts(query) }
    private var allResultsSelected: Bool {
        !results.isEmpty && results.allSatisfy { selected.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                if app.snippets.hosts.isEmpty {
                    ContentUnavailableView(
                        AppStrings.Vault.noHosts.swiftUIKey, systemImage: "server.rack",
                        description: Text(
                            AppStrings.Snippets.addAHostBeforeChoosingDefaultTargets
                        )
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    Section {
                        Button(
                            allResultsSelected
                                ? String(localized: AppStrings.Common.deselectAll)
                                : String(localized: AppStrings.Common.selectAll)
                        ) {
                            toggleAllResults()
                        }
                    }
                    Section {
                        ForEach(results) { host in
                            Button {
                                toggle(host.id)
                            } label: {
                                MobileHostPickerRow(
                                    host: host,
                                    loginAddress: app.snippets.loginAddress(for: host)
                                ) {
                                    if selected.contains(host.id) {
                                        Image(systemName: "checkmark")
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(.tint)
                                            .accessibilityHidden(true)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected.contains(host.id) ? [.isSelected] : [])
                        }
                    }
                }
            }
            .searchable(text: $query.singleLineText, prompt: AppStrings.Vault.searchHosts.swiftUIKey)
            .navigationTitle(Text(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppStrings.Common.cancel.swiftUIKey, systemImage: "xmark") { dismiss() }.labelStyle(
                        .iconOnly)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle, systemImage: "checkmark") {
                        let ordered = app.snippets.searchHosts("").filter { selected.contains($0.id) }.map(\.id)
                        save(ordered)
                        dismiss()
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.tint)
                    .disabled(requiresSelection && selected.isEmpty)
                }
            }
            .onAppear {
                selected.formIntersection(Set(app.snippets.hosts.map(\.id)))
            }
        }
        .mobileSheetPresentation(compact: true)
    }

    private func toggle(_ id: Host.ID) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }

    private func toggleAllResults() {
        if allResultsSelected {
            selected.subtract(results.map(\.id))
        } else {
            selected.formUnion(results.map(\.id))
        }
    }
}
