// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

/// Privacy-bounded audit history for tools invoked through the local MCP server.
/// It consumes the existing ordered event channel, but deliberately reconstructs
/// only metadata. Tool results and file bodies never enter this store.
@MainActor
@Observable
final class ToolAuditModel {
    static let globalLimit = 2_000

    private let repository: any ToolAuditRepository
    private let hostName: (Host.ID) -> String?
    private var clients: [UUID: String] = [:]
    private var rowsByInvocation: [AgentToolInvocation.ID: ExternalToolCall.ID] = [:]
    private var handleHosts: [UUID: (Host.ID, String?)] = [:]
    private var consumer: Task<Void, Never>?
    private(set) var revision: UInt64 = 0
    private(set) var storageError: String?

    init(
        entries: [ExternalToolCall] = [],
        repository: (any ToolAuditRepository)? = nil,
        hostName: @escaping (Host.ID) -> String? = { _ in nil }
    ) {
        self.repository =
            repository
            ?? InMemoryToolAuditRepository(
                entries: Array(
                    entries.sorted { $0.startedAt > $1.startedAt }.prefix(Self.globalLimit)
                )
            )
        self.hostName = hostName
        recoverInterruptedCalls()
    }

    func consume(_ channel: AgentEventChannel) {
        consumer?.cancel()
        consumer = Task { [weak self] in
            for await event in channel.events { self?.receive(event) }
        }
    }

    func register(runID: UUID, clientName: String) {
        clients[runID] = String(clientName.prefix(160))
    }

    func unregister(runID: UUID) { clients[runID] = nil }

    func beginUpload(runID: UUID, clientName: String, hostID: UUID, remotePath: String, overwrite: Bool) -> UUID {
        let row = ExternalToolCall(
            runID: runID, clientName: clientName, toolName: "http_sftp_upload", hostID: hostID,
            hostDisplayName: hostName(hostID), summary: "\(remotePath) [overwrite=\(overwrite)]",
            risk: overwrite ? .destructive : .modifiesState, bytesWritten: 0, startedAt: .now
        )
        insert(row)
        return row.id
    }

    func updateUpload(id: UUID, bytes: Int64, succeeded: Bool? = nil) {
        guard var row = value(id: id) else { return }
        row.bytesRead = Int(bytes)
        row.bytesWritten = Int(bytes)
        if let succeeded {
            row.status = succeeded ? .ok : .error
            row.finishedAt = .now
        }
        update(row)
    }

    func beginDownload(runID: UUID, clientName: String, hostID: UUID, remotePath: String) -> UUID {
        let row = ExternalToolCall(
            runID: runID, clientName: clientName, toolName: "http_sftp_download", hostID: hostID,
            hostDisplayName: hostName(hostID), summary: remotePath, risk: .readOnly,
            bytesRead: 0, startedAt: .now
        )
        insert(row)
        return row.id
    }
    func updateDownload(id: UUID, bytes: Int64, succeeded: Bool? = nil) {
        guard var row = value(id: id) else { return }
        row.bytesRead = Int(bytes)
        if let succeeded {
            row.status = succeeded ? .ok : .error
            row.finishedAt = .now
        }
        update(row)
    }

    func entries(
        matching query: String = "", tool: String? = nil, hostID: Host.ID? = nil
    ) -> [ExternalToolCall] {
        _ = revision
        let values: [ExternalToolCall]
        do {
            values = try repository.entries()
            storageError = nil
        } catch {
            storageError = error.localizedDescription
            return []
        }
        return values.filter { row in
            (tool == nil || row.toolName == tool)
                && (hostID == nil || row.hostID == hostID)
                && (query.isEmpty
                    || row.clientName.localizedCaseInsensitiveContains(query)
                    || row.toolName.localizedCaseInsensitiveContains(query)
                    || row.hostDisplayName?.localizedCaseInsensitiveContains(query) == true
                    || row.summary.localizedCaseInsensitiveContains(query))
        }
    }

    func clear() {
        do {
            try repository.clear()
            rowsByInvocation.removeAll()
            storageError = nil
            revision &+= 1
        } catch {
            storageError = error.localizedDescription
        }
    }

