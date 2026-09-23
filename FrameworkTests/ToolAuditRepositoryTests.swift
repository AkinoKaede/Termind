import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

@Suite
@MainActor
struct ToolAuditRepositoryTests {
    @Test
    func inMemoryRepositoryPreservesAuditBehavior() throws {
        let repository = InMemoryToolAuditRepository()
        let recoveryRepository = InMemoryToolAuditRepository()

        try exerciseStorageBehavior(repository: repository, freshRepository: { repository })
        try exerciseRecoveryBehavior(repository: recoveryRepository, freshRepository: { recoveryRepository })
    }

    @Test
    func swiftDataRepositoryPersistsAuditBehavior() throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let repository = SwiftDataToolAuditRepository(context: ModelContext(container))

        try exerciseStorageBehavior(
            repository: repository,
            freshRepository: { SwiftDataToolAuditRepository(context: ModelContext(container)) }
        )
        try exerciseRecoveryBehavior(
            repository: SwiftDataToolAuditRepository(context: ModelContext(container)),
            freshRepository: { SwiftDataToolAuditRepository(context: ModelContext(container)) }
        )
    }

    private func exerciseStorageBehavior(
        repository: any ToolAuditRepository,
        freshRepository: () -> any ToolAuditRepository
    ) throws {
        let oldest = call(summary: "oldest", startedAt: 10)
        let newest = call(summary: "newest", startedAt: 30)
        var middle = call(summary: "middle", startedAt: 20)

        try repository.insert(oldest, limit: 2)
        try repository.insert(middle, limit: 2)
        try repository.insert(newest, limit: 2)

        let reloaded = freshRepository()
        #expect(try reloaded.entries().map(\.id) == [newest.id, middle.id])
        #expect(try reloaded.value(id: oldest.id) == nil)

        middle.summary = "updated"
        middle.status = .ok
        middle.finishedAt = Date(timeIntervalSince1970: 25)
        try reloaded.update(middle)

        let storedMiddle = try freshRepository().value(id: middle.id)
        let updated = try #require(storedMiddle)
        #expect(updated == middle)

        try reloaded.clear()
        #expect(try freshRepository().entries().isEmpty)
    }

    private func exerciseRecoveryBehavior(
        repository: any ToolAuditRepository,
        freshRepository: () -> any ToolAuditRepository
    ) throws {
        let running = call(summary: "running", status: .running, startedAt: 100)
        let okFinishedAt = Date(timeIntervalSince1970: 210)
        let errorFinishedAt = Date(timeIntervalSince1970: 220)
        let deniedFinishedAt = Date(timeIntervalSince1970: 230)
        let ok = call(summary: "ok", status: .ok, startedAt: 200, finishedAt: okFinishedAt)
        let error = call(summary: "error", status: .error, startedAt: 201, finishedAt: errorFinishedAt)
        let denied = call(summary: "denied", status: .denied, startedAt: 202, finishedAt: deniedFinishedAt)

        for value in [running, ok, error, denied] {
            try repository.insert(value, limit: 10)
        }
        try repository.recoverInterruptedCalls()

        let reloaded = freshRepository()
        let storedRunning = try reloaded.value(id: running.id)
        let recoveredRunning = try #require(storedRunning)
        #expect(recoveredRunning.status == .error)
        #expect(recoveredRunning.finishedAt != nil)

        let storedOK = try reloaded.value(id: ok.id)
        let unchangedOK = try #require(storedOK)
        #expect(unchangedOK == ok)
        let storedError = try reloaded.value(id: error.id)
        let unchangedError = try #require(storedError)
        #expect(unchangedError == error)
        let storedDenied = try reloaded.value(id: denied.id)
        let unchangedDenied = try #require(storedDenied)
        #expect(unchangedDenied == denied)
    }

    private func call(
        summary: String,
        status: ExternalToolCall.Status = .running,
        startedAt: TimeInterval,
        finishedAt: Date? = nil
    ) -> ExternalToolCall {
        ExternalToolCall(
            runID: UUID(), clientName: "Client", toolName: "list_hosts",
            summary: summary, risk: .readOnly, status: status,
            startedAt: Date(timeIntervalSince1970: startedAt), finishedAt: finishedAt
        )
    }
}
