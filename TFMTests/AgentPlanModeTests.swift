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

private actor ScriptedPlanTurns: AgentModelStreaming {
    private let turns: [[AgentModelStreamEvent]]
    private var index = 0

    init(_ turns: [[AgentModelStreamEvent]]) { self.turns = turns }

    private func next() -> [AgentModelStreamEvent] {
        defer { index += 1 }
        return turns[min(index, turns.count - 1)]
    }

    nonisolated func stream(
        _ request: AgentModelRequest
    ) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                for event in await next() { continuation.yield(event) }
                continuation.finish()
            }
        }
    }
}

private actor RanFlag {
    private(set) var didRun = false
    func mark() { didRun = true }
}

private let emptySchema = AgentJSONValue.object([
    "type": .string("object"), "properties": .object([:]),
    "required": .array([]), "additionalProperties": .bool(false),
])

private func spyTool(
    _ name: String,
    approvalPolicy: AgentToolDescriptor.ApprovalPolicy,
    target: AgentToolDescriptor.Target = .local,
    availableIn: Set<AgentRunMode> = [.planning, .acting],
    ran: RanFlag
) -> AnyAgentTool {
    AnyAgentTool(
        descriptor: AgentToolDescriptor(
            name: name, summary: name, inputSchema: emptySchema,
            target: target, approvalPolicy: approvalPolicy, concurrency: .parallel
        ),
        availableIn: availableIn,
        execute: { invocation, _ in
            await ran.mark()
            return AgentToolResult(callID: invocation.call.id, content: "ok")
        }
    )
}

/// An `ssh_exec` stand-in whose preflight is the real one: the classifier
/// decides its approval policy, exactly as `AgentBuiltInSSHTools` does.
private func execTool(ran: RanFlag) -> AnyAgentTool {
    let schema = AgentJSONValue.object([
        "type": .string("object"),
        "properties": .object(["command": .object(["type": .string("string")])]),
        "required": .array([.string("command")]),
        "additionalProperties": .bool(false),
    ])
    return AnyAgentTool(
        descriptor: AgentToolDescriptor(
            name: TermindAgentPolicy.sshExecToolName, summary: "exec",
            inputSchema: schema, target: .host, approvalPolicy: .ask
        ),
        preflight: { invocation in
            let command = invocation.call.arguments.objectValue?["command"]?.stringValue ?? ""
            let risk = CommandRiskClassifier.assess(command).risk
            return AgentToolPreflight(
                invocation: invocation,
                approvalPolicy: risk == .destructive ? .deny : risk == .safe ? .approve : .ask
            )
        },
        execute: { invocation, _ in
            await ran.mark()
            return AgentToolResult(callID: invocation.call.id, content: "ok")
        }
    )
}

private func execTurns(_ command: String) -> [[AgentModelStreamEvent]] {
    let arguments = AgentJSONValue.object(["command": .string(command)]).encodedString
    return [
        [
            .toolCallSnapshot(
                id: "call-0", providerItemID: nil,
                name: TermindAgentPolicy.sshExecToolName, arguments: arguments
            ),
            .finished(.toolCalls),
        ],
        [.textDelta("done"), .finished(.completed)],
    ]
}

private func callingTurns(_ names: [String]) -> [[AgentModelStreamEvent]] {
    [
        names.enumerated().map { index, name in
            .toolCallSnapshot(
                id: "call-\(index)", providerItemID: nil, name: name, arguments: "{}"
            )
        } + [.finished(.toolCalls)],
        [.textDelta("done"), .finished(.completed)],
    ]
}

private func drain(
    tools: [AnyAgentTool], turns: [[AgentModelStreamEvent]], isPlanning: Bool
) async -> [AgentEvent] {
    let runtime = AgentRuntime(
        model: ScriptedPlanTurns(turns), tools: tools,
        approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }),
        hooks: [TermindAgentPolicy.planModeHook(isPlanning: isPlanning)]
    )
    var events: [AgentEvent] = []
    for await event in await runtime.start(
        AgentRunRequest(
            conversationID: UUID(), prompt: "go", permissionMode: .askForApproval,
            isPlanning: isPlanning
        ))
    { events.append(event) }
    return events
}