    private func receive(_ event: AgentEvent) {
        switch event {
        case .toolProposed(let invocation, let descriptor):
            begin(invocation, descriptor: descriptor)
        case .toolFinished(let invocation, let result):
            finish(invocation, result: result)
        case .toolProgress(let invocation, let result) where invocation.call.name == TermindToolName.sftpCopy:
            if let id = rowsByInvocation[invocation.id], var row = value(id: id),
                let payload = result.untrustedPayload,
                let object = try? AgentJSONValue.decode(Data(payload.utf8)).objectValue
            {
                row.bytesRead = object["completed_bytes"]?.integerValue
                row.bytesWritten = row.bytesRead
                update(row)
            }
        default:
            break
        }
    }

    private func begin(_ invocation: AgentToolInvocation, descriptor: AgentToolDescriptor) {
        guard rowsByInvocation[invocation.id] == nil else { return }
        var hostID = invocation.targetHostID
        if [
            "ssh_wait", TermindToolName.sshExecOutput, TermindToolName.sshExecStdin,
            TermindToolName.sshExecCancel,
        ].contains(descriptor.name),
            let raw = invocation.call.arguments.objectValue?["handle"]?.stringValue,
            let handle = UUID(uuidString: raw), let mapped = handleHosts[handle]
        {
            hostID = mapped.0
        }
        let row = ExternalToolCall(
            runID: invocation.runID,
            clientName: clients[invocation.runID] ?? String(localized: AppStrings.MCP.unknownMcpClient),
            toolName: descriptor.qualifiedName,
            hostID: hostID,
            hostDisplayName: hostID.flatMap(hostName),
            summary: Self.summary(for: invocation.call),
            risk: Self.risk(for: invocation.call),
            bytesWritten: Self.bytesWritten(for: invocation.call),
            startedAt: invocation.createdAt
        )
        rowsByInvocation[invocation.id] = row.id
        insert(row)
    }

    private func finish(_ invocation: AgentToolInvocation, result: AgentToolResult) {
        guard let rowID = rowsByInvocation.removeValue(forKey: invocation.id),
            var row = value(id: rowID)
        else { return }
        row.status = result.isError ? .error : .ok
        row.finishedAt = .now

        if let payload = result.untrustedPayload,
            let value = try? AgentJSONValue.decode(Data(payload.utf8)),
            let object = value.objectValue
        {
            row.exitCode = object["exit_code"]?.integerValue
            row.bytesRead = object["bytes"]?.integerValue
            if invocation.call.name == TermindToolName.sftpCopy { row.bytesWritten = object["bytes"]?.integerValue }
            if ["ssh_exec", TermindToolName.sshExecRun, TermindToolName.runSnippet].contains(invocation.call.name),
                let raw = object["handle"]?.stringValue, let handle = UUID(uuidString: raw),
                let hostID = row.hostID
            {
                handleHosts[handle] = (hostID, row.hostDisplayName)
            }
            if invocation.call.name == TermindToolName.sshExecCancel,
                let raw = invocation.call.arguments.objectValue?["handle"]?.stringValue,
                let handle = UUID(uuidString: raw)
            {
                handleHosts[handle] = nil
            }
        }
        update(row)
    }

    private func insert(_ value: ExternalToolCall) {
        do {
            try repository.insert(value, limit: Self.globalLimit)
            storageError = nil
            revision &+= 1
        } catch {
            storageError = error.localizedDescription
        }
    }

    private func update(_ value: ExternalToolCall) {
        do {
            try repository.update(value)
            storageError = nil
            revision &+= 1
        } catch {
            storageError = error.localizedDescription
        }
    }

    private func value(id: UUID) -> ExternalToolCall? {
        try? repository.value(id: id)
    }

    private func recoverInterruptedCalls() {
        do {
            try repository.recoverInterruptedCalls()
        } catch {
            storageError = error.localizedDescription
        }
    }

