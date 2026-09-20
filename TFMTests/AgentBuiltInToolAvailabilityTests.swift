import AgentKit
import AgentKitScrubber
import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind

@Suite
@MainActor
struct AgentBuiltInToolAvailabilityTests {
    @Test
    func terminalSuggestionDefinitionIsStableAcrossSurfaces() throws {
        let hosts = AgentHostResolver(store: HostLibraryModel())
        let connections = AgentConnectionPool(
            configuration: { _ in throw AgentToolError.invalidHost },
            routeFingerprint: { _ in "" },
            openConnection: { _ in throw AgentToolError.invalidHost },
            openSFTP: { _ in throw AgentToolError.invalidHost },
            sweepInterval: nil
        )

        let mainAssistant = TermindAgentTools.tools(
            in: .init(
                hosts: hosts, metrics: TestMetricsReader(), connections: connections
            )
        ).map(\.descriptor)
        let workspaceSidebar = TermindAgentTools.tools(
            in: .init(
                hosts: hosts, metrics: TestMetricsReader(), connections: connections, includesTerminalSuggestion: true
            )
        ).map(\.descriptor)

        #expect(mainAssistant.contains { $0.name == "get_metrics" })
        #expect(workspaceSidebar.contains { $0.name == "get_metrics" })
        #expect(mainAssistant.contains { $0.name == "terminal_suggest" })
        #expect(mainAssistant == workspaceSidebar)
        #expect(workspaceSidebar.contains { $0.name == "terminal_suggest" })

        let registry = AgentToolRegistry(
            TermindAgentTools.tools(
                in: .init(
                    hosts: hosts, metrics: TestMetricsReader(), connections: connections
                )
            )
        )
        let planning = Set(registry.available(in: .planning).descriptors.map(\.name))
        let acting = Set(registry.available(in: .acting).descriptors.map(\.name))
        #expect(registry.available(in: .reviewing).descriptors.isEmpty)
        #expect(planning.contains("ssh_exec"))
        #expect(!planning.contains("sftp_write"))
        #expect(!planning.contains("sftp_copy"))
        #expect(acting.contains("sftp_copy"))
        #expect(acting.isSuperset(of: ["ssh_exec", "sftp_write"]))
        let exec = try #require(mainAssistant.first { $0.name == "ssh_exec" })
        #expect(registry.available(in: .planning).descriptors.first { $0.name == "ssh_exec" } == exec)
        #expect(exec.summary.contains("discover host_id with list_hosts"))
        #expect(exec.summary.contains("do not call request_user_secret for SSH login"))
        #expect(
            mainAssistant.first { $0.name == "list_hosts" }?.summary.contains("no session context") == true
        )
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
        let tool = SSHExecTool(
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
        #expect(properties["secret_handle"]?.objectValue?["description"]?.stringValue?.contains("Omit when") == true)
        #expect(
            properties["stdin_purpose"]?.objectValue?["description"]?.stringValue?.contains("Omit otherwise") == true
        )
        let checked = try await tool.preflight(
            .init(runID: UUID(), call: .init(id: "inspect", name: "ssh_exec", arguments: arguments))
        )
        #expect(checked.invocation.targetHostID == hostID)
        #expect(checked.approvalPolicy == .approve)
    }

    @Test(arguments: [true, false])
    func standaloneContextKeepsHostDiscoveryInstructions(includesTerminalSuggestion: Bool) {
        let snapshot = AgentTurnContextSnapshot(
            sessionContext: SessionContext.none.modelContext,
            toolAvailability: ["terminal_suggest": includesTerminalSuggestion]
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
                tasks: AgentTaskList { _ in }, plans: AgentPlanRecorder { _ in }
            ),
            additional: TermindAgentTools.tools(
                in: .init(
                    hosts: hosts, metrics: TestMetricsReader(), connections: connections,
                    includesTerminalSuggestion: true, workspace: workspace
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
            tasks: AgentTaskList { _ in }, plans: AgentPlanRecorder { _ in },
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
            "fetch", "web_search", "scratch_fetch", "skill_read_file", "manage_tasks",
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
