// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import Testing

@testable import Termind

@Suite @MainActor
struct MCPTransferTicketTests {
    private let date = Date(timeIntervalSince1970: 1_000_000)

    @Test
    func ticketMetadataBindsTheInvocationAndExpiresAtExactlyTenMinutes() throws {
        let invocation = AgentToolInvocation(
            runID: UUID(), call: AgentToolCall(id: "ticket", name: "sftp_upload", arguments: .object([:])))
        let first = try MCPTransferTicket(invocation, clientName: "Client", now: date)
        let second = try MCPTransferTicket(invocation, clientName: "Client", now: date)
        #expect(first.runID == invocation.runID)
        #expect(first.invocationID == invocation.id)
        #expect(first.clientName == "Client")
        #expect(first.id != second.id)
        #expect(first.token != second.token)
        #expect(first.expiresAt == date.addingTimeInterval(600))
        #expect(first.state == "waiting")
        #expect(first.finishedAt == nil)
    }

    @Test(arguments: ["waiting", "paused", "connecting", "transferring", "cleaning", "succeeded"])
    func expiryOnlySelectsUnclaimedOrPausedTicketsAtTheBoundary(state: String) throws {
        let entry = try ticket(state: state)
        let tickets = [entry.info.id: entry]
        #expect(tickets.expiredTransferIDs(at: entry.info.expiresAt.addingTimeInterval(-0.001)).isEmpty)
        let expired = tickets.expiredTransferIDs(at: entry.info.expiresAt)
        #expect(expired == ((state == "waiting" || state == "paused") ? [entry.info.id] : []))
    }

    @Test
    func activityRequiresTheOwningSessionAndRetainedAuditedCompletion() throws {
        var entry = try ticket(state: "succeeded")
        entry.info.finishedAt = date
        var tickets = [entry.info.id: entry]
        #expect(!tickets.hasTransferActivity(runID: entry.info.runID, at: date))
        entry.info.auditID = UUID()
        tickets[entry.info.id] = entry
        #expect(!tickets.hasTransferActivity(runID: UUID(), at: date))
        #expect(tickets.hasTransferActivity(runID: entry.info.runID, at: date.addingTimeInterval(1_799.999)))
        #expect(!tickets.hasTransferActivity(runID: entry.info.runID, at: date.addingTimeInterval(1_800)))
        entry.info.state = "cleaning"
        entry.info.finishedAt = nil
        tickets[entry.info.id] = entry
        #expect(tickets.hasTransferActivity(runID: entry.info.runID, at: date.addingTimeInterval(9_000)))
        entry.info.state = "paused"
        tickets[entry.info.id] = entry
        #expect(
            tickets.hasTransferActivity(runID: entry.info.runID, at: entry.info.expiresAt.addingTimeInterval(-0.001)))
        #expect(!tickets.hasTransferActivity(runID: entry.info.runID, at: entry.info.expiresAt))
    }

    @Test
    func retentionRemovesOldestCompletionsAndPreservesLiveTickets() throws {
        var tickets: [UUID: Entry] = [:]
        var ids: [UUID] = []
        for index in 0..<260 {
            var entry = try ticket(state: "succeeded")
            entry.info.finishedAt = date.addingTimeInterval(Double(index))
            tickets[entry.info.id] = entry
            ids.append(entry.info.id)
        }
        let live = try ticket(state: "cleaning")
        tickets[live.info.id] = live
        tickets.pruneTransferCompletions(at: date.addingTimeInterval(300))
        #expect(tickets.count == 257)
        #expect(ids.prefix(4).allSatisfy { tickets[$0] == nil })
        #expect(ids.dropFirst(4).allSatisfy { tickets[$0] != nil })
        tickets.pruneTransferCompletions(at: date.addingTimeInterval(1_804))
        #expect(tickets[ids[4]] == nil)
        #expect(tickets[ids[5]] != nil)
        #expect(tickets[live.info.id] != nil)
    }

    private func ticket(state: String) throws -> Entry {
        let invocation = AgentToolInvocation(
            runID: UUID(), call: AgentToolCall(id: "ticket", name: "sftp_upload", arguments: .object([:])))
        var info = try MCPTransferTicket(invocation, clientName: "Client", now: date)
        info.state = state
        return Entry(info: info)
    }

    private struct Entry: MCPTransferTicketEntry {
        var info: MCPTransferTicket
        var live: Bool { ["connecting", "transferring", "cleaning"].contains(info.state) }
    }
}
