import SwiftUI

/// What happens when a conversation runs out of room.
///
/// There is no `/autocompact` command to match `/compact`, and that is
/// deliberate: it is on by default and changing it is a preference rather than
/// an action, so it belongs here rather than in a palette someone opens mid-task.
struct AssistantSettings: View {
    @AppStorage(SettingsKey.autoCompactEnabled) private var isEnabled =
        SettingsKey.defaultAutoCompactEnabled
    @AppStorage(SettingsKey.compactionReserveTokens) private var reserveTokens =
        AgentCompaction.defaultReserveTokens
    @AppStorage(SettingsKey.compactionKeepRecentTokens) private var keepRecentTokens =
        AgentCompaction.defaultKeepRecentTokens

    var body: some View {
        Group {
            Section {
                Toggle("Compact Automatically", isOn: $isEnabled)

                Text(
                    isEnabled
                        ? "As a conversation nears the model's context window, its older turns "
                            + "are replaced by a summary so it can keep going. Nothing is "
                            + "deleted — the transcript stays complete on screen, and only what "
                            + "is sent to the model changes."
                        : "Long conversations will eventually be refused by the model. Use "
                            + "/compact to summarize the older turns yourself."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Context")
            }

            Section {
                Stepper(value: $keepRecentTokens, in: 4_000...80_000, step: 4_000) {
                    LabeledContent("Keep Recent") {
                        Text("\(keepRecentTokens.formatted()) tokens")
                            .monospacedDigit()
                    }
                }

                Stepper(value: $reserveTokens, in: 4_000...64_000, step: 4_000) {
                    LabeledContent("Reserve for Reply") {
                        Text("\(reserveTokens.formatted()) tokens")
                            .monospacedDigit()
                    }
                }

                Text(
                    "Recent turns are never summarized, so the model keeps the detail of what "
                        + "it is working on now. The reserve is the headroom compaction leaves "
                        + "for the reply, which is what decides how early it happens."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Budgets")
            }
            .disabled(!isEnabled)
        }
    }
}
