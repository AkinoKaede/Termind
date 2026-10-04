import AgentKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

@Observable
final class ModelNameEditorSession {
    private(set) var modelID: String?
    private(set) var name = ""

    func begin(with model: AIModel?) {
        guard modelID != model?.id else { return }
        modelID = model?.id
        name = model?.displayName ?? ""
    }

    func save(_ name: String, model: AIModel, providerID: ModelProvider.ID, in store: AIConfigurationModel) {
        guard var current = store.modelProvider(providerID)?.model(model.id) else { return }
        begin(with: current)
        self.name = name
        current.displayName = name
        store.updateModel(current, in: providerID)
    }
}

/// A provider's full-width models page: a checkable list and details for the
/// selected row.
///
/// Master–detail inside the sheet rather than a second sheet on top of the
/// first. macOS handles stacked modals badly, and the thing being edited here is
/// usually *one wrong chip on one row of many* — a flow that has to survive
/// being repeated, which a modal that must be opened and closed each time does
/// not.
///
/// Two selections coexist, and they answer different questions. Clicking a row
/// says "show me this one"; the tick says "act on this one". The toolbar's verbs
/// all read from the ticks and nothing else, so there is one rule to learn
/// rather than one per button — and Test in particular needs it, since testing
/// every model on an endpoint would spend real money on models the user has no
/// intention of using.
struct ModelListEditor: View {
    @Environment(\.locale) private var locale
    @Observable
    final class EditorState {
        var query = ""
        var selection: String?
        var checked: Set<String> = []
        var results: [String: TestResult] = [:]
        var fetch: FetchState = .idle
        var isTesting = false
        var isAdding = false
        var newModelID = ""
        var candidates: [AIModel] = []
        var isChoosing = false
    }

    let modelProviderID: ModelProvider.ID

    @Environment(AppModel.self) private var app

    @State private var state = EditorState()
    @State private var nameSession = ModelNameEditorSession()

    private var provider: ModelProvider? { app.aiConfiguration.modelProvider(modelProviderID) }

    private var models: [AIModel] {
        (provider?.models ?? []).filter { $0.matches(state.query) }
    }

    private var selected: AIModel? {
        state.selection.flatMap { id in provider?.model(id) }
    }

