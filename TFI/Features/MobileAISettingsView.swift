import AgentKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

struct MobileAISettingsView: View {
    let ai: AIConfigurationModel
    @State private var editing: ModelProvider?
    @State private var deleting: ModelProvider?

    var body: some View {
        List {
            Section("Model Providers") {
                ForEach(ai.modelProviders) { provider in
                    VStack(alignment: .leading, spacing: 8) {
                        Button(provider.name) { editing = provider }
                        NavigationLink("Manage Models") { MobileModelSettingsView(ai: ai, providerID: provider.id) }
                        Toggle(
                            "Enabled",
                            isOn: Binding(
                                get: { ai.modelProvider(provider.id)?.isEnabled ?? false },
                                set: { ai.setModelProviderEnabled($0, for: provider.id) }))
                    }
                    .swipeActions { Button("Delete", role: .destructive) { deleting = provider } }
                }
            }
            Section("Model Roles") {
                ForEach(AIRole.allCases) { role in
                    Picker(
                        role.displayName,
                        selection: Binding(get: { ai.assignment(for: role) }, set: { ai.assign($0, to: role) })
                    ) {
                        Text("Automatic").tag(nil as AIModelRef?)
                        ForEach(ai.enabledModelProviders) { provider in
                            ForEach(provider.chatModels) { model in
                                Text("\(provider.name) · \(model.id)")
                                    .tag(AIModelRef(modelProviderID: provider.id, modelID: model.id) as AIModelRef?)
                            }
                        }
                    }
                }
            }
            if let error = ai.storageError ?? ai.secretStorageError { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("AI")
        .toolbar { Button("Add", systemImage: "plus") { editing = ModelProvider(name: "") } }
        .sheet(item: $editing) { provider in MobileProviderEditor(ai: ai, provider: provider) }
        .confirmationDialog(
            "Delete Provider", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Provider", role: .destructive) {
                if let deleting { ai.delete(modelProviderID: deleting.id) }
                deleting = nil
            }
        } message: {
            Text("Permanently deletes this provider, its key, and its models.")
        }
    }
}

private struct MobileProviderEditor: View {
    @State private var model: MobileProviderEditorModel

    init(ai: AIConfigurationModel, provider: ModelProvider) {
        _model = State(initialValue: MobileProviderEditorModel(ai: ai, provider: provider))
    }

    var body: some View {
        MobileEditorSheet(
            title: String(localized: "Model Provider"), isDirty: model.isDirty, canSave: model.canSave,
            save: { try model.save() },
            content: {
                ModelProviderConnectionFields(name: $model.draft.name, endpoint: $model.endpoint)
                    .textInputAutocapitalization(.never)
                Section("API Key") {
                    Picker("API Key", selection: $model.keyAction) {
                        Text("Keep Existing Key").tag(MobileProviderEditorModel.KeyAction.preserve)
                        Text("Replace Key").tag(MobileProviderEditorModel.KeyAction.replace)
                        Text("Clear Key").tag(MobileProviderEditorModel.KeyAction.clear)
                    }
                    if model.keyAction == .replace {
                        LabeledContent("API Key") { SecureField("API Key", text: $model.secret) }
                    }
                }
            })
    }
}

struct MobileModelSettingsView: View {
    let ai: AIConfigurationModel
    let providerID: UUID
    @State private var discovery = MobileModelDiscovery()
    @State private var selected = Set<String>()
    @State private var adding = false
    @State private var modelID = ""
    private var provider: ModelProvider? { ai.modelProvider(providerID) }

    var body: some View {
        List {
            if let provider {
                Section("Models") {
                    ForEach(provider.models) { model in
                        VStack(alignment: .leading) {
                            Text(model.id).font(.body.monospaced())
                            if model.kind == .chat {
                                Toggle(
                                    "Show in Assistant",
                                    isOn: Binding(
                                        get: {
                                            ai.modelProvider(providerID)?.model(model.id)?.isShownInAssistant ?? false
                                        },
                                        set: { value in
                                            guard var current = ai.modelProvider(providerID)?.model(model.id) else {
                                                return
                                            }
                                            current.isShownInAssistant = value
                                            ai.updateModel(current, in: providerID)
                                        }))
                            }
                        }.swipeActions {
                            Button("Delete", role: .destructive) { ai.removeModels([model.id], from: providerID) }
                        }
                    }
                }
                Section {
                    Button("Fetch") {
                        selected = []
                        discovery.start(ai: ai, provider: provider)
                    }
                    .disabled(!provider.canFetchModels || discovery.running)
                    Button("Add Model") { adding = true }
                    if discovery.running { ProgressView() }
                }
                if !discovery.candidates.isEmpty {
                    Section("Available Models") {
                        ForEach(discovery.candidates, id: \.id) { candidate in
                            Toggle(
                                candidate.id,
                                isOn: Binding(
                                    get: { selected.contains(candidate.id) },
                                    set: { value in
                                        if value {
                                            selected.insert(candidate.id)
                                        } else {
                                            selected.remove(candidate.id)
                                        }
                                    })
                            ).disabled(provider.model(candidate.id) != nil)
                        }
                        Button("Add Selected") {
                            for model in discovery.candidates where selected.contains(model.id) {
                                ai.addModel(model, to: providerID)
                            }
                            if ai.storageError == nil {
                                ai.markModelsFetched(for: providerID)
                                discovery.cancel()
                                selected = []
                            }
                        }.disabled(selected.isEmpty)
                    }
                }
                if let error = discovery.error ?? ai.storageError { Text(error).foregroundStyle(.red) }
            } else {
                ContentUnavailableView("Provider Deleted", systemImage: "trash")
            }
        }
        .navigationTitle("Models")
        .onDisappear { discovery.cancel() }
        .onChange(of: provider) { old, new in
            if old?.inferenceURL != new?.inferenceURL || old?.credentialRef != new?.credentialRef || new == nil {
                discovery.cancel()
            }
        }
        .sheet(isPresented: $adding) {
            MobileEditorSheet(
                title: String(localized: "Add Model"), isDirty: !modelID.isEmpty,
                canSave: !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, compact: true,
                save: {
                    guard let provider else { throw MobileEditorError.message(String(localized: "Provider Deleted")) }
                    let model = ModelCapabilityResolver.resolve(
                        model: AIModel(id: modelID.trimmingCharacters(in: .whitespacesAndNewlines)), provider: provider
                    ).model
                    ai.addModel(model, to: providerID)
                    if let error = ai.storageError { throw MobileEditorError.message(error) }
                    modelID = ""
                },
                content: {
                    LabeledContent("Model ID") {
                        TextField("Model ID", text: $modelID).textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                })
        }
    }
}
