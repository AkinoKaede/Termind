// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import SwiftData
import TermindDomain

@Model
public final class PersistentExternalToolCall {
    @Attribute(.unique) public var id: UUID = UUID()
    public var runID: UUID = UUID()
    public var clientName = ""
    public var toolName = ""
    public var hostID: UUID?
    public var hostDisplayName: String?
    public var summary = ""
    public var risk = ExternalToolCall.Risk.readOnly.rawValue
    public var status = ExternalToolCall.Status.running.rawValue
    public var exitCode: Int?
    public var bytesRead: Int?
    public var bytesWritten: Int?
    public var startedAt = Date(timeIntervalSince1970: 0)
    public var finishedAt: Date?

    public init(_ value: ExternalToolCall) { apply(value) }

    public func apply(_ value: ExternalToolCall) {
        id = value.id
        runID = value.runID
        clientName = value.clientName
        toolName = value.toolName
        hostID = value.hostID
        hostDisplayName = value.hostDisplayName
        summary = value.summary
        risk = value.risk.rawValue
        status = value.status.rawValue
        exitCode = value.exitCode
        bytesRead = value.bytesRead
        bytesWritten = value.bytesWritten
        startedAt = value.startedAt
        finishedAt = value.finishedAt
    }

    public var value: ExternalToolCall {
        ExternalToolCall(
            id: id, runID: runID, clientName: clientName, toolName: toolName,
            hostID: hostID, hostDisplayName: hostDisplayName, summary: summary,
            risk: ExternalToolCall.Risk(rawValue: risk) ?? .readOnly,
            status: ExternalToolCall.Status(rawValue: status) ?? .error,
            exitCode: exitCode, bytesRead: bytesRead, bytesWritten: bytesWritten,
            startedAt: startedAt, finishedAt: finishedAt
        )
    }
}
