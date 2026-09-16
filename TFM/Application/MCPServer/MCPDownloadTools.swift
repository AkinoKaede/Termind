import AgentKit
import Foundation
import TermindApplication

nonisolated struct MCPDownloadTool: AgentToolDefinition, AgentToolSchemaBuilding {
    static let presenter = AgentToolDetailPresenter(id: "termind.sftp_download", present: { _ in [] })
    let downloads: MCPDownloadCoordinator
    var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "sftp_download",
            "Create a ten-minute one-use HTTP download ticket for a single regular remote file. "
                + "Use the returned URL and Authorization header with a separate HTTP GET, not MCP. "
                + "No directories, symlinks, Range, or resume. Save to a client-owned temporary file, then poll "
                + "sftp_download_status to a terminal state and compare local size and SHA-256 before accepting it. "
                + "HTTP 200 alone does not prove success. expected_sha256 is optional. No atomic remote snapshot is promised.",
            properties: [
                "host_id": Self.string(), "remote_path": Self.string(max: 4_096),
                "expected_sha256": Self.string(max: 64),
            ],
            required: ["host_id", "remote_path"], target: .host, approvalPolicy: .ask,
            presentation: .init(
                symbol: "arrow.down.doc", activity: .semanticArgument(key: "remote_path", fallback: .remoteFile),
                output: .json, actionKind: .pull)
        )
    }
    func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
        let request = try MCPDownloadRequest(invocation)
        var checked = invocation
        checked.targetHostID = request.hostID
        return AgentToolPreflight(invocation: checked, approvalPolicy: .ask)
    }
    func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws -> AgentToolResult
    {
        try await Self.result(invocation, downloads.create(invocation))
    }
}

nonisolated struct MCPDownloadStatusTool: AgentToolDefinition, AgentToolSchemaBuilding {
    static let presenter = AgentToolDetailPresenter(id: "termind.sftp_download_status", present: { _ in [] })
    let downloads: MCPDownloadCoordinator
    var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "sftp_download_status",
            "Read this MCP session's download status, sent byte count, actual SHA-256 and safe error. "
                + "Connecting/transferring are not terminal; succeeded means the source and HTTP send completed, not that a client saved the file.",
            properties: ["download_id": Self.string()], required: ["download_id"], target: .local,
            approvalPolicy: .approve,
            concurrency: .parallel,
            presentation: .init(
                symbol: "info.circle", activity: .semanticArgument(key: "download_id", fallback: .remoteFile),
                output: .json, actionKind: .inspect))
    }
    func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws -> AgentToolResult
    {
        let id = try Arguments(invocation).uuid("download_id")
        return try await Self.result(invocation, downloads.status(id: id, runID: invocation.runID))
    }
}
