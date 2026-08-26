import Foundation
import Testing

@testable import Termind

@MainActor
@Suite
struct AgentUserInputTests {

    // MARK: - Parsing the tool's options

    @Test
    func optionsCarryTheirDescriptionAndRecommendation() throws {
        let options = try arguments([
            "prompt": .string("Which database?"),
            "options": .array([
                .object([
                    "id": .string("postgres"), "label": .string("Postgres"),
                    "description": .string("JSONB, and it matches the existing schema."),
                    "recommended": .bool(true),
                ]),
                .object(["id": .string("sqlite"), "label": .string("SQLite")]),
            ]),
        ]).userInputOptions()

        #expect(options.count == 2)
        #expect(options[0].id == "postgres")
        #expect(options[0].detail == "JSONB, and it matches the existing schema.")
        #expect(options[0].isRecommended)
        // Absent is absent, not false-y noise.
        #expect(options[1].detail.isEmpty)
        #expect(!options[1].isRecommended)
    }

    @Test
    func noOptionsMeansAFreeFormQuestion() throws {
        #expect(try arguments(["prompt": .string("Which URL?")]).userInputOptions().isEmpty)
        #expect(
            try arguments(["prompt": .string("Which URL?"), "options": .null])
                .userInputOptions().isEmpty
        )
    }

    /// A malformed row is rejected rather than dropped: a menu quietly missing
    /// the option the user wanted is worse than an error the model can retry.
    @Test
    func malformedOptionsAreRejectedRatherThanDropped() {
        #expect(throws: AgentToolError.self) {
            try arguments([
                "prompt": .string("?"),
                "options": .array([.object(["label": .string("No id here")])]),
            ]).userInputOptions()
        }
        #expect(throws: AgentToolError.self) {
            try arguments([
                "prompt": .string("?"),
                "options": .array([.string("a bare string")]),
            ]).userInputOptions()
        }
    }

    @Test
    func duplicateOptionIdsAreRejected() {
        #expect(throws: AgentToolError.self) {
            try arguments([
                "prompt": .string("?"),
                "options": .array([
                    .object(["id": .string("a"), "label": .string("First")]),
                    .object(["id": .string("a"), "label": .string("Second")]),
                ]),
            ]).userInputOptions()
        }
    }

    // MARK: - One answer, or several

    @Test
    func nothingIsPreselectedEvenWhenAnOptionIsRecommended() {
        let conversation = ConversationModel()
        conversation.present(request(multiple: false))

        #expect(conversation.userInputSelection.isEmpty)
        // A recommendation is a label, not a default — Continue stays off until
        // the user actually answers.
        #expect(!conversation.canSubmitUserInput)
    }

    @Test
    func choosingAnOptionInASingleAnswerQuestionClearsATypedOne() {
        let conversation = ConversationModel()
        conversation.present(request(multiple: false))

        conversation.setUserInputCustomAnswer("MySQL")
        #expect(conversation.canSubmitUserInput)

        conversation.toggleUserInputOption("postgres")
        #expect(conversation.userInputSelection == ["postgres"])
        #expect(conversation.userInputDraft.isEmpty)
    }

    @Test
    func typingInASingleAnswerQuestionClearsTheChosenOption() {
        let conversation = ConversationModel()
        conversation.present(request(multiple: false))

        conversation.toggleUserInputOption("postgres")
        conversation.setUserInputCustomAnswer("MySQL")

        #expect(conversation.userInputSelection.isEmpty)
        #expect(conversation.userInputDraft == "MySQL")
    }

    @Test
    func singleAnswerSelectionReplacesRatherThanAccumulates() {
        let conversation = ConversationModel()
        conversation.present(request(multiple: false))

        conversation.toggleUserInputOption("postgres")
        conversation.toggleUserInputOption("sqlite")
        #expect(conversation.userInputSelection == ["sqlite"])

        // Clicking the chosen one again takes the answer back.
        conversation.toggleUserInputOption("sqlite")
        #expect(conversation.userInputSelection.isEmpty)
    }

    /// When several answers are allowed the two routes are additive, not
    /// exclusive — "these two, plus this other thing" is a real answer.
    @Test
    func severalAnswersMayIncludeATypedOne() {
        let conversation = ConversationModel()
        conversation.present(request(multiple: true))

        conversation.toggleUserInputOption("postgres")
        conversation.toggleUserInputOption("sqlite")
        conversation.setUserInputCustomAnswer("and DuckDB")

        #expect(conversation.userInputSelection == ["postgres", "sqlite"])
        #expect(conversation.userInputDraft == "and DuckDB")
    }

    // MARK: - What the tool gets back

    @Test
    func answerReportsIdsInTheOrderTheRequestListedThem() async {
        let conversation = ConversationModel()
        let pending = request(multiple: true)
        let answering = Task { await conversation.request(pending) }
        await settle(conversation)

        // Clicked back to front; the answer still reads front to back, because
        // the model wrote the list and reads the reply against it.
        conversation.toggleUserInputOption("duckdb")
        conversation.toggleUserInputOption("postgres")
        conversation.submitUserInput()

        #expect(await answering.value == .choice(selectedIDs: ["postgres", "duckdb"], custom: nil))
    }

    @Test
    func aTypedAnswerComesBackAsCustomTextWithNoSelection() async {
        let conversation = ConversationModel()
        let answering = Task { await conversation.request(request(multiple: false)) }
        await settle(conversation)

        conversation.setUserInputCustomAnswer("  MySQL  ")
        conversation.submitUserInput()

        // Trimmed, because trailing whitespace is not part of anyone's answer.
        #expect(await answering.value == .choice(selectedIDs: [], custom: "MySQL"))
    }

    @Test
    func cancellingReportsCancelledRatherThanAnEmptyAnswer() async {
        let conversation = ConversationModel()
        let answering = Task { await conversation.request(request(multiple: false)) }
        await settle(conversation)

        conversation.cancelUserInput()

        #expect(await answering.value == .cancelled)
        #expect(conversation.pendingUserInput == nil)
        #expect(conversation.userInputSelection.isEmpty)
    }

    @Test
    func submittingNothingIsRefusedRatherThanSentAsAnEmptyChoice() async {
        let conversation = ConversationModel()
        let answering = Task { await conversation.request(request(multiple: false)) }
        await settle(conversation)

        conversation.submitUserInput()
        #expect(conversation.pendingUserInput != nil, "the request must still be waiting")

        conversation.toggleUserInputOption("sqlite")
        conversation.submitUserInput()
        #expect(await answering.value == .choice(selectedIDs: ["sqlite"], custom: nil))
    }

    @Test
    func aFreeFormQuestionStillAnswersAsPlainText() async {
        let conversation = ConversationModel()
        let answering = Task {
            await conversation.request(AgentUserInputRequest(prompt: "Base URL?", kind: .text))
        }
        await settle(conversation)

        conversation.userInputDraft = "https://api.example.com"
        conversation.submitUserInput()

        #expect(await answering.value == .text("https://api.example.com"))
    }

    // MARK: - Helpers

    private func arguments(_ object: [String: AgentJSONValue]) throws -> Arguments {
        try Arguments(
            AgentToolInvocation(
                runID: UUID(),
                call: AgentToolCall(
                    id: "call-1", name: "request_user_input", arguments: .object(object)
                )
            )
        )
    }

    private func request(multiple: Bool) -> AgentUserInputRequest {
        AgentUserInputRequest(
            prompt: "Which database?",
            kind: .choice(
                AgentUserInputChoice(
                    options: [
                        AgentUserInputOption(
                            id: "postgres", label: "Postgres",
                            detail: "Matches the existing schema.", isRecommended: true
                        ),
                        AgentUserInputOption(id: "sqlite", label: "SQLite"),
                        AgentUserInputOption(id: "duckdb", label: "DuckDB"),
                    ],
                    allowsMultipleAnswers: multiple
                )
            ),
            header: "Storage"
        )
    }

    /// `request(_:)` publishes the pending question and then suspends on its
    /// continuation. Waiting for that to be installed is what keeps these tests
    /// from racing the answer in ahead of the question.
    private func settle(_ conversation: ConversationModel) async {
        for _ in 0..<100 where conversation.pendingUserInput == nil {
            await Task.yield()
        }
        #expect(conversation.pendingUserInput != nil, "the request never became pending")
    }
}
