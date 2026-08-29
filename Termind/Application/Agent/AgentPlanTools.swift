import Foundation

nonisolated struct PresentPlanTool: AgentToolDefinition, AgentToolSchemaBuilding {
    static let presenter = AgentToolDetailPresenter(
        id: "builtin.present_plan", present: present
    )
    static let maximumPlanBytes = 64 * 1_024
    let workspace: AgentScratchWorkspace
    let plans: AgentPlanRecorder

    var descriptor: AgentToolDescriptor { Self.descriptor(
        AgentPlanModeHook.presentPlanToolName,
        """
        Put a finished plan to the user and end the turn. Pass the scratch path you drafted it \
        at, not the text: write it with scratch_write and revise it with scratch_edit. Call this \
        on its own and last. Do not call it to think out loud; use request_user_input for that.
        """,
        properties: ["title": Self.string(max: 120),
                     "scratch_path": Self.string(max: AgentScratchWorkspace.Limits.pathBytes)],
        required: ["title", "scratch_path"], target: .user, safety: .locallyReadOnly,
        presentation: .init(
            symbol: "lightbulb.max", activity: .semanticArgument(key: "title", fallback: .plan),
            output: .field("plan"), actionKind: .present
        )
    ) }

    func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult {
        let arguments = try Arguments(invocation)
        let path = try arguments.string("scratch_path")
        let file = try await workspace.data(at: path)
        guard file.bytes <= Self.maximumPlanBytes else {
            throw AgentToolError.invalidArguments(
                "\(path) is \(file.bytes) bytes, past the \(Self.maximumPlanBytes)-byte limit for a plan. Shorten it to what the user has to decide."
            )
        }
        guard let body = String(data: file.data, encoding: .utf8),
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.invalidArguments("\(path) is not readable text.")
        }
        plans.record(AgentPlan(
            title: try arguments.string("title"), body: body, scratchPath: path
        ))
        return Self.result(invocation, .object([
            "presented": .bool(true), "scratch_path": .string(path), "plan": .string(body),
        ]))
    }
}

nonisolated struct ManageTasksTool: AgentToolDefinition, AgentToolSchemaBuilding {
    static let presenter = AgentToolDetailPresenter(
        id: "builtin.manage_tasks", present: present
    )
    let tasks: AgentTaskList

    var descriptor: AgentToolDescriptor {
        let task = Self.object(
            properties: [
                "id": Self.string(max: 64), "title": Self.string(max: 200),
                "status": Self.enumeration(AgentTask.Status.allCases.map(\.rawValue)),
            ], required: ["id", "title", "status"]
        )
        return Self.descriptor(
            "manage_tasks",
            """
            Replace the visible task list with the complete list as it now stands. Keep exactly \
            one item in_progress, and update it in the same turn the work happens. Do not create \
            a list for work that only has one or two steps.
            """,
            properties: ["tasks": Self.array(items: task, max: AgentTaskList.maximumTasks)],
            required: ["tasks"], target: .user, safety: .locallyReadOnly,
            presentation: .init(
                symbol: "checklist", activity: .semanticLabel(.taskList), output: .json,
                actionKind: .update
            )
        )
    }

    func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult {
        let updated = try Arguments(invocation).agentTasks()
        tasks.replace(updated)
        return Self.result(invocation, .object([
            "tasks": .number(Double(updated.count)),
            "completed": .number(Double(updated.filter { $0.status == .completed }.count)),
        ]))
    }
}

nonisolated extension PresentPlanTool {
    static func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        guard let path = input.result.objectValue?["scratch_path"]?.stringValue else {
            return AgentToolDetailFormatting.genericItems(input.result, locale: input.locale)
        }
        return [.message(
            String(localized: "Plan presented from \(path)", locale: input.locale), .success
        )]
    }
}

nonisolated extension ManageTasksTool {
    static func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        guard let object = input.result.objectValue,
              let total = object["tasks"]?.integerValue,
              let completed = object["completed"]?.integerValue else {
            return AgentToolDetailFormatting.genericItems(input.result, locale: input.locale)
        }
        return [.message(
            String(localized: "\(total) tasks · \(completed) completed", locale: input.locale),
            .secondary
        )]
    }
}

/// Where `manage_tasks` writes, and nothing else.
///
/// A narrow port rather than handing the tool the whole `AgentEventChannel`: a
/// tool that can emit any event can emit `toolFinished`, and the executor is
/// what owns that. This one can publish a task list and that is all.
nonisolated struct AgentTaskList: Sendable {
    /// Past this a checklist has stopped being a summary of the work. The tool
    /// says so rather than truncating, so the model can shorten it.
    static let maximumTasks = 20

    private let publish: @Sendable ([AgentTask]) -> Void

    init(_ publish: @escaping @Sendable ([AgentTask]) -> Void) {
        self.publish = publish
    }

    func replace(_ tasks: [AgentTask]) { publish(tasks) }
}

/// The same, for a presented plan.
nonisolated struct AgentPlanRecorder: Sendable {
    private let publish: @Sendable (AgentPlan) -> Void

    init(_ publish: @escaping @Sendable (AgentPlan) -> Void) {
        self.publish = publish
    }

    func record(_ plan: AgentPlan) { publish(plan) }
}

/// The two tools that turn a conversation into a piece of work: one that puts a
/// finished plan to the user, one that tracks the steps once they agree.
///
/// They are deliberately not the same surface. A plan is a **document, decided
/// once** — it is presented, answered, and stays in the transcript where it
/// happened. A task list is **live state, rewritten every turn**, and belongs in
/// the strip above the composer where the current one is always the only one.
/// The hook that runs planning blocks `manage_tasks` for exactly this reason.
nonisolated enum AgentPlanTools: AgentToolSchemaBuilding {
}

nonisolated extension Arguments {
    /// The `tasks` array of `manage_tasks`.
    ///
    /// Malformed rows are rejected rather than skipped, on the same grounds as
    /// `userQuestions()`: a list silently missing the step the user was watching
    /// for is worse than an error the model can see and correct.
    func agentTasks() throws -> [AgentTask] {
        guard let rows = object["tasks"]?.arrayValue else {
            throw AgentToolError.invalidArguments("tasks must be an array.")
        }
        guard rows.count <= AgentTaskList.maximumTasks else {
            throw AgentToolError.invalidArguments(
                "At most \(AgentTaskList.maximumTasks) tasks may be tracked at once."
            )
        }
        var seen: Set<String> = []
        let tasks = try rows.map { row -> AgentTask in
            guard let fields = row.objectValue,
                let id = fields["id"]?.stringValue, !id.isEmpty,
                let title = fields["title"]?.stringValue, !title.isEmpty,
                let rawStatus = fields["status"]?.stringValue,
                let status = AgentTask.Status(rawValue: rawStatus)
            else {
                throw AgentToolError.invalidArguments(
                    "Each task requires id, title, and a known status."
                )
            }
            guard seen.insert(id).inserted else {
                throw AgentToolError.invalidArguments("Task ids must be unique: \(id).")
            }
            return AgentTask(id: id, title: title, status: status)
        }
        // Stated as an error rather than silently repaired. Two things in
        // progress at once is the model losing track of which it is doing, and
        // a list that quietly demotes one hides that.
        guard tasks.filter({ $0.status == .inProgress }).count <= 1 else {
            throw AgentToolError.invalidArguments(
                "Only one task may be in_progress at a time."
            )
        }
        return tasks
    }
}
