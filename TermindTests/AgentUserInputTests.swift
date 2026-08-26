import Foundation
import Testing

@testable import Termind

@MainActor
@Suite
struct AgentUserInputTests {

    // MARK: - Parsing the tool's questions

    @Test
    func questionsCarryTheirOptionsDescriptionsAndRecommendations() throws {
        let questions = try arguments([
            "questions": .array([
                .object([
                    "id": .string("storage"),
                    "header": .string("Storage"),
                    "prompt": .string("Which database?"),
                    "options": .array([
                        .object([
                            "id": .string("postgres"), "label": .string("Postgres"),
                            "description": .string("JSONB, and it matches the existing schema."),
                            "recommended": .bool(true),
                        ]),
                        .object(["id": .string("sqlite"), "label": .string("SQLite")]),
                    ]),
                ]),
                .object(["id": .string("base_url"), "prompt": .string("Which URL?")]),
            ])
        ]).userQuestions()

        #expect(questions.count == 2)
        #expect(questions[0].header == "Storage")
        #expect(questions[0].options.count == 2)
        #expect(questions[0].options[0].detail == "JSONB, and it matches the existing schema.")
        #expect(questions[0].options[0].isRecommended)
        // Absent is absent, not false-y noise.
        #expect(questions[0].options[1].detail.isEmpty)
        #expect(!questions[0].options[1].isRecommended)

        // No options is a free-form question, not an empty menu.
        guard case .text = questions[1].kind else {
            Issue.record("expected a free-form question, got \(questions[1].kind)")
            return
        }
    }

    @Test
    func choiceFlagsDefaultToOfferingAWayOut() throws {
        let questions = try arguments([
            "questions": .array([
                .object([
                    "id": .string("q"), "prompt": .string("?"),
                    "options": .array([.object(["id": .string("a"), "label": .string("A")])]),
                ])
            ])
        ]).userQuestions()

        guard case .choice(let choice) = questions[0].kind else {
            Issue.record("expected a choice question")
            return
        }
        #expect(choice.allowsCustomAnswer, "a way out has to be the default")
        #expect(!choice.allowsMultipleAnswers)
    }

    /// Everything malformed is rejected rather than dropped: a form silently
    /// missing the question the user needed is worse than an error the model
    /// can retry.
    @Test
    func malformedQuestionsAreRejectedRatherThanDropped() {
        let bad: [[String: AgentJSONValue]] = [
            [:],
            ["questions": .array([])],
            ["questions": .object([:])],
            ["questions": .array([.object(["prompt": .string("no id")])])],
            ["questions": .array([.object(["id": .string("q")])])],
            ["questions": .array([
                .object(["id": .string("q"), "prompt": .string("first")]),
                .object(["id": .string("q"), "prompt": .string("duplicate id")]),
            ])],
            ["questions": .array([
                .object([
                    "id": .string("q"), "prompt": .string("?"),
                    "options": .array([
                        .object(["id": .string("a"), "label": .string("A")]),
                        .object(["id": .string("a"), "label": .string("Also A")]),
                    ]),
                ])
            ])],
            ["questions": .array([.object([
                "id": .string("q"), "prompt": .string("?"),
                "options": .array([.string("a bare string")]),
            ])])],
        ]
        for object in bad {
            #expect(throws: AgentToolError.self) { try arguments(object).userQuestions() }
        }
    }

