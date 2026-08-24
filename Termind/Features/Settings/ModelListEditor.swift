import SwiftUI

/// The models column of `ModelProviderEditorSheet`: a checkable list, and an
/// Context Panel for whichever row is selected.
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

    private var provider: ModelProvider? { app.ai.modelProvider(modelProviderID) }

    private var models: [AIModel] {
        (provider?.models ?? []).filter { $0.matches(state.query) }
    }

    private var selected: AIModel? {
        state.selection.flatMap { id in provider?.model(id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            list
            Divider()
            detail
        }
        .background(.background)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            HStack(spacing: Metrics.Space.s) {
                Text("Models")
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
                Button("Fetch", action: fetchModels)
                    .disabled(provider?.canFetchModels != true || state.fetch == .running)
                    .help(fetchHelp)
                    .popover(
                        isPresented: Binding(
                            get: { state.isChoosing }, set: { state.isChoosing = $0 }
                        ),
                        arrowEdge: .bottom
                    ) { candidatePicker }

                Button("Add") { state.isAdding = true }

                Button("Delete", role: .destructive, action: deleteChecked)
                    .disabled(state.checked.isEmpty)
                    .help(deleteHelp)

                Button("Test", action: testChecked)
                    .disabled(
                        state.checked.isEmpty || state.isTesting
                            || provider?.hasCredential != true
                    )
                    .help(Text("Sends each selected model a short prompt and shows the response."))

                Spacer(minLength: 0)

                if state.fetch == .running || state.isTesting {
                    ProgressView().controlSize(.mini)
                }
            }
            .controlSize(.small)

            status
        }
        .padding(Metrics.Space.l)
        .alert(
            "Add Model",
            isPresented: Binding(get: { state.isAdding }, set: { state.isAdding = $0 })
        ) {
            TextField(
                "Model id",
                text: Binding(get: { state.newModelID }, set: { state.newModelID = $0 })
            )
            Button("Cancel", role: .cancel) { state.newModelID = "" }
            Button("Add", action: addModel)
        } message: {
            Text("Enter the exact model ID expected by the endpoint, such as gpt-5.4.")
        }
    }

    private var filterField: some View {
        HStack(spacing: Metrics.Space.xs) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(
                "Filter", text: Binding(get: { state.query }, set: { state.query = $0 })
            ).textFieldStyle(.plain)
            if !state.query.isEmpty {
                Button {
                    state.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear filter"))
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
            Text("\(state.checked.count) selected")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else if let fetched = provider?.modelsFetchedAt {
            Text("Fetched \(fetched.formatted(.relative(presentation: .named)))")
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
            return Text("Removes the selected models. You can fetch them again.")
        }
        let names = broken.map(\.displayName).formatted(.list(type: .and))
        return Text("Removes the selected models. \(names) would return to Automatic.")
    }

    /// Roles whose model is among the ticked ones.
    private var brokenRoles: [AIRole] {
        AIRole.allCases.filter { role in
            guard let ref = app.ai.assignment(for: role), ref.modelProviderID == modelProviderID else { return false }
            return state.checked.contains(ref.modelID)
        }
    }

    /// Says *why* the button is off rather than just being off. The Vertex case
    /// is the one people will otherwise read as a bug.
    private var fetchHelp: Text {
        guard let provider else { return Text("") }
        if provider.usesVertex && provider.kind == .google {
            return Text(ModelCatalogError.unsupportedForVertex.localizedDescription)
        }
        if !provider.hasCredential {
            return Text("Add a key first. This endpoint requires one to list models.")
        }
        return Text("Fetch available models from the endpoint.")
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
                    app.ai.addModel(model, to: modelProviderID)
                }
                app.ai.markModelsFetched(for: modelProviderID)
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
                Text(provider?.models.isEmpty == true ? "No models yet" : "No match")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if provider?.models.isEmpty == true {
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
                            select: { state.selection = model.id },
                            check: { toggleCheck(model.id) }
                        )
                    }
                }
            }
        }
    }

    private var emptyHint: LocalizedStringKey {
        guard let provider else { return "" }
        if provider.usesVertex && provider.kind == .google {
            return "Add Vertex models manually"
        }
        return provider.hasCredential ? "Press Fetch" : "Add a key, then press Fetch"
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
                    // No delete here. Removing is a toolbar verb driven by the
                    // ticks, like Test — a second destructive button acting on a
                    // *different* selection than the one beside it is how the
                    // wrong model gets deleted.
                    Text(model.id)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let result = state.results[model.id] {
                        Label(result.message, systemImage: result.symbol)
                            .font(.caption)
                            .foregroundStyle(result.isSuccess ? Color.green : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    TextField("Name", text: field(model, \.displayName), prompt: Text(model.id))
                        .textFieldStyle(.roundedBorder)

                    Picker("Type", selection: field(model, \.kind)) {
                        ForEach(AIModel.Kind.allCases) { Text($0.displayName).tag($0) }
                    }

                    modalityToggles("Input", model: model, keyPath: \.input)
                    abilityToggles(model)

                    HStack(spacing: Metrics.Space.m) {
                        limitField("Context", model: model, keyPath: \.contextLength)
                        limitField("Max output", model: model, keyPath: \.maxOutputTokens)
                    }

                    if model.origin == .manual {
                        Text("Added manually")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(Metrics.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 268)
            .controlSize(.small)
        } else {
            Text("Select a model to edit it. Use the checkboxes to test or delete models.")
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
        _ label: LocalizedStringKey,
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
                        app.ai.updateModel(updated, in: modelProviderID)
                    }
                    .opacity(modality == .text ? 0.6 : 1)
                }
            }
        }
    }

    private func abilityToggles(_ model: AIModel) -> some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xs) {
            Text("Can")
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
                        app.ai.updateModel(updated, in: modelProviderID)
                    }
                }
            }
        }
    }

    private func limitField(
        _ label: LocalizedStringKey,
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
                        app.ai.updateModel(updated, in: modelProviderID)
                    }
                ),
                format: .number
            )
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
        }
    }

    private func field(
        _ model: AIModel, _ keyPath: WritableKeyPath<AIModel, String>
    ) -> Binding<String> {
        Binding(
            get: { app.ai.modelProvider(modelProviderID)?.model(model.id)?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard var updated = app.ai.modelProvider(modelProviderID)?.model(model.id) else { return }
                updated[keyPath: keyPath] = newValue
                app.ai.updateModel(updated, in: modelProviderID)
            }
        )
    }

    private func field<Value>(
        _ model: AIModel, _ keyPath: WritableKeyPath<AIModel, Value>
    ) -> Binding<Value> where Value: Hashable {
        Binding(
            get: {
                app.ai.modelProvider(modelProviderID)?.model(model.id)?[keyPath: keyPath] ?? model[keyPath: keyPath]
            },
            set: { newValue in
                guard var updated = app.ai.modelProvider(modelProviderID)?.model(model.id) else { return }
                updated[keyPath: keyPath] = newValue
                app.ai.updateModel(updated, in: modelProviderID)
            }
        )
    }

    // MARK: - Actions

    /// Fetches, then opens the picker. Nothing is written to the provider here.
    private func fetchModels() {
        guard let provider else { return }
        state.fetch = .running
        let secret = app.ai.secret(for: provider.credentialRef) ?? ""
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
        let secret = app.ai.secret(for: provider.credentialRef) ?? ""
        let vertexSecret = app.ai.secret(for: provider.vertex.credentialRef) ?? ""
        let credential = provider.usesVertex && provider.kind == .google ? vertexSecret : secret
        let targets = provider.models.filter { state.checked.contains($0.id) }

        state.isTesting = true
        Task {
            for model in targets {
                state.results[model.id] = .running
                do {
                    let result = try await ChatProbe().run(model: model, on: provider, secret: credential)
                    state.results[model.id] = .passed(result.summary)
                } catch {
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

    /// A hand-typed model gets the same inference a fetched one does, so the
    /// chips arrive already right for anything the table recognises and the
    /// user only has to correct what it does not.
    private func addModel() {
        let id = state.newModelID.trimmingCharacters(in: .whitespaces)
        state.newModelID = ""
        guard !id.isEmpty else { return }
        app.ai.addModel(ModelInference.fill(AIModel(id: id)), to: modelProviderID)
        state.selection = id
    }

    private func deleteChecked() {
        let doomed = state.checked
        app.ai.removeModels(doomed, from: modelProviderID)
        state.checked.removeAll()
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
    enum TestResult: Equatable {
        case running
        case passed(String)
        case failed(String)

        var isSuccess: Bool { if case .passed = self { true } else { false } }

        var message: String {
            switch self {
            case .running: String(localized: "Testing…")
            case .passed(let summary): summary
            case .failed(let reason): reason
            }
        }

        var symbol: String {
            switch self {
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
        Binding(get: { chooser.query }, set: { chooser.query = $0 })
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
        SheetScaffold { header } content: { list } footer: { footer }
        .frame(width: 420, height: 460)
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
            Text("\(candidates.count) models offered")
                .font(.headline)
            Text("Select the models you want to add. You can fetch the rest later.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TermindSearchField(text: queryBinding, prompt: "Filter", density: .compact)

            HStack(spacing: Metrics.Space.m) {
                Button("Select All") {
                    let ids = filtered.map(\.id)
                    chooser.toggleAll(visible: ids, enabled: Set(selectable.map(\.id)))
                }
                    .disabled(selectable.isEmpty)
                Button("Select None") { chooser.selected.subtract(filtered.map(\.id)) }
                    .disabled(chooser.selected.isEmpty)
                Spacer(minLength: 0)
            }
            .controlSize(.small)
        }
        .padding(Metrics.Space.l)
    }

    private var list: some View {
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
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Metrics.Space.m) {
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
            Spacer(minLength: 0)
            Button(
                chooser.selected.isEmpty ? "Add" : "Add \(chooser.selected.count)"
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
                CardChip(text: String(localized: "Added"))
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
    let select: () -> Void
    let check: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Metrics.Space.s) {
            Button(action: check) {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isChecked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Select \(model.label) for batch actions"))

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
            ForEach(model.input.sorted { $0.rawValue < $1.rawValue }) { modality in
                if modality != .text {
                    Image(systemName: modality.symbol)
                }
            }
            ForEach(model.abilities.sorted { $0.rawValue < $1.rawValue }) { ability in
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
