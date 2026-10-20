// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public nonisolated struct ExternalToolCall: Identifiable, Hashable, Sendable {
    public nonisolated enum Risk: String, Hashable, Sendable, Codable {
        case readOnly, modifiesState, destructive

        public var label: String {
            switch self {
            case .readOnly: String(localized: "Read-only")
            case .modifiesState: String(localized: "Modifies state")
            case .destructive: String(localized: "Destructive")
            }
        }
    }

    public nonisolated enum Status: String, Hashable, Sendable, Codable {
        case running, ok, error, denied
    }

    public var id: UUID = UUID()
    public var runID: UUID
    public var clientName: String
    public var toolName: String
    public var hostID: Host.ID?
    public var hostDisplayName: String?
    public var summary: String
    public var risk: Risk
    public var status: Status = .running
    public var exitCode: Int?
    public var bytesRead: Int?
    public var bytesWritten: Int?
    public var startedAt: Date
    public var finishedAt: Date?

    public var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(startedAt) }
    }
    public init(
        id: UUID = UUID(), runID: UUID, clientName: String, toolName: String, hostID: Host.ID? = nil,
        hostDisplayName: String? = nil, summary: String, risk: Risk, status: Status = .running, exitCode: Int? = nil,
        bytesRead: Int? = nil, bytesWritten: Int? = nil, startedAt: Date, finishedAt: Date? = nil
    ) {
        self.id = id
        self.runID = runID
        self.clientName = clientName
        self.toolName = toolName
        self.hostID = hostID
        self.hostDisplayName = hostDisplayName
        self.summary = summary
        self.risk = risk
        self.status = status
        self.exitCode = exitCode
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

}
