import Foundation
import TermindApplication
import Testing

@testable import TermindRemoteInfrastructure

@Suite
struct TerminalRouteReporterTests {
    @Test func authenticationEstablishesOnlyTheIncomingPrefixAndMovesTheActiveTarget() throws {
        let first = UUID()
        let second = UUID()
        let destination = UUID()
        let events = RouteSnapshots()
        let reporter = TerminalRouteReporter(hostIDs: [first, second, destination], changed: events.record)
        let attempt = reporter.begin()
        #expect(events.values.last?.establishedHostIDs == [])
        #expect(events.values.last?.activeHostID == first)
        reporter.receive(.authenticating(first), attemptID: attempt)
        #expect(events.values.last?.establishedHostIDs == [])
        reporter.receive(.authenticated(first), attemptID: attempt)
        #expect(events.values.last?.establishedHostIDs == [first])
        #expect(events.values.last?.activeHostID == second)
        #expect(events.values.last?.event == .authenticated(first))
        #expect(events.values.last?.stage == .opening)

        // The first hop's outbound channel completion must not move activity back to that hop.
        reporter.receive(.connected(first), attemptID: attempt)
        #expect(events.values.last?.activeHostID == second)
        reporter.receive(.proxyConnecting(second), attemptID: attempt)
        #expect(events.values.last?.establishedHostIDs == [first])
        reporter.receive(.authenticated(second), attemptID: attempt)
        #expect(events.values.last?.establishedHostIDs == [first, second])
        #expect(events.values.last?.activeHostID == destination)
        reporter.ready(attemptID: attempt)
        #expect(events.values.last?.stage == .ready)
        #expect(events.values.last?.establishedHostIDs == [first, second, destination])
        #expect(events.values.last?.activeHostID == nil)
    }

    @Test func unrelatedOrOutOfOrderEventsCannotInventAnEstablishedPrefix() {
        let first = UUID()
        let second = UUID()
        let events = RouteSnapshots()
        let reporter = TerminalRouteReporter(hostIDs: [first, second], changed: events.record)
        let attempt = reporter.begin()
        reporter.receive(.authenticated(second), attemptID: attempt)
        reporter.receive(.authenticated(UUID()), attemptID: attempt)
        reporter.receive(.authenticated(first), attemptID: UUID())
        #expect(events.values.count == 1)
        reporter.receive(.proxyConnected(first), attemptID: attempt)
        #expect(events.values.last?.establishedHostIDs == [])
    }

    @Test func retirementRejectsLateCallbacksAndRetriesKeepIncreasingRevisions() throws {
        let hop = UUID()
        let events = RouteSnapshots()
        let reporter = TerminalRouteReporter(hostIDs: [hop, UUID()], changed: events.record)
        let old = reporter.begin()
        reporter.receive(.authenticated(hop), attemptID: old)
        reporter.retire(attemptID: old)
        let retired = try #require(events.values.last)
        #expect(retired.stage == .unavailable)
        #expect(retired.establishedHostIDs.isEmpty)
        reporter.receive(.connected(hop), attemptID: old)
        reporter.ready(attemptID: old)
        #expect(events.values.last == retired)

        let next = reporter.begin()
        #expect(next != old)
        #expect(events.values.last?.revision == retired.revision + 1)
        #expect(events.values.last?.establishedHostIDs == [])
        let opening = events.values
        reporter.receive(.authenticated(hop), attemptID: old)
        reporter.retire(attemptID: old)
        reporter.ready(attemptID: old)
        #expect(events.values == opening)
        reporter.receive(.authenticated(hop), attemptID: next)
        #expect(events.values.last?.establishedHostIDs == [hop])
        #expect(events.values.last?.attemptID == next)
        #expect(events.values.map(\.revision) == Array(1...UInt64(events.values.count)))
    }

    @Test func closeInvalidatesTheCurrentRouteAndCannotBeReopened() throws {
        let host = UUID()
        let events = RouteSnapshots()
        let reporter = TerminalRouteReporter(hostIDs: [host], changed: events.record)
        let attempt = reporter.begin()
        reporter.ready(attemptID: attempt)
        reporter.close()
        let retired = try #require(events.values.last)
        #expect(retired.stage == .unavailable)
        #expect(retired.establishedHostIDs.isEmpty)
        let lateAttempt = reporter.begin()
        reporter.receive(.authenticated(host), attemptID: attempt)
        reporter.ready(attemptID: attempt)
        reporter.ready(attemptID: lateAttempt)
        reporter.retire(attemptID: attempt)
        reporter.close()
        #expect(events.values.last == retired)
        #expect(events.values.count == 3)
    }
}

private nonisolated final class RouteSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [TerminalRouteSnapshot] = []
    var values: [TerminalRouteSnapshot] { lock.withLock { snapshots } }
    func record(_ snapshot: TerminalRouteSnapshot) { lock.withLock { snapshots.append(snapshot) } }
}
