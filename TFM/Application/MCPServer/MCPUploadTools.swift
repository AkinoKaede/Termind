import AgentKit
import Foundation
import TermindApplication

nonisolated struct MCPUploadTool: AgentToolDefinition, AgentToolSchemaBuilding {
    static let presenter = AgentToolDetailPresenter(id: "termind.sftp_upload", present: { _ in [] })
    let uploads: MCPUploadCoordinator
    var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "sftp_upload",
            "Create a resumable HTTP-to-SFTP upload ticket for a single file. Send the local file bytes with a separate "
                + "HTTP PUT using the returned URL and headers, not through MCP. Requires byte count and SHA-256. "
                + "The parent directory must exist. Defaults to no overwrite. Tickets expire after ten minutes; "
                + "poll sftp_upload_status after an interruption. When paused, PUT only the suffix from upload_offset, "
                + "set Upload-Offset to that value and Content-Length to the remaining size. "
                + "One request at a time; succeeded means committed and must not be uploaded again. "
                + "Resume requires the same live MCP session and application process.",
            properties: [
                "host_id": Self.string(), "remote_path": Self.string(max: 4_096),
                "byte_count": Self.integer(min: 0, max: MCPUploadRequest.maximumBytes),
                "sha256": Self.string(max: 64), "overwrite": Self.boolean(),
            ], required: ["host_id", "remote_path", "byte_count", "sha256"],
            target: .host, approvalPolicy: .ask,
            presentation: .init(
                symbol: "arrow.up.doc", activity: .semanticArgument(key: "remote_path", fallback: .remoteFile),
                output: .json, actionKind: .push
            )
        )
    }

    func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
        let request = try MCPUploadRequest(invocation)
        var checked = invocation
        checked.targetHostID = request.hostID
        return AgentToolPreflight(invocation: checked, approvalPolicy: .ask)
    }

    func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws -> AgentToolResult
    {
        try await Self.result(invocation, uploads.create(invocation))
    }
}

nonisolated struct MCPUploadStatusTool: AgentToolDefinition, AgentToolSchemaBuilding {
    static let presenter = AgentToolDetailPresenter(id: "termind.sftp_upload_status", present: { _ in [] })
    let uploads: MCPUploadCoordinator
    var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "sftp_upload_status",
            "Read upload status and the acknowledged upload_offset. Resume only when paused; poll succeeded after a lost response.",
            properties: ["upload_id": Self.string()], required: ["upload_id"],
            target: .local, approvalPolicy: .approve, concurrency: .parallel,
            presentation: .init(
                symbol: "info.circle", activity: .semanticArgument(key: "upload_id", fallback: .remoteFile),
                output: .json, actionKind: .inspect
            )
        )
    }

    func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws -> AgentToolResult
    {
        let id = try Arguments(invocation).uuid("upload_id")
        return try await Self.result(invocation, uploads.status(id: id, runID: invocation.runID))
    }
}