private func results(_ events: [AgentEvent]) -> [AgentToolResult] {
    events.compactMap {
        guard case .toolFinished(_, let result) = $0 else { return nil }
        return result
    }
}

@Suite
struct AgentPlanModeTests {

    // MARK: - The gate

    @Test
    func planModeRefusesAToolThatChangesSomethingOutsideTermind() async {
        let ran = RanFlag()
        let events = await drain(
            tools: [
                spyTool(
                    "sftp_write", approvalPolicy: .ask,
                    availableIn: [.acting], ran: ran
                )
            ],
            turns: callingTurns(["sftp_write"]), isPlanning: true
        )

        #expect(await ran.didRun == false)
        #expect(results(events).first?.isError == true)
        // A refusal is still a card. Three cards for four calls reads as one
        // having been quietly ignored.
        #expect(events.contains { if case .toolProposed = $0 { true } else { false } })
    }

    @Test
    func theSameToolRunsOnceThePostureIsOff() async {
        let ran = RanFlag()
        _ = await drain(
            tools: [
                spyTool(
                    "sftp_write", approvalPolicy: .ask,
                    availableIn: [.acting], ran: ran
                )
            ],
            turns: callingTurns(["sftp_write"]), isPlanning: false
        )

        #expect(await ran.didRun)
    }

    @Test
    func readsAreUntouchedWhilePlanning() async {
        let ran = RanFlag()
        let events = await drain(
            tools: [spyTool("sftp_read", approvalPolicy: .approve, ran: ran)],
            turns: callingTurns(["sftp_read"]), isPlanning: true
        )

        #expect(await ran.didRun)
        #expect(results(events).first?.isError == false)
    }

    /// The scratch workspace is where a plan is drafted. A planning mode that
    /// cannot write its own plan is not one.
    @Test
    func containedWritesAreAllowedSoThePlanCanBeDrafted() async {
        let ran = RanFlag()
        _ = await drain(
            tools: [spyTool("scratch_edit", approvalPolicy: .approve, ran: ran)],
            turns: callingTurns(["scratch_edit"]), isPlanning: true
        )

        #expect(await ran.didRun)
    }

    // MARK: - Reading a server

    /// Reading state is most of planning, and the classifier fails closed — so
    /// gating `ssh_exec` on "provably safe" refused most of the ways of asking
    /// what a machine is doing. The bar is destructiveness instead; anything
    /// unproven still meets the ordinary approval gate.
    @Test
    func planModeRunsACommandTheClassifierCannotVouchFor() async {
        let ran = RanFlag()
        let events = await drain(
            tools: [execTool(ran: ran)],
            turns: execTurns("vendorctl inspect"), isPlanning: true
        )

        #expect(await ran.didRun)
        #expect(results(events).first?.isError == false)
    }

    @Test
    func planModeRefusesADestructiveCommand() async {
        let ran = RanFlag()
        let events = await drain(
            tools: [execTool(ran: ran)],
            turns: execTurns("rm -rf /var/log/nginx"), isPlanning: true
        )

        #expect(await ran.didRun == false)
        #expect(results(events).first?.isError == true)
    }

    @Test
    func planModeRunsAnOrdinaryRead() async {
        let ran = RanFlag()
        _ = await drain(
            tools: [execTool(ran: ran)], turns: execTurns("df -h"), isPlanning: true
        )

        #expect(await ran.didRun)
    }

