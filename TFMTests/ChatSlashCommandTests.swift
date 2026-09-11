import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind

@Suite
struct ChatSlashCommandTests {
    private let commands = [
        ChatSlashCommand(
            id: "compact", displayName: "Compact",
            summary: "Summarize older turns", icon: .contextRing,
            argumentHint: "instructions"
        ),
        ChatSlashCommand(
            id: "plan", displayName: "Plan mode",
            summary: "Research first", icon: .symbol("sparkles")
        ),
        ChatSlashCommand(
            id: "reasoning", displayName: "Reasoning",
            summary: "Thinking effort", icon: .symbol("brain")
        ),
    ]

    private func options(_ command: ChatSlashCommand) -> [ChatSlashCommand.Option] {
        guard command.id == "reasoning" else { return [] }
        return [
            ChatSlashCommand.Option(id: "low", label: "Low"),
            ChatSlashCommand.Option(id: "medium", label: "Medium"),
            ChatSlashCommand.Option(id: "high", label: "High"),
        ]
    }

    // MARK: - Parsing

    @Test
    func aBareSlashIsACommandBeingNamed() {
        #expect(ChatSlashCommandInput.parse("/") == .naming(""))
        #expect(ChatSlashCommandInput.parse("/comp") == .naming("comp"))
    }

