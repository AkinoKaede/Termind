// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

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
    public var management: AgentResourceManager?

    public init(
        hosts: AgentHostResolver,
        metrics: any MetricsSnapshotReading,
        connections: AgentConnectionPool,
        authentication suppliedAuthentication: AgentSSHAuthenticationRegistry? = nil,
        background: AgentBackgroundCommands = AgentBackgroundCommands(),
        scope: UUID = UUID(),
        workspace: AgentScratchWorkspace? = nil,
        panes: AgentPaneAccess? = nil,
        management: AgentResourceManager? = nil
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
        self.management = management
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
            + HostManagementTools.tools(in: environment)
            + MetricsManagementTools.tools(in: environment)
            + (environment.management.map(ResourceManagementTool.tools) ?? [])
    }

    /// Every presenter that can draw a card in this app, ours after the
    /// runtime's. Built once: the map is immutable and the lookup happens on
    /// every historical card the transcript draws.
    public static let presenterRegistry = AgentToolPresenterRegistry(
        AgentToolCatalog.builtInPresenters + definitions.map(\.presenter)
            + HostManagementTools.presenters + MetricsManagementTools.presenters + [ResourceManagementTool.presenter]
    )

    public static func presenter(id: String) -> AgentToolDetailPresenter? {
        presenterRegistry.presenter(id: id)
    }

    public static func presenter(for descriptor: AgentToolDescriptor) -> AgentToolDetailPresenter? {
        guard descriptor.target != .mcp, let id = descriptor.presentation?.presenterID else { return nil }
        return presenter(id: id)
    }

    private static let definitions: [Registration] = [
        .init(ListPanesTool.self) { $0.panes.map(ListPanesTool.init) },
        .init(ReadPaneTool.self) { $0.panes.map(ReadPaneTool.init) },
        .init(RunSnippetTool.self, availableIn: [.acting]) { environment in
            environment.management.map {
                RunSnippetTool(
                    manager: $0,
                    base: SSHExecRunTool(
                        authentication: environment.authentication, pool: environment.connections,
                        background: environment.background, scope: environment.scope),
                    planning: false)
            }
        },
        .init(RunSnippetTool.self, availableIn: [.planning]) { environment in
            environment.management.map {
                RunSnippetTool(
                    manager: $0,
                    base: SSHExecRunTool(
                        authentication: environment.authentication, pool: environment.connections,
                        background: environment.background, scope: environment.scope),
                    planning: true)
            }
        },
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
}
