import AgentKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

struct MobileAISettingsView: View {
    let app: MobileAppModel

    var body: some View {
        List {
            ForEach(MobileAISettingsDestination.allCases) { destination in
                NavigationLink {
                    destinationView(destination)
                } label: {
                    Label(destination.title, systemImage: destination.symbol)
                }
            }
        }
        .navigationTitle("AI")
    }

    @ViewBuilder
    private func destinationView(_ destination: MobileAISettingsDestination) -> some View {
        switch destination {
        case .models:
            MobileModelsSettingsView(ai: app.ai)
        case .skills:
            MobileSkillSettings(skills: app.skills)
        case .mcp:
            MobileMCPSettings(ai: app.ai, pro: app.pro)
        }
    }
}

enum MobileAISettingsDestination: String, CaseIterable, Identifiable {
    case models
    case skills
    case mcp

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .models: "Models"
        case .skills: "Skills"
        case .mcp: "MCP"
        }
    }

    var symbol: String {
        switch self {
        case .models: "cube"
        case .skills: "doc.text"
        case .mcp: "network"
        }
    }
}

struct MobileModelsSettingsView: View {
    let ai: AIConfigurationModel
    @State private var editing: ModelProvider?
    @State private var deleting: ModelProvider?

    var body: some View {
        List {
            if ai.modelProviders.isEmpty {
                ContentUnavailableView(
                    "No Providers", systemImage: "brain",
                    description: Text("Add a provider to configure AI models.")
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                Section("Model Providers") {
                    ForEach(ai.modelProviders) { provider in
                        Button {
                            editing = provider
                        } label: {
                            HStack {
                                Image(systemName: "brain").foregroundStyle(.secondary).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(provider.name).foregroundStyle(.primary)
                                    Text(provider.inferenceURL).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                    Text("\(provider.models.count) Models").font(.caption).foregroundStyle(.secondary)
                                    if !provider.isEnabled {
                                        Text("Disabled").font(.caption).foregroundStyle(.secondary)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(
                                    .tertiary)
                            }.contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") { editing = provider }
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = provider }
                        }
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = provider }
                        }
                    }
                }
            }
            ModelRoleSettings(ai: ai)
            if let error = ai.storageError ?? ai.secretStorageError { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Models")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Provider", systemImage: "plus") { editing = ModelProvider(name: "") }
                    .labelStyle(.iconOnly)
            }
        }
        .sheet(item: $editing) { provider in MobileProviderEditor(ai: ai, provider: provider) }
        .confirmationDialog(
            "Delete Provider",
            isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible
        ) {
            Button("Delete Provider", role: .destructive) {
                if let deleting { ai.delete(modelProviderID: deleting.id) }
                deleting = nil
            }
        } message: {
            Text("Permanently deletes this provider, its key, and its models.")
            if let deleting, !ai.roles(using: deleting.id).isEmpty {
                Text("Assigned roles will return to their defaults.")
            }
        }
    }
}

struct MobileSecretFields: View {
    @Bindable var key: MobileSecretDraft
    var isToken = false
    var hasExistingCredential = true
    var requiresCredential = false

    var body: some View {
        Section(isToken ? "Bearer Token" : "API Key") {
            if hasExistingCredential {
                Picker("Credential", selection: $key.action) {
                    Text(isToken ? "Keep Existing Token" : "Keep Existing Key").tag(
                        MobileSecretDraft.Action.preserve)
                    Text(isToken ? "Replace Token" : "Replace Key").tag(MobileSecretDraft.Action.replace)
                    Text(isToken ? "Clear Token" : "Clear Key").tag(MobileSecretDraft.Action.clear)
                }
                if key.action == .replace {
                    SecureField(isToken ? "Bearer Token" : "API Key", text: $key.text)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .multilineTextAlignment(.leading)
                }
            } else {
                SecureField(
                    isToken ? "Bearer Token" : "API Key",
                    text: Binding(
                        get: { key.text },
                        set: { value in
                            key.text = value
                            key.action = value.isEmpty && !requiresCredential ? .preserve : .replace
                        }
                    ),
                    prompt: Text(requiresCredential ? "Required" : "Optional")
                )
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .multilineTextAlignment(.leading)
            }
        }
    }
}