    @Test
    func aSpaceSeparatesTheNameFromItsArgument() {
        #expect(
            ChatSlashCommandInput.parse("/compact keep the nginx findings")
                == .argument(name: "compact", text: "keep the nginx findings")
        )
        // The trailing space is what advances the palette to the options, so an
        // empty argument has to be distinguishable from no argument at all.
        #expect(ChatSlashCommandInput.parse("/reasoning ") == .argument(name: "reasoning", text: ""))
    }

    @Test
    func proseIsNotACommand() {
        #expect(ChatSlashCommandInput.parse("check /etc/nginx for the include") == nil)
        #expect(ChatSlashCommandInput.parse("what does df say") == nil)
        #expect(ChatSlashCommandInput.parse("") == nil)
    }

    /// A path pasted as the whole draft still parses as a name — it is one
    /// token beginning with a slash — but it matches no command, so the palette
    /// stays shut and the draft sends as a message.
    @Test
    func aPastedPathMatchesNoCommandAndSendsAsAMessage() {
        let completion = ChatSlashCommandCompletion.rows(
            draft: "/etc/nginx/nginx.conf", commands: commands, options: options
        )

        #expect(completion.isEmpty)
    }

    /// Once a draft has a second line it is prose that happened to start with a
    /// slash, and losing it to a command would be the worst outcome available.
    @Test
    func aMultiLineDraftIsNeverACommand() {
        #expect(ChatSlashCommandInput.parse("/compact\nand also check disk") == nil)
    }

    // MARK: - Completion

    @Test
    func displayNamesDoNotChangeTheTypedCommands() {
        #expect(commands[1].name == "/plan")
        #expect(
            ChatSlashCommandCompletion.accepted(
                .command(commands[1]), takesArgument: false
            ) == "/plan"
        )
    }

    @Test
    func anEmptyNameOffersEveryCommand() {
        let completion = ChatSlashCommandCompletion.rows(
            draft: "/", commands: commands, options: options
        )

        #expect(completion.rows.count == 3)
    }

    @Test
    func typingNarrowsTheListAndThenClosesIt() {
        #expect(
            ChatSlashCommandCompletion.rows(
                draft: "/co", commands: commands, options: options
            ).rows.count == 1
        )
        #expect(
            ChatSlashCommandCompletion.rows(
                draft: "/zzz", commands: commands, options: options
            ).isEmpty
        )
    }

    @Test
    func aCompletedNameOffersItsOptions() {
        let completion = ChatSlashCommandCompletion.rows(
            draft: "/reasoning ", commands: commands, options: options
        )

        #expect(completion.rows.count == 3)
        #expect(completion.rows.first?.id == "reasoning/low")
        guard let first = completion.rows.first,
            case .option(let command, _) = first
        else {
            Issue.record("Expected an option row")
            return
        }
        #expect(command.icon == .symbol("brain"))
    }

    @Test
    func anArgumentFiltersTheOptions() {
        let completion = ChatSlashCommandCompletion.rows(
            draft: "/reasoning hi", commands: commands, options: options
        )

        #expect(completion.rows.count == 1)
        #expect(completion.rows.first?.id == "reasoning/high")
    }

    @Test
    func anOptionPageCanSelectItsCurrentValue() {
        let completion = ChatSlashCommandCompletion.rows(
            draft: "/reasoning ", commands: commands, options: options
        )

        #expect(completion.selectionIndex(commandID: "reasoning", optionID: "medium") == 1)
    }

    @Test
    func preferredOptionMatchingUsesTheStableIDNotTheVisibleLabel() {
        let model = ChatSlashCommand(
            id: "model", displayName: "Model", summary: "Switch models",
            icon: .symbol("sparkles")
        )
        let providerA = "11111111-1111-1111-1111-111111111111:same-model"
        let providerB = "22222222-2222-2222-2222-222222222222:same-model"
        let completion = ChatSlashCommandCompletion.rows(
            draft: "/model ", commands: [model]
        ) { _ in
            [
                ChatSlashCommand.Option(id: providerA, label: "Same model"),
                ChatSlashCommand.Option(id: providerB, label: "Same model"),
            ]
        }

        #expect(completion.selectionIndex(commandID: "model", optionID: providerB) == 1)
    }

    @Test
    func anUnavailableOrFilteredPreferredOptionFallsBackToTheFirstRow() {
        let completion = ChatSlashCommandCompletion.rows(
            draft: "/reasoning hi", commands: commands, options: options
        )

        #expect(completion.selectionIndex(commandID: "reasoning", optionID: "medium") == 0)
        #expect(completion.selectionIndex(commandID: "model", optionID: "high") == 0)
    }

    /// `/compact` takes free text, not a menu. Once the name is complete the
    /// palette gets out of the way so the instructions can be typed.
    @Test
    func aFreeTextCommandClosesThePaletteAfterItsName() {
        let completion = ChatSlashCommandCompletion.rows(
            draft: "/compact drop the log dumps", commands: commands, options: options
        )

        #expect(completion.isEmpty)
    }

    // MARK: - Acceptance

    @Test
    func acceptingANameThatTakesAnArgumentLeavesATrailingSpace() {
        let row = ChatSlashCommandCompletion.Row.command(commands[2])

        #expect(ChatSlashCommandCompletion.accepted(row, takesArgument: true) == "/reasoning ")
        #expect(ChatSlashCommandCompletion.accepted(row, takesArgument: false) == "/reasoning")
    }

    @Test
    func acceptingAnOptionWritesTheWholeCommand() {
        let row = ChatSlashCommandCompletion.Row.option(
            commands[2], ChatSlashCommand.Option(id: "high", label: "High")
        )

        #expect(
            ChatSlashCommandCompletion.accepted(row, takesArgument: false) == "/reasoning high"
        )
    }

    // MARK: - Named arguments

    /// `/skill <name>` arms it, `/skill <name> <text>` arms it and asks in the
    /// same keystroke, and the two have to be told apart from one draft.
    @Test
    func aNamedArgumentSplitsTheNameFromWhatFollowsIt() {
        let armed = ChatSlashCommandInput.parse("/skill disk-triage")
        #expect(armed?.selection?.name == "disk-triage")
        #expect(armed?.selection?.remainder == "")

        let asked = ChatSlashCommandInput.parse("/skill disk-triage why is root full?")
        #expect(asked?.selection?.name == "disk-triage")
        #expect(asked?.selection?.remainder == "why is root full?")

        let padded = ChatSlashCommandInput.parse("/skill   disk-triage    check staging  ")
        #expect(padded?.selection?.name == "disk-triage")
        #expect(padded?.selection?.remainder == "check staging")
    }

    @Test
    func aCommandWithNothingAfterItNamesNothing() {
        #expect(ChatSlashCommandInput.parse("/skill")?.selection == nil)
        #expect(ChatSlashCommandInput.parse("/skill   ")?.selection == nil)
    }
}
