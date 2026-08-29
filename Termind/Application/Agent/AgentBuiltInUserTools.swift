import Foundation

nonisolated struct RequestUserInputTool: AgentToolDefinition, AgentToolSchemaBuilding {
    static let presenter = AgentToolDetailPresenter(
        id: "builtin.request_user_input", present: present
    )

    var descriptor: AgentToolDescriptor { Self.descriptor(
            "request_user_input",
            """
            Ask the user to decide things you cannot decide yourself, and wait for the answers. \
            Use it only when the answer is genuinely theirs: a preference, a tradeoff with no \
            defensible default, or a fact only they hold — which host is production, where a \
            credential lives. If the repository, the request, or an obvious convention already \
            answers it, choose, say which assumption you made, and keep going; a question the \
            user has to stop and think about costs more than a decision you make and flag. Never \
            use it to ask whether to proceed. Ask a whole group of related decisions in one \
            call, up to three, rather than one at a time — a second question raised only after \
            the first is answered was hidden at the moment it would have informed it. One \
            question is still the common case; three is a ceiling, not a target. Give each \
            question 2-4 options with a description saying what it costs rather than restating \
            the label, and put your recommendation on the option itself instead of in its \
            wording. A free-form field is offered alongside them unless you set allow_custom \
            false, so never write an "Other" option yourself. Omit options entirely for a \
            question no menu can answer, such as a URL or a name. A question may come back with \
            a null answer: that is the user declining to decide that one, not an error and not \
            a reason to ask again — decide it yourself and say which assumption you used.
            """,
            properties: [
                "questions": Self.array(
                    items: Self.object(
                        properties: [
                            "id": Self.string(max: 64),
                            "header": Self.string(max: 24),
                            "prompt": Self.string(max: 4_096),
                            "options": Self.array(
                                items: Self.object(
                                    properties: [
                                        "id": Self.string(max: 64),
                                        "label": Self.string(max: 120),
                                        "description": Self.string(max: 400),
                                        "recommended": Self.boolean(),
                                    ],
                                    required: ["id", "label"]
                                ),
                                max: 4
                            ),
                            "multi_select": Self.boolean(),
                            "allow_custom": Self.boolean(),
                            "custom_placeholder": Self.string(max: 120),
                        ],
                        required: ["id", "prompt"]
                    ),
                    max: AgentUserInputLimits.maxQuestions
                ),
                "timeout_seconds": Self.integer(
                    min: AgentUserInputLimits.minimumTimeoutSeconds,
                    max: AgentUserInputLimits.maximumTimeoutSeconds
                ),
            ], required: ["questions"], target: .user, safety: .locallyReadOnly,
            presentation: .init(
                symbol: "questionmark.circle",
                activity: .semanticArrayCount(
                    key: "questions", unit: .question, fallback: .question
                ),
                actionKind: .ask
            )
        ) }

    func execute(
        _ invocation: AgentToolInvocation, context: AgentToolExecutionContext
    ) async throws -> AgentToolResult {
            let arguments = try Arguments(invocation)
            let questions = try arguments.userQuestions()
            let timeoutSeconds = arguments.optionalInt("timeout_seconds")
                ?? AgentUserInputLimits.defaultTimeoutSeconds
            let response = await context.userInteraction.request(
                AgentUserInputRequest(
                    questions: questions, timeout: .seconds(timeoutSeconds)
                )
            )
            switch response {
            case .answered(let answers):
                return Self.result(invocation, .object([
                    "answers": .array(Self.reported(questions, answers))
                ]))
            case .cancelled: throw AgentToolError.cancelled
            case .timedOut: throw AgentToolError.userInputTimedOut(timeoutSeconds)
            }
    }

    /// Every question, answered or not, in the order it was asked.
    ///
    /// Reporting the skipped ones rather than omitting them is what makes a
    /// null legible: a model reading its own list back finds each entry where
    /// it put it, and an absent key would read as a bug rather than as the user
    /// declining that one.
    ///
    /// Not private, because this shape *is* the contract with the model and a
    /// test should be able to hold it still.
    static func reported(
        _ questions: [AgentUserQuestion], _ answers: [AgentUserInputAnswer]
    ) -> [AgentJSONValue] {
        let byID = Dictionary(answers.map { ($0.questionID, $0.value) }) { first, _ in first }
        return questions.map { question in
            switch byID[question.id] {
            case .choice(let selectedIDs, let custom):
                let labels = selectedIDs.compactMap { id in
                    question.options.first { $0.id == id }?.label
                }
                return row(
                    question.id,
                    // The canonical human answer, whichever route produced it,
                    // so a model that reads one field reads the right one.
                    answer: custom ?? labels.joined(separator: ", "),
                    selected: selectedIDs, custom: custom
                )
            case .text(let typed):
                return row(question.id, answer: typed, selected: [], custom: typed)
            case .secret:
                // Unreachable — `request_user_input` never builds a secret
                // question. Reported as skipped rather than echoed, so that if
                // one ever does arrive here the plaintext still does not reach
                // the model.
                return row(question.id, answer: nil, selected: [], custom: nil)
            case nil:
                return row(question.id, answer: nil, selected: [], custom: nil)
            }
        }
    }

    private static func row(
        _ questionID: String, answer: String?, selected: [String], custom: String?
    ) -> AgentJSONValue {
        .object([
            "question_id": .string(questionID),
            "answer": answer.map(AgentJSONValue.string) ?? .null,
            "selected_option_ids": .array(selected.map(AgentJSONValue.string)),
            "custom_text": custom.map(AgentJSONValue.string) ?? .null,
        ])
    }

}

