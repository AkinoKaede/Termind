import AgentKit
import AgentKitScrubber
import Foundation
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind

private actor SurfaceToolExecutionLog {
    private var names: [String] = []

    func record(_ name: String) { names.append(name) }
    func snapshot() -> Set<String> { Set(names) }
}

private actor SurfaceAvailabilityModel: AgentModelStreaming {
    private var turn = 0

    private func nextTurn() -> Int {
        defer { turn += 1 }
        return turn
    }

    nonisolated func stream(
        _ request: AgentModelRequest
    ) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                if await nextTurn() == 0 {
                    for (index, name) in ["terminal_suggest", "ssh_exec_run", "sftp_read"].enumerated() {
                        continuation.yield(
                            .toolCallSnapshot(
                                id: "call-\(index)", providerItemID: nil,
                                name: name, arguments: "{}"))
                    }
                    continuation.yield(.finished(.toolCalls))
                } else {
                    continuation.yield(.textDelta("done"))
                    continuation.yield(.finished(.completed))
                }
                continuation.finish()
            }
        }
    }
}

private func surfaceTool(_ name: String, log: SurfaceToolExecutionLog) -> AnyAgentTool {
    AnyAgentTool(
        descriptor: AgentToolDescriptor(
            name: name, summary: name,
            inputSchema: .object([
                "type": .string("object"), "properties": .object([:]),
                "required": .array([]), "additionalProperties": .bool(false),
            ]),
            target: .host, approvalPolicy: .approve, concurrency: .parallel
        ),
        execute: { invocation, _ in
            await log.record(name)
            return AgentToolResult(callID: invocation.call.id, content: "ok")
        }
    )
}

