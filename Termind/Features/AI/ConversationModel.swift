import Foundation

/// A command the model proposed. It is *never* executed on the model's say-so —
/// `risk` is computed locally by `CommandRiskClassifier` and the user always
/// clicks.
nonisolated struct SuggestedCommand: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var command: String
    var explanation: String = ""

    var risk: RiskAssessment {
        CommandRiskClassifier.assess(command)
    }
}

/// One piece of context the user has agreed to send to the LLM endpoint.
///
/// BYOK means the user's own key pays for and is exposed to whatever we upload,
/// so the rule is: nothing leaves the machine unless it is visible as a chip.
/// Only host name and cwd are attached by default; output, selections, and file
/// contents must be added explicitly.
nonisolated struct ContextChip: Identifiable, Hashable, Sendable {
    nonisolated enum Kind: Hashable, Sendable {
        case host, directory, output, selection, file

        var symbol: String {
            switch self {
            case .host: "server.rack"
            case .directory: "folder"
            case .output: "text.alignleft"
            case .selection: "text.cursor"
            case .file: "doc"
            }
        }
    }

    var id: UUID = UUID()
    var kind: Kind
    var label: String
    /// Host and cwd are cheap and near-universally needed, so they are pinned;
    /// everything the user added by hand can be taken back off.
    var isRemovable: Bool = true
    var approximateTokens: Int = 0
}

nonisolated struct ChatMessage: Identifiable, Hashable, Sendable {
    nonisolated enum Role: Hashable, Sendable {
        case user, assistant
    }

    var id: UUID = UUID()
    var role: Role
    var text: String
    var commands: [SuggestedCommand] = []
    /// True while tokens are still arriving, so the view can show a caret.
    var isStreaming: Bool = false
}

/// The approval posture selected for one conversation.
///
/// This turn-level state does not yet alter command or MCP execution. Keeping
/// it separate from those existing approval gates prevents a UI choice from
/// silently weakening either one before the agent execution pipeline exists.
nonisolated enum ChatPermissionMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case askForApproval, approveForMe, fullAccess

    nonisolated var id: String { rawValue }

    var displayName: String {
        switch self {
        case .askForApproval: String(localized: "Ask for approval")
        case .approveForMe: String(localized: "Approve for me")
        case .fullAccess: String(localized: "Full access")
        }
    }

    var symbol: String {
        switch self {
        case .askForApproval: "hand.raised"
        case .approveForMe: "checkmark.shield"
        case .fullAccess: "lock.open"
        }
    }
}

/// One AI conversation. Session-scoped instances belong to a Workspace's
/// context panel; standalone instances belong to `AssistantLibraryModel` and
/// appear in the fixed Assistant tab.
@Observable
final class ConversationModel: Identifiable {
    let id = UUID()
    var messages: [ChatMessage] = []
    var contextChips: [ContextChip] = []
    var draft: String = ""
    var isStreaming: Bool = false

    /// Per-conversation reasoning state, normalized against the resolved model
    /// by the composer before a request is made.
    var reasoningEffort: ReasoningEffort = .medium

    /// An explicit choice for this conversation. `nil` follows the app-wide
    /// last selection through `AIStore.resolve(conversation:)`, the same shape
    /// used by `model` below.
    var permissionMode: ChatPermissionMode?

    /// The model this conversation was told to use, if it was told.
    ///
    /// `nil` is the normal state and is not a missing value — it means "whatever
    /// the Chat role resolves to", which `AIStore.resolve(_:)` answers. Keeping
    /// it unset rather than assigning a default on creation is what lets a
    /// change in Settings move every conversation that never chose, and lets one
    /// that did keep its choice.
    ///
    /// A ref rather than a name: two providers can both offer `gpt-5`, and which
    /// key pays for it is the question. The store is not held here — views
    /// resolve through `AppModel`, so a conversation stays a value that knows
    /// nothing about where models come from.
    var model: AIModelRef?

