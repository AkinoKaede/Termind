// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindRemoteInfrastructure

/// Shared metadata only; each direction owns claims, cancellation, and transfer tasks.
struct MCPTransferTicket {
    var id = UUID()
    var token: String
    var runID: UUID
    var clientName: String
    var invocationID: UUID
    var expiresAt: Date
    var state = "waiting"
    var errorCode: String?
    var finishedAt: Date?
    var cancellation = TransferCancellationToken()
    var cancelRequested = false
    var auditID: UUID?

    init(_ invocation: AgentToolInvocation, clientName: String, now: Date) throws {
        token = try MCPUploadToken.make()
        runID = invocation.runID
        invocationID = invocation.id
        self.clientName = clientName
        expiresAt = now.addingTimeInterval(600)
    }
}

@MainActor
protocol MCPTransferTicketEntry {
    var info: MCPTransferTicket { get }
    var live: Bool { get }
}

extension Dictionary where Key == UUID, Value: MCPTransferTicketEntry {
    func hasTransferActivity(runID: UUID, at date: Date) -> Bool {
        values.contains {
            $0.info.runID == runID
                && ($0.live || ($0.info.state == "paused" && $0.info.expiresAt > date)
                    || ($0.info.auditID != nil && $0.info.finishedAt.map { date.timeIntervalSince($0) < 1_800 } == true))
        }
    }

    func expiredTransferIDs(at date: Date) -> [UUID] {
        values.filter { ($0.info.state == "waiting" || $0.info.state == "paused") && $0.info.expiresAt <= date }.map(
            \.info.id)
    }

    mutating func pruneTransferCompletions(at date: Date) {
        let finished = values.compactMap { ticket in ticket.info.finishedAt.map { (ticket.info.id, $0) } }
            .sorted { $0.1 > $1.1 }
        for (index, entry) in finished.enumerated() where index >= 256 || date.timeIntervalSince(entry.1) >= 1_800 {
            self[entry.0] = nil
        }
    }
}