nonisolated struct RequestUserSecretTool: AgentToolDefinition, AgentToolSchemaBuilding {
    static let presenter = AgentToolDetailPresenter(
        id: "builtin.request_user_secret", present: present
    )

    var descriptor: AgentToolDescriptor { Self.descriptor(
            "request_user_secret", "Collect a secret in SecureField and return a one-shot bound handle.",
            properties: [
                "prompt": Self.string(max: 4_096), "host_id": Self.string(),
                "consumer_tool": Self.enumeration(["ssh_exec"]), "purpose": Self.string(max: 256),
                "timeout_seconds": Self.integer(
                    min: AgentUserInputLimits.minimumTimeoutSeconds,
                    max: AgentUserInputLimits.maximumTimeoutSeconds
                ),
            ], required: ["prompt", "host_id", "consumer_tool", "purpose"],
            // Sequential, by the default, and it should stay that way despite
            // being read-only: this and `request_user_input` are the two tools
            // whose work is done by a person. Racing them against other calls
            // means output arriving under a question that is still being read.
            target: .user, safety: .locallyReadOnly,
            presentation: .init(
                symbol: "key", activity: .semanticArgument(key: "prompt", fallback: .secret),
                actionKind: .request
            )
        ) }

    func execute(
        _ invocation: AgentToolInvocation, context: AgentToolExecutionContext
    ) async throws -> AgentToolResult {
            let arguments = try Arguments(invocation)
            let hostID = try arguments.uuid("host_id")
            let toolName = try arguments.string("consumer_tool")
            let purpose = try arguments.string("purpose")
            let timeoutSeconds = arguments.optionalInt("timeout_seconds")
                ?? AgentUserInputLimits.defaultTimeoutSeconds
            // One question, always. A secret is not a decision among options and
            // has no business sharing a form with one.
            let request = AgentUserInputRequest(
                questions: [
                    AgentUserQuestion(
                        id: "secret", prompt: try arguments.string("prompt"), kind: .secret
                    )
                ],
                purpose: purpose, hostID: hostID,
                timeout: .seconds(timeoutSeconds)
            )
            switch await context.userInteraction.request(request) {
            case .answered(let answers):
                guard case .secret(let secret)? = answers.first?.value else {
                    // A secret must come back through `SecureField` and the
                    // broker. Anything else means it took the ordinary-answer
                    // path, where it would have been echoed on screen and kept
                    // in plain state.
                    throw AgentToolError.invalidArguments(
                        "The secret prompt returned ordinary text."
                    )
                }
                let handle = await context.secretBroker.issue(
                    secret,
                    binding: SecretBinding(
                        runID: context.runID, toolName: toolName, hostID: hostID, purpose: purpose
                    )
                )
                return Self.result(invocation, .object([
                    "secret_handle": .string(handle.id.uuidString), "single_use": .bool(true),
                ]))
            case .cancelled: throw AgentToolError.cancelled
            case .timedOut: throw AgentToolError.userInputTimedOut(timeoutSeconds)
            }
    }
}

