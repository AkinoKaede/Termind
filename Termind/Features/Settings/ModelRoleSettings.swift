import SwiftUI

/// The "Model Roles" section: which model answers which job.
///
/// Four pickers, and none of them has to be touched. Naming a conversation is a
/// dozen tokens and wants the cheapest model available; the conversation itself
/// is what the expensive one is for. Under BYOK that difference is the user's
/// own money, which is what makes the distinction worth a control instead of a
/// hardcoded choice.
///
/// Chat reads **Automatic** when unset, and says underneath what that currently
/// resolves to — a default you cannot see is indistinguishable from a bug. The
/// other three read **Same as Chat**, which is what they actually do.
struct ModelRoleSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Section {
            ForEach(AIRole.allCases) { role in
                RolePicker(role: role)
            }

            if app.ai.firstAvailableModel == nil {
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

    @Environment(AppModel.self) private var app

    /// Chat models only. An embedding model cannot hold a conversation, and
    /// offering one is offering a request that will fail.
    private var modelProviders: [ModelProvider] {
        app.ai.enabledModelProviders.filter { !$0.chatModels.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
            Picker(role.displayName, selection: selection) {
                Text(role.unsetLabel).tag(AIModelRef?.none)

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

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var selection: Binding<AIModelRef?> {
        Binding(
            get: { app.ai.assignment(for: role) },
            set: { app.ai.assign($0, to: role) }
        )
    }

    /// What this role is for, plus — for Chat on Automatic — where that lands.
    ///
    /// Naming the resolved model is the whole reason "Automatic" is an
    /// acceptable default: without it, a user with three providers has no way to
    /// know which key the assistant is about to spend.
    ///
    /// Only Chat gets the suffix. The other three already say "Same as Chat" in
    /// the picker, and repeating the resolved model on each of them put the same
    /// sentence on screen four times — which reads as four separate facts rather
    /// than one, and buries the row that is actually deciding.
    private var caption: String {
        guard role == .chat, app.ai.assignment(for: .chat) == nil,
            let resolved = app.ai.resolve(.chat)
        else { return role.detail }
        return "\(role.detail) Currently \(resolved.model.label) on \(resolved.provider.name)."
    }
}
