import Foundation

@MainActor
final class MCPServerTools {
    static let exportedNames: Set<String> = [
        "list_hosts", "request_user_secret", "ssh_exec", "ssh_wait",
        "sftp_list", "sftp_stat", "sftp_read", "sftp_write",
        "sftp_mkdir", "sftp_move", "sftp_chmod", "sftp_delete",
    ]

    private let channel: AgentEventChannel
    private let history: ToolAuditModel
    private let externalAuthentication: ExternalAuthCoordinator
    private let approval: AgentApprovalBroker
    private var registry: AgentToolRegistry

    init(
        hosts: AgentHostResolver,
        connections: AgentConnectionPool,
        authentication: AgentSSHAuthenticationRegistry,
        background: AgentBackgroundCommands,
        externalAuthentication: ExternalAuthCoordinator,
        history: ToolAuditModel,
        disabledTools: Set<String> = []
    ) {
        channel = AgentEventChannel(repository: InMemoryAgentRunRepository())
        self.history = history
        self.externalAuthentication = externalAuthentication
        approval = AgentApprovalBroker(
            reviewer: nil,
            manualApproval: { _ in
                .deny(String(localized: "External tool calls are no longer authorized."))
            },
            event: channel.emit
        )
        registry = Self.makeRegistry(
            hosts: hosts, connections: connections, authentication: authentication,
            background: background, disabledTools: disabledTools
        )
        history.consume(channel)
    }

    var descriptors: [AgentToolDescriptor] { registry.descriptors }

    func contains(_ name: String) -> Bool { registry[name] != nil }

    func replaceDisabledTools(
        _ disabledTools: Set<String>, hosts: AgentHostResolver,
        connections: AgentConnectionPool, authentication: AgentSSHAuthenticationRegistry,
        background: AgentBackgroundCommands
    ) {
        registry = Self.makeRegistry(
            hosts: hosts, connections: connections, authentication: authentication,
            background: background, disabledTools: disabledTools
        )
    }

    func call(
        name: String, arguments: AgentJSONValue, runID: UUID, clientName: String,
        callID: String, secretBroker: SecretBroker
    ) async throws -> AgentToolResult {
        guard registry[name] != nil else { throw MCPServerToolsError.unknownTool(name) }
        history.register(runID: runID, clientName: clientName)
        let executor = AgentToolExecutor(
            tools: registry, approval: approval, hooks: AgentLoopHooks([]),
            channel: channel, secretBroker: secretBroker,
            userInteraction: externalAuthentication.handler(
                clientName: clientName, runID: runID
            ),
            runID: runID, permissionMode: .fullAccess,
            userIntent: "MCP client: \(clientName)"
        )
        let call = AgentToolCall(id: callID, name: name, arguments: arguments)
        return await executor.execute(executor.plan(call))
    }

    func endSession(runID: UUID, secretBroker: SecretBroker) async {
        externalAuthentication.cancel(runID: runID)
        history.unregister(runID: runID)
        await secretBroker.discardAll()
    }

    private static func makeRegistry(
        hosts: AgentHostResolver, connections: AgentConnectionPool,
        authentication: AgentSSHAuthenticationRegistry,
        background: AgentBackgroundCommands, disabledTools: Set<String>
    ) -> AgentToolRegistry {
        AgentToolCatalog.registry(environment: AgentToolEnvironment(
            hosts: hosts, connections: connections, authentication: authentication,
            background: background
        )).filtering {
            exportedNames.contains($0.name) && !disabledTools.contains($0.name)
        }
    }
}

nonisolated enum MCPServerToolsError: LocalizedError, Sendable, Equatable {
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name): String(localized: "Unknown or disabled tool: \(name)")
        }
    }
}