// MARK: - Tool-owned transcript details

nonisolated extension RequestUserInputTool {
    static func present(
        _ input: AgentToolDetailInput
    ) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        guard let answers = input.result.objectValue?["answers"]?.arrayValue else {
            return F.genericItems(input.result, locale: input.locale)
        }
        let answerByID = Dictionary(
            answers.compactMap { row -> (String, [String: AgentJSONValue])? in
                guard let fields = row.objectValue,
                    let id = fields["question_id"]?.stringValue
                else { return nil }
                return (id, fields)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let questions = input.arguments["questions"]?.arrayValue ?? []
        var items: [AgentToolDetail.Item] = []
        for questionValue in questions {
            guard let question = questionValue.objectValue else { continue }
            let id = question["id"]?.stringValue ?? ""
            let prompt = question["prompt"]?.stringValue
                ?? F.localized("Question unavailable", locale: input.locale)
            let displayedQuestion = F.nonempty(question["header"]?.stringValue)
                .map { "\($0) — \(prompt)" } ?? prompt
            let answerFields = answerByID[id]
            let answer = answerFields?["answer"]
            let displayedAnswer: String
            if let answer, answer != .null {
                let selected = answerFields?["selected_option_ids"]?.arrayValue?
                    .compactMap(\.stringValue) ?? []
                let selectedSet = Set(selected)
                let labels = question["options"]?.arrayValue?.compactMap { option -> String? in
                    guard let fields = option.objectValue,
                        let optionID = fields["id"]?.stringValue,
                        selectedSet.contains(optionID)
                    else { return nil }
                    return F.nonempty(fields["label"]?.stringValue)
                } ?? []
                let custom = F.nonempty(answerFields?["custom_text"]?.stringValue)
                let structured = labels + [custom].compactMap { $0 }
                displayedAnswer = structured.isEmpty
                    ? F.nonempty(answer.stringValue)
                        ?? F.localized("Skipped", locale: input.locale)
                    : structured.joined(separator: ", ")
            } else {
                displayedAnswer = F.localized("Skipped", locale: input.locale)
            }
            items.append(F.field("Question", displayedQuestion, locale: input.locale))
            items.append(F.field("Answer", displayedAnswer, locale: input.locale))
        }
        return items.isEmpty ? F.genericItems(input.result, locale: input.locale) : items
    }

}

nonisolated extension RequestUserSecretTool {
    static func present(
        _ input: AgentToolDetailInput
    ) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        var items: [AgentToolDetail.Item] = []
        F.appendField(&items, "Request", input.arguments["prompt"]?.stringValue, locale: input.locale)
        F.appendField(&items, "Purpose", input.arguments["purpose"]?.stringValue, locale: input.locale)
        if input.arguments["consumer_tool"]?.stringValue == "ssh_exec" {
            items.append(F.field(
                "Consumer", F.localized("SSH command", locale: input.locale), locale: input.locale
            ))
        } else {
            F.appendField(
                &items, "Consumer",
                input.arguments["consumer_tool"]?.stringValue.map(F.humanized),
                locale: input.locale
            )
        }
        items.append(F.field(
            "Status", F.localized("Secret received securely", locale: input.locale),
            locale: input.locale
        ))
        return items
    }
}