struct MobileProviderEditor: View {
    let ai: AIConfigurationModel
    @State private var model: MobileProviderEditorModel
    @State private var discovery = MobileModelDiscovery()
    @State private var probes = MobileModelTests()
    private enum Sheet: Identifiable {
        case fetch
        case add
        case edit(AIModel)

        var id: String {
            switch self {
            case .fetch: "fetch"
            case .add: "add"
            case .edit(let model): "edit-\(model.id)"
            }
        }
    }
    @State private var presentedSheet: Sheet?
    @State private var query = ""
    @State private var error: String?

    init(ai: AIConfigurationModel, provider: ModelProvider) {
        self.ai = ai
        _model = State(initialValue: MobileProviderEditorModel(ai: ai, provider: provider))
    }

    var body: some View {
        MobileEditorSheet(
            title: String(localized: "Model Provider"), isDirty: model.isDirty, canSave: model.canSave,
            save: { try model.save() },
            content: {
                ModelProviderConnectionFields(
                    name: $model.draft.name, endpoint: $model.endpoint, isEnabled: $model.draft.isEnabled
                )
                .textInputAutocapitalization(.never)
                MobileSecretFields(
                    key: model.key,
                    hasExistingCredential: model.hasExistingKey,
                    requiresCredential: model.requiresKey
                )
                modelSection.buttonStyle(.borderless)
                if let error { Text(error).foregroundStyle(.red) }
            }
        )
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .fetch:
                MobileModelFetchSheet(discovery: discovery, existing: Set(model.draft.models.map(\.id)), fetch: fetch) {
                    values in
                    model.add(values)
                    model.draft.modelsFetchedAt = .now
                }
            case .add:
                MobileAddModelSheet(existing: Set(model.draft.models.map(\.id))) { model.add(id: $0) }
            case .edit(let value):
                MobileModelEditorSheet(model: value, provider: model.requestProvider) { model.update($0) }
            }
        }
        .onChange(of: model.requestProvider) { _, _ in cancelRequests() }
        .onChange(of: model.key.action) { _, _ in cancelRequests() }
        .onChange(of: model.key.text) { _, _ in cancelRequests() }
        .onChange(of: ai.modelProvider(model.original.id)) { _, _ in cancelRequests() }
        .onDisappear { cancelRequests() }
    }

    private var modelSection: some View {
        Section("Models") {
            TextField("Filter", text: $query)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.leading)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            ForEach(
                model.draft.models.filter {
                    query.isEmpty || $0.id.localizedCaseInsensitiveContains(query)
                        || $0.label.localizedCaseInsensitiveContains(query)
                }
            ) { value in
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        presentedSheet = .edit(value)
                    } label: {
                        HStack {
                            Image(systemName: "cube").foregroundStyle(.secondary).accessibilityHidden(true)
                            VStack(alignment: .leading) {
                                Text(value.label)
                                Text(value.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary).accessibilityHidden(true)
                        }.contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Test", systemImage: "play") { test([value]) }.disabled(probes.running)
                        Button("Delete", systemImage: "trash", role: .destructive) { remove([value.id]) }
                    }
                    if let result = probes.results[value.id] { Text(result).font(.caption).textSelection(.enabled) }
                }
            }
            if model.draft.models.isEmpty {
                Text("No Models Available").foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button {
                    presentedSheet = .fetch
                } label: {
                    Label("Fetch", systemImage: "arrow.down.circle").frame(maxWidth: .infinity, minHeight: 44)
                }.disabled(!model.canSave)
                Button {
                    presentedSheet = .add
                } label: {
                    Label("Add", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 44)
                }
            }.buttonStyle(.bordered)
        }
    }

    private func remove(_ ids: Set<String>) { model.remove(ids) }

    private func fetch() {
        do { discovery.start(provider: model.requestProvider, secret: try model.requestSecret()) } catch {
            discovery.error = error.localizedDescription
        }
    }

    private func test(_ values: [AIModel]) {
        do {
            error = nil
            probes.start(models: values, provider: model.requestProvider, secret: try model.requestSecret())
        } catch { self.error = error.localizedDescription }
    }

    private func cancelRequests() {
        discovery.cancel()
        probes.cancel()
    }
}

struct MobileModelEditorSheet: View {
    let original: AIModel
    let provider: ModelProvider
    let save: (AIModel) -> Void
    @State private var draft: AIModel

