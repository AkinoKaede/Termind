import Foundation

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
    static func make(
        workspace: AgentScratchWorkspace,
        tasks: AgentTaskList,
        plans: AgentPlanRecorder
    ) -> [AnyAgentTool] {
        [presentPlan(workspace, plans), manageTasks(tasks)]
    }

    /// The maximum plan we will read out of the workspace and put on screen.
    ///
    /// A plan is meant to be read by a person before they agree to it. Past this
    /// it is not a plan, and the honest failure is to say so rather than to
    /// silently truncate the part they would have based the decision on.
    static let maximumPlanBytes = 64 * 1_024

    // MARK: - present_plan

    private static func presentPlan(
        _ workspace: AgentScratchWorkspace, _ plans: AgentPlanRecorder
    ) -> AnyAgentTool {
        AnyAgentTool(descriptor: descriptor(
            AgentPlanModeHook.presentPlanToolName,
            """
            Put a finished plan to the user and end the turn. Pass the scratch path you \
            drafted it at, not the text: write it with scratch_write and revise it with \
            scratch_edit, so a revision costs a diff rather than another copy of the \
            document. Call this on its own and last — the run stops here, and the user \
            decides whether to implement it. Do not call it to think out loud or to check \
            direction; ask with request_user_input for that.
            """,
            properties: [
                "title": string(max: 120),
                "scratch_path": string(max: AgentScratchWorkspace.Limits.pathBytes),
            ],
            required: ["title", "scratch_path"], target: .user, safety: .locallyReadOnly,
            presentation: .init(
                symbol: "lightbulb.max",
                activity: .semanticArgument(key: "title", fallback: .plan), output: .field("plan"),
                detailPresenterID: "builtin.present_plan",
                actionKind: .present
            )
        )) { invocation, _ in
            let arguments = try Arguments(invocation)
            let path = try arguments.string("scratch_path")
            let file = try await workspace.data(at: path)
            guard file.bytes <= maximumPlanBytes else {
                throw AgentToolError.invalidArguments(
                    """
                    \(path) is \(file.bytes) bytes, past the \(maximumPlanBytes)-byte limit for \
                    a plan. Shorten it to what the user has to decide.
                    """
                )
            }
            guard let body = String(data: file.data, encoding: .utf8),
                !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw AgentToolError.invalidArguments("\(path) is not readable text.")
            }

            let plan = AgentPlan(
                title: try arguments.string("title"), body: body, scratchPath: path
            )
            plans.record(plan)
            // The plan goes back to the model as well as to the screen. It has
            // to survive into the next run's history: implementing it starts a
            // fresh run whose only memory of the plan is this transcript.
            return result(invocation, .object([
                "presented": .bool(true), "scratch_path": .string(path),
                "plan": .string(body),
            ]))
        }
    }

    // MARK: - manage_tasks

    private static func manageTasks(_ tasks: AgentTaskList) -> AnyAgentTool {
        let task = object(
            properties: [
                "id": string(max: 64),
                "title": string(max: 200),
                "status": enumeration(AgentTask.Status.allCases.map(\.rawValue)),
            ],
            required: ["id", "title", "status"]
        )
        return AnyAgentTool(descriptor: descriptor(
            "manage_tasks",
            """
            Replace the visible task list with the whole list as it now stands, including the \
            items that have not changed. Send the complete list every time — this is not a \
            patch, and an item you leave out disappears. Keep exactly one item in_progress, \
            and update the list in the same turn the work happens rather than as a separate \
            bookkeeping step. Do not create a list for a job that is one or two steps: a \
            checklist longer than the work is noise the user has to read past.
            """,
            properties: ["tasks": array(items: task, max: AgentTaskList.maximumTasks)],
            required: ["tasks"], target: .user, safety: .locallyReadOnly,
            presentation: .init(
                symbol: "checklist", activity: .semanticLabel(.taskList),
                output: .json,
                detailPresenterID: "builtin.manage_tasks",
                actionKind: .update
            )
        )) { invocation, _ in
            let updated = try Arguments(invocation).agentTasks()
            tasks.replace(updated)
            return result(invocation, .object([
                "tasks": .number(Double(updated.count)),
                "completed": .number(Double(updated.filter { $0.status == .completed }.count)),
            ]))
        }
    }
}

// MARK: - Tool-owned transcript details

nonisolated extension AgentPlanTools {
    static let presentPlanDetailPresenter = AgentToolDetailPresenter(
        id: "builtin.present_plan"
    ) { input in
        guard let path = input.result.objectValue?["scratch_path"]?.stringValue else {
            return AgentToolDetailFormatting.genericItems(input.result, locale: input.locale)
        }
        return [.message(
            String(localized: "Plan presented from \(path)", locale: input.locale), .success
        )]
    }

    static let manageTasksDetailPresenter = AgentToolDetailPresenter(
        id: "builtin.manage_tasks"
    ) { input in
        guard let object = input.result.objectValue,
            let total = object["tasks"]?.integerValue,
            let completed = object["completed"]?.integerValue
        else {
            return AgentToolDetailFormatting.genericItems(input.result, locale: input.locale)
        }
        return [.message(
            String(localized: "\(total) tasks · \(completed) completed", locale: input.locale),
            .secondary
        )]
    }
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