@Suite
@MainActor
struct AgentBuiltInToolAvailabilityTests {
    @Test
    func termindCatalogHasStableDefinitionsAndExactRunModeSets() async throws {
        let hosts = AgentHostResolver(store: HostLibraryModel())
        let connections = AgentConnectionPool(
            configuration: { _ in throw AgentToolError.invalidHost },
            routeFingerprint: { _ in "" },
            openConnection: { _ in throw AgentToolError.invalidHost },
            openSFTP: { _ in throw AgentToolError.invalidHost },
            sweepInterval: nil
        )
        let workspace = AgentScratchWorkspace(
            conversationID: UUID(), base: FileManager.default.temporaryDirectory
        )

        let catalog = TermindAgentTools.tools(
            in: .init(
                hosts: hosts, metrics: TestMetricsReader(), connections: connections,
                workspace: workspace
            )
        ).map(\.descriptor)

        #expect(catalog.contains { $0.name == "get_metrics" })
        #expect(catalog.contains { $0.name == "terminal_suggest" })

        let registry = AgentToolRegistry(
            TermindAgentTools.tools(
                in: .init(
                    hosts: hosts, metrics: TestMetricsReader(), connections: connections,
                    workspace: workspace
                )
            )
        )
        let planningRegistry = registry.available(in: .planning)
        let actingRegistry = registry.available(in: .acting)
        let planning = Set(planningRegistry.descriptors.map(\.name))
        let acting = Set(actingRegistry.descriptors.map(\.name))
        #expect(registry.available(in: .reviewing).descriptors.isEmpty)
        #expect(
            planning == [
                "get_metrics", "list_hosts", "ssh_exec_run", "ssh_exec_output", "ssh_exec_stdin", "ssh_exec_cancel",
                "ssh_exec_list", "terminal_suggest",
                "sftp_list", "sftp_stat", "sftp_read", "scratch_pull",
            ])
        #expect(
            acting == [
                "get_metrics", "list_hosts", "ssh_exec_run", "ssh_exec_output", "ssh_exec_stdin", "ssh_exec_cancel",
                "ssh_exec_list", "terminal_suggest",
                "sftp_list", "sftp_stat", "sftp_read", "sftp_write", "sftp_mkdir",
                "sftp_move", "sftp_copy", "sftp_chmod", "sftp_delete", "scratch_pull",
                "scratch_push",
            ])
        let exec = try #require(catalog.first { $0.name == "ssh_exec_run" })
        #expect(registry.available(in: .planning).descriptors.first { $0.name == "ssh_exec_run" } == exec)
        #expect(exec.summary.contains("Discover host_id with list_hosts"))
        #expect(exec.summary.contains("Termind handles login"))
        #expect(
            catalog.first { $0.name == "list_hosts" }?.summary.contains("no session context") == true
        )

        let planningExec = try #require(planningRegistry["ssh_exec_run"])
        let actingExec = try #require(actingRegistry["ssh_exec_run"])
        let hostID = UUID()
        func invocation(_ command: String) -> AgentToolInvocation {
            AgentToolInvocation(
                runID: UUID(),
                call: AgentToolCall(
                    id: UUID().uuidString, name: "ssh_exec_run",
                    arguments: .object([
                        "host_id": .string(hostID.uuidString), "command": .string(command),
                    ])))
        }

        let destructive = invocation("rm -rf /var/log/nginx")
        #expect(try await planningExec.preflight(destructive).approvalPolicy == .deny)
        #expect(try await actingExec.preflight(destructive).approvalPolicy == .ask)

        let read = invocation("systemctl status nginx")
        let planningRead = try await planningExec.preflight(read)
        let actingRead = try await actingExec.preflight(read)
        #expect(planningRead.approvalPolicy == .approve)
        #expect(planningRead.concurrency == .parallel)
        #expect(actingRead.approvalPolicy == .approve)
        #expect(actingRead.concurrency == .parallel)
    }

    @Test(arguments: [false, true])
    func contextSnapshotGatesOnlyTerminalSuggestionsAtExecution(terminalSuggestionsAvailable: Bool) async {
        let log = SurfaceToolExecutionLog()
        let runtime = AgentRuntime(
            model: SurfaceAvailabilityModel(),
            tools: [
                surfaceTool("terminal_suggest", log: log),
                surfaceTool("ssh_exec_run", log: log),
                surfaceTool("sftp_read", log: log),
            ],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow })
        )
        var results: [String: AgentToolResult] = [:]
        for await event in await runtime.start(
            AgentRunRequest(
                conversationID: UUID(), prompt: "inspect", permissionMode: .askForApproval,
                contextSnapshot: .init(
                    toolAvailability: ["terminal_suggest": terminalSuggestionsAvailable]))
        ) {
            if case .toolFinished(let invocation, let result) = event {
                results[invocation.call.name] = result
            }
        }

        let executed = await log.snapshot()
        #expect(executed.contains("ssh_exec_run"))
        #expect(executed.contains("sftp_read"))
        #expect(results["ssh_exec_run"]?.isError == false)
        #expect(results["sftp_read"]?.isError == false)
        #expect(executed.contains("terminal_suggest") == terminalSuggestionsAvailable)
        #expect(results["terminal_suggest"]?.isError == !terminalSuggestionsAvailable)
    }

    @Test
    func ordinarySSHNeedsOnlyAHostAndCommand() async throws {
        let hosts = AgentHostResolver(store: HostLibraryModel())
        let pool = AgentConnectionPool(
            configuration: { _ in throw AgentToolError.invalidHost },
            routeFingerprint: { _ in "" },
            openConnection: { _ in throw AgentToolError.invalidHost },
            openSFTP: { _ in throw AgentToolError.invalidHost },
            sweepInterval: nil
        )
        let tool = SSHExecRunTool(
            authentication: AgentSSHAuthenticationRegistry(resolver: hosts), pool: pool,
            background: AgentBackgroundCommands(sweepInterval: nil)
        )
        let hostID = UUID()
        let arguments = AgentJSONValue.object([
            "host_id": .string(hostID.uuidString), "command": .string("uname -a"),
        ])
        let schema = tool.descriptor.inputSchema
        try AgentJSONSchemaValidator.validate(arguments, against: schema)
        #expect(schema.objectValue?["required"]?.arrayValue == [.string("host_id"), .string("command")])
        let properties = try #require(schema.objectValue?["properties"]?.objectValue)
        #expect(Set(properties.keys) == ["host_id", "command", "run_in_background"])
        let checked = try await tool.preflight(
            .init(runID: UUID(), call: .init(id: "inspect", name: "ssh_exec_run", arguments: arguments))
        )
        #expect(checked.invocation.targetHostID == hostID)
        #expect(checked.approvalPolicy == .approve)
    }

    @Test(arguments: [true, false])
    func standaloneContextKeepsHostDiscoveryInstructions(terminalSuggestionsAvailable: Bool) {
        let snapshot = AgentTurnContextSnapshot(
            sessionContext: SessionContext.none.modelContext,
            toolAvailability: ["terminal_suggest": terminalSuggestionsAvailable]
        )
        let context = AgentContextSnapshotReplay().transform(
            .init(
                systemPrompt: TermindAgentPolicy.systemPrompt,
                messages: [.init(role: .user, text: "Inspect my server", contextSnapshot: snapshot)],
                tools: []
            )
        )
        #expect(context.messages.contains { $0.text.contains("no active session") })
        #expect(context.systemPrompt.contains("Use list_hosts to find the requested host"))
        #expect(context.systemPrompt.contains("not the complete catalog"))
        #expect(context.systemPrompt.contains("request_user_secret is not a prerequisite"))
    }

    @Test
    func everyBuiltInToolDeclaresARegisteredDetailPresenter() {
        let hosts = AgentHostResolver(store: HostLibraryModel())
        let connections = AgentConnectionPool(
            configuration: { _ in throw AgentToolError.invalidHost },
            routeFingerprint: { _ in "" },
            openConnection: { _ in throw AgentToolError.invalidHost },
            openSFTP: { _ in throw AgentToolError.invalidHost },
            sweepInterval: nil
        )
        let workspace = AgentScratchWorkspace(
            conversationID: UUID(), base: FileManager.default.temporaryDirectory
        )
        let web = ScrubberWebClient(
            document: { _ in throw AgentWebError.emptyDocument },
            search: { _, _ in [] }
        )
        let descriptors = AgentToolCatalog.registry(
            builtIn: .init(
                workspace: workspace, web: web, search: web,
                plans: AgentPlanRecorder { _ in }
            ),
            additional: TermindAgentTools.tools(
                in: .init(
                    hosts: hosts, metrics: TestMetricsReader(), connections: connections,
                    workspace: workspace
                ))
        ).descriptors

        for descriptor in descriptors where descriptor.target != .mcp {
            let id = descriptor.presentation?.presenterID
            #expect(id != nil, "Missing presenter for \(descriptor.name)")
            if let id {
                #expect(TermindAgentTools.presenter(id: id) != nil)
            }
        }
    }

    /// The point of `AgentToolGroup`: an adopter with no web client and no
    /// skills gets a registry that never names `fetch` or `skill_read_file`, rather
    /// than one that offers them and fails on the first call.
    @Test
    func onlyTheSelectedGroupsReachTheRegistry() throws {
        let workspace = AgentScratchWorkspace(
            conversationID: UUID(), base: FileManager.default.temporaryDirectory
        )
        let web = ScrubberWebClient(
            document: { _ in throw AgentWebError.emptyDocument },
            search: { _, _ in [] }
        )
        let everything = AgentBuiltInToolConfiguration(
            workspace: workspace, web: web, search: web,
            plans: AgentPlanRecorder { _ in },
            skills: AgentSkillCatalog([
                AgentSkill(name: "deploy", summary: "Deploy the app", body: "Steps")
            ])
        )

        var narrowed = everything
        narrowed.groups = [.scratch, .userInteraction]
        let names = Set(AgentToolCatalog.registry(builtIn: narrowed).descriptors.map(\.name))

        #expect(names.contains("scratch_write"))
        #expect(names.contains("request_user_secret"))
        for absent in [
            "fetch", "web_search", "scratch_fetch", "skill_read_file",
            "present_plan",
        ] {
            #expect(!names.contains(absent), "\(absent) survived group selection")
        }

        // Everything the narrowed set dropped is present when its group is.
        let all = Set(AgentToolCatalog.registry(builtIn: everything).descriptors.map(\.name))
        #expect(names.isSubset(of: all))
        #expect(all.isSuperset(of: ["fetch", "web_search", "skill_read_file", "present_plan"]))
    }

    /// A selected group whose dependency is missing contributes nothing. The
    /// alternative — registering `fetch` with no fetcher — puts a tool in front
    /// of the model that can only ever fail.
    @Test
    func aSelectedGroupWithoutItsDependencyRegistersNothing() {
        let names = Set(
            AgentToolCatalog.registry(builtIn: .init(groups: [.web, .scratch, .planning]))
                .descriptors.map(\.name)
        )
        #expect(names.isEmpty)
    }
}
