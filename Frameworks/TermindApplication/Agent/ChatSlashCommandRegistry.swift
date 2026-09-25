import AgentKit
import Foundation

/// Live state and host actions used by registered slash commands.
///
/// Conversation mutations are shared. Window navigation and run orchestration
/// remain injected because their owners differ between macOS and iOS.
@MainActor
public struct ChatSlashCommandContext {
    public let platform: ChatSlashCommand.Platform
    public let conversation: ConversationModel
    public let configuration: AIConfigurationModel
    public let skills: SkillLibraryModel
    public let archive: (() -> Void)?
    public let newConversation: (() -> Void)?
    public let compact: (String) -> Void
    public let send: () -> Void
    public let selectModel: ((AIModelRef) -> Bool)?
    public let authorizeRemoteMCP: () -> Bool
    public let localized: (String.LocalizationValue) -> String

    public init(
        platform: ChatSlashCommand.Platform,
        conversation: ConversationModel,
        configuration: AIConfigurationModel,
        skills: SkillLibraryModel,
        archive: (() -> Void)? = nil,
        newConversation: (() -> Void)? = nil,
        compact: @escaping (String) -> Void,
        send: @escaping () -> Void,
        selectModel: ((AIModelRef) -> Bool)? = nil,
        authorizeRemoteMCP: @escaping () -> Bool = { true },
        localized: @escaping (String.LocalizationValue) -> String = { String(localized: $0) }
    ) {
        self.platform = platform
        self.conversation = conversation
        self.configuration = configuration
        self.skills = skills
        self.archive = archive
        self.newConversation = newConversation
        self.compact = compact
        self.send = send
        self.selectModel = selectModel
        self.authorizeRemoteMCP = authorizeRemoteMCP
        self.localized = localized
    }
}

/// One independently registered slash command.
@MainActor
public struct ChatSlashCommandRegistration {
    public typealias CommandBuilder = (ChatSlashCommandContext) -> ChatSlashCommand?
    public typealias OptionsBuilder = (ChatSlashCommandContext) -> [ChatSlashCommand.Option]
    public typealias TrailingTextBuilder =
        (ChatSlashCommandCompletion.Row, ChatSlashCommandContext) -> String?
    public typealias CurrentValueMatcher =
        (ChatSlashCommandCompletion.Row, ChatSlashCommandContext) -> Bool
    public typealias PreferredOption = (ChatSlashCommandContext) -> String?
    public typealias Performer = (ChatSlashCommandInput, ChatSlashCommandContext) -> Bool

    public let id: String
    let command: CommandBuilder
    let options: OptionsBuilder
    let trailingText: TrailingTextBuilder
    let isCurrent: CurrentValueMatcher
    let preferredOption: PreferredOption
    let perform: Performer

    public init(
        id: String,
        command: @escaping CommandBuilder,
        options: @escaping OptionsBuilder = { _ in [] },
        trailingText: @escaping TrailingTextBuilder = { _, _ in nil },
        isCurrent: @escaping CurrentValueMatcher = { _, _ in false },
        preferredOption: @escaping PreferredOption = { _ in nil },
        perform: @escaping Performer
    ) {
        self.id = id
        self.command = command
        self.options = options
        self.trailingText = trailingText
        self.isCurrent = isCurrent
        self.preferredOption = preferredOption
        self.perform = perform
    }
}

/// The single catalog and executor used by the macOS and mobile composers.
///
/// Registration keeps command metadata beside its option and execution policy,
/// so adding a command cannot leave another string switch out of sync.
@MainActor
public struct ChatSlashCommandRegistry {
    private var registrations: [ChatSlashCommandRegistration] = []

    public init() {}

    public mutating func register(_ registration: ChatSlashCommandRegistration) {
        precondition(
            !registrations.contains { $0.id == registration.id },
            "Duplicate slash command registration: \(registration.id)"
        )
        registrations.append(registration)
    }