    @Test
    func askingMoreThanThreeQuestionsAtOnceIsRefused() {
        let four = (1...4).map { index in
            AgentJSONValue.object([
                "id": .string("q\(index)"), "prompt": .string("Question \(index)?"),
            ])
        }
        #expect(throws: AgentToolError.self) {
            try arguments(["questions": .array(four)]).userQuestions()
        }
        #expect(throws: Never.self) {
            try arguments(["questions": .array(Array(four.prefix(3)))]).userQuestions()
        }
    }

    // MARK: - One question

    @Test
    func nothingIsPreselectedEvenWhenAnOptionIsRecommended() {
        let conversation = ConversationModel()
        conversation.present(request(multiple: false))

        #expect(conversation.userInputDraft(for: "storage").selection.isEmpty)
        // A recommendation is a label, not a default — Continue stays off until
        // the user actually answers.
        #expect(!conversation.canSubmitUserInput)
    }

    @Test
    func choosingAnOptionInASingleAnswerQuestionClearsATypedOne() {
        let conversation = ConversationModel()
        conversation.present(request(multiple: false))

        conversation.setUserInputCustomAnswer("MySQL", for: "storage")
        #expect(conversation.canSubmitUserInput)

        conversation.toggleUserInputOption("postgres", in: "storage")
        #expect(conversation.userInputDraft(for: "storage").selection == ["postgres"])
        #expect(conversation.userInputDraft(for: "storage").text.isEmpty)
    }

    @Test
    func typingInASingleAnswerQuestionClearsTheChosenOption() {
        let conversation = ConversationModel()
        conversation.present(request(multiple: false))

        conversation.toggleUserInputOption("postgres", in: "storage")
        conversation.setUserInputCustomAnswer("MySQL", for: "storage")

        #expect(conversation.userInputDraft(for: "storage").selection.isEmpty)
        #expect(conversation.userInputDraft(for: "storage").text == "MySQL")
    }

    @Test
    func singleAnswerSelectionReplacesRatherThanAccumulates() {
        let conversation = ConversationModel()
        conversation.present(request(multiple: false))

        conversation.toggleUserInputOption("postgres", in: "storage")
        conversation.toggleUserInputOption("sqlite", in: "storage")
        #expect(conversation.userInputDraft(for: "storage").selection == ["sqlite"])

        // Clicking the chosen one again takes the answer back.
        conversation.toggleUserInputOption("sqlite", in: "storage")
        #expect(conversation.userInputDraft(for: "storage").selection.isEmpty)
    }

    /// When several answers are allowed the two routes are additive, not
    /// exclusive — "these two, plus this other thing" is a real answer.
    @Test
    func severalAnswersMayIncludeATypedOne() {
        let conversation = ConversationModel()
        conversation.present(request(multiple: true))

        conversation.toggleUserInputOption("postgres", in: "storage")
        conversation.toggleUserInputOption("sqlite", in: "storage")
        conversation.setUserInputCustomAnswer("and DuckDB", for: "storage")

        #expect(conversation.userInputDraft(for: "storage").selection == ["postgres", "sqlite"])
        #expect(conversation.userInputDraft(for: "storage").text == "and DuckDB")
    }

    // MARK: - Several questions at once

    @Test
    func eachQuestionKeepsItsOwnAnswer() {
        let conversation = ConversationModel()
        conversation.present(threeQuestions())

        conversation.toggleUserInputOption("postgres", in: "storage")
        conversation.toggleUserInputOption("flyway", in: "migrations")
        conversation.setUserInputCustomAnswer("staging-2", for: "host")

        #expect(conversation.userInputDraft(for: "storage").selection == ["postgres"])
        #expect(conversation.userInputDraft(for: "migrations").selection == ["flyway"])
        #expect(conversation.userInputDraft(for: "storage").text.isEmpty)
        #expect(conversation.userInputDraft(for: "host").text == "staging-2")
        #expect(conversation.answeredUserInputCount == 3)
    }

    /// Single- and multi-answer questions sit in the same form and keep their
    /// own rule; the mutual exclusion of one must not reach into the other.
    @Test
    func exclusionRulesApplyPerQuestionNotPerForm() {
        let conversation = ConversationModel()
        conversation.present(threeQuestions())

        conversation.toggleUserInputOption("flyway", in: "migrations")
        conversation.toggleUserInputOption("liquibase", in: "migrations")
        #expect(
            conversation.userInputDraft(for: "migrations").selection == ["flyway", "liquibase"],
            "migrations allows several"
        )

        conversation.toggleUserInputOption("postgres", in: "storage")
        conversation.toggleUserInputOption("sqlite", in: "storage")
        #expect(
            conversation.userInputDraft(for: "storage").selection == ["sqlite"],
            "storage allows one"
        )
        #expect(
            conversation.userInputDraft(for: "migrations").selection == ["flyway", "liquibase"],
            "and choosing in one question must not disturb another"
        )
    }

    @Test
    func oneAnswerIsEnoughToContinueButNoneIsNot() {
        let conversation = ConversationModel()
        conversation.present(threeQuestions())

        #expect(!conversation.canSubmitUserInput, "answering nothing is Cancel, not Continue")
        conversation.toggleUserInputOption("postgres", in: "storage")
        #expect(conversation.canSubmitUserInput)
        #expect(conversation.answeredUserInputCount == 1)
    }

    // MARK: - What the tool gets back

    @Test
    func skippedQuestionsAreAbsentFromTheResponse() async {
        let conversation = ConversationModel()
        let answering = Task { await conversation.request(threeQuestions()) }
        await settle(conversation)

        conversation.toggleUserInputOption("flyway", in: "migrations")
        conversation.submitUserInput()

        #expect(
            await answering.value
                == .answered([
                    AgentUserInputAnswer(
                        questionID: "migrations", value: .choice(selectedIDs: ["flyway"], custom: nil)
                    )
                ])
        )
    }

    @Test
    func answerReportsIdsInTheOrderTheQuestionListedThem() async {
        let conversation = ConversationModel()
        let answering = Task { await conversation.request(request(multiple: true)) }
        await settle(conversation)

        // Clicked back to front; the answer still reads front to back, because
        // the model wrote the list and reads the reply against it.
        conversation.toggleUserInputOption("duckdb", in: "storage")
        conversation.toggleUserInputOption("postgres", in: "storage")
        conversation.submitUserInput()

        #expect(
            await answering.value
                == .answered([
                    AgentUserInputAnswer(
                        questionID: "storage",
                        value: .choice(selectedIDs: ["postgres", "duckdb"], custom: nil)
                    )
                ])
        )
    }

    @Test
    func aTypedAnswerComesBackAsCustomTextWithNoSelection() async {
        let conversation = ConversationModel()
        let answering = Task { await conversation.request(request(multiple: false)) }
        await settle(conversation)

        conversation.setUserInputCustomAnswer("  MySQL  ", for: "storage")
        conversation.submitUserInput()

        // Trimmed, because trailing whitespace is not part of anyone's answer.
        #expect(
            await answering.value
                == .answered([
                    AgentUserInputAnswer(
                        questionID: "storage", value: .choice(selectedIDs: [], custom: "MySQL")
                    )
                ])
        )
    }

    @Test
    func cancellingReportsCancelledRatherThanAnEmptyAnswer() async {
        let conversation = ConversationModel()
        let answering = Task { await conversation.request(threeQuestions()) }
        await settle(conversation)

        conversation.toggleUserInputOption("postgres", in: "storage")
        conversation.cancelUserInput()

        #expect(await answering.value == .cancelled)
        #expect(conversation.pendingUserInput == nil)
        #expect(conversation.userInputDraft(for: "storage").selection.isEmpty)
    }

    @Test
    func submittingNothingIsRefusedRatherThanSentAsAnEmptyAnswerList() async {
        let conversation = ConversationModel()
        let answering = Task { await conversation.request(request(multiple: false)) }
        await settle(conversation)

        conversation.submitUserInput()
        #expect(conversation.pendingUserInput != nil, "the request must still be waiting")

        conversation.toggleUserInputOption("sqlite", in: "storage")
        conversation.submitUserInput()
        #expect(
            await answering.value
                == .answered([
                    AgentUserInputAnswer(
                        questionID: "storage", value: .choice(selectedIDs: ["sqlite"], custom: nil)
                    )
                ])
        )
    }

    @Test
    func aFreeFormQuestionStillAnswersAsPlainText() async {
        let conversation = ConversationModel()
        let pending = AgentUserInputRequest(
            questions: [AgentUserQuestion(id: "base_url", prompt: "Base URL?", kind: .text)]
        )
        let answering = Task { await conversation.request(pending) }
        await settle(conversation)

        conversation.setUserInputCustomAnswer("https://api.example.com", for: "base_url")
        conversation.submitUserInput()

        #expect(
            await answering.value
                == .answered([
                    AgentUserInputAnswer(
                        questionID: "base_url", value: .text("https://api.example.com")
                    )
                ])
        )
    }

    @Test
    func aSecretAnswersThroughItsOwnDraftAndNotTheSharedOne() async {
        let conversation = ConversationModel()
        let pending = AgentUserInputRequest(
            questions: [AgentUserQuestion(id: "secret", prompt: "Sudo password?", kind: .secret)]
        )
        let answering = Task { await conversation.request(pending) }
        await settle(conversation)

        #expect(!conversation.canSubmitUserInput)
        conversation.secretInputDraft = "hunter2"
        #expect(conversation.canSubmitUserInput)
        conversation.submitUserInput()

        #expect(
            await answering.value
                == .answered([
                    AgentUserInputAnswer(questionID: "secret", value: .secret("hunter2"))
                ])
        )
        // Never left behind in the plain drafts, which are what the transcript
        // and the next question read from.
        #expect(conversation.userInputDraft(for: "secret").text.isEmpty)
        #expect(conversation.secretInputDraft.isEmpty)
    }

    // MARK: - What the model reads

    /// The skipped question still appears, carrying a null. Omitting it would
    /// read as a bug; a null says plainly that this one is now the model's call.
    @Test
    func everyQuestionIsReportedWhetherAnsweredOrNot() {
        let questions = threeQuestions().questions
        let rows = AgentBuiltInTools.reported(
            questions,
            [
                AgentUserInputAnswer(
                    questionID: "migrations",
                    value: .choice(selectedIDs: ["flyway", "liquibase"], custom: "or none")
                ),
                AgentUserInputAnswer(questionID: "host", value: .text("staging-2")),
            ]
        )

        #expect(rows.count == 3)
        // Order follows the questions, not the answers.
        #expect(field(rows[0], "question_id") == .string("storage"))
        #expect(field(rows[0], "answer") == .null)
        #expect(field(rows[0], "selected_option_ids") == .array([]))
        #expect(field(rows[0], "custom_text") == .null)

        // A typed answer wins the canonical `answer`, and the ids still travel.
        #expect(field(rows[1], "answer") == .string("or none"))
        #expect(
            field(rows[1], "selected_option_ids")
                == .array([.string("flyway"), .string("liquibase")])
        )
        #expect(field(rows[2], "answer") == .string("staging-2"))
    }

    /// With no typed answer the canonical `answer` is the labels, not the ids —
    /// a model that reads one field should read something a human wrote.
    @Test
    func selectedLabelsBecomeTheCanonicalAnswer() {
        let rows = AgentBuiltInTools.reported(
            [storage(multiple: true)],
            [
                AgentUserInputAnswer(
                    questionID: "storage",
                    value: .choice(selectedIDs: ["postgres", "duckdb"], custom: nil)
                )
            ]
        )
        #expect(field(rows[0], "answer") == .string("Postgres, DuckDB"))
        #expect(field(rows[0], "custom_text") == .null)
    }

    /// Unreachable through `request_user_input`, which never builds a secret
    /// question — but if one ever arrives, the plaintext must not be echoed.
    @Test
    func aSecretIsNeverReportedBackToTheModel() {
        let rows = AgentBuiltInTools.reported(
            [AgentUserQuestion(id: "secret", prompt: "Password?", kind: .secret)],
            [AgentUserInputAnswer(questionID: "secret", value: .secret("hunter2"))]
        )
        #expect(field(rows[0], "answer") == .null)
        #expect(field(rows[0], "custom_text") == .null)
    }

    // MARK: - Helpers

    private func field(_ row: AgentJSONValue, _ key: String) -> AgentJSONValue? {
        row.objectValue?[key]
    }

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
        AgentUserInputRequest(questions: [storage(multiple: multiple)])
    }

    private func threeQuestions() -> AgentUserInputRequest {
        AgentUserInputRequest(questions: [
            storage(multiple: false),
            AgentUserQuestion(
                id: "migrations", header: "Migrations", prompt: "Which tools may we use?",
                kind: .choice(
                    AgentUserInputChoice(
                        options: [
                            AgentUserInputOption(id: "flyway", label: "Flyway"),
                            AgentUserInputOption(id: "liquibase", label: "Liquibase"),
                        ],
                        allowsMultipleAnswers: true
                    )
                )
            ),
            AgentUserQuestion(id: "host", prompt: "Which host is staging?", kind: .text),
        ])
    }

    private func storage(multiple: Bool) -> AgentUserQuestion {
        AgentUserQuestion(
            id: "storage", header: "Storage", prompt: "Which database?",
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
            )
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
