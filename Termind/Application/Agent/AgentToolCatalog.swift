import Foundation

/// Dependencies and surface policy used to materialize the static tool catalog.
/// Tool types remain narrowly injected: the environment is unpacked here and
/// each concrete definition receives only what it uses.
nonisolated struct AgentToolEnvironment: Sendable {
    var hosts: AgentHostResolver
    var connections: AgentConnectionPool
    var authentication: AgentSSHAuthenticationRegistry
    var background: AgentBackgroundCommands
    var web: ScrubberWebClient
    var search: ScrubberWebClient?
    var includesTerminalSuggestion: Bool
    var workspace: AgentScratchWorkspace?
    var tasks: AgentTaskList?
    var plans: AgentPlanRecorder?
    /// The enabled skills, snapshotted for this run. Empty removes `load_skill`
    /// from the registry entirely rather than offering a tool with nothing to
    /// read — the same shape as `search` and the scratch tools.
    var skills: AgentSkillCatalog
    var mcpServers: [(server: MCPServer, bearerToken: String?)]
    var mcpClient: MCPClient

    init(
        hosts: AgentHostResolver,
        connections: AgentConnectionPool,
        authentication suppliedAuthentication: AgentSSHAuthenticationRegistry? = nil,
        background: AgentBackgroundCommands = AgentBackgroundCommands(),
        web: ScrubberWebClient = ScrubberWebClient(),
        search: ScrubberWebClient? = nil,
        includesTerminalSuggestion: Bool = false,
        workspace: AgentScratchWorkspace? = nil,
        tasks: AgentTaskList? = nil,
        plans: AgentPlanRecorder? = nil,
        skills: AgentSkillCatalog = AgentSkillCatalog(),
        mcpServers: [(server: MCPServer, bearerToken: String?)] = [],
        mcpClient: MCPClient = MCPClient()
    ) {
        self.hosts = hosts
        self.connections = connections
        authentication = suppliedAuthentication
            ?? AgentSSHAuthenticationRegistry(resolver: hosts)
        self.background = background
        self.web = web
        self.search = search
        self.includesTerminalSuggestion = includesTerminalSuggestion
        self.workspace = workspace
        self.tasks = tasks
        self.plans = plans
        self.skills = skills
        self.mcpServers = mcpServers
        self.mcpClient = mcpClient
    }
}

/// One type's only registration point. It supplies both executable construction
/// and the trusted presenter retained for historical transcript rendering.
nonisolated struct AgentToolTypeRegistration: Sendable {
    let presenter: AgentToolDetailPresenter
    private let materialize: @Sendable (AgentToolEnvironment) -> AnyAgentTool?

    init<T: AgentToolDefinition>(
        _ type: T.Type,
        make: @escaping @Sendable (AgentToolEnvironment) -> T?
    ) {
        presenter = type.presenter
        materialize = { environment in
            guard let tool = make(environment) else { return nil }
            return AnyAgentTool(
                descriptor: tool.registeredDescriptor,
                preflight: tool.preflight,
                execute: tool.execute
            )
        }
    }

    func tool(in environment: AgentToolEnvironment) -> AnyAgentTool? {
        materialize(environment)
    }
}

