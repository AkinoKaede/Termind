import AgentKit
import SwiftUI
import TermindApplication

/// The "Model Roles" section: which model answers which job.
///
/// Chat always names the model that will actually answer, matching the concrete-only
/// model picker in the Assistant. Each auxiliary role supplies the label for its own
/// automatic resolution behavior.
public struct ModelRoleSettings: View {
    let ai: AIConfigurationModel

    public init(ai: AIConfigurationModel) { self.ai = ai }

    public var body: some View {
        Section {
            ForEach(AIRole.allCases) { role in
                RolePicker(role: role, ai: ai)
            }

            if ai.firstAvailableModel == nil {
                Text("No models yet. Add a provider above and fetch its models.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Model Roles")
        }
    }
}

private struct RolePicker: View {
    let role: AIRole

    let ai: AIConfigurationModel

    /// Chat models only. An embedding model cannot hold a conversation, and
    /// offering one is offering a request that will fail.
    private var modelProviders: [ModelProvider] {
        ai.enabledModelProviders.filter { !$0.chatModels.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(role.displayName, selection: selection) {
                if role != .chat {
                    Text(role.unsetLabel).tag(AIModelRef?.none)
                }

                // Grouped by provider, because the same model id can appear
                // under two of them and the provider is the only thing that
                // tells them apart.
                ForEach(modelProviders) { provider in
                    Section(provider.name) {
                        ForEach(provider.chatModels) { model in
                            Text(model.label)
                                .tag(AIModelRef?.some(AIModelRef(modelProviderID: provider.id, modelID: model.id)))
                        }
                    }
                }
            }
            .disabled(modelProviders.isEmpty)

            Text(role.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var selection: Binding<AIModelRef?> {
        Binding(
            get: {
                if let assignment = ai.assignment(for: role) { return assignment }
                guard role == .chat, let resolved = ai.resolve(.chat) else { return nil }
                return AIModelRef(modelProviderID: resolved.provider.id, modelID: resolved.model.id)
            },
            set: { ai.assign($0, to: role) }
        )
    }
}
