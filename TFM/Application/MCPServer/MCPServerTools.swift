import AgentKit
import Foundation
import TermindApplication
import TermindPresentation
import TermindRemoteInfrastructure

@MainActor
final class MCPServerTools {
    static let exportedNames: Set<String> = [
        "list_hosts", "get_metrics", "request_user_secret", "ssh_exec_run", "ssh_exec_output", "ssh_exec_stdin",
        "ssh_exec_cancel", "ssh_exec_list",
        "sftp_list", "sftp_stat", "sftp_read", "sftp_write",
        "sftp_mkdir", "sftp_move", "sftp_copy", "sftp_chmod", "sftp_delete", "sftp_upload", "sftp_upload_status",
        "sftp_download", "sftp_download_status",
    ]

    private let channel: AgentEventChannel
    private let history: ToolAuditModel
    private let externalAuthentication: ExternalAuthCoordinator
    private let approval: AgentApprovalBroker
    private var registry: AgentToolRegistry
    private var registryForScope: (UUID) -> AgentToolRegistry
    private var background: AgentBackgroundCommands
    private var copies: [UUID: [UUID: Task<AgentToolResult, Never>]] = [:]
    let uploads: MCPUploadCoordinator
    let downloads: MCPDownloadCoordinator

    init(
        hosts: AgentHostResolver, metrics: any MetricsSnapshotReading,
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
        let budget = MCPTransferBudget()
        uploads = MCPUploadCoordinator(
            hosts: hosts, history: history, budget: budget,
            cleanup: {
                request, runID, invocationID, clientName in
                let handler = await externalAuthentication.handler(clientName: clientName, runID: runID)
                try await authentication.withSFTP(
                    hostID: request.hostID, invocationID: invocationID, interaction: handler.sshInteraction,
                    pool: connections, cancellation: TransferCancellationToken()
                ) { client in try await request.resume.cleanup(using: client) }
            },
            transfer: {
                request, runID, invocationID, client, read, token, report in
                let handler = await externalAuthentication.handler(clientName: client, runID: runID)
                return try await authentication.withSFTP(
                    hostID: request.hostID, invocationID: invocationID, interaction: handler.sshInteraction,
                    pool: connections, cancellation: token,
                    runID: runID, byteCount: request.byteCount,
                    schedulesDataTransfer: true
                ) { client in
                    try await SFTPStreamUploadOperation.run(
                        client: client, remotePath: request.remotePath, byteCount: request.byteCount,
                        sha256: request.sha256, overwrite: request.overwrite,
                        cancellation: token, resume: request.resume, read: read, progress: report
                    )
                }
            })
        downloads = MCPDownloadCoordinator(hosts: hosts, history: history, budget: budget) {
            request, runID, invocationID, clientName, token, serve in
            let handler = await externalAuthentication.handler(clientName: clientName, runID: runID)
            try await authentication.withSFTP(
                hostID: request.hostID, invocationID: invocationID, interaction: handler.sshInteraction,
                pool: connections, cancellation: token,
                runID: runID, schedulesDataTransfer: true
            ) { client in
                let stream = try await client.openDownloadStream(
                    at: request.remotePath, maximumBytes: Int64(MCPTransferBudget.maximumBytes), cancellation: token
                )
                do { try await serve(stream) } catch {
                    try await stream.close()
                    throw error
                }
                try await stream.close()
            }
        }
        uploads.setEnabled(!disabledTools.contains("sftp_upload"))
        downloads.setEnabled(!disabledTools.contains("sftp_download"))
        approval = AgentApprovalBroker(
            reviewer: nil,
            manualApproval: { _ in
                .deny(String(localized: AppStrings.MCP.externalToolCallsAreNoLongerAuthorized))
            },
            event: channel.emit
        )
        registry = Self.makeRegistry(
            hosts: hosts, metrics: metrics, connections: connections, authentication: authentication,
            background: background, disabledTools: disabledTools, uploads: uploads, downloads: downloads
        )
        self.background = background
        registryForScope = { [uploads, downloads] scope in
            Self.makeRegistry(
                hosts: hosts, metrics: metrics, connections: connections, authentication: authentication,
                background: background, disabledTools: disabledTools, uploads: uploads, downloads: downloads,
                scope: scope)
        }
        history.consume(channel)
    }

    var descriptors: [AgentToolDescriptor] { registry.descriptors }

    func contains(_ name: String) -> Bool { registry[name] != nil }

    func replaceDisabledTools(
        _ disabledTools: Set<String>, hosts: AgentHostResolver, metrics: any MetricsSnapshotReading,
        connections: AgentConnectionPool, authentication: AgentSSHAuthenticationRegistry,
        background: AgentBackgroundCommands
    ) {
        uploads.setEnabled(!disabledTools.contains("sftp_upload"))
        downloads.setEnabled(!disabledTools.contains("sftp_download"))
        registry = Self.makeRegistry(
            hosts: hosts, metrics: metrics, connections: connections, authentication: authentication,
            background: background, disabledTools: disabledTools, uploads: uploads, downloads: downloads
        )
        self.background = background
        registryForScope = { [uploads, downloads] scope in
            Self.makeRegistry(
                hosts: hosts, metrics: metrics, connections: connections, authentication: authentication,
                background: background, disabledTools: disabledTools, uploads: uploads, downloads: downloads,
                scope: scope)
        }
    }

