import AgentKit
import SwiftUI
import TermindApplication

struct MobileAISettingsView: View {
    let ai: AIConfigurationModel
    @State private var editing: ModelProvider?

    var body: some View {
        List {
            ForEach(ai.modelProviders) { provider in
                Button(provider.name) { editing = provider }
            }
        }
        .navigationTitle("AI")
        .toolbar { Button("Add", systemImage: "plus") { editing = ModelProvider(name: "") } }
        .sheet(item: $editing) { MobileProviderEditor(ai: ai, provider: $0) }
    }
}

private struct MobileProviderEditor: View {
    let ai: AIConfigurationModel
    let original: ModelProvider
    @State private var draft: ModelProvider
    @State private var apiKey = ""
    @State private var modelID: String

    init(ai: AIConfigurationModel, provider: ModelProvider) {
        self.ai = ai
        original = provider
        _draft = State(initialValue: provider)
        _modelID = State(initialValue: provider.models.first?.id ?? "")
    }

    var body: some View {
        MobileEditorSheet(
            title: String(localized: "Model Provider"),
            isDirty: draft != original || !apiKey.isEmpty || modelID != (original.models.first?.id ?? ""),
            canSave: !draft.name.isEmpty && URL(string: draft.inferenceURL)?.scheme == "https" && !modelID.isEmpty,
            save: {
                if !draft.models.contains(where: { $0.id == modelID }) { draft.models.append(AIModel(id: modelID)) }
                ai.upsert(draft)
                if let error = ai.storageError { throw MobileEditorError.message(error) }
                if !apiKey.isEmpty { ai.setSecret(apiKey, for: draft.effectiveCredentialRef) }
                if let error = ai.storageError { throw MobileEditorError.message(error) }
                ai.select(AIModelRef(modelProviderID: draft.id, modelID: modelID))
            },
            content: {
                TextField("Name", text: $draft.name)
                TextField("Inference URL", text: $draft.inferenceURL).textInputAutocapitalization(.never)
                    .autocorrectionDisabled().keyboardType(.URL)
                Picker("API Format", selection: $draft.apiFormat) {
                    ForEach(ModelAPIFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                SecureField("API Key", text: $apiKey)
                TextField("Model ID", text: $modelID).textInputAutocapitalization(.never).autocorrectionDisabled()
            })
    }
}