    private static func summary(for call: AgentToolCall) -> String {
        let arguments = call.arguments.objectValue ?? [:]
        func oneLine(_ value: String) -> String {
            value.replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\n", with: "\\n")
        }
        switch call.name {
        case TermindToolName.sftpDownload: return oneLine(arguments["remote_path"]?.stringValue ?? "")
        case TermindToolName.sftpDownloadStatus: return "Download \(arguments["download_id"]?.stringValue ?? "")"
        case TermindToolName.sftpUpload:
            return "\(oneLine(arguments["remote_path"]?.stringValue ?? "")) "
                + "[bytes=\(arguments["byte_count"]?.integerValue ?? 0), "
                + "overwrite=\(arguments["overwrite"]?.boolValue ?? false)]"
        case TermindToolName.sftpUploadStatus: return "Upload \(arguments["upload_id"]?.stringValue ?? "")"
        case "ssh_exec", TermindToolName.sshExecRun, TermindToolName.runSnippet:
            return oneLine(arguments["command"]?.stringValue ?? "")
        case "ssh_wait", TermindToolName.sshExecOutput, TermindToolName.sshExecCancel,
            TermindToolName.sshExecStdin:
            return "Handle \(arguments["handle"]?.stringValue ?? "")"
        case TermindToolName.sftpMove:
            return "\(oneLine(arguments["path"]?.stringValue ?? "")) → "
                + oneLine(arguments["destination"]?.stringValue ?? "")
        case TermindToolName.sftpCopy:
            return "\(arguments["source_host_id"]?.stringValue ?? ""):"
                + "\(oneLine(arguments["source_path"]?.stringValue ?? "")) → "
                + "\(arguments["destination_host_id"]?.stringValue ?? ""):"
                + "\(oneLine(arguments["destination_path"]?.stringValue ?? "")) "
                + "[\(arguments["conflict_policy"]?.stringValue ?? "skip")]"
        case TermindToolName.sftpChmod:
            return "\(oneLine(arguments["path"]?.stringValue ?? "")) "
                + (arguments["mode"]?.stringValue ?? "")
        case let name where name.hasPrefix("sftp_"):
            return oneLine(arguments["path"]?.stringValue ?? "")
        case TermindToolName.listHosts: return String(localized: AppStrings.MCP.listSavedHosts)
        case let name where TermindToolName.managementNames.contains(name):
            return oneLine(
                arguments["label"]?.stringValue ?? arguments["name"]?.stringValue
                    ?? arguments["title"]?.stringValue ?? name)
        default: return ""
        }
    }

    private static func bytesWritten(for call: AgentToolCall) -> Int? {
        guard call.name == TermindToolName.sftpWrite,
            let content = call.arguments.objectValue?["content"]?.stringValue
        else { return nil }
        return content.lengthOfBytes(using: .utf8)
    }

    private static func risk(for call: AgentToolCall) -> ExternalToolCall.Risk {
        if ["ssh_exec", TermindToolName.sshExecRun, TermindToolName.runSnippet].contains(call.name),
            let command = call.arguments.objectValue?["command"]?.stringValue
        {
            switch CommandRiskClassifier.assess(command).risk {
            case .safe: return .readOnly
            case .caution: return .modifiesState
            case .destructive: return .destructive
            }
        }
        if TermindToolName.managementReadOnlyNames.contains(call.name) { return .readOnly }
        if TermindToolName.managementDestructiveNames.contains(call.name) { return .destructive }
        if [
            TermindToolName.listHosts, TermindToolName.getMetrics, "request_user_secret", "ssh_wait",
            TermindToolName.sshExecOutput, TermindToolName.sshExecList, TermindToolName.sshExecCancel,
            TermindToolName.sftpList, TermindToolName.sftpStat, TermindToolName.sftpRead,
            TermindToolName.sftpUploadStatus, TermindToolName.sftpDownload, TermindToolName.sftpDownloadStatus,
        ].contains(call.name) {
            return .readOnly
        }
        let replacingCopy =
            call.name == TermindToolName.sftpCopy
            && call.arguments.objectValue?["conflict_policy"]?.stringValue == "replace"
        return call.name == TermindToolName.sftpDelete || replacingCopy ? .destructive : .modifiesState
    }
}
