import AgentKit
import Foundation
import TermindDomain
import TermindInfrastructure
import Testing

import struct TermindDomain.Host

@testable import TermindApplication

@MainActor
@Suite
struct AgentUserInputTests {

    // MARK: - Parsing the tool's questions

    @Test
    func userInputToolsExposeOptionalBoundedTimeouts() throws {
        for tool in [
            AnyAgentTool(RequestUserInputTool()), AnyAgentTool(RequestUserSecretTool()),
        ] {
            let schema = tool.descriptor.inputSchema
            let properties = try #require(schema.objectValue?["properties"]?.objectValue)
            let timeout = try #require(properties["timeout_seconds"]?.objectValue)
            let required = schema.objectValue?["required"]?.arrayValue?.compactMap(\.stringValue)

            #expect(timeout["type"] == .string("integer"))
            #expect(timeout["minimum"] == .number(1))
            #expect(timeout["maximum"] == .number(1_800))
            #expect(required?.contains("timeout_seconds") == false)

            #expect(throws: Never.self) {
                try AgentJSONSchemaValidator.validate(
                    argumentsFor(tool.descriptor.name, timeout: 1), against: schema
                )
            }
            #expect(throws: Never.self) {
                try AgentJSONSchemaValidator.validate(
                    argumentsFor(tool.descriptor.name, timeout: 1_800), against: schema
                )
            }
            #expect(throws: AgentSchemaError.self) {
                try AgentJSONSchemaValidator.validate(
                    argumentsFor(tool.descriptor.name, timeout: 0), against: schema
                )
            }
            #expect(throws: AgentSchemaError.self) {
                try AgentJSONSchemaValidator.validate(
                    argumentsFor(tool.descriptor.name, timeout: 1_801), against: schema
                )
            }
        }
    }

    @Test
    func requestsDefaultToFiveMinutes() {
        #expect(request(multiple: false).timeout == .seconds(300))
    }

    @Test
    func requestUserInputAppliesDefaultAndExplicitTimeoutsToThePresentedRequest() async {
        let interaction = TimeoutRecordingUserInteraction()
        let tool = RequestUserInputTool()

        for expectedSeconds in [300, 17] {
            var object: [String: AgentJSONValue] = [
                "questions": .array([
                    .object(["id": .string("q"), "prompt": .string("Question?")])
                ])
            ]
            if expectedSeconds != 300 {
                object["timeout_seconds"] = .number(Double(expectedSeconds))
            }
            let invocation = AgentToolInvocation(
                runID: UUID(),
                call: AgentToolCall(
                    id: "timeout-\(expectedSeconds)", name: "request_user_input",
                    arguments: .object(object)
                )
            )

            do {
                _ = try await tool.execute(
                    invocation,
                    context: AgentToolExecutionContext(
                        runID: invocation.runID, userIntent: "ask",
                        secretBroker: SecretBroker(), userInteraction: interaction,
                        preflightMetadata: [:], authorize: { _ in .allow }
                    )
                )
                Issue.record("expected timeout to fail the tool")
            } catch {
                #expect(
                    error.localizedDescription
                        == "User input timed out after \(expectedSeconds) seconds."
                )
            }
            #expect(await interaction.lastRequest?.timeout == .seconds(expectedSeconds))
        }
    }

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
            [
                "questions": .array([
                    .object(["id": .string("q"), "prompt": .string("first")]),
                    .object(["id": .string("q"), "prompt": .string("duplicate id")]),
                ])
            ],
            [
                "questions": .array([
                    .object([
                        "id": .string("q"), "prompt": .string("?"),
                        "options": .array([
                            .object(["id": .string("a"), "label": .string("A")]),
                            .object(["id": .string("a"), "label": .string("Also A")]),
                        ]),
                    ])
                ])
            ],
            [
                "questions": .array([
                    .object([
                        "id": .string("q"), "prompt": .string("?"),
                        "options": .array([.string("a bare string")]),
                    ])
                ])
            ],
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

    @Test
    func choosingASingleOptionImmediatelySubmitsAOneQuestionRequest() async {
        let conversation = ConversationModel()
        let answering = Task { await conversation.request(request(multiple: false)) }
        await settle(conversation)

        conversation.answerUserInputOption("postgres", in: "storage")

        #expect(
            await answering.value
                == .answered([
                    AgentUserInputAnswer(
                        questionID: "storage",
                        value: .choice(selectedIDs: ["postgres"], custom: nil)
                    )
                ])
        )
        #expect(conversation.pendingUserInput == nil)
    }

    @Test
    func singleOptionsAdvanceAndTheLastOneSubmitsTheRequest() async {
        let conversation = ConversationModel()
        let answering = Task { await conversation.request(twoSingleChoiceQuestions()) }
        await settle(conversation)

        conversation.answerUserInputOption("postgres", in: "storage")
        #expect(conversation.currentUserInputQuestion?.id == "region")
        #expect(conversation.pendingUserInput != nil)

        conversation.answerUserInputOption("eu", in: "region")
        #expect(
            await answering.value
                == .answered([
                    AgentUserInputAnswer(
                        questionID: "storage",
                        value: .choice(selectedIDs: ["postgres"], custom: nil)
                    ),
                    AgentUserInputAnswer(
                        questionID: "region",
                        value: .choice(selectedIDs: ["eu"], custom: nil)
                    ),
                ])
        )
    }

    @Test
    func revisitingASingleChoiceReplacesItsAnswerAndAdvancesAgain() {
        let conversation = ConversationModel()
        conversation.present(twoSingleChoiceQuestions())

        conversation.answerUserInputOption("postgres", in: "storage")
        conversation.previousUserInputQuestion()
        conversation.answerUserInputOption("sqlite", in: "storage")

        #expect(conversation.currentUserInputQuestion?.id == "region")
        #expect(conversation.userInputDraft(for: "storage").selection == ["sqlite"])
    }

    @Test
    func choosingAMultipleAnswerOptionDoesNotAdvance() {
        let conversation = ConversationModel()
        conversation.present(request(multiple: true))

        conversation.answerUserInputOption("postgres", in: "storage")

        #expect(conversation.currentUserInputQuestion?.id == "storage")
        #expect(conversation.pendingUserInput != nil)
        #expect(conversation.userInputDraft(for: "storage").selection == ["postgres"])
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
    func currentQuestionMustBeAnsweredOrSkippedBeforeAdvancing() {
        let conversation = ConversationModel()
        conversation.present(threeQuestions())

        #expect(!conversation.canAdvanceUserInput)
        #expect(!conversation.canSubmitUserInput)
        conversation.toggleUserInputOption("postgres", in: "storage")
        #expect(conversation.canAdvanceUserInput)
        #expect(!conversation.canSubmitUserInput, "only the last step submits")
        #expect(conversation.answeredUserInputCount == 1)

        conversation.advanceUserInputQuestion()
        #expect(conversation.currentUserInputQuestionIndex == 1)
        #expect(conversation.currentUserInputQuestion?.id == "migrations")
    }

    @Test
    func goingBackKeepsDraftsAndChangingASkippedQuestionMakesItUnresolved() {
        let conversation = ConversationModel()
        conversation.present(threeQuestions())

        conversation.toggleUserInputOption("postgres", in: "storage")
        conversation.advanceUserInputQuestion()
        conversation.toggleUserInputOption("flyway", in: "migrations")
        conversation.previousUserInputQuestion()

        #expect(conversation.currentUserInputQuestion?.id == "storage")
        #expect(conversation.userInputDraft(for: "storage").selection == ["postgres"])
        #expect(conversation.userInputDraft(for: "migrations").selection == ["flyway"])

        conversation.skipUserInputQuestion()
        #expect(conversation.userInputDraft(for: "storage").selection.isEmpty)
        #expect(conversation.skippedUserInputQuestionIDs.contains("storage"))
        conversation.previousUserInputQuestion()
        #expect(conversation.canAdvanceUserInput, "the explicit skip remains resolved")

        conversation.toggleUserInputOption("sqlite", in: "storage")
        conversation.toggleUserInputOption("sqlite", in: "storage")
        #expect(!conversation.skippedUserInputQuestionIDs.contains("storage"))
        #expect(!conversation.canAdvanceUserInput)
    }

    // MARK: - What the tool gets back

    @Test
    func skippedQuestionsAreAbsentFromTheResponse() async {
        let conversation = ConversationModel()
        let answering = Task { await conversation.request(threeQuestions()) }
        await settle(conversation)

        conversation.skipUserInputQuestion()
        conversation.toggleUserInputOption("flyway", in: "migrations")
        conversation.advanceUserInputQuestion()
        conversation.skipUserInputQuestion()

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
    func explicitlySkippingEveryQuestionReturnsASuccessfulEmptyAnswer() async {
        let conversation = ConversationModel()
        let answering = Task { await conversation.request(threeQuestions()) }
        await settle(conversation)

        conversation.skipUserInputQuestion()
        conversation.skipUserInputQuestion()
        conversation.skipUserInputQuestion()

        #expect(await answering.value == .answered([]))
        #expect(conversation.pendingUserInput == nil)
    }

    @Test
    func completingARequestResetsNavigationForTheQueuedOne() {
        let conversation = ConversationModel()
        conversation.present(threeQuestions())
        conversation.present(request(multiple: false))

        conversation.skipUserInputQuestion()
        conversation.skipUserInputQuestion()
        conversation.skipUserInputQuestion()

        #expect(conversation.pendingUserInputs.count == 1)
        #expect(conversation.currentUserInputQuestionIndex == 0)
        #expect(conversation.skippedUserInputQuestionIDs.isEmpty)
        #expect(conversation.userInputDrafts.isEmpty)
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
    func timingOutDiscardsEveryDraftAndReturnsNoPartialAnswers() async {
        let conversation = ConversationModel()
        var pending = threeQuestions()
        pending.timeout = .milliseconds(40)
        let answering = Task { await conversation.request(pending) }
        await settle(conversation)

        conversation.toggleUserInputOption("postgres", in: "storage")
        conversation.advanceUserInputQuestion()
        conversation.toggleUserInputOption("flyway", in: "migrations")

        #expect(await answering.value == .timedOut)
        #expect(conversation.pendingUserInput == nil)
        #expect(conversation.userInputDrafts.isEmpty)
        #expect(conversation.secretInputDraft.isEmpty)
        #expect(conversation.skippedUserInputQuestionIDs.isEmpty)
        #expect(conversation.currentUserInputQuestionIndex == 0)
    }

    @Test
    func navigatingBetweenQuestionsDoesNotResetTheRequestDeadline() async throws {
        let conversation = ConversationModel()
        let clock = QuestionTestClock()
        conversation.questionClockNow = { clock.now }
        conversation.questionClockSleep = { try await clock.sleep(until: $0) }
        var pending = threeQuestions()
        pending.timeout = .milliseconds(200)
        let answering = Task { await conversation.request(pending) }
        await settle(conversation)

        let deadline = try #require(conversation.userInputDeadline)
        conversation.toggleUserInputOption("postgres", in: "storage")
        conversation.advanceUserInputQuestion()
        conversation.previousUserInputQuestion()
        #expect(conversation.userInputDeadline == deadline)
        clock.advance(by: .seconds(1))
        #expect(await answering.value == .timedOut)
        #expect(conversation.pendingUserInput == nil)
        #expect(conversation.userInputDeadline == nil)
    }

    @Test
    func timingOutASecretClearsItsDedicatedDraft() async {
        let conversation = ConversationModel()
        let pending = AgentUserInputRequest(
            questions: [AgentUserQuestion(id: "secret", prompt: "Password?", kind: .secret)],
            timeout: .milliseconds(40)
        )
        let answering = Task { await conversation.request(pending) }
        await settle(conversation)
        conversation.secretInputDraft = "never-return-this"

        #expect(await answering.value == .timedOut)
        #expect(conversation.secretInputDraft.isEmpty)
        #expect(conversation.pendingUserInput == nil)
    }

    @Test
    func queuedRequestGetsItsFullTimeoutOnlyAfterItBecomesVisible() async throws {
        let conversation = ConversationModel()
        let clock = QuestionTestClock()
        conversation.questionClockNow = { clock.now }
        conversation.questionClockSleep = { try await clock.sleep(until: $0) }
        var firstRequest = request(multiple: false)
        firstRequest.timeout = .milliseconds(300)
        var secondRequest = request(multiple: false)
        secondRequest.timeout = .milliseconds(40)

        let first = Task { await conversation.request(firstRequest) }
        await settle(conversation)
        let second = Task { await conversation.request(secondRequest) }
        try await waitUntil { conversation.pendingUserInputs.count == 2 }

        clock.advance(by: .milliseconds(80))
        await Task.yield()
        #expect(conversation.pendingUserInput?.id == firstRequest.id)
        #expect(conversation.pendingUserInputs.contains { $0.id == secondRequest.id })

        conversation.cancelUserInput()
        #expect(await first.value == .cancelled)
        #expect(conversation.pendingUserInput?.id == secondRequest.id)
        clock.advance(by: .seconds(1))
        #expect(await second.value == .timedOut)
        #expect(conversation.pendingUserInput == nil)
    }

    @Test
    func answeringCancelsTheOldDeadlineBeforeTheNextRequest() async throws {
        let conversation = ConversationModel()
        let clock = QuestionTestClock()
        conversation.questionClockNow = { clock.now }
        conversation.questionClockSleep = { try await clock.sleep(until: $0) }
        var firstRequest = request(multiple: false)
        firstRequest.timeout = .milliseconds(40)
        var secondRequest = request(multiple: false)
        secondRequest.timeout = .milliseconds(200)

        let first = Task { await conversation.request(firstRequest) }
        await settle(conversation)
        conversation.toggleUserInputOption("sqlite", in: "storage")
        conversation.submitUserInput()
        guard case .answered = await first.value else {
            Issue.record("expected the first request to be answered")
            return
        }

        let second = Task { await conversation.request(secondRequest) }
        await settle(conversation)
        clock.advance(by: .milliseconds(80))
        await Task.yield()
        #expect(conversation.pendingUserInput?.id == secondRequest.id)

        conversation.cancelUserInput()
        #expect(await second.value == .cancelled)
    }

    @Test
    func cancellingTheWaitingTaskRemovesItsPrompt() async {
        let conversation = ConversationModel()
        let answering = Task { await conversation.request(request(multiple: false)) }
        await settle(conversation)

        answering.cancel()

        #expect(await answering.value == .cancelled)
        #expect(conversation.pendingUserInput == nil)
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
        #expect(!conversation.canSkipUserInputQuestion)
        conversation.skipUserInputQuestion()
        #expect(conversation.pendingUserInput != nil)
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
        let rows = RequestUserInputTool.reported(
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
        let rows = RequestUserInputTool.reported(
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
        let rows = RequestUserInputTool.reported(
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

    private func argumentsFor(_ toolName: String, timeout: Int) -> AgentJSONValue {
        if toolName == "request_user_secret" {
            return .object([
                "prompt": .string("Password"), "host_id": .string(UUID().uuidString),
                "consumer_tool": .string("ssh_exec"), "purpose": .string("sudo"),
                "timeout_seconds": .number(Double(timeout)),
            ])
        }
        return .object([
            "questions": .array([
                .object(["id": .string("q"), "prompt": .string("Question?")])
            ]),
            "timeout_seconds": .number(Double(timeout)),
        ])
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

    private func twoSingleChoiceQuestions() -> AgentUserInputRequest {
        AgentUserInputRequest(questions: [
            storage(multiple: false),
            AgentUserQuestion(
                id: "region", prompt: "Which region?",
                kind: .choice(
                    AgentUserInputChoice(
                        options: [
                            AgentUserInputOption(id: "us", label: "United States"),
                            AgentUserInputOption(id: "eu", label: "Europe"),
                        ]
                    )
                )
            ),
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

    @Test
    func localSSHCheckpointsAndQuestionsPresentByCreationTime() async throws {
        let conversation = ConversationModel()
        let base = Date(timeIntervalSince1970: 100)
        let hostID = UUID()
        let authentication = AgentSSHAuthenticationRequest(
            createdAt: base.addingTimeInterval(2), invocationID: UUID(),
            hostID: hostID, displayName: "Host", address: "host.example",
            mode: .identity, username: "", selectedKeyID: nil
        )
        let hostKey = AgentSSHHostKeyRequest(
            createdAt: base.addingTimeInterval(1), invocationID: UUID(),
            hostID: hostID, displayName: "Host", address: "host.example",
            prompt: SSHHostKeyPrompt(
                observation: SSHHostKeyObservation(
                    hostname: "host.example", port: 22, algorithm: .ed25519,
                    fingerprint: "SHA256:new"
                ),
                kind: .firstUse
            ),
            allowsPersistentTrust: true
        )
        let question = AgentUserInputRequest(
            createdAt: base,
            questions: [
                AgentUserQuestion(id: "q", prompt: "Choose", kind: .text)
            ]
        )
        let authenticationTask = Task {
            await conversation.requestSSHAuthentication(authentication)
        }
        let hostKeyTask = Task {
            await conversation.requestSSHHostKeyConfirmation(hostKey)
        }
        let questionTask = Task { await conversation.request(question) }
        try await waitUntil {
            conversation.pendingSSHAuthentication != nil
                && conversation.pendingSSHHostKey != nil
                && conversation.pendingUserInput != nil
        }

        guard case .questions(let visible)? = conversation.pendingUserInteraction else {
            Issue.record("Expected the oldest question first")
            return
        }
        #expect(visible.id == question.id)
        conversation.cancelUserInput()
        #expect(await questionTask.value == .cancelled)
        guard case .sshHostKey(let visibleHostKey)? = conversation.pendingUserInteraction else {
            Issue.record("Expected host key second")
            return
        }
        #expect(visibleHostKey.id == hostKey.id)
        conversation.respondToSSHHostKey(.continueOnce)
        #expect(await hostKeyTask.value == .continueOnce)
        guard case .sshAuthentication(let visibleAuthentication)? = conversation.pendingUserInteraction else {
            Issue.record("Expected authentication last")
            return
        }
        #expect(visibleAuthentication.id == authentication.id)
        conversation.respondToSSHAuthentication(.cancelled)
        #expect(await authenticationTask.value == .cancelled)
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

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            await Task.yield()
        }
        throw AgentUserInputTestFailure.timedOut
    }
}

private enum AgentUserInputTestFailure: Error { case timedOut }

private actor TimeoutRecordingUserInteraction: AgentUserInteractionHandling {
    private(set) var lastRequest: AgentUserInputRequest?

    func request(_ request: AgentUserInputRequest) async -> AgentUserInputResponse {
        lastRequest = request
        return .timedOut
    }

    func requestSSHAuthentication(
        _ request: AgentSSHAuthenticationRequest
    ) async -> AgentSSHAuthenticationResponse {
        .cancelled
    }

    func requestSSHHostKeyConfirmation(
        _ request: AgentSSHHostKeyRequest
    ) async -> AgentSSHHostKeyResponse { .deny }
}

@MainActor
private final class QuestionTestClock {
    var now = ContinuousClock.now
    private var waiters: [UUID: (ContinuousClock.Instant, CheckedContinuation<Void, any Error>)] = [:]

    func advance(by duration: Duration) {
        now = now.advanced(by: duration)
        for (id, waiter) in waiters where waiter.0 <= now {
            waiters.removeValue(forKey: id)?.1.resume()
        }
    }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        guard deadline > now else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = (deadline, continuation)
            }
        } onCancel: {
            Task { @MainActor in
                self.waiters.removeValue(forKey: id)?.1.resume(throwing: CancellationError())
            }
        }
    }
}