    @Test
    func mcpPoliciesRemainAuthoritativeWhilePlanning() async {
        let asked = RanFlag()
        let approved = RanFlag()
        let denied = RanFlag()
        let events = await drain(
            tools: [
                spyTool("mcp_ask", approvalPolicy: .ask, target: .mcp, ran: asked),
                spyTool("mcp_approve", approvalPolicy: .approve, target: .mcp, ran: approved),
                spyTool("mcp_deny", approvalPolicy: .deny, target: .mcp, ran: denied),
            ],
            turns: callingTurns(["mcp_ask", "mcp_approve", "mcp_deny"]),
            isPlanning: true
        )

        #expect(await asked.didRun)
        #expect(await approved.didRun)
        #expect(await denied.didRun == false)
        #expect(results(events).count == 3)
        #expect(results(events).contains { $0.isApprovalPolicyDenied })
    }

    @Test
    @MainActor
    func sshExecPreflightUsesClassifierForApprovalAndConcurrency() async throws {
        let host = Host(name: "Host", host: "host.example")
        let hosts = AgentHostResolver(store: HostLibraryModel(hosts: [host]))
        let pool = AgentConnectionPool(
            configuration: { _ in throw AgentToolError.invalidHost },
            routeFingerprint: { _ in "" },
            openConnection: { _ in throw AgentToolError.invalidHost },
            openSFTP: { _ in throw AgentToolError.invalidHost },
            sweepInterval: nil
        )
        let tool = SSHExecTool(
            authentication: AgentSSHAuthenticationRegistry(resolver: hosts),
            pool: pool,
            background: AgentBackgroundCommands(sweepInterval: nil)
        )

        func invocation(_ command: String) -> AgentToolInvocation {
            AgentToolInvocation(
                runID: UUID(),
                call: AgentToolCall(
                    id: UUID().uuidString,
                    name: TermindAgentPolicy.sshExecToolName,
                    arguments: .object([
                        "host_id": .string(host.id.uuidString),
                        "command": .string(command),
                    ])
                )
            )
        }

        let read = try await tool.preflight(invocation("systemctl status nginx"))
        #expect(read.approvalPolicy == .approve)
        #expect(read.concurrency == .parallel)
        #expect(read.reasons.isEmpty)

        let write = try await tool.preflight(invocation("systemctl restart nginx"))
        #expect(write.approvalPolicy == .ask)
        #expect(write.concurrency == .sequential)
        #expect(!write.reasons.isEmpty)
    }