    var estimatedContextTokens: Int {
        contextChips.reduce(0) { $0 + $1.approximateTokens }
    }

    var derivedTitle: String {
        guard let first = messages.first(where: { $0.role == .user }) else {
            return String(localized: "New Chat")
        }
        let line = first.text.split(separator: "\n").first.map(String.init) ?? first.text
        return line.count > 40 ? String(line.prefix(40)) + "…" : line
    }

    var isEmpty: Bool { messages.isEmpty }

    func addChip(_ chip: ContextChip) {
        guard !contextChips.contains(where: { $0.kind == chip.kind && $0.label == chip.label }) else { return }
        contextChips.append(chip)
    }

    func removeChip(_ id: ContextChip.ID) {
        contextChips.removeAll { $0.id == id && $0.isRemovable }
    }

    /// P0 stub: records the user's turn so the composer and message list can be
    /// exercised. P3 replaces the body with a streaming `LLMClient` call.
    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messages.append(ChatMessage(role: .user, text: text))
        draft = ""
    }

    /// Adds a final speech-recognition result without disturbing text the user
    /// already wrote. The callback keeps the standalone composer and the
    /// sidebar's "promote draft to conversation" path on the same behavior.
    @discardableResult
    func applyTranscription(
        _ transcript: String,
        sendAfterTranscription: Bool,
        send: () -> Void
    ) -> Bool {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }

        if draft.isEmpty {
            draft = cleaned
        } else if draft.last?.isWhitespace == true {
            draft += cleaned
        } else {
            draft += " " + cleaned
        }

        if sendAfterTranscription { send() }
        return true
    }

    /// Seeds the two chips that are always attached, so the user can see the
    /// baseline rather than having to infer it.
    func syncDefaultChips(hostName: String?, workingDirectory: String?) {
        contextChips.removeAll { !$0.isRemovable }
        var defaults: [ContextChip] = []
        if let hostName {
            defaults.append(ContextChip(kind: .host, label: hostName, isRemovable: false, approximateTokens: 8))
        }
        if let workingDirectory {
            defaults.append(
                ContextChip(kind: .directory, label: workingDirectory, isRemovable: false, approximateTokens: 8))
        }
        contextChips.insert(contentsOf: defaults, at: 0)
    }

    /// Replaces only the pinned cwd while preserving the pinned host and every
    /// piece of context the user attached explicitly.
    func syncDirectoryChip(_ workingDirectory: String?) {
        contextChips.removeAll { !$0.isRemovable && $0.kind == .directory }
        guard let workingDirectory else { return }
        let directory = ContextChip(
            kind: .directory,
            label: workingDirectory,
            isRemovable: false,
            approximateTokens: 8
        )
        let insertionIndex =
            contextChips.lastIndex { !$0.isRemovable && $0.kind == .host }
            .map { contextChips.index(after: $0) }
            ?? 0
        contextChips.insert(directory, at: insertionIndex)
    }
}

// MARK: - Demo data

extension ConversationModel {
    static func demo() -> ConversationModel {
        let conversation = ConversationModel()
        conversation.syncDefaultChips(hostName: "web-01", workingDirectory: "/var/log")
        conversation.addChip(ContextChip(kind: .output, label: "Last 200 lines", approximateTokens: 1_450))
        conversation.messages = [
            ChatMessage(role: .user, text: "Root is at 99%. What is eating the space?"),
            ChatMessage(
                role: .assistant,
                text:
                    "`df` shows `/` at 99% while `/data` has room, so the growth is on the root volume. Start by finding the biggest directory under `/var`, which is where logs and package caches accumulate.",
                commands: [
                    SuggestedCommand(
                        command: "du -sh /var/* | sort -h",
                        explanation: "Read-only. Lists each directory under /var by size."
                    ),
                    SuggestedCommand(
                        command: "rm -rf /var/log/nginx/*.gz",
                        explanation: "Deletes rotated nginx logs. Roughly 2.1 GB, unrecoverable."
                    ),
                ]
            ),
        ]
        return conversation
    }
}