/// The application-owned Agent Tool catalog.
///
/// Local definitions appear exactly once below. Runtime MCP discovery joins the
/// same registry after that static list is materialized, but cannot contribute
/// executable presentation code.
nonisolated enum AgentToolCatalog {
    static func registry(environment: AgentToolEnvironment) -> AgentToolRegistry {
        let local = definitions.compactMap { $0.tool(in: environment) }
        let remote = AgentMCPTools.make(
            servers: environment.mcpServers, client: environment.mcpClient
        )
        return AgentToolRegistry(local + remote)
    }

    static var presenterIDs: [String] { definitions.map(\.presenter.id) }

    static func presenter(id: String) -> AgentToolDetailPresenter? { presentersByID[id] }

    static func legacyPresenter(forToolNamed name: String) -> AgentToolDetailPresenter? {
        guard legacyToolNames.contains(name) else { return nil }
        return presenter(id: "builtin.\(name)")
    }

    private static let definitions: [AgentToolTypeRegistration] = [
        .init(ListHostsTool.self) { ListHostsTool(hosts: $0.hosts) },
        .init(SSHExecTool.self) {
            SSHExecTool(
                authentication: $0.authentication, pool: $0.connections,
                background: $0.background
            )
        },
        .init(SSHWaitTool.self) { SSHWaitTool(background: $0.background) },
        .init(TerminalSuggestTool.self) {
            $0.includesTerminalSuggestion ? TerminalSuggestTool() : nil
        },
        .init(SFTPListTool.self) {
            SFTPListTool(authentication: $0.authentication, connections: $0.connections)
        },
        .init(SFTPStatTool.self) {
            SFTPStatTool(authentication: $0.authentication, connections: $0.connections)
        },
        .init(SFTPReadTool.self) {
            SFTPReadTool(authentication: $0.authentication, connections: $0.connections)
        },
        .init(SFTPWriteTool.self) {
            SFTPWriteTool(authentication: $0.authentication, connections: $0.connections)
        },
        .init(SFTPMkdirTool.self) {
            SFTPMkdirTool(authentication: $0.authentication, connections: $0.connections)
        },
        .init(SFTPMoveTool.self) {
            SFTPMoveTool(authentication: $0.authentication, connections: $0.connections)
        },
        .init(SFTPChmodTool.self) {
            SFTPChmodTool(authentication: $0.authentication, connections: $0.connections)
        },
        .init(SFTPDeleteTool.self) {
            SFTPDeleteTool(authentication: $0.authentication, connections: $0.connections)
        },
        .init(FetchTool.self) { FetchTool(web: $0.web) },
        .init(WebSearchTool.self) { environment in
            environment.search.map(WebSearchTool.init(web:))
        },
        .init(RequestUserInputTool.self) { _ in RequestUserInputTool() },
        .init(RequestUserSecretTool.self) { _ in RequestUserSecretTool() },
        .init(ScratchListTool.self) { $0.workspace.map(ScratchListTool.init(workspace:)) },
        .init(ScratchReadTool.self) { $0.workspace.map(ScratchReadTool.init(workspace:)) },
        .init(ScratchSearchTool.self) { $0.workspace.map(ScratchSearchTool.init(workspace:)) },
        .init(ScratchWriteTool.self) { $0.workspace.map(ScratchWriteTool.init(workspace:)) },
        .init(ScratchEditTool.self) { $0.workspace.map(ScratchEditTool.init(workspace:)) },
        .init(ScratchDiffTool.self) { $0.workspace.map(ScratchDiffTool.init(workspace:)) },
        .init(ScratchDeleteTool.self) { $0.workspace.map(ScratchDeleteTool.init(workspace:)) },
        .init(ScratchPullTool.self) { environment in
            environment.workspace.map {
                ScratchPullTool(
                    workspace: $0, pool: environment.connections,
                    authentication: environment.authentication
                )
            }
        },
        .init(ScratchPushTool.self) { environment in
            environment.workspace.map {
                ScratchPushTool(
                    workspace: $0, pool: environment.connections,
                    authentication: environment.authentication
                )
            }
        },
        .init(ScratchFetchTool.self) { environment in
            environment.workspace.map { ScratchFetchTool(workspace: $0, web: environment.web) }
        },
        .init(PresentPlanTool.self) { environment in
            guard let workspace = environment.workspace, let plans = environment.plans else {
                return nil
            }
            return PresentPlanTool(workspace: workspace, plans: plans)
        },
        .init(ManageTasksTool.self) { environment in
            environment.tasks.map(ManageTasksTool.init(tasks:))
        },
        .init(LoadSkillTool.self) { environment in
            environment.skills.isEmpty ? nil : LoadSkillTool(skills: environment.skills)
        },
    ]

    private static let presentersByID: [String: AgentToolDetailPresenter] = {
        var result: [String: AgentToolDetailPresenter] = [:]
        for presenter in definitions.map(\.presenter) {
            precondition(result[presenter.id] == nil, "Duplicate detail presenter ID: \(presenter.id)")
            result[presenter.id] = presenter
        }
        return result
    }()

    /// Names understood by releases that predate persisted presenter IDs.
    private static let legacyToolNames: Set<String> = [
        "list_hosts", "ssh_exec", "ssh_wait", "terminal_suggest",
        "sftp_list", "sftp_stat", "sftp_read", "sftp_write", "sftp_mkdir",
        "sftp_move", "sftp_chmod", "sftp_delete", "fetch", "web_search",
        "request_user_input", "request_user_secret", "scratch_list", "scratch_read",
        "scratch_write", "scratch_edit", "scratch_diff", "scratch_delete",
        "scratch_pull", "scratch_push", "present_plan", "manage_tasks",
    ]
}
