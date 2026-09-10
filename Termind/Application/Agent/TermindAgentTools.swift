import AgentKit
import Foundation

/// What Termind's own agent tools are built from.
///
/// The runtime's `AgentBuiltInToolConfiguration` covers the tools it ships;
/// this covers ours, which are all about hosts — listing them, running commands
/// on them, moving files to and from them. Tool types stay narrowly injected:
/// the environment is unpacked here and each definition receives only what it
/// uses.
nonisolated struct TermindAgentToolEnvironment: Sendable {
    var metrics: any MetricsSnapshotReading
    var hosts: AgentHostResolver
    var connections: AgentConnectionPool
    var authentication: AgentSSHAuthenticationRegistry
    var background: AgentBackgroundCommands
    var includesTerminalSuggestion: Bool
    /// Shared with the runtime's scratch group. `scratch_pull` and
    /// `scratch_push` are ours rather than the runtime's precisely because they
    /// are the two ends that touch a host, and they must stage into the same
    /// directory `scratch_replace` reads.
    var workspace: AgentScratchWorkspace?

    init(
        hosts: AgentHostResolver,
        metrics: any MetricsSnapshotReading,
        connections: AgentConnectionPool,
        authentication suppliedAuthentication: AgentSSHAuthenticationRegistry? = nil,
        background: AgentBackgroundCommands = AgentBackgroundCommands(),
        includesTerminalSuggestion: Bool = false,
        workspace: AgentScratchWorkspace? = nil
    ) {
        self.metrics = metrics
        self.hosts = hosts
        self.connections = connections
        authentication =
            suppliedAuthentication ?? AgentSSHAuthenticationRegistry(resolver: hosts)
        self.background = background
        self.includesTerminalSuggestion = includesTerminalSuggestion
        self.workspace = workspace
    }
}

/// Termind's own agent tool catalog, registered alongside the runtime's.
///
/// It exists for the same reason the runtime's does: one registration point per
/// type, supplying both the executable definition and the presenter a persisted
/// card is redrawn from years later.
nonisolated enum TermindAgentTools {
    typealias Registration = AgentToolTypeRegistration<TermindAgentToolEnvironment>

    static func tools(in environment: TermindAgentToolEnvironment) -> [AnyAgentTool] {
        definitions.compactMap { $0.tool(in: environment) }
    }

    /// Every presenter that can draw a card in this app, ours after the
    /// runtime's. Built once: the map is immutable and the lookup happens on
    /// every historical card the transcript draws.
    static let presenterRegistry = AgentToolPresenterRegistry(
        AgentToolCatalog.builtInPresenters + definitions.map(\.presenter)
    )

    static func presenter(id: String) -> AgentToolDetailPresenter? {
        presenterRegistry.presenter(id: id)
    }

    /// Cards written before presenter IDs were persisted carry only a tool name.
    ///
    /// Every built-in of that era used the `builtin.` namespace, so the name is
    /// enough — but only for the names that existed then, which is why this is a
    /// closed list rather than a prefix rule. A tool added later has always
    /// recorded its ID.
    static func legacyPresenter(forToolNamed name: String) -> AgentToolDetailPresenter? {
        guard legacyToolNames.contains(name) else { return nil }
        return presenter(id: "builtin.\(name)")
    }

    private static let definitions: [Registration] = [
        .init(GetMetricsTool.self) { GetMetricsTool(hosts: $0.hosts, metrics: $0.metrics) },
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
    ]

    /// Names understood by releases that predate persisted presenter IDs. Both
    /// catalogs' tools appear here, because at that point they were one list.
    private static let legacyToolNames: Set<String> = [
        "list_hosts", "ssh_exec", "ssh_wait", "terminal_suggest",
        "sftp_list", "sftp_stat", "sftp_read", "sftp_write", "sftp_mkdir",
        "sftp_move", "sftp_chmod", "sftp_delete", "fetch", "web_search",
        "request_user_input", "request_user_secret", "scratch_list", "scratch_read",
        "scratch_write", "scratch_edit", "scratch_diff", "scratch_delete",
        "scratch_pull", "scratch_push", "present_plan", "manage_tasks",
    ]
}