    public func commands(in context: ChatSlashCommandContext) -> [ChatSlashCommand] {
        registrations.compactMap { registration in
            guard let command = registration.command(context) else { return nil }
            guard command.platforms.contains(context.platform) else { return nil }
            return command
        }
        .sorted { lhs, rhs in
            let order = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    public func options(
        for command: ChatSlashCommand,
        in context: ChatSlashCommandContext
    ) -> [ChatSlashCommand.Option] {
        registration(for: command.id)?.options(context) ?? []
    }

    public func completion(
        for draft: String,
        in context: ChatSlashCommandContext
    ) -> ChatSlashCommandCompletion {
        ChatSlashCommandCompletion.rows(
            draft: draft,
            commands: commands(in: context),
            options: { options(for: $0, in: context) }
        )
    }

    public func trailingText(
        for row: ChatSlashCommandCompletion.Row,
        in context: ChatSlashCommandContext
    ) -> String? {
        registration(for: row.commandID)?.trailingText(row, context)
    }

    public func isCurrent(
        _ row: ChatSlashCommandCompletion.Row,
        in context: ChatSlashCommandContext
    ) -> Bool {
        registration(for: row.commandID)?.isCurrent(row, context) == true
    }

    public func preferredSelection(
        in completion: ChatSlashCommandCompletion,
        context: ChatSlashCommandContext
    ) -> Int {
        guard case .option(let command, _) = completion.rows.first,
            let option = registration(for: command.id)?.preferredOption(context)
        else { return 0 }
        return completion.selectionIndex(commandID: command.id, optionID: option)
    }

    @discardableResult
    public func perform(draft: String, in context: ChatSlashCommandContext) -> Bool {
        guard let input = ChatSlashCommandInput.parse(draft),
            commands(in: context).contains(where: { $0.id == input.name.lowercased() }),
            let registration = registration(for: input.name.lowercased())
        else { return false }
        return registration.perform(input, context)
    }

    public static func standard() -> Self {
        var registry = Self()
        registry.register(archiveRegistration)
        registry.register(newConversationRegistration)
        registry.register(planRegistration)
        registry.register(compactRegistration)
        registry.register(reasoningRegistration)
        registry.register(modelRegistration)
        registry.register(mcpRegistration)
        registry.register(skillRegistration)
        return registry
    }

    private func registration(for id: String) -> ChatSlashCommandRegistration? {
        registrations.first { $0.id == id }
    }
}

extension ChatSlashCommandCompletion.Row {
    fileprivate nonisolated var commandID: String {
        switch self {
        case .command(let command), .option(let command, _): command.id
        }
    }
}

// MARK: - Standard registrations

extension ChatSlashCommandRegistry {
    private static var archiveRegistration: ChatSlashCommandRegistration {
        ChatSlashCommandRegistration(
            id: "archive",
            command: { context in
                guard !context.conversation.isEmpty, context.archive != nil else { return nil }
                return ChatSlashCommand(
                    id: "archive", displayName: context.localized("Archive"),
                    summary: context.localized("Move this conversation to Archive"),
                    icon: .symbol("archivebox"), platforms: [.desktop]
                )
            },
            perform: { input, context in
                guard !context.conversation.isStreaming, !context.conversation.isCompacting,
                    let archive = context.archive
                else { return false }
                context.conversation.composer.draft = input.leadingText
                archive()
                return true
            }
        )
    }

    private static var newConversationRegistration: ChatSlashCommandRegistration {
        ChatSlashCommandRegistration(
            id: "new",
            command: { context in
                guard !context.conversation.isEmpty, context.newConversation != nil else { return nil }
                return ChatSlashCommand(
                    id: "new", displayName: context.localized("New chat"),
                    summary: context.localized("Start a new conversation"),
                    icon: .symbol("plus.bubble"), platforms: [.desktop]
                )
            },
            perform: { input, context in
                guard let newConversation = context.newConversation else { return false }
                context.conversation.composer.draft = input.leadingText
                newConversation()
                return true
            }
        )
    }

    private static var planRegistration: ChatSlashCommandRegistration {
        ChatSlashCommandRegistration(
            id: "plan",
            command: { context in
                ChatSlashCommand(
                    id: "plan", displayName: context.localized("Plan mode"),
                    summary: context.conversation.isPlanning
                        ? context.localized("Stop planning and act")
                        : context.localized("Research and propose before acting"),
                    icon: .symbol("lightbulb.max"), argumentHint: context.localized("what to plan")
                )
            },
            perform: { input, context in
                let question = input.argumentText(trimmed: context.platform == .desktop)
                if question.isEmpty {
                    context.conversation.isPlanning.toggle()
                    context.conversation.composer.draft = input.leadingText
                } else {
                    context.conversation.isPlanning = true
                    context.conversation.composer.draft = input.leadingText + question
                    if input.leadingText.isEmpty { context.send() }
                }
                return true
            }
        )
    }

    private static var compactRegistration: ChatSlashCommandRegistration {
        ChatSlashCommandRegistration(
            id: "compact",
            command: { context in
                guard !context.conversation.isEmpty else { return nil }
                return ChatSlashCommand(
                    id: "compact", displayName: context.localized("Compact"),
                    summary: context.localized("Summarize older turns to free context"),
                    icon: .contextRing, argumentHint: context.localized("what to emphasize")
                )
            },
            perform: { input, context in
                if context.platform == .mobile,
                    context.conversation.isStreaming || context.conversation.isCompacting
                {
                    return true
                }
                let instructions = input.argumentText(trimmed: context.platform == .desktop)
                context.conversation.composer.draft = input.leadingText
                context.compact(instructions)
                return true
            }
        )
    }

    private static var reasoningRegistration: ChatSlashCommandRegistration {
        ChatSlashCommandRegistration(
            id: "reasoning",
            command: { context in
                guard context.reasoning?.supported.contains(where: { $0 != .off }) == true else { return nil }
                return ChatSlashCommand(
                    id: "reasoning", displayName: context.localized("Reasoning"),
                    summary: context.localized("How hard the model thinks"), icon: .symbol("brain"),
                    argumentHint: context.localized("effort"), platforms: [.desktop]
                )
            },
            options: { context in
                context.reasoning?.supported.map {
                    ChatSlashCommand.Option(id: $0.rawValue, label: $0.displayName)
                } ?? []
            },
            trailingText: { row, context in
                switch row {
                case .command:
                    return context.effectiveReasoningEffort.displayName
                case .option(_, let option):
                    return context.platform == .desktop && option.id == context.effectiveReasoningEffort.rawValue
                        ? context.localized("Current") : nil
                }
            },
            isCurrent: { row, context in
                guard case .option(_, let option) = row else { return false }
                return option.id == context.effectiveReasoningEffort.rawValue
            },
            preferredOption: { $0.effectiveReasoningEffort.rawValue },
            perform: { input, context in
                guard case .argument(_, _, let argument) = input,
                    let effort = ReasoningEffort(rawValue: argument.lowercased()),
                    context.reasoning?.supported.contains(effort) == true
                else { return false }
                context.conversation.reasoningEffort = effort
                context.conversation.composer.draft = input.leadingText
                return true
            }
        )
    }

    private static var modelRegistration: ChatSlashCommandRegistration {
        ChatSlashCommandRegistration(
            id: "model",
            command: { context in
                guard !context.modelChoices.isEmpty else { return nil }
                return ChatSlashCommand(
                    id: "model", displayName: context.localized("Model"),
                    summary: context.localized("Switch the model for this conversation"), icon: .symbol("sparkles"),
                    argumentHint: context.localized("model"), platforms: [.desktop]
                )
            },
            options: { context in
                context.modelChoices.map {
                    ChatSlashCommand.Option(
                        id: $0.argument, label: $0.model.label,
                        detail: context.platform == .mobile ? $0.provider.name : ""
                    )
                }
            },
            trailingText: { row, context in
                switch row {
                case .command:
                    return context.resolved?.model.label ?? context.localized("No model")
                case .option(_, let option):
                    guard context.platform == .desktop else { return nil }
                    return context.modelChoices.first { $0.argument == option.id }?.provider.name
                }
            },
            isCurrent: { row, context in
                guard case .option(_, let option) = row else { return false }
                return option.id == context.resolvedModelArgument
            },
            preferredOption: { $0.resolvedModelArgument },
            perform: { input, context in
                guard case .argument(_, _, let argument) = input,
                    let choice = context.modelChoices.first(where: { $0.argument == argument })
                else { return false }
                let reference = AIModelRef(modelProviderID: choice.provider.id, modelID: choice.model.id)
                if let selectModel = context.selectModel {
                    guard selectModel(reference) else { return false }
                } else {
                    context.conversation.model = reference
                    context.configuration.select(reference)
                }
                context.conversation.reasoningEffort = ModelCapabilityResolver.reasoning(
                    model: choice.model, provider: choice.provider
                ).clamp(context.conversation.reasoningEffort)
                context.conversation.composer.draft = input.leadingText
                return true
            }
        )
    }

    private static var mcpRegistration: ChatSlashCommandRegistration {
        ChatSlashCommandRegistration(
            id: "mcp",
            command: { context in
                guard !context.configuration.mcpServers.isEmpty else { return nil }
                return ChatSlashCommand(
                    id: "mcp", displayName: context.localized("MCP"),
                    summary: context.localized("Enable or disable MCP servers"), icon: .symbol("server.rack"),
                    argumentHint: context.localized("server"), platforms: [.desktop]
                )
            },
            options: { context in
                context.configuration.mcpServers.map {
                    ChatSlashCommand.Option(id: $0.id.uuidString.lowercased(), label: $0.name)
                }
            },
            trailingText: { row, context in
                guard case .option(_, let option) = row,
                    let id = UUID(uuidString: option.id),
                    let server = context.configuration.mcpServer(id)
                else { return nil }
                return server.isEnabled ? context.localized("Enabled") : context.localized("Disabled")
            },
            perform: { input, context in
                guard case .argument(_, _, let argument) = input,
                    let id = UUID(uuidString: argument),
                    let server = context.configuration.mcpServer(id),
                    context.authorizeRemoteMCP()
                else { return false }
                context.configuration.setServerEnabled(!server.isEnabled, for: id)
                context.conversation.composer.draft = input.leadingText
                return true
            }
        )
    }

    private static var skillRegistration: ChatSlashCommandRegistration {
        ChatSlashCommandRegistration(
            id: "skill",
            command: { context in
                guard !context.skills.enabledSkills.isEmpty else { return nil }
                return ChatSlashCommand(
                    id: "skill", displayName: context.localized("Skill"),
                    summary: context.localized("Use an installed skill"), icon: .symbol("book.closed"),
                    argumentHint: context.localized("skill")
                )
            },
            options: { context in
                context.skills.enabledSkills.map {
                    ChatSlashCommand.Option(
                        id: $0.effectiveName, label: $0.displayTitle,
                        detail: context.platform == .mobile ? $0.summary : ""
                    )
                }
            },
            trailingText: { row, _ in
                guard case .option(_, let option) = row else { return nil }
                return option.id
            },
            isCurrent: { row, context in
                guard case .option(_, let option) = row else { return false }
                return option.id == context.conversation.composer.armedSkillName
            },
            perform: { input, context in
                guard let selection = input.selection,
                    context.skills.enabledSkills.contains(where: { $0.effectiveName == selection.name })
                else { return false }
                context.conversation.composer.armedSkillName = selection.name
                context.conversation.composer.draft = input.leadingText + selection.remainder
                if input.leadingText.isEmpty, !selection.remainder.isEmpty { context.send() }
                return true
            }
        )
    }
}

extension ChatSlashCommandContext {
    fileprivate typealias ModelChoice = (argument: String, provider: ModelProvider, model: AIModel)

    fileprivate var modelChoices: [ModelChoice] {
        configuration.enabledModelProviders.flatMap { provider in
            provider.assistantModels.map { model in
                (
                    ChatSlashCommand.argumentID(
                        scope: provider.id.uuidString.lowercased(), value: model.id
                    ),
                    provider,
                    model
                )
            }
        }
    }

    fileprivate var resolved: (provider: ModelProvider, model: AIModel)? {
        configuration.resolve(conversation: conversation.model)
    }

    fileprivate var reasoning: ModelCapabilityResolver.ReasoningResolution? {
        guard let resolved else { return nil }
        return ModelCapabilityResolver.reasoning(model: resolved.model, provider: resolved.provider)
    }

    fileprivate var effectiveReasoningEffort: ReasoningEffort {
        reasoning?.clamp(conversation.reasoningEffort) ?? .off
    }

    fileprivate var resolvedModelArgument: String? {
        guard let resolved else { return nil }
        return ChatSlashCommand.argumentID(
            scope: resolved.provider.id.uuidString.lowercased(), value: resolved.model.id
        )
    }
}

extension ChatSlashCommandInput {
    fileprivate nonisolated func argumentText(trimmed: Bool) -> String {
        guard case .argument(_, _, let text) = self else { return "" }
        return trimmed ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }
}