    var body: some View {
        Group {
            if state.isChoosing {
                candidatePicker
            } else {
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    list
                    Divider()
                    detail
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(TermindColor.windowSurface)
        .onChange(of: state.selection, initial: true) { nameSession.begin(with: selected) }
        .onChange(of: modelProviderID) {
            nameSession.begin(with: nil)
            nameSession.begin(with: selected)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            HStack(spacing: Metrics.Space.s) {
                Text(AppStrings.Settings.models)
                    .font(.headline)
                if let count = provider?.models.count, count > 0 {
                    Text(count, format: .number)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Metrics.Space.s)
                        .padding(.vertical, 1)
                        .background(.quaternary.opacity(0.6), in: .capsule)
                }
                Spacer(minLength: 0)
            }

            filterField

            HStack(spacing: Metrics.Space.s) {
                Button(AppStrings.Settings.fetch.swiftUIKey, action: fetchModels)
                    .disabled(provider?.canFetchModels != true || state.fetch == .running)
                    .help(fetchHelp)

                Button(AppStrings.Common.add.swiftUIKey) { state.isAdding = true }

                Button(AppStrings.Common.delete.swiftUIKey, role: .destructive, action: deleteChecked)
                    .disabled(state.checked.isEmpty)
                    .help(deleteHelp)

                Button(AppStrings.Common.test.swiftUIKey, action: testChecked)
                    .disabled(
                        state.checked.isEmpty || state.isTesting
                    )
                    .help(Text(AppStrings.Settings.modelTestExplanation))

                Spacer(minLength: 0)

                if state.fetch == .running || state.isTesting {
                    ProgressView().controlSize(.mini)
                }
            }
            .controlSize(.small)

            if state.isAdding {
                HStack(spacing: Metrics.Space.s) {
                    TextField(
                        AppStrings.Settings.exactModelIdSuchAsGpt54.swiftUIKey,
                        text: $state.newModelID.singleLineText,
                        axis: .horizontal
                    ).singleLinePaste().lineLimit(1)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addModel)

                    Button(AppStrings.Common.cancel.swiftUIKey) {
                        state.newModelID = ""
                        state.isAdding = false
                    }
                    Button(AppStrings.Common.add.swiftUIKey, action: addModel)
                        .disabled(state.newModelID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)
            }

            status
        }
        .padding(Metrics.Space.l)
    }

    private var filterField: some View {
        HStack(spacing: Metrics.Space.xs) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(
                AppStrings.Common.filter.swiftUIKey,
                text: $state.query.singleLineText,
                axis: .horizontal
            ).singleLinePaste().lineLimit(1).textFieldStyle(.plain)
            if !state.query.isEmpty {
                Button {
                    state.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(AppStrings.Settings.clearFilter))
            }
        }
        .padding(.horizontal, Metrics.Space.s)
        .padding(.vertical, Metrics.Space.xs)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: Metrics.Radius.medium))
    }

    @ViewBuilder
    private var status: some View {
        if case .failed(let message) = state.fetch {
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        } else if !state.checked.isEmpty {
            Text(AppStrings.Common.selected(state.checked.count))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else if let fetched = provider?.modelsFetchedAt {
            Text(AppStrings.Settings.fetched(fetched.formatted(.relative(presentation: .named).locale(locale))))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// What Delete takes with it.
    ///
    /// A model is re-fetchable, so this needs no confirmation — but a role
    /// pointing at one is not obviously at stake, and a Chat model that quietly
    /// went back to Automatic is exactly the kind of change nobody connects to
    /// the click that caused it.
    private var deleteHelp: Text {
        let broken = brokenRoles
        guard !broken.isEmpty else {
            return Text(AppStrings.Settings.removesTheSelectedModelsYouCanFetchThemAgain)
        }
        let names = broken.map(\.displayName).formatted(.list(type: .and).locale(locale))
        return Text(AppStrings.Settings.removesTheSelectedModelsWouldReturnToAutomatic(names))
    }

    /// Roles whose model is among the ticked ones.
    private var brokenRoles: [AIRole] {
        AIRole.allCases.filter { role in
            guard let ref = app.aiConfiguration.assignment(for: role), ref.modelProviderID == modelProviderID else {
                return false
            }
            return state.checked.contains(ref.modelID)
        }
    }

    /// Says *why* the button is off rather than just being off.
    private var fetchHelp: Text {
        guard let provider else { return Text("") }
        if provider.resolvedModelsURL == nil {
            return Text(AppStrings.Settings.modelDiscoveryRequiresURL)
        }
        return Text(AppStrings.Settings.fetchAvailableModelsFromTheEndpoint)
    }

    // MARK: - Candidate picker

    /// What a Fetch opens.
    ///
    /// A gateway can answer `/models` with eighty entries, most of them models
    /// this user will never call — embeddings, audio, a dozen dated snapshots of
    /// the same thing. Adding all of them would bury the four that matter in
    /// every picker in the app. So a fetch proposes, and the user disposes.
    ///
    /// Nothing is ticked to start with, and Select All acts on the *filtered*
    /// set — which makes "give me every Claude" two actions rather than twelve.
    private var candidatePicker: some View {
        CandidatePicker(
            candidates: state.candidates,
            existing: Set(provider?.models.map(\.id) ?? []),
            add: { chosen in
                for model in state.candidates where chosen.contains(model.id) {
                    app.aiConfiguration.addModel(model, to: modelProviderID)
                }
                app.aiConfiguration.markModelsFetched(for: modelProviderID)
                state.isChoosing = false
            },
            cancel: { state.isChoosing = false }
        )
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if models.isEmpty {
            VStack(spacing: Metrics.Space.s) {
                Spacer()
                Text(provider?.models.isEmpty == true ? AppStrings.Settings.noModelsYet : AppStrings.Settings.noMatch)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if provider?.models.isEmpty == true, let emptyHint {
                    Text(emptyHint)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(.horizontal, Metrics.Space.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(models) { model in
                        ModelRow(
                            model: model,
                            isSelected: state.selection == model.id,
                            isChecked: state.checked.contains(model.id),
                            result: state.results[model.id],
                            canTest: !state.isTesting,
                            select: { state.selection = model.id },
                            check: { toggleCheck(model.id) },
                            edit: { state.selection = model.id },
                            test: { testModels([model]) },
                            delete: { deleteModels([model.id]) }
                        )
                        .frame(height: 56)
                    }
                }
            }
        }
    }

    private var emptyHint: LocalizedStringResource? {
        guard provider?.resolvedModelsURL == nil else { return nil }
        return AppStrings.Settings.addAUrlThenPressFetch
    }

    // MARK: - Detail

    /// Editing one row.
    ///
    /// Every field here exists because some endpoint does not report it. A
    /// gateway that sends full metadata means this pane is only ever read; a
    /// bare `/models` means it is the only way the chips get to be right.
    @ViewBuilder
    private var detail: some View {
        if let model = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.Space.l) {
                    // No delete here. Removing is available from the toolbar for
                    // checked models and from a row's context menu for that row;
                    // neither can be confused with this pane's current contents.
                    HStack(spacing: Metrics.Space.s) {
                        Text(model.id)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 0)

                        Button {
                            state.selection = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 20, height: 20)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help(AppStrings.Settings.closeModelDetails.swiftUIKey)
                        .accessibilityLabel(Text(AppStrings.Settings.closeModelDetails))
                    }
                    .frame(maxWidth: .infinity)

                    if let result = state.results[model.id] {
                        Label(result.message, systemImage: result.symbol)
                            .font(.caption)
                            .foregroundStyle(result.isSuccess ? Color.green : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    TextField(
                        AppStrings.Common.name.swiftUIKey,
                        text: Binding(
                            get: { nameSession.modelID == model.id ? nameSession.name : model.displayName },
                            set: {
                                nameSession.save($0, model: model, providerID: modelProviderID, in: app.aiConfiguration)
                            }
                        ).singleLineText, prompt: Text(verbatim: model.id),
                        axis: .horizontal
                    ).singleLinePaste().lineLimit(1)
                        .textFieldStyle(.roundedBorder)

                    Picker(AppStrings.Common.type.swiftUIKey, selection: field(model, \.kind)) {
                        ForEach(AIModel.Kind.allCases) { Text($0.displayName).tag($0) }
                    }

                    Toggle(
                        AppStrings.Settings.showInAssistant.swiftUIKey,
                        isOn: field(model, \AIModel.isShownInAssistant)
                    )
                    .help(AppStrings.Settings.modelPickerVisibilityExplanation.swiftUIKey)

                    modalityToggles(AppStrings.Settings.input, model: model, keyPath: \.input)
                    abilityToggles(model)
                    if model.abilities.contains(.reasoning), let provider {
                        reasoningSection(model, provider: provider)
                    }

                    HStack(spacing: Metrics.Space.m) {
                        limitField(AppStrings.Settings.contextWindow, model: model, keyPath: \.contextLength)
                        limitField(AppStrings.Settings.maxOutput, model: model, keyPath: \.maxOutputTokens)
                    }

                    if model.origin == .manual {
                        Text(AppStrings.Settings.addedManually)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(Metrics.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 320)
            .controlSize(.small)
        } else {
            Text(AppStrings.Settings.modelSelectionExplanation)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(Metrics.Space.l)
                .frame(maxWidth: .infinity)
        }
    }

    /// Output modalities are deliberately not editable.
    ///
    /// Every chat model in existence outputs text, an image model's output is
    /// implied by its type, and a toggle for a value with one plausible setting
    /// is a row of noise in a pane that already has eight.
    private func modalityToggles(
        _ label: LocalizedStringResource,
        model: AIModel,
        keyPath: WritableKeyPath<AIModel, Set<AIModel.Modality>>
    ) -> some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xs) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            FlowLayout(spacing: Metrics.Space.xs) {
                ForEach(AIModel.Modality.allCases) { modality in
                    ToggleChip(
                        label: modality.displayName,
                        symbol: modality.symbol,
                        isOn: model[keyPath: keyPath].contains(modality)
                    ) {
                        // Text is not removable: a model that accepts nothing is
                        // not a state any endpoint means to describe.
                        guard modality != .text else { return }
                        var updated = model
                        if updated[keyPath: keyPath].contains(modality) {
                            updated[keyPath: keyPath].remove(modality)
                        } else {
                            updated[keyPath: keyPath].insert(modality)
                        }
                        app.aiConfiguration.updateModel(updated, in: modelProviderID)
                    }
                    .opacity(modality == .text ? 0.6 : 1)
                }
            }
        }
    }

    private func abilityToggles(_ model: AIModel) -> some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xs) {
            Text(AppStrings.Settings.can)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            FlowLayout(spacing: Metrics.Space.xs) {
                ForEach(AIModel.Ability.allCases) { ability in
                    ToggleChip(
                        label: ability.displayName,
                        symbol: ability.symbol,
                        isOn: model.abilities.contains(ability)
                    ) {
                        var updated = model
                        if updated.abilities.contains(ability) {
                            updated.abilities.remove(ability)
                        } else {
                            updated.abilities.insert(ability)
                        }
                        app.aiConfiguration.updateModel(updated, in: modelProviderID)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func reasoningSection(_ model: AIModel, provider: ModelProvider) -> some View {
        let automatic = ModelCapabilityResolver.reasoning(
            model: model.withoutReasoningOverride,
            provider: provider
        )

        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(AppStrings.Settings.reasoningEffort)
                        .font(.caption.weight(.medium))
                    Text(
                        model.reasoningProfile == nil
                            ? AppStrings.Settings.automaticFromModelCatalog : AppStrings.Settings.customMapping
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                Spacer()
                if model.reasoningProfile == nil {
                    Button(AppStrings.Common.customize.swiftUIKey) {
                        var updated = model
                        updated.reasoningProfile = ModelCapabilityResolver.customProfile(
                            from: automatic
                        )
                        app.aiConfiguration.updateModel(updated, in: modelProviderID)
                    }
                } else {
                    Button(AppStrings.Settings.resetToAutomatic.swiftUIKey) {
                        var updated = model
                        updated.reasoningProfile = nil
                        app.aiConfiguration.updateModel(updated, in: modelProviderID)
                    }
                }
            }

            if model.reasoningProfile == nil {
                FlowLayout(spacing: Metrics.Space.xs) {
                    ForEach(automatic.supported) { effort in
                        CardChip(
                            text: automatic.wireValue(for: effort).map {
                                "\(effort.displayName) → \($0)"
                            } ?? effort.displayName
                        )
                    }
                }
            } else {
                ForEach(ReasoningEffort.allCases) { effort in
                    reasoningLevelRow(effort, model: model)
                }
            }
        }
        .padding(.top, Metrics.Space.xs)
    }

    private func reasoningLevelRow(_ effort: ReasoningEffort, model: AIModel) -> some View {
        let mapping =
            model.reasoningProfile?.mapping(for: effort)
            ?? ReasoningLevelMapping(isSupported: false)
        return HStack(spacing: Metrics.Space.s) {
            Toggle(
                effort.displayName,
                isOn: Binding(
                    get: { mapping.isSupported },
                    set: { enabled in
                        var updated = model
                        guard updated.setReasoningEffort(effort, isSupported: enabled) else { return }
                        app.aiConfiguration.updateModel(updated, in: modelProviderID)
                    }
                )
            )
            .toggleStyle(.checkbox)
            .frame(width: 100, alignment: .leading)

            TextField(
                AppStrings.Settings.providerDefault.swiftUIKey,
                text: Binding(
                    get: { mapping.wireValue ?? "" },
                    set: { value in
                        var updated = model
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.setReasoningWireValue(trimmed.isEmpty ? nil : value, for: effort)
                        app.aiConfiguration.updateModel(updated, in: modelProviderID)
                    }
                ).singleLineText, axis: .horizontal
            ).singleLinePaste().lineLimit(1)
                .textFieldStyle(.roundedBorder)
                .disabled(!mapping.isSupported)
                .accessibilityLabel(Text(AppStrings.Settings.reasoningProviderValue(effort.displayName)))
        }
    }

    private func limitField(
        _ label: LocalizedStringResource,
        model: AIModel,
        keyPath: WritableKeyPath<AIModel, Int?>
    ) -> some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField(
                label,
                value: Binding(
                    get: { model[keyPath: keyPath] },
                    set: { newValue in
                        var updated = model
                        updated[keyPath: keyPath] = newValue
                        app.aiConfiguration.updateModel(updated, in: modelProviderID)
                    }
                ),
                format: .number
            ).lineLimit(1)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
        }
    }

    private func field<Value>(
        _ model: AIModel, _ keyPath: WritableKeyPath<AIModel, Value>
    ) -> Binding<Value> where Value: Hashable {
        Binding(
            get: {
                app.aiConfiguration.modelProvider(modelProviderID)?.model(model.id)?[keyPath: keyPath]
                    ?? model[keyPath: keyPath]
            },
            set: { newValue in
                guard var updated = app.aiConfiguration.modelProvider(modelProviderID)?.model(model.id) else { return }
                updated[keyPath: keyPath] = newValue
                app.aiConfiguration.updateModel(updated, in: modelProviderID)
            }
        )
    }

    // MARK: - Actions

    /// Fetches, then opens the picker. Nothing is written to the provider here.
    private func fetchModels() {
        guard let provider else { return }
        state.fetch = .running
        guard let secret = app.aiConfiguration.modelSecret(for: provider) else {
            state.fetch = .failed(
                app.aiConfiguration.secretStorageError
                    ?? String(localized: AppStrings.Settings.providerCredentialUnavailable)
            )
            return
        }
        Task {
            do {
                state.candidates = try await ModelCatalogClient().models(
                    for: provider, secret: secret
                )
                state.fetch = .idle
                state.isChoosing = true
            } catch {
                state.fetch = .failed(error.localizedDescription)
            }
        }
    }

    /// Runs a real chat request against each ticked model.
    ///
    /// Sequential rather than concurrent, on purpose: these are billed requests
    /// against one account, and firing eight at once is how a rate limit turns a
    /// working setup into a page of red.
    private func testChecked() {
        guard let provider else { return }
        testModels(provider.models.filter { state.checked.contains($0.id) })
    }

    private func testModels(_ targets: [AIModel]) {
        guard let provider, !state.isTesting, !targets.isEmpty else {
            return
        }
        guard let credential = app.aiConfiguration.modelSecret(for: provider) else {
            for model in targets {
                state.results[model.id] = .failed(
                    app.aiConfiguration.secretStorageError
                        ?? String(localized: AppStrings.Settings.providerCredentialUnavailable))
            }
            return
        }

        state.isTesting = true
        for model in targets {
            state.results[model.id] = .queued
        }
        Task {
            for model in targets {
                guard app.aiConfiguration.modelProvider(modelProviderID)?.model(model.id) != nil else {
                    state.results[model.id] = nil
                    continue
                }
                state.results[model.id] = .running
                do {
                    let result = try await ChatProbe().run(model: model, on: provider, secret: credential)
                    guard app.aiConfiguration.modelProvider(modelProviderID)?.model(model.id) != nil else {
                        state.results[model.id] = nil
                        continue
                    }
                    state.results[model.id] = .passed(result.summary)
                } catch {
                    guard app.aiConfiguration.modelProvider(modelProviderID)?.model(model.id) != nil else {
                        state.results[model.id] = nil
                        continue
                    }
                    state.results[model.id] = .failed(error.localizedDescription)
                }
            }
            state.isTesting = false
        }
    }

    private func toggleCheck(_ id: String) {
        if state.checked.contains(id) {
            state.checked.remove(id)
        } else {
            state.checked.insert(id)
        }
    }

    /// A hand-typed model gets the same resolution a fetched one does, so the
    /// chips arrive already right for anything the catalog recognises and the
    /// user only has to correct what it does not.
    private func addModel() {
        let id = state.newModelID.trimmingCharacters(in: .whitespaces)
        state.newModelID = ""
        guard !id.isEmpty, let provider else { return }
        let model = ModelCapabilityResolver.resolve(
            model: AIModel(id: id),
            provider: provider
        ).model
        app.aiConfiguration.addModel(model, to: modelProviderID)
        state.selection = id
        state.isAdding = false
    }

    private func deleteChecked() {
        deleteModels(state.checked)
    }

    private func deleteModels(_ doomed: Set<String>) {
        app.aiConfiguration.removeModels(doomed, from: modelProviderID)
        state.checked.subtract(doomed)
        for id in doomed { state.results[id] = nil }
        if let selection = state.selection, doomed.contains(selection) {
            state.selection = nil
        }
    }

    enum FetchState: Equatable {
        case idle
        case running
        case failed(String)
    }

    /// What one Test came back with.
    nonisolated enum TestResult: Hashable, Sendable {
        case queued
        case running
        case passed(String)
        case failed(String)

        var isSuccess: Bool { if case .passed = self { true } else { false } }

        var message: String {
            switch self {
            case .queued: String(localized: AppStrings.Settings.waitingProgress)
            case .running: String(localized: AppStrings.Settings.testingProgress)
            case .passed(let summary): summary
            case .failed(let reason): reason
            }
        }

        var symbol: String {
            switch self {
            case .queued: "hourglass"
            case .running: "clock"
            case .passed: "checkmark.circle.fill"
            case .failed: "exclamationmark.triangle.fill"
            }
        }
    }
}

// MARK: - Picking what to add

/// The list a Fetch proposes.
///
/// Its own view with its own state, so the tick marks made here cannot be
/// confused with the ones in the list behind it — those mean "test this", these
/// mean "add this", and sharing a `Set` between them would be a bug that only
/// shows up once somebody uses both.
private struct CandidatePicker: View {
    let candidates: [AIModel]
    /// Ids the provider already has. Shown, but not offered again.
    let existing: Set<String>
    let add: (Set<String>) -> Void
    let cancel: () -> Void

    @State private var chooser = ManagedChooserState<String>(mode: .multiple)

    private var query: String { chooser.query }
    private var queryBinding: Binding<String> {
        $chooser.query
    }

    private var filtered: [AIModel] {
        candidates.filter { $0.matches(query) }
    }

    /// What Select All acts on: the filtered set minus what is already there.
    /// Acting on the filter is what turns "add every Claude" into two clicks.
    private var selectable: [AIModel] {
        filtered.filter { !existing.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(maxWidth: .infinity)
        .onChange(of: chooser.query) {
            chooser.queryDidChange(
                visible: filtered.map(\.id), enabled: Set(selectable.map(\.id))
            )
        }
        .onKeyPress(.upArrow) { moveCursor(-1) }
        .onKeyPress(.downArrow) { moveCursor(1) }
        .onKeyPress(.space) { toggleCursor() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            Text(AppStrings.Settings.modelsOffered(candidates.count))
                .font(.headline)

            TermindSearchField(text: queryBinding, prompt: AppStrings.Common.filter, density: .compact)

            HStack(spacing: Metrics.Space.m) {
                Button(AppStrings.Common.selectAll.swiftUIKey) {
                    let ids = filtered.map(\.id)
                    chooser.toggleAll(visible: ids, enabled: Set(selectable.map(\.id)))
                }
                .disabled(selectable.isEmpty)
                Button(AppStrings.Common.selectNone.swiftUIKey) { chooser.selected.subtract(filtered.map(\.id)) }
                    .disabled(chooser.selected.isEmpty)
                Spacer(minLength: 0)
            }
            .controlSize(.small)
        }
        .padding(Metrics.Space.l)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { model in
                        CandidateRow(
                            model: model,
                            isAlreadyAdded: existing.contains(model.id),
                            isCursor: chooser.cursor == model.id,
                            isChosen: chooser.selected.contains(model.id)
                        ) {
                            chooser.activate(model.id)
                        }
                        .frame(height: 52)
                        .id(model.id)
                    }
                }
            }
            .onAppear { scrollCursorIntoView(using: proxy) }
            .onChange(of: chooser.cursor) { _, _ in scrollCursorIntoView(using: proxy) }
            .onChange(of: filtered.map(\.id)) { _, _ in scrollCursorIntoView(using: proxy) }
        }
    }

    private func scrollCursorIntoView(using proxy: ScrollViewProxy) {
        guard let cursor = chooser.cursor else { return }
        proxy.scrollTo(cursor)
    }

    private var footer: some View {
        HStack(spacing: Metrics.Space.m) {
            Button(AppStrings.Common.cancel.swiftUIKey, action: cancel)
                .keyboardShortcut(.cancelAction)
            Spacer(minLength: 0)
            Button(
                chooser.selected.isEmpty
                    ? AppStrings.Common.add.swiftUIKey : AppStrings.Settings.add(chooser.selected.count).swiftUIKey
            ) { add(chooser.selected) }
            .keyboardShortcut(.defaultAction)
            .disabled(chooser.selected.isEmpty)
        }
        .padding(Metrics.Space.l)
    }

    private func moveCursor(_ delta: Int) -> KeyPress.Result {
        let ids = selectable.map(\.id)
        chooser.moveCursor(by: delta, through: ids)
        return ids.isEmpty ? .ignored : .handled
    }

    private func toggleCursor() -> KeyPress.Result {
        guard let cursor = chooser.cursor else { return .ignored }
        chooser.toggle(cursor)
        return .handled
    }
}