    init(model: AIModel, provider: ModelProvider, save: @escaping (AIModel) -> Void) {
        original = model
        self.provider = provider
        self.save = save
        _draft = State(initialValue: model)
    }

    var body: some View {
        MobileEditorSheet(
            title: String(localized: "Model"), isDirty: draft != original,
            save: { save(draft) },
            content: { MobileModelFields(model: $draft, provider: provider) }
        )
    }
}

struct MobileModelFetchSheet: View {
    let discovery: MobileModelDiscovery
    let existing: Set<String>
    let fetch: () -> Void
    let add: ([AIModel]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<String>()
    @State private var query = ""
    private var filtered: [AIModel] {
        discovery.candidates.filter {
            query.isEmpty || $0.id.localizedCaseInsensitiveContains(query)
                || $0.label.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if discovery.running {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else if let error = discovery.error {
                    Spacer()
                    Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    Button("Retry", systemImage: "arrow.clockwise") {
                        selected = []
                        fetch()
                    }.buttonStyle(.bordered)
                    Spacer()
                } else {
                    HStack {
                        Text("\(discovery.candidates.count) Models Offered").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            Button("Select All", systemImage: "checkmark.circle") {
                                selected.formUnion(filtered.map(\.id).filter { !existing.contains($0) })
                            }
                            Button("Select None", systemImage: "circle") { selected.subtract(filtered.map(\.id)) }
                            Button("Fetch", systemImage: "arrow.down.circle") {
                                selected = []
                                fetch()
                            }
                        } label: {
                            MobileOverflowMenuLabel("Available Models").frame(minWidth: 44, minHeight: 44)
                                .contentShape(.rect)
                        }
                    }.padding(.horizontal)
                    if filtered.isEmpty {
                        ContentUnavailableView("No Models Available", systemImage: "cube")
                    } else {
                        List(filtered) { candidate in
                            Button {
                                if !selected.insert(candidate.id).inserted { selected.remove(candidate.id) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "cube").foregroundStyle(.secondary).accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(candidate.label).foregroundStyle(.primary)
                                        if candidate.label != candidate.id {
                                            Text(candidate.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    if existing.contains(candidate.id) {
                                        Text("Added").font(.caption).foregroundStyle(.secondary)
                                    } else if selected.contains(candidate.id) {
                                        Image(systemName: "checkmark").font(.body.weight(.semibold))
                                            .accessibilityHidden(true)
                                    }
                                }.frame(minHeight: 36).contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .disabled(existing.contains(candidate.id))
                            .accessibilityAddTraits(selected.contains(candidate.id) ? [.isSelected] : [])
                        }.listStyle(.plain)
                    }
                }
            }
            .searchable(text: $query, prompt: "Filter")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .background(Color(uiColor: .systemBackground))
            .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationTitle("Available Models").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", systemImage: "plus") {
                        add(discovery.candidates.filter { selected.contains($0.id) })
                        dismiss()
                    }
                    .labelStyle(.iconOnly).disabled(selected.isEmpty || discovery.running)
                    .accessibilityLabel(Text("Add Selected"))
                }
            }
        }
        .mobileSheetPresentation(compact: true)
        .presentationBackground(Color(uiColor: .systemBackground))
        .task { fetch() }
        .onDisappear { discovery.cancel() }
    }
}

struct MobileAddModelSheet: View {
    let existing: Set<String>
    let add: (String) -> Void
    @State private var modelID = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    private var trimmedID: String { modelID.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Model ID") {
                    TextField("Model ID", text: $modelID)
                        .textFieldStyle(.plain).multilineTextAlignment(.leading)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focused).onSubmit(submit)
                    if existing.contains(trimmedID) { Text("Added").foregroundStyle(.secondary) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationTitle("Add Model").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", systemImage: "plus", action: submit).labelStyle(.iconOnly).disabled(
                        trimmedID.isEmpty || existing.contains(trimmedID))
                }
            }
        }
        .mobileSheetPresentation(compact: true)
        .presentationBackground(Color(uiColor: .systemBackground))
        .task { focused = true }
    }

    private func submit() {
        guard !trimmedID.isEmpty, !existing.contains(trimmedID) else { return }
        add(trimmedID)
        dismiss()
    }
}