    /// The commands a plan is usually built from. They are classified locally
    /// as reads, so they can skip approval and run in parallel across hosts.
    @Test
    func ordinaryInspectionCommandsAreProvenReadOnly() {
        let commands = [
            "systemctl list-timers", "systemctl is-enabled nginx",
            "systemctl list-unit-files", "systemctl show-environment",
            "pgrep -a nginx", "findmnt /var", "getent passwd deploy",
            "timedatectl", "resolvectl status", "dpkg-query -l",
            "zcat /var/log/nginx/access.log.2.gz", "tac /var/log/syslog",
        ]

        for command in commands {
            #expect(
                CommandRiskClassifier.assess(command).risk == .safe,
                "\(command) should be read-only"
            )
        }
    }

    /// Membership of the read-only list means *no invocation writes*. These read
    /// in their common form and write in another, so they must stay off it until
    /// they have a rule of their own.
    @Test
    func namesWhoseVerdictDependsOnArgumentsStayOffTheReadOnlyList() {
        #expect(CommandRiskClassifier.assess("swapon /dev/sdb1").risk != .safe)
        #expect(CommandRiskClassifier.assess("rpm -i nginx.rpm").risk != .safe)
        #expect(CommandRiskClassifier.assess("ulimit -n 4096").risk != .safe)
        // And the systemctl subcommands that act are still not reads.
        #expect(CommandRiskClassifier.assess("systemctl restart nginx").risk != .safe)
        #expect(CommandRiskClassifier.assess("systemctl stop nginx").risk == .destructive)
    }

    /// This is what "the plan must be able to suggest" rests on: the tool that
    /// asks the user a question with options is read-only, so it survives the
    /// gate with no special case.
    @Test
    func askingTheUserIsNotBlockedWhilePlanning() async {
        let ran = RanFlag()
        _ = await drain(
            tools: [spyTool("request_user_input", approvalPolicy: .approve, ran: ran)],
            turns: callingTurns(["request_user_input"]), isPlanning: true
        )

        #expect(await ran.didRun)
    }

    /// Blocked by name rather than by approval policy: `manage_tasks` changes
    /// nothing, so the approval gate has no reason to stop it, and it still has no business
    /// running before anything has been agreed to.
    @Test
    func theTaskListIsRefusedWhilePlanningEvenThoughItIsReadOnly() async {
        let ran = RanFlag()
        let events = await drain(
            tools: [
                spyTool(
                    "manage_tasks", approvalPolicy: .approve,
                    availableIn: [.acting], ran: ran
                )
            ],
            turns: callingTurns(["manage_tasks"]), isPlanning: true
        )

        #expect(await ran.didRun == false)
        #expect(results(events).first?.isError == true)
    }

    @Test
    func theTaskListRunsOutsidePlanMode() async {
        let ran = RanFlag()
        _ = await drain(
            tools: [spyTool("manage_tasks", approvalPolicy: .approve, ran: ran)],
            turns: callingTurns(["manage_tasks"]), isPlanning: false
        )

        #expect(await ran.didRun)
    }

    /// A partially-blocked turn must still answer every call it was asked for.
    /// An assistant turn with an unanswered tool call is rejected outright by
    /// every provider on the next request.
    @Test
    func aMixedBatchStillAnswersEveryCall() async {
        let ran = RanFlag()
        let events = await drain(
            tools: [
                spyTool("sftp_read", approvalPolicy: .approve, ran: ran),
                spyTool(
                    "sftp_write", approvalPolicy: .ask,
                    availableIn: [.acting], ran: ran
                ),
            ],
            turns: callingTurns(["sftp_read", "sftp_write"]), isPlanning: true
        )

        #expect(results(events).count == 2)
    }

    // MARK: - Termination

    @Test
    func presentingAPlanEndsTheRun() async {
        let ran = RanFlag()
        let events = await drain(
            tools: [
                spyTool(
                    AgentPlanModeHook.presentPlanToolName,
                    approvalPolicy: .approve, ran: ran
                )
            ],
            turns: callingTurns([AgentPlanModeHook.presentPlanToolName]),
            isPlanning: true
        )

        #expect(await ran.didRun)
        // One turn only. Without `shouldStop` the scripted second turn would
        // have produced a "done" message after the plan.
        let turns = events.filter { if case .turnStarted = $0 { true } else { false } }
        #expect(turns.count == 1)
        #expect(events.contains { $0 == .runState(.completed) })
    }

    /// A plan presented with the mode already off is still a plan the user has
    /// to answer, and continuing past it would act on something nobody agreed to.
    @Test
    func presentingAPlanEndsTheRunOutsidePlanModeToo() async {
        let ran = RanFlag()
        let events = await drain(
            tools: [
                spyTool(
                    AgentPlanModeHook.presentPlanToolName,
                    approvalPolicy: .approve, ran: ran
                )
            ],
            turns: callingTurns([AgentPlanModeHook.presentPlanToolName]),
            isPlanning: false
        )

        let turns = events.filter { if case .turnStarted = $0 { true } else { false } }
        #expect(turns.count == 1)
    }

    // MARK: - The contract

    @Test
    func theContractRidesTheTailAndLeavesTheSystemPromptAlone() {
        let prompt = AgentTranscriptMessage(role: .user, text: "why is root at 99%")
        let context = AgentModelContext(
            systemPrompt: AgentSystemPrompt.default,
            messages: [AgentTranscriptMessage(role: .user, text: "earlier"), prompt],
            tools: []
        )

        let planned = AgentPlanContractInjection(isPlanning: true, before: prompt.id)
            .transform(context)

        // Byte-identical: every provider cache is a prefix cache, so a system
        // prompt that changed with the mode would miss the whole replayed
        // conversation on each toggle.
        #expect(planned.systemPrompt == AgentSystemPrompt.default)
        #expect(planned.messages.count == 3)
        #expect(planned.messages[1].text == AgentPlanContractInjection.contract)
        #expect(planned.messages[2].id == prompt.id)
    }

    @Test
    func theContractIsAbsentWhenNotPlanning() {
        let prompt = AgentTranscriptMessage(role: .user, text: "go")
        let context = AgentModelContext(
            systemPrompt: AgentSystemPrompt.default, messages: [prompt], tools: []
        )

        let unchanged = AgentPlanContractInjection(isPlanning: false, before: prompt.id)
            .transform(context)

        #expect(unchanged.messages.count == 1)
    }

    /// The runtime ships a contract that describes only the built-in tools.
    /// Termind's names hosts, `ssh_exec` and the pull/push route, and that is the
    /// one a Termind run must actually be given — a plan drafted against the
    /// neutral text would not know commands were available.
    @Test
    func theHostsContractIsWhatAPlanningRunReceives() {
        let prompt = AgentTranscriptMessage(role: .user, text: "why is root at 99%")
        let context = AgentModelContext(
            systemPrompt: TermindAgentPolicy.systemPrompt, messages: [prompt], tools: []
        )

        let planned = AgentContextPipeline.chat(
            sessionContext: nil, before: prompt.id, isPlanning: true,
            planContract: TermindAgentPolicy.planContract
        )(context)

        #expect(planned.messages.count == 4)
        #expect(planned.messages[2].text == TermindAgentPolicy.planContract)
        #expect(planned.messages[2].text != AgentPlanContractInjection.contract)
        #expect(planned.messages[2].text.contains("ssh_exec"))
    }

    // MARK: - Task arguments

    @Test
    func aTaskListMustNameOneThingInProgress() throws {
        let two = AgentToolInvocation(
            runID: UUID(),
            call: AgentToolCall(
                id: "c", name: "manage_tasks",
                arguments: .object([
                    "tasks": .array([
                        taskJSON("a", "Check disk", "in_progress"),
                        taskJSON("b", "Read config", "in_progress"),
                    ])
                ])
            )
        )

        #expect(throws: AgentToolError.self) {
            try Arguments(two).agentTasks()
        }
    }

    @Test
    func aTaskListRejectsDuplicateIDs() throws {
        let duplicated = AgentToolInvocation(
            runID: UUID(),
            call: AgentToolCall(
                id: "c", name: "manage_tasks",
                arguments: .object([
                    "tasks": .array([
                        taskJSON("a", "Check disk", "pending"),
                        taskJSON("a", "Read config", "pending"),
                    ])
                ])
            )
        )

        #expect(throws: AgentToolError.self) {
            try Arguments(duplicated).agentTasks()
        }
    }

    @Test
    func aWellFormedTaskListParsesInOrder() throws {
        let valid = AgentToolInvocation(
            runID: UUID(),
            call: AgentToolCall(
                id: "c", name: "manage_tasks",
                arguments: .object([
                    "tasks": .array([
                        taskJSON("a", "Check disk", "completed"),
                        taskJSON("b", "Read config", "in_progress"),
                        taskJSON("c", "Propose a fix", "pending"),
                    ])
                ])
            )
        )

        let tasks = try Arguments(valid).agentTasks()

        #expect(tasks.map(\.id) == ["a", "b", "c"])
        #expect(tasks[1].status == .inProgress)
    }

    private func taskJSON(_ id: String, _ title: String, _ status: String) -> AgentJSONValue {
        .object([
            "id": .string(id), "title": .string(title), "status": .string(status),
        ])
    }
}