private struct CandidateRow: View {
    let model: AIModel
    let isAlreadyAdded: Bool
    let isCursor: Bool
    let isChosen: Bool
    let toggle: () -> Void

    var body: some View {
        SelectableRow(
            isCursor: isCursor, isSelected: isChosen, isEnabled: !isAlreadyAdded
        ) {
            HStack(spacing: Metrics.Space.m) {
                if isAlreadyAdded {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.tertiary)
                } else {
                    SelectionMark(mode: .multiple, isSelected: isChosen)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(model.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(model.id)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } trailing: {
            if isAlreadyAdded {
                CardChip(text: String(localized: AppStrings.Settings.added))
            } else {
                ModelBadges(model: model)
            }
        }
        .font(.callout)
        .onTapGesture { if !isAlreadyAdded { toggle() } }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Rows

private struct ModelRow: View {
    let model: AIModel
    let isSelected: Bool
    let isChecked: Bool
    let result: ModelListEditor.TestResult?
    let canTest: Bool
    let select: () -> Void
    let check: () -> Void
    let edit: () -> Void
    let test: () -> Void
    let delete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Metrics.Space.s) {
            Button(action: check) {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isChecked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(AppStrings.Settings.selectForBatchActions(model.label)))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Metrics.Space.xs) {
                    Text(model.label)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let result {
                        Image(systemName: result.symbol)
                            .font(.caption2)
                            .foregroundStyle(result.isSuccess ? Color.green : Color.orange)
                    }
                }

                HStack(spacing: Metrics.Space.xxs) {
                    ModelBadges(model: model)
                    Spacer(minLength: 0)
                    if let context = model.contextLength {
                        Text(Self.contextLabel(context)).monospacedDigit()
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Metrics.Space.l)
        .padding(.vertical, Metrics.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Highlight.fill(isSelected: isSelected, isHovering: isHovering))
        .contentShape(.rect)
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(AppStrings.Common.edit.swiftUIKey, systemImage: MenuSymbol.edit, action: edit)
            Button(AppStrings.Common.test.swiftUIKey, systemImage: MenuSymbol.test, action: test)
                .disabled(!canTest)
            Divider()
            DestructiveMenuButton(AppStrings.Common.delete, action: delete)
        }
        .help(Text(result?.message ?? model.id))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// `1M` beats `1,000,000` in a narrow column, and nobody reading a model
    /// list needs the exact figure — the editor below has it.
    static func contextLabel(_ tokens: Int) -> String {
        switch tokens {
        case 1_000_000...: "\(tokens / 1_000_000)M"
        case 1_000...: "\(tokens / 1_000)K"
        default: "\(tokens)"
        }
    }
}

/// The glyph run that says what a model can do.
///
/// Modality first, because "can it see" is the question asked most often about a
/// model you are choosing between. Text is left out — every model has it, so
/// drawing it says nothing and costs a column.
private struct ModelBadges: View {
    let model: AIModel

    var body: some View {
        HStack(spacing: Metrics.Space.xxs) {
            ForEach(AIModel.Modality.allCases.filter { model.input.contains($0) }) { modality in
                if modality != .text {
                    Image(systemName: modality.symbol)
                }
            }
            ForEach(AIModel.Ability.allCases.filter { model.abilities.contains($0) }) { ability in
                Image(systemName: ability.symbol)
            }
            if model.kind != .chat {
                Text(model.kind.displayName)
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}

/// A capsule that toggles.
///
/// Chips rather than a column of `Toggle`s: there are seven of these and a
/// switch each would be taller than the pane. Styled off `CardChip` so a chip
/// that can be pressed still looks like the chips that cannot.
private struct ToggleChip: View {
    let label: String
    let symbol: String
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Metrics.Space.xxs) {
                Image(systemName: symbol)
                Text(label)
            }
            .font(.caption2)
            .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .padding(.horizontal, Metrics.Space.s)
            .padding(.vertical, 2)
            .background(
                isOn
                    ? AnyShapeStyle(Color.accentColor.opacity(0.16))
                    : AnyShapeStyle(.quaternary.opacity(0.6)),
                in: .capsule
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
    }
}
