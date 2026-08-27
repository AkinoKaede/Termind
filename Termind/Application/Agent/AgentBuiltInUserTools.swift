import Foundation

nonisolated extension AgentBuiltInTools {
    static func requestUserInput() -> AnyAgentTool {
        AnyAgentTool(descriptor: descriptor(
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
                "questions": array(
                    items: object(
                        properties: [
                            "id": string(max: 64),
                            "header": string(max: 24),
                            "prompt": string(max: 4_096),
                            "options": array(
                                items: object(
                                    properties: [
                                        "id": string(max: 64),
                                        "label": string(max: 120),
                                        "description": string(max: 400),
                                        "recommended": boolean(),
                                    ],
                                    required: ["id", "label"]
                                ),
                                max: 4
                            ),
                            "multi_select": boolean(),
                            "allow_custom": boolean(),
                            "custom_placeholder": string(max: 120),
                        ],
                        required: ["id", "prompt"]
                    ),
                    max: AgentUserInputLimits.maxQuestions
                ),
                "timeout_seconds": integer(
                    min: AgentUserInputLimits.minimumTimeoutSeconds,
                    max: AgentUserInputLimits.maximumTimeoutSeconds
                ),
            ], required: ["questions"], target: .user, safety: .locallyReadOnly,
            presentation: .init(
                symbol: "questionmark.circle",
                activity: .localizedArrayCount(
                    key: "questions", unit: .question, fallback: "a question"
                ),
                action: .init(infinitive: "ask", progressive: "Asking", past: "Asked")
            )
        )) { invocation, context in
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
                return result(invocation, .object([
                    "answers": .array(reported(questions, answers))
                ]))
            case .cancelled: throw AgentToolError.cancelled
            case .timedOut: throw AgentToolError.userInputTimedOut(timeoutSeconds)
            }
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

    static func requestUserSecret() -> AnyAgentTool {
        AnyAgentTool(descriptor: descriptor(
            "request_user_secret", "Collect a secret in SecureField and return a one-shot bound handle.",
            properties: [
                "prompt": string(max: 4_096), "host_id": string(),
                "consumer_tool": enumeration(["ssh_exec"]), "purpose": string(max: 256),
                "timeout_seconds": integer(
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
                symbol: "key", activity: .argument(key: "prompt", fallback: "a secret"),
                action: .init(infinitive: "request", progressive: "Requesting", past: "Requested")
            )
        )) { invocation, context in
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
                return result(invocation, .object([
                    "secret_handle": .string(handle.id.uuidString), "single_use": .bool(true),
                ]))
            case .cancelled: throw AgentToolError.cancelled
            case .timedOut: throw AgentToolError.userInputTimedOut(timeoutSeconds)
            }
        }
    }
}
