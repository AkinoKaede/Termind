import AgentKit
import Foundation
import TermindApplication

/// What Termind's own agent tools are built from.
///
/// The runtime's `AgentBuiltInToolConfiguration` covers the tools it ships;
/// this covers ours, which are all about hosts — listing them, running commands
/// on them, moving files to and from them. Tool types stay narrowly injected:
/// the environment is unpacked here and each definition receives only what it
/// uses.
nonisolated public struct TermindAgentToolEnvironment: Sendable {
    public var metrics: any MetricsSnapshotReading
    public var hosts: AgentHostResolver
    public var connections: AgentConnectionPool
    public var authentication: AgentSSHAuthenticationRegistry
    public var scope: UUID
    public var background: AgentBackgroundCommands
    /// Shared with the runtime's scratch group. `scratch_pull` and
    /// `scratch_push` are ours rather than the runtime's precisely because they
    /// are the two ends that touch a host, and they must stage into the same
    /// directory `scratch_replace` reads.
    public var workspace: AgentScratchWorkspace?
    public var panes: AgentPaneAccess?

    public init(
        hosts: AgentHostResolver,
        metrics: any MetricsSnapshotReading,
        connections: AgentConnectionPool,
        authentication suppliedAuthentication: AgentSSHAuthenticationRegistry? = nil,
        background: AgentBackgroundCommands = AgentBackgroundCommands(),
        scope: UUID = UUID(),
        workspace: AgentScratchWorkspace? = nil,
        panes: AgentPaneAccess? = nil
    ) {
        self.metrics = metrics
        self.hosts = hosts
        self.connections = connections
        authentication =
            suppliedAuthentication ?? AgentSSHAuthenticationRegistry(resolver: hosts)
        self.background = background
        self.scope = scope
        self.workspace = workspace
        self.panes = panes
    }
}

/// Termind's own agent tool catalog, registered alongside the runtime's.
///
/// It exists for the same reason the runtime's does: one registration point per
/// type, supplying both the executable definition and the presenter a persisted
/// card is redrawn from years later.
nonisolated public enum TermindAgentTools {
    public typealias Registration = AgentToolTypeRegistration<TermindAgentToolEnvironment>

    public static func tools(in environment: TermindAgentToolEnvironment) -> [AnyAgentTool] {
        definitions.compactMap { $0.tool(in: environment) }
    }

    /// Every presenter that can draw a card in this app, ours after the
    /// runtime's. Built once: the map is immutable and the lookup happens on
    /// every historical card the transcript draws.
    public static let presenterRegistry = AgentToolPresenterRegistry(
        AgentToolCatalog.builtInPresenters + definitions.map(\.presenter) + [
            .init(
                id: "builtin.ssh_exec", present: SSHCommandPresentation.present,
                presentArguments: SSHExecRunTool.presentArguments),
            .init(
                id: "builtin.ssh_wait", present: SSHCommandPresentation.present,
                presentArguments: SSHExecResults.handleArguments),
        ]
    )

    public static func presenter(id: String) -> AgentToolDetailPresenter? {
        presenterRegistry.presenter(id: id)
    }

    public static func presenter(for descriptor: AgentToolDescriptor) -> AgentToolDetailPresenter? {
        guard descriptor.target != .mcp else { return nil }
        if let id = descriptor.presentation?.presenterID { return presenter(id: id) }
        return legacyPresenter(forToolNamed: descriptor.name)
    }

    /// Cards written before presenter IDs were persisted carry only a tool name.
    ///
    /// Every built-in of that era used the `builtin.` namespace, so the name is
    /// enough — but only for the names that existed then, which is why this is a
    /// closed list rather than a prefix rule. A tool added later has always
    /// recorded its ID.
    public static func legacyPresenter(forToolNamed name: String) -> AgentToolDetailPresenter? {
        guard legacyToolNames.contains(name) else { return nil }
        return presenter(id: "builtin.\(name)")
    }

    private static let definitions: [Registration] = [
        .init(GetMetricsTool.self) {
            GetMetricsTool(hosts: $0.hosts, metrics: $0.metrics)
        },
        .init(ListHostsTool.self) {
            ListHostsTool(hosts: $0.hosts)
        },
        .init(ListPanesTool.self) { $0.panes.map(ListPanesTool.init) },
        .init(ReadPaneTool.self) { $0.panes.map(ReadPaneTool.init) },
        .init(SSHExecRunTool.self, availableIn: [.acting]) {
            SSHExecRunTool(
                authentication: $0.authentication, pool: $0.connections,
                background: $0.background, scope: $0.scope
            )
        },
        .init(PlanningSSHExecRunTool.self, availableIn: [.planning]) {
            PlanningSSHExecRunTool(
                authentication: $0.authentication, pool: $0.connections,
                background: $0.background, scope: $0.scope
            )
        },
        .init(SSHExecOutputTool.self) { SSHExecOutputTool(background: $0.background, scope: $0.scope) },
        .init(SSHExecStdinTool.self, availableIn: [.acting]) {
            SSHExecStdinTool(background: $0.background, scope: $0.scope)
        },
        .init(PlanningSSHExecStdinTool.self, availableIn: [.planning]) {
            PlanningSSHExecStdinTool(background: $0.background, scope: $0.scope)
        },
        .init(SSHExecCancelTool.self) { SSHExecCancelTool(background: $0.background, scope: $0.scope) },
        .init(SSHExecListTool.self) { SSHExecListTool(background: $0.background, scope: $0.scope) },
        .init(TerminalSuggestTool.self) { _ in
            TerminalSuggestTool()
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
        .init(SFTPWriteTool.self, availableIn: [.acting]) {
            SFTPWriteTool(authentication: $0.authentication, connections: $0.connections)
        },
        .init(SFTPMkdirTool.self, availableIn: [.acting]) {
            SFTPMkdirTool(authentication: $0.authentication, connections: $0.connections)
        },
        .init(SFTPMoveTool.self, availableIn: [.acting]) {
            SFTPMoveTool(authentication: $0.authentication, connections: $0.connections)
        },
        .init(SFTPCopyTool.self, availableIn: [.acting]) {
            SFTPCopyTool(hosts: $0.hosts, authentication: $0.authentication, connections: $0.connections)
        },
        .init(SFTPChmodTool.self, availableIn: [.acting]) {
            SFTPChmodTool(authentication: $0.authentication, connections: $0.connections)
        },
        .init(SFTPDeleteTool.self, availableIn: [.acting]) {
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
        .init(ScratchPushTool.self, availableIn: [.acting]) { environment in
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
        "scratch_pull", "scratch_push", "present_plan", "manage_tasks", "load_skill",
    ]
}
