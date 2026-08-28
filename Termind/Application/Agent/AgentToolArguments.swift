import Foundation

nonisolated struct Arguments: Sendable {
    let object: [String: AgentJSONValue]

    init(_ invocation: AgentToolInvocation) throws {
        guard let object = invocation.call.arguments.objectValue else {
            throw AgentToolError.invalidArguments("Arguments must be an object.")
        }
        self.object = object
    }

    func string(_ key: String) throws -> String {
        guard let value = object[key]?.stringValue, !value.isEmpty else {
            throw AgentToolError.invalidArguments("\(key) is required.")
        }
        return value
    }

    func uuid(_ key: String) throws -> UUID {
        guard let value = UUID(uuidString: try string(key)) else { throw AgentToolError.invalidHost }
        return value
    }

    func optionalString(_ key: String) -> String? { object[key]?.stringValue }
    func optionalInt(_ key: String) -> Int? { object[key]?.integerValue }
    func optionalBool(_ key: String) -> Bool? { object[key]?.boolValue }
    /// The `questions` array of `request_user_input`.
    ///
    /// Everything malformed is rejected rather than dropped. A form silently
    /// missing the question — or the option — the user needed is a worse
    /// failure than an error the model can see and retry.
    func userQuestions() throws -> [AgentUserQuestion] {
        guard let rows = object["questions"]?.arrayValue else {
            throw AgentToolError.invalidArguments("questions must be an array.")
        }
        guard !rows.isEmpty else {
            throw AgentToolError.invalidArguments("questions must contain at least one question.")
        }
        guard rows.count <= AgentUserInputLimits.maxQuestions else {
            throw AgentToolError.invalidArguments(
                "At most \(AgentUserInputLimits.maxQuestions) questions may be asked at once."
            )
        }

        var seen: Set<String> = []
        return try rows.map { row in
            guard let fields = row.objectValue,
                let id = fields["id"]?.stringValue, !id.isEmpty,
                let prompt = fields["prompt"]?.stringValue, !prompt.isEmpty
            else {
                throw AgentToolError.invalidArguments("Each question requires id and prompt.")
            }
            guard seen.insert(id).inserted else {
                throw AgentToolError.invalidArguments("Question ids must be unique: \(id).")
            }

            let options = try Self.options(in: fields)
            return AgentUserQuestion(
                id: id,
                header: fields["header"]?.stringValue ?? "",
                prompt: prompt,
                kind: options.isEmpty
                    ? .text
                    : .choice(
                        AgentUserInputChoice(
                            options: options,
                            allowsCustomAnswer: fields["allow_custom"]?.boolValue ?? true,
                            allowsMultipleAnswers: fields["multi_select"]?.boolValue ?? false,
                            customPlaceholder: fields["custom_placeholder"]?.stringValue ?? ""
                        )
                    )
            )
        }
    }

    private static func options(in question: [String: AgentJSONValue]) throws
        -> [AgentUserInputOption]
    {
        guard let value = question["options"], value != .null else { return [] }
        guard let rows = value.arrayValue else {
            throw AgentToolError.invalidArguments("options must be an array.")
        }
        var seen: Set<String> = []
        return try rows.map { row in
            guard let fields = row.objectValue,
                let id = fields["id"]?.stringValue, !id.isEmpty,
                let label = fields["label"]?.stringValue, !label.isEmpty
            else {
                throw AgentToolError.invalidArguments("Each option requires id and label.")
            }
            guard seen.insert(id).inserted else {
                throw AgentToolError.invalidArguments("Option ids must be unique: \(id).")
            }
            return AgentUserInputOption(
                id: id, label: label,
                detail: fields["description"]?.stringValue ?? "",
                isRecommended: fields["recommended"]?.boolValue ?? false
            )
        }
    }

    /// `new_text` may legitimately be empty — that is how a block is deleted — so it
    /// is read for presence rather than through `string(_:)`, which rejects empty.
    func scratchEdits() throws -> [ScratchEdit] {
        guard let rows = object["edits"]?.arrayValue, !rows.isEmpty else {
            throw AgentToolError.invalidArguments("edits must be a non-empty array.")
        }
        return try rows.map { row in
            guard let fields = row.objectValue,
                let oldText = fields["old_text"]?.stringValue,
                let newText = fields["new_text"]?.stringValue
            else {
                throw AgentToolError.invalidArguments("Each edit requires old_text and new_text.")
            }
            return ScratchEdit(oldText: oldText, newText: newText)
        }
    }
}

nonisolated enum AgentToolError: LocalizedError, Sendable {
    case invalidHost, invalidPath, notFound, cancelled, invalidArguments(String)
    case userInputTimedOut(Int)
    case scratchPathEscapes
    case scratchNotFound(String)
    case scratchNotText(String)
    case scratchQuotaExceeded(String)

    var errorDescription: String? {
        switch self {
        case .invalidHost: "The host ID is invalid or unavailable."
        case .invalidPath: "The remote path must be an absolute normalized path."
        case .notFound: "The remote path does not exist."
        case .cancelled: "The user cancelled the request."
        case .userInputTimedOut(let seconds):
            "User input timed out after \(seconds) seconds."
        case .invalidArguments(let message): message
        case .scratchPathEscapes:
            """
            A scratch path must be relative, must not contain "..", and must stay inside \
            the workspace.
            """
        case .scratchNotFound(let path): "\(path) is not in the scratch workspace."
        case .scratchNotText(let path):
            """
            \(path) is not UTF-8 text. It can still be moved with scratch_push, \
            which does not decode it.
            """
        case .scratchQuotaExceeded(let message): message
        }
    }
}