    func call(
        name: String, arguments: AgentJSONValue, runID: UUID, clientName: String,
        callID: String, secretBroker: SecretBroker
    ) async throws -> AgentToolResult {
        guard registry[name] != nil else { throw MCPServerToolsError.unknownTool(name) }
        let registry = registryForScope(runID)
        history.register(runID: runID, clientName: clientName)
        uploads.register(runID: runID, clientName: clientName)
        downloads.register(runID: runID, clientName: clientName)
        let handler = externalAuthentication.handler(clientName: clientName, runID: runID)
        let executor = AgentToolExecutor(
            tools: registry, approval: approval, hooks: AgentLoopHooks([]),
            channel: channel, secretBroker: secretBroker,
            userInteraction: handler,
            services: AgentToolServices()
                .setting(handler.sshInteraction, for: .sshInteraction),
            runID: runID, permissionMode: .fullAccess,
            userIntent: "MCP client: \(clientName)"
        )
        let call = AgentToolCall(id: callID, name: name, arguments: arguments)
        let id = UUID()
        let task = Task { await executor.execute(executor.plan(call)) }
        copies[runID, default: [:]][id] = task
        defer {
            copies[runID]?[id] = nil
            if copies[runID]?.isEmpty == true { copies[runID] = nil }
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func endSession(runID: UUID, secretBroker: SecretBroker) async {
        let tasks = Array(copies.removeValue(forKey: runID)?.values ?? [:].values)
        for task in tasks { task.cancel() }
        uploads.revokeSession(runID: runID)
        downloads.revokeSession(runID: runID)
        await background.close(scope: runID)
        await uploads.endSession(runID: runID)
        await downloads.endSession(runID: runID)
        externalAuthentication.cancel(runID: runID)
        for task in tasks { _ = await task.value }
        await background.close(scope: runID)
        history.unregister(runID: runID)
        await secretBroker.discardAll()
    }

    func configureTransfers(port: UInt16) {
        uploads.configure(port: port)
        downloads.configure(port: port)
    }
    func stopTransfers() async {
        uploads.suspend()
        downloads.suspend()
        await uploads.stop()
        await downloads.stop()
    }
    func revokeHost(_ hostID: UUID) {
        uploads.revokeHost(hostID)
        downloads.revokeHost(hostID)
    }
    func cancelHostTransfers(_ hostID: UUID) async {
        await uploads.cancelHost(hostID)
        await downloads.cancelHost(hostID)
    }
    func hasTransferActivity(runID: UUID) async -> Bool {
        if copies[runID]?.isEmpty == false || uploads.hasUploadActivity(runID: runID)
            || downloads.hasDownloadActivity(runID: runID)
        {
            return true
        }
        return await background.hasActivity(scope: runID)
    }

    private static func makeRegistry(
        hosts: AgentHostResolver, metrics: any MetricsSnapshotReading, connections: AgentConnectionPool,
        authentication: AgentSSHAuthenticationRegistry,
        background: AgentBackgroundCommands, disabledTools: Set<String>, uploads: MCPUploadCoordinator,
        downloads: MCPDownloadCoordinator, scope: UUID = UUID()
    ) -> AgentToolRegistry {
        AgentToolCatalog.registry(
            // `request_user_secret` is the only exported tool the runtime owns;
            // every other name below is Termind's. HTTP uploads have their own
            // session-bound byte channel, not an AgentKit scratch workspace. The rest of the built-in
            // groups are left out rather than filtered out, so an external client
            // cannot reach a scratch workspace or a web fetch that no Termind
            // conversation is backing.
            builtIn: AgentBuiltInToolConfiguration(
                groups: [.userInteraction]
            ),
            additional: TermindAgentTools.tools(
                in: TermindAgentToolEnvironment(
                    hosts: hosts, metrics: metrics, connections: connections, authentication: authentication,
                    background: background, scope: scope
                )) + [
                    AnyAgentTool(MCPUploadTool(uploads: uploads)), AnyAgentTool(MCPUploadStatusTool(uploads: uploads)),
                    AnyAgentTool(MCPDownloadTool(downloads: downloads)),
                    AnyAgentTool(MCPDownloadStatusTool(downloads: downloads)),
                ]
        ).available(in: .acting).filtering {
            exportedNames.contains($0.name) && !disabledTools.contains($0.name)
        }
    }
}

nonisolated enum MCPServerToolsError: LocalizedError, Sendable, Equatable {
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name): String(localized: AppStrings.MCP.unknownOrDisabledTool(name))
        }
    }
}
