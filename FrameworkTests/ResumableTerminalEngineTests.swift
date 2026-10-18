import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import TermindRemoteInfrastructure

@Suite
struct ResumableTerminalEngineTests {
    @Test func routeFactsPassWhileRecoveryIsFrozenWithoutConfirmingProtocolReadiness() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events, gates: ["retry"])
        let client = client(engine, events: events)
        try await connect(client)
        await events.emit(.recovering)
        let retrying = Task { try await client.retryNow() }
        await events.wait(for: "gated:retry")
        let attemptID = UUID()
        await events.emit(.routeChanged(.init(attemptID: attemptID, revision: 1, stage: .opening)))
        await events.emit(.routeChanged(.init(attemptID: attemptID, revision: 2, stage: .ready)))
        #expect(events.values.suffix(2) == ["route:1:opening", "route:2:ready"])
        #expect(events.values.filter { $0.hasPrefix("state:") }.last == "state:recovering")
        await #expect(throws: TerminalTransportError.self) { try await client.write(Data("blocked".utf8)) }
        await engine.release("retry")
        try await retrying.value
        #expect(events.values.filter { $0.hasPrefix("state:") }.last == "state:recovering")
        #expect(events.values.filter { $0 == "prepareRetry" }.count == 1)
        #expect(events.values.filter { $0 == "retry" }.count == 1)
        await events.emit(.connected)
        #expect(events.values.last == "state:connected")
        await client.close()
    }

    @Test func reorderedRouteCallbacksAndClosedClientCannotReviveAnOldRoute() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events)
        let client = client(engine, events: events)
        try await connect(client)
        let old = UUID()
        let next = UUID()
        await events.emit(.routeChanged(.init(attemptID: old, revision: 3, stage: .unavailable)))
        await events.emit(.routeChanged(.init(attemptID: old, revision: 2, stage: .ready)))
        await events.emit(.routeChanged(.init(attemptID: next, revision: 4, stage: .opening)))
        await events.emit(.routeChanged(.init(attemptID: old, revision: 3, stage: .unavailable)))
        #expect(events.values.filter { $0.hasPrefix("route:") } == ["route:3:unavailable", "route:4:opening"])
        await client.close()
        let closed = events.values
        await events.emit(.routeChanged(.init(attemptID: next, revision: 5, stage: .ready)))
        #expect(events.values == closed)
    }

    @Test func recoveryRetryUsesTheExistingEngineWithoutReplayingStartup() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events)
        let client = client(engine, events: events)
        try await connect(client)
        await events.emit(.recovering)
        try await client.retryNow()
        #expect(Array(events.values.suffix(3)) == ["prepareRetry", "retry", "resize:80x24"])
        #expect(events.values.filter { $0 == "prepare" }.count == 1)
        #expect(events.values.filter { $0.hasPrefix("start:") }.count == 1)
        #expect(!events.values.contains(where: { $0.hasPrefix("write:") }))
        await client.close()
        let closedEvents = events.values
        await events.emit(.recovering)
        await events.emit(.connected)
        #expect(events.values == closedEvents)
    }

    @Test func missingRegistrationFailsBeforeWakeOrBootstrapAndClearsFacadeSecrets() async throws {
        let events = EngineEvents()
        let channel = RemoteConnectionCoordinator(transportEngines: .init(factories: [:])).makePTYChannel(
            output: { _ in }, exit: { _ in })
        await channel.configureTransport(
            .mosh, options: options,
            route: { _ in
                events.record("route")
                throw CancellationError()
            }, stateChanged: { _ in })
        await channel.configureStartup { _ in
            events.record("startup")
            return nil
        }
        let password = SSHSecret("one-use")
        var request = request
        request.configuration.credentials = [.password(password)]
        request.configuration.beforeConnect = { events.record("wake") }
        do {
            try await channel.connect(using: request, columns: 80, rows: 24)
            Issue.record("An unregistered transport must fail before attempting SSH")
        } catch TerminalTransportError.unsupportedRoute {
        }
        #expect(events.values.isEmpty)
        #expect(password.isConsumed)
        await channel.disconnect()
    }

    @Test func coordinatorVariantUsesRegisteredEngineAndRestoresWithoutStartupOrRoute() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events)
        let coordinator = RemoteConnectionCoordinator(transportEngines: registry(engine, events: events))
            .withKeyboardInteractive { _ in [] }
        let channel = coordinator.makePTYChannel(
            output: { events.record("output:\(String(decoding: $0, as: UTF8.self))") }, exit: { _ in })
        await channel.configureTransport(
            .mosh, options: options, checkpoint: checkpoint,
            route: { _ in
                events.record("route")
                throw CancellationError()
            }, stateChanged: { events.record("state:\($0)") })
        await channel.configureStartup { _ in
            events.record("startup")
            return nil
        }
        try await channel.connect(using: request, columns: 81, rows: 25)
        #expect(await engine.preparedPayload == checkpoint.payload)
        #expect(await engine.permitsAgentForwarding == false)
        #expect(events.values.contains("start:81x25"))
        #expect(events.values.contains("output:ready"))
        #expect(!events.values.contains("startup"))
        #expect(!events.values.contains("route"))
        await channel.write(Data("hello".utf8))
        await channel.resize(columns: 100, rows: 30, widthPixels: 0, heightPixels: 0)
        await channel.disconnect()
        await channel.disconnect()
        #expect(events.values.contains("write:hello"))
        #expect(events.values.contains("resize:100x30"))
        #expect(events.values.filter { $0 == "close" }.count == 1)
    }

    @Test func suspensionDrainsWritesAndLateActivityCannotUnfreezeTheCheckpoint() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events)
        let client = client(engine, events: events)
        try await connect(client)
        let writing = Task { try await client.write(Data("hold".utf8)) }
        #expect(await eventually { events.values.contains("write:hold") })
        let suspending = Task { try await client.suspend() }
        #expect(
            await eventually {
                do {
                    try await client.write(Data("probe".utf8))
                    return false
                } catch TerminalTransportError.suspended {
                    return true
                } catch {
                    return false
                }
            })
        #expect(!events.values.contains("checkpoint"))
        await events.emit(.connected)
        await events.emit(.activity)
        await events.emit(.output(Data("tail".utf8)))
        await #expect(throws: TerminalTransportError.self) { try await client.write(Data("blocked".utf8)) }
        try await client.resize(columns: 132, rows: 43)
        #expect(!events.values.contains("resize:132x43"))
        await engine.finishWrite()
        try await writing.value
        let saved = try await suspending.value
        #expect(saved.transport == .mosh)
        #expect(saved.payload == Data("saved-state".utf8))
        #expect(events.values.contains("output:tail"))
        #expect(events.values.last == "state:suspended")
        await events.emit(.connected)
        #expect(events.values.last == "state:suspended")
        try await client.retryNow()
        let retry = events.values.suffix(5)
        #expect(Array(retry) == ["prepareRetry", "beforeResume", "state:recovering", "resume", "resize:132x43"])
        try await client.write(Data("after".utf8))
        #expect(events.values.last == "write:after")
        await client.close()
    }

    @Test func resumeCoalescesAndFlushesOnlyTheLatestViewportBeforeIntegrationAndConnected() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events, gates: ["resume"], restoresIntegration: true)
        let client = client(engine, events: events)
        try await connect(client)
        _ = try await client.suspend()
        let resuming = Task { try await client.resume() }
        await events.wait(for: "gated:resume")
        let secondResume = Task { try await client.resume() }
        await events.wait(for: "lifecycle:queued", count: 3)
        try await client.resize(columns: 100, rows: 30)
        try await client.resize(columns: 132, rows: 43)
        await events.emit(.connected)
        await events.emit(.output(Data("__TRMD_RESTORE_SHELL__/bin/bash__\r\n".utf8)))
        await #expect(throws: TerminalTransportError.self) { try await client.write(Data("blocked".utf8)) }
        #expect(!events.values.contains(where: { $0.hasPrefix("resize:") || $0.hasPrefix("write:") }))
        #expect(events.values.filter { $0.hasPrefix("state:") }.last == "state:recovering")

        await engine.release("resume")
        try await resuming.value
        try await secondResume.value
        #expect(events.values.filter { $0 == "resume" }.count == 1)
        #expect(events.values.filter { $0.hasPrefix("resize:") } == ["resize:132x43"])
        let writes = events.values.filter { $0.hasPrefix("write:") }
        #expect(writes.count == 1)
        #expect(writes.first?.contains("TermindCommand=RESTORE") == true)
        let resizeIndex = try #require(events.values.firstIndex(of: "resize:132x43"))
        let writeIndex = try #require(events.values.firstIndex(where: { $0.hasPrefix("write:") }))
        #expect(resizeIndex < writeIndex)
        #expect(events.values.last == "state:connected")
        #expect(!events.values.contains("state:failed"))
        try await client.write(Data("after".utf8))
        #expect(events.values.last == "write:after")
        await client.close()
    }

    @Test func retryDrainsExistingSendsAndCoalescesWhilePreservingBlockedViewportChanges() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events, gates: ["retry"])
        let client = client(engine, events: events)
        try await connect(client)
        let writing = Task { try await client.write(Data("hold".utf8)) }
        await events.wait(for: "write:hold")
        let retrying = Task { try await client.retryNow() }
        await events.wait(for: "lifecycle:queued")
        let secondRetry = Task { try await client.retryNow() }
        await events.wait(for: "lifecycle:queued", count: 2)
        await #expect(throws: TerminalTransportError.self) { try await client.write(Data("blocked".utf8)) }
        try await client.resize(columns: 111, rows: 31)
        #expect(!events.values.contains("prepareRetry"))
        #expect(!events.values.contains("retry"))
        await engine.finishWrite()
        try await writing.value
        await events.wait(for: "gated:retry")
        try await client.resize(columns: 140, rows: 50)
        #expect(!events.values.contains(where: { $0.hasPrefix("resize:") }))
        await events.emit(.connected)
        await engine.release("retry")
        try await retrying.value
        try await secondRetry.value
        #expect(events.values.filter { $0 == "prepareRetry" }.count == 1)
        #expect(events.values.filter { $0 == "retry" }.count == 1)
        #expect(events.values.filter { $0.hasPrefix("resize:") } == ["resize:140x50"])
        #expect(events.values.last == "state:connected")
        #expect(!events.values.contains("state:failed"))
        await client.close()
    }

    @Test func checkpointAndResumeQueueBehindRetryWithoutOpeningSendAdmissionBetweenThem() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events, gates: ["retry", "checkpoint", "resume"])
        let client = client(engine, events: events)
        try await connect(client)
        let retrying = Task { try await client.retryNow() }
        await events.wait(for: "gated:retry")
        let suspending = Task { try await client.suspend() }
        await events.wait(for: "lifecycle:queued", count: 2)
        let resuming = Task { try await client.resume() }
        await events.wait(for: "lifecycle:queued", count: 3)
        #expect(!events.values.contains("checkpoint"))
        #expect(!events.values.contains("resume"))
        await events.emit(.connected)
        await engine.release("retry")
        try await retrying.value
        await events.wait(for: "gated:checkpoint")
        await #expect(throws: TerminalTransportError.self) { try await client.write(Data("blocked".utf8)) }
        #expect(!events.values.contains("resume"))
        await engine.release("checkpoint")
        let saved = try await suspending.value
        #expect(saved.payload == Data("saved-state".utf8))
        await events.wait(for: "gated:resume")
        await #expect(throws: TerminalTransportError.self) { try await client.write(Data("blocked".utf8)) }
        await events.emit(.connected)
        await engine.release("resume")
        try await resuming.value
        #expect(
            events.values.filter { ["retry", "checkpoint", "resume"].contains($0) } == [
                "retry", "checkpoint", "resume",
            ])
        #expect(events.values.filter { $0 == "state:connected" }.count == 2)
        #expect(!events.values.contains("state:failed"))
        try await client.write(Data("after".utf8))
        await client.close()
    }

    @Test func queuedResumePreservesTheOnlyConnectedEventFromRetry() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events, gates: ["retry"])
        let client = client(engine, events: events)
        try await connect(client)
        let retrying = Task { try await client.retryNow() }
        await events.wait(for: "gated:retry")
        let resuming = Task { try await client.resume() }
        await events.wait(for: "lifecycle:queued", count: 2)
        await events.emit(.connected)
        await engine.release("retry")
        try await retrying.value
        try await resuming.value
        #expect(events.values.last == "state:connected")
        #expect(events.values.filter { $0 == "resume" }.count == 1)
        #expect(!events.values.contains("state:failed"))
        await client.close()
    }

    @Test func checkpointQueuedDuringInitialStartUsesTheConnectedEventAfterDrainingConnect() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events, gates: ["start"])
        let client = client(engine, events: events)
        let connecting = Task { try await connect(client) }
        await events.wait(for: "gated:start")
        let suspending = Task { try await client.suspend() }
        await events.wait(for: "lifecycle:queued")
        #expect(!events.values.contains("checkpoint"))
        await engine.release("start")
        try await connecting.value
        let saved = try await suspending.value
        #expect(saved.transport == .mosh)
        #expect(events.values.last == "state:suspended")
        #expect(!events.values.contains("state:failed"))
        await #expect(throws: TerminalTransportError.self) { try await client.write(Data("blocked".utf8)) }
        try await client.resume()
        try await client.write(Data("after".utf8))
        await client.close()
    }

    @Test func checkpointAfterStartDoesNotRequireTheConnectedObserverToHaveCaughtUp() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events, reportsConnectedOnStart: false)
        let client = client(engine, events: events)
        try await connect(client)
        _ = try await client.suspend()
        #expect(events.values.contains("checkpoint"))
        #expect(events.values.last == "state:suspended")
        try await client.resume()
        try await client.write(Data("after".utf8))
        await events.emit(.connected)
        #expect(events.values.last == "state:connected")
        await client.close()
    }

    @Test func resizeChangesDuringRecoveryFlushAreAppliedBeforeUserWritesReopen() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events, gates: ["resize"])
        let client = client(engine, events: events)
        try await connect(client)
        _ = try await client.suspend()
        let resuming = Task { try await client.resume() }
        await events.wait(for: "gated:resize")
        try await client.resize(columns: 110, rows: 40)
        try await client.resize(columns: 150, rows: 60)
        await #expect(throws: TerminalTransportError.self) { try await client.write(Data("blocked".utf8)) }
        #expect(events.values.filter { $0.hasPrefix("resize:") } == ["resize:80x24"])
        await engine.release("resize")
        try await resuming.value
        #expect(events.values.filter { $0.hasPrefix("resize:") } == ["resize:80x24", "resize:150x60"])
        try await client.write(Data("after".utf8))
        await client.close()
    }

    @Test func coalescedResumeFailureReachesEveryCallerAndKeepsAdmissionFrozenUntilRetry() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events, gates: ["resume", "prepareRetry"], failures: ["resume"])
        let client = client(engine, events: events)
        try await connect(client)
        _ = try await client.suspend()
        let resuming = Task { try await client.resume() }
        await events.wait(for: "gated:resume")
        let secondResume = Task { try await client.resume() }
        await events.wait(for: "lifecycle:queued", count: 3)
        let retrying = Task { try await client.retryNow() }
        await events.wait(for: "lifecycle:queued", count: 4)
        await engine.release("resume")
        await expectUnreachable(resuming)
        await expectUnreachable(secondResume)
        await events.wait(for: "gated:prepareRetry")
        #expect(events.values.filter { $0 == "resume" }.count == 1)
        await #expect(throws: TerminalTransportError.self) { try await client.write(Data("blocked".utf8)) }
        #expect(!events.values.contains(where: { $0.hasPrefix("resize:") }))
        await engine.release("prepareRetry")
        try await retrying.value
        #expect(events.values.filter { $0 == "resume" }.count == 2)
        try await client.write(Data("after".utf8))
        await client.close()
    }

    @Test func failedResumeAdmissionLeavesTheExistingCheckpointEligible() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events, failures: ["beforeResume"])
        let client = client(engine, events: events)
        try await connect(client)
        let saved = try await client.suspend()
        await expectUnreachable(Task { try await client.resume() })
        let stillSaved = try await client.suspend()
        #expect(stillSaved.payload == saved.payload)
        #expect(events.values.filter { $0 == "checkpoint" }.count == 1)
        #expect(!events.values.contains("resume"))
        await #expect(throws: TerminalTransportError.self) { try await client.write(Data("blocked".utf8)) }
        try await client.retryNow()
        try await client.write(Data("after".utf8))
        await client.close()
    }

    @Test func failedResumePreflightWithoutASuspensionKeepsBufferedStateFrozenUntilRecovery() async throws {
        let events = EngineEvents()
        let engine = TestEngine(
            events: events, gates: ["beforeResume"], restoresIntegration: true, failures: ["beforeResume"])
        let client = client(engine, events: events)
        try await connect(client)
        let resuming = Task { try await client.resume() }
        await events.wait(for: "gated:beforeResume")
        try await client.resize(columns: 150, rows: 60)
        await events.emit(.output(Data("__TRMD_RESTORE_SHELL__/bin/bash__\r\n".utf8)))
        await engine.release("beforeResume")
        await expectUnreachable(resuming)
        await #expect(throws: TerminalTransportError.self) { try await client.write(Data("blocked".utf8)) }
        #expect(!events.values.contains(where: { $0.hasPrefix("resize:") }))
        #expect(!events.values.contains(where: { $0.hasPrefix("write:") }))
        try await client.retryNow()
        #expect(events.values.filter { $0.hasPrefix("resize:") } == ["resize:150x60"])
        #expect(events.values.filter { $0.hasPrefix("write:") && $0.contains("TermindCommand=RESTORE") }.count == 1)
        try await client.write(Data("after".utf8))
        await client.close()
    }

    @Test func cancellingOneCoalescedRetryDoesNotCancelTheOtherCaller() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events, gates: ["retry"])
        let client = client(engine, events: events)
        try await connect(client)
        let retrying = Task { try await client.retryNow() }
        await events.wait(for: "gated:retry")
        let cancelled = Task { try await client.retryNow() }
        await events.wait(for: "lifecycle:queued", count: 2)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        await #expect(throws: TerminalTransportError.self) { try await client.write(Data("blocked".utf8)) }
        await engine.release("retry")
        try await retrying.value
        #expect(events.values.filter { $0 == "retry" }.count == 1)
        try await client.write(Data("after".utf8))
        await client.close()
    }

    @Test func cancelledQueuedCheckpointDoesNotSuspendTheRecoveredEngine() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events, gates: ["retry"])
        let client = client(engine, events: events)
        try await connect(client)
        let retrying = Task { try await client.retryNow() }
        await events.wait(for: "gated:retry")
        let cancelled = Task { try await client.suspend() }
        await events.wait(for: "lifecycle:queued", count: 2)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        await engine.release("retry")
        try await retrying.value
        #expect(!events.values.contains("checkpoint"))
        try await client.write(Data("after".utf8))
        await client.close()
    }

    @Test func cancellingRetryCallerDuringSendDrainStillFinishesBeforeTheQueuedCheckpoint() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events)
        let client = client(engine, events: events)
        try await connect(client)
        let writing = Task { try await client.write(Data("hold".utf8)) }
        await events.wait(for: "write:hold")
        let cancelled = Task { try await client.retryNow() }
        await events.wait(for: "lifecycle:queued")
        let suspending = Task { try await client.suspend() }
        await events.wait(for: "lifecycle:queued", count: 2)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(!events.values.contains("checkpoint"))
        await engine.finishWrite()
        try await writing.value
        _ = try await suspending.value
        #expect(
            events.values.filter { ["prepareRetry", "retry", "checkpoint"].contains($0) } == [
                "prepareRetry", "retry", "checkpoint",
            ])
        #expect(events.values.last == "state:suspended")
        await client.close()
    }

    @Test func cancelledRetryCallerStillFlushesAndANewCallerCanJoinItsAdmittedWork() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events, gates: ["retry"], restoresIntegration: true)
        let client = client(engine, events: events)
        try await connect(client)
        await events.emit(.recovering)
        let writing = Task { try await client.write(Data("hold".utf8)) }
        await events.wait(for: "write:hold")
        let cancelled = Task { try await client.retryNow() }
        await events.wait(for: "lifecycle:queued")
        try await client.resize(columns: 150, rows: 60)
        await events.emit(.output(Data("__TRMD_RESTORE_SHELL__/bin/bash__\r\n".utf8)))
        #expect(events.values.filter { $0.hasPrefix("state:") }.last == "state:recovering")
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(!events.values.contains("prepareRetry"))
        let replacement = Task { try await client.retryNow() }
        await events.wait(for: "lifecycle:queued", count: 2)
        await #expect(throws: TerminalTransportError.self) { try await client.write(Data("blocked".utf8)) }
        await engine.finishWrite()
        try await writing.value
        await events.wait(for: "gated:retry")
        await events.emit(.connected)
        await engine.release("retry")
        try await replacement.value
        #expect(events.values.filter { $0 == "retry" }.count == 1)
        #expect(events.values.filter { $0.hasPrefix("resize:") } == ["resize:150x60"])
        #expect(events.values.filter { $0.hasPrefix("write:") && $0.contains("TermindCommand=RESTORE") }.count == 1)
        #expect(events.values.last == "state:connected")
        try await client.write(Data("after".utf8))
        await client.close()
    }

    @Test func cancelledResumeCallerLeavesProtocolWorkSerializedBeforeTheNextCheckpoint() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events, gates: ["resume"])
        let client = client(engine, events: events)
        try await connect(client)
        _ = try await client.suspend()
        let cancelled = Task { try await client.resume() }
        await events.wait(for: "gated:resume")
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let suspending = Task { try await client.suspend() }
        await events.wait(for: "lifecycle:queued", count: 3)
        #expect(events.values.filter { $0 == "checkpoint" }.count == 1)
        await #expect(throws: TerminalTransportError.self) { try await client.write(Data("blocked".utf8)) }
        await engine.release("resume")
        _ = try await suspending.value
        #expect(events.values.filter { $0 == "checkpoint" }.count == 2)
        #expect(events.values.last == "state:suspended")
        #expect(events.values.filter { $0.hasPrefix("resize:") } == ["resize:80x24"])
        await client.close()
    }

    @Test(arguments: ["resume", "retry", "checkpoint", "beforeResume", "prepareRetry"])
    func closeImmediatelyReleasesLifecycleCallersAndFencesLateEngineCompletion(_ gate: String) async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events, gates: [gate])
        let client = client(engine, events: events)
        try await connect(client)
        if gate == "resume" || gate == "beforeResume" { _ = try await client.suspend() }
        let baseline = events.values.filter { $0 == "lifecycle:queued" }.count
        let operation = Task {
            if gate == "checkpoint" {
                _ = try await client.suspend()
            } else if gate == "retry" || gate == "prepareRetry" {
                try await client.retryNow()
            } else {
                try await client.resume()
            }
        }
        await events.wait(for: "gated:\(gate)")
        let queued = Task {
            if gate == "checkpoint" {
                try await client.resume()
            } else {
                _ = try await client.suspend()
            }
        }
        await events.wait(for: "lifecycle:queued", count: baseline + 2)
        await client.close()
        await #expect(throws: CancellationError.self) { try await operation.value }
        await #expect(throws: CancellationError.self) { try await queued.value }
        let closedEvents = events.values
        await engine.release(gate)
        await events.wait(for: "released:\(gate)")
        await events.emit(.output(Data("late".utf8)))
        await events.emit(.connected)
        await events.emit(.activity)
        await #expect(throws: CancellationError.self) { try await client.resize(columns: 200, rows: 80) }
        await #expect(throws: CancellationError.self) { try await client.write(Data("late".utf8)) }
        #expect(events.values == closedEvents + ["released:\(gate)"])
        #expect(events.values.filter { $0 == "close" }.count == 1)
    }

    @Test func closeReleasesARetryWaitingForAnOutstandingWrite() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events)
        let client = client(engine, events: events)
        try await connect(client)
        let writing = Task { try await client.write(Data("hold".utf8)) }
        await events.wait(for: "write:hold")
        let retrying = Task { try await client.retryNow() }
        await events.wait(for: "lifecycle:queued")
        await client.close()
        await #expect(throws: CancellationError.self) { try await retrying.value }
        try await writing.value
        #expect(!events.values.contains("prepareRetry"))
        #expect(!events.values.contains("retry"))
        #expect(events.values.last == "state:closed")
    }

    @Test func initialHealthyPathDoesNotReconnectButSubsequentHealthyHandoversDo() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events)
        let client = client(engine, events: events)
        try await connect(client)
        await client.networkPathChanged(available: true)
        #expect(!events.values.contains("networkAvailable"))
        #expect(!events.values.contains("state:recovering"))
        await client.networkPathChanged(available: true)
        await client.networkPathChanged(available: true)
        #expect(events.values.filter { $0 == "networkAvailable" }.count == 2)
        await client.close()
        await client.networkPathChanged(available: true)
        #expect(events.values.filter { $0 == "networkAvailable" }.count == 2)
    }

    @Test func initialUnavailablePathPresentsRecoveryAndRestorationNotifiesTheEngine() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events)
        let client = client(engine, events: events)
        try await connect(client)
        await client.networkPathChanged(available: false)
        #expect(events.values.last == "state:recovering")
        #expect(!events.values.contains("networkAvailable"))
        await client.networkPathChanged(available: true)
        #expect(events.values.filter { $0 == "networkAvailable" }.count == 1)
        await client.close()
    }

    @Test func frozenNetworkObservationsAreRememberedWithoutContactingTheEngine() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events)
        let client = client(engine, events: events)
        try await connect(client)
        _ = try await client.suspend()
        await client.networkPathChanged(available: true)
        await client.networkPathChanged(available: false)
        #expect(!events.values.contains("networkAvailable"))
        #expect(events.values.last == "state:suspended")
        try await client.resume()
        await client.networkPathChanged(available: true)
        #expect(events.values.filter { $0 == "networkAvailable" }.count == 1)
        await client.close()
    }

    @Test func failedStartRollsBackAndClosesTheSelectedEngine() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events, failsStart: true)
        let client = client(engine, events: events)
        await #expect(throws: TerminalTransportError.self) { try await connect(client) }
        #expect(Array(events.values.suffix(3)) == ["rollback", "close", "state:closed"])
        await client.close()
        #expect(events.values.filter { $0 == "close" }.count == 1)
    }

    @Test func checkpointCapturesShellEventsEmittedDuringCheckpointPreparation() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events, emitsShellEventDuringCheckpoint: true)
        let client = client(engine, events: events)
        try await connect(client)
        _ = try await client.suspend()
        var filter = try #require(await engine.capturedShell?.commandFilter)
        let update = filter.receive(Data("hello\u{7}visible".utf8))
        #expect(update.events == [.commandStarted("echo hello")])
        #expect(update.visibleOutput == Data("visible".utf8))
        await client.close()
    }

    @Test func remoteEndClosesOnceAndRejectsLateEngineEvents() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events)
        let client = client(engine, events: events)
        try await connect(client)
        await events.emit(.ended)
        let ended = events.values
        await events.emit(.output(Data("late".utf8)))
        await events.emit(.connected)
        await events.emit(.ended)
        await client.close()
        #expect(events.values == ended)
        #expect(events.values.filter { $0 == "state:ended" }.count == 1)
        #expect(events.values.filter { $0 == "close" }.count == 1)
        await #expect(throws: CancellationError.self) { try await client.write(Data("late".utf8)) }
    }

    @Test func incompatibleEnvelopeNeverConstructsAnEngine() async throws {
        for invalid in [
            TerminalTransportCheckpoint(transport: .eternalTerminal, payload: Data()),
            {
                var value = checkpoint
                value.version = 99
                return value
            }(),
        ] {
            let events = EngineEvents()
            let engine = TestEngine(events: events)
            let client = ResumableTerminalClient(
                transport: .mosh, checkpoint: invalid, output: { _ in }, stateChanged: { _ in },
                shellIntegration: { _ in }, registry: registry(engine, events: events))
            await #expect(throws: TerminalTransportError.self) { try await connect(client) }
            #expect(events.values.isEmpty)
        }
    }

    @Test func legacyMoshPayloadRemainsTheUnwrappedVendorSnapshot() throws {
        let literal = Data(
            """
            {"endpoint":{"host":"old.example","port":60001,"keyBase64_22":"AAAAAAAAAAAAAAAAAAAAAA"},
             "transportState":"bGVnYWN5LXN0YXRl","createdAtMs":1700000000123,"schemaVersion":2}
            """.utf8)
        let snapshot = try MoshTerminalEngine.decodeCheckpoint(literal)
        #expect(snapshot.endpoint.host == "old.example")
        #expect(snapshot.endpoint.port == 60001)
        #expect(snapshot.transportState == Data("legacy-state".utf8))
        #expect(try json(JSONEncoder().encode(snapshot)) == json(literal))
    }

    @Test func legacyEternalPayloadRetainsFlatKeysAndRestoredShellInput() throws {
        let literal = Data(
            """
            {"clientID":"legacy-client","passkey":"AAECAwQ=",
             "checkpoint":{"reader":{"nonce":"AQID","sequenceNumber":17},
               "writer":{"nonce":"BAUG","sequenceNumber":19,"serializedBackupPackets":["YWJj"]}},
             "integratedShell":{"shell":"zsh","homeDirectory":"/home/legacy"},
             "pendingIntegrationCommand":"cGVuZGluZw=="}
            """.utf8)
        let payload = try EternalTerminalEngine.decodeCheckpoint(literal)
        #expect(payload.clientID == "legacy-client")
        #expect(payload.passkey == Data([0, 1, 2, 3, 4]))
        #expect(payload.shellState.integratedShell?.homeDirectory == "/home/legacy")
        #expect(payload.shellState.pendingIntegrationCommand == Data("pending".utf8))
        #expect(try json(JSONEncoder().encode(payload)) == json(literal))
    }

    private var options: HostTerminalTransports {
        var options = HostTerminalTransports()
        options.moshEnabled = true
        return options
    }

    private var request: SSHConnectionRequest {
        .init(
            configuration: .init(
                hostID: UUID(), host: "127.0.0.1", port: 1, username: "unused", credentials: [], expectedHostKeys: []))
    }

    private var checkpoint: TerminalTransportCheckpoint {
        .init(transport: .mosh, payload: Data("old-state".utf8))
    }

    private func registry(_ engine: TestEngine, events: EngineEvents) -> ResumableTerminalEngineRegistry {
        .init(factories: [
            .mosh: {
                events.install($0)
                events.record("factory")
                return engine
            }
        ])
    }

    private func client(_ engine: TestEngine, events: EngineEvents) -> ResumableTerminalClient {
        .init(
            transport: .mosh, checkpoint: checkpoint,
            output: { events.record("output:\(String(decoding: $0, as: UTF8.self))") },
            stateChanged: { events.record("state:\($0)") }, shellIntegration: { _ in },
            registry: registry(engine, events: events), pathMonitor: nil,
            lifecycleRequestEnqueued: { events.record("lifecycle:queued") },
            routeChanged: { events.record("route:\($0.revision):\($0.stage)") })
    }

    private func connect(_ client: ResumableTerminalClient) async throws {
        try await client.connect(
            request: request, options: options, environment: [], shellIntegrationEnabled: true,
            columns: 80, rows: 24, route: { _ in throw CancellationError() }, progress: nil,
            startupPreparation: { _ in
                Issue.record("Restoring a checkpoint must not prepare a new shell")
                return nil
            })
    }

    private func json(_ data: Data) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    private func expectUnreachable(_ task: Task<Void, any Error>) async {
        do {
            try await task.value
            Issue.record("Expected the injected engine failure")
        } catch TerminalTransportError.unreachable {
        } catch {
            Issue.record("Unexpected lifecycle error: \(error)")
        }
    }

    private func eventually(_ predicate: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await predicate()
    }
}

private nonisolated final class EngineEvents: @unchecked Sendable {
    private struct Waiter {
        let value: String
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }
    private let lock = NSLock()
    private var recorded: [String] = []
    private var waiters: [Waiter] = []
    private var receive: ResumableTerminalEngine.EventHandler?
    var values: [String] { lock.withLock { recorded } }
    func record(_ value: String) {
        let ready = lock.withLock {
            recorded.append(value)
            let count = recorded.filter { $0 == value }.count
            let ready = waiters.filter { $0.value == value && $0.count <= count }
            waiters.removeAll { $0.value == value && $0.count <= count }
            return ready
        }
        for waiter in ready { waiter.continuation.resume() }
    }
    func wait(for value: String, count: Int = 1) async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if recorded.filter({ $0 == value }).count >= count { return true }
                waiters.append(.init(value: value, count: count, continuation: continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }
    func install(_ receive: @escaping ResumableTerminalEngine.EventHandler) {
        lock.withLock { self.receive = receive }
    }
    func emit(_ event: ResumableTerminalEngineEvent) async {
        let receive = lock.withLock { self.receive }
        await receive?(event)
    }
}

private actor TestEngine: ResumableTerminalEngine {
    let events: EngineEvents
    let failsStart: Bool
    let emitsShellEventDuringCheckpoint: Bool
    let restoresIntegration: Bool
    let reportsConnectedOnStart: Bool
    private(set) var preparedPayload: Data?
    private(set) var permitsAgentForwarding = true
    private(set) var capturedShell: ResumableTerminalShellState?
    private var writing: CheckedContinuation<Void, Never>?
    private var gates: Set<String>
    private var failures: Set<String>
    private var blocked: [String: CheckedContinuation<Void, Never>] = [:]

    init(
        events: EngineEvents, failsStart: Bool = false, emitsShellEventDuringCheckpoint: Bool = false,
        gates: Set<String> = [], restoresIntegration: Bool = false, failures: Set<String> = [],
        reportsConnectedOnStart: Bool = true
    ) {
        self.events = events
        self.failsStart = failsStart
        self.emitsShellEventDuringCheckpoint = emitsShellEventDuringCheckpoint
        self.gates = gates
        self.restoresIntegration = restoresIntegration
        self.failures = failures
        self.reportsConnectedOnStart = reportsConnectedOnStart
    }
    func prepare(_ context: ResumableTerminalEngineContext) async throws -> ResumableTerminalEnginePreparation {
        preparedPayload = context.checkpoint
        permitsAgentForwarding = context.request.permitsAgentForwarding
        events.record("prepare")
        return .init(
            shell: .init(
                integration: restoresIntegration ? RemoteShellIntegrationBootstrap(token: "RESTORE") : nil,
                commandFilter: emitsShellEventDuringCheckpoint ? RemoteCommandEventFilter(token: "capture") : nil))
    }
    func start(columns: UInt16, rows: UInt16) async throws {
        events.record("start:\(columns)x\(rows)")
        if failsStart { throw TerminalTransportError.unreachable }
        await waitAtGate("start")
        if reportsConnectedOnStart { await events.emit(.connected) }
        await events.emit(.output(Data("ready".utf8)))
    }
    func write(_ data: Data) async throws {
        events.record("write:\(String(decoding: data, as: UTF8.self))")
        if data == Data("hold".utf8) {
            await withCheckedContinuation { writing = $0 }
        }
    }
    func finishWrite() {
        writing?.resume()
        writing = nil
    }
    func resize(columns: UInt16, rows: UInt16) async throws {
        events.record("resize:\(columns)x\(rows)")
        await waitAtGate("resize")
        try failIfRequested("resize")
    }
    func checkpoint(shell: @Sendable () async -> ResumableTerminalShellState) async throws -> Data {
        events.record("checkpoint")
        await waitAtGate("checkpoint")
        try failIfRequested("checkpoint")
        if emitsShellEventDuringCheckpoint {
            await events.emit(.output(Data("\u{1b}]777;TermindCommand=capture;echo%20".utf8)))
        }
        capturedShell = await shell()
        return Data("saved-state".utf8)
    }
    func beforeResume() async throws {
        events.record("beforeResume")
        await waitAtGate("beforeResume")
        try failIfRequested("beforeResume")
    }
    func resume() async throws {
        events.record("resume")
        await waitAtGate("resume")
        try failIfRequested("resume")
    }
    func prepareRetry() async {
        events.record("prepareRetry")
        await waitAtGate("prepareRetry")
    }
    func retry() async throws {
        events.record("retry")
        await waitAtGate("retry")
        try failIfRequested("retry")
    }
    func networkAvailable() async { events.record("networkAvailable") }
    private func waitAtGate(_ name: String) async {
        guard gates.contains(name) else { return }
        await withCheckedContinuation {
            blocked[name] = $0
            events.record("gated:\(name)")
        }
        events.record("released:\(name)")
    }
    func release(_ name: String) {
        gates.remove(name)
        blocked.removeValue(forKey: name)?.resume()
    }
    private func failIfRequested(_ name: String) throws {
        if failures.remove(name) != nil { throw TerminalTransportError.unreachable }
    }
    func rollback(using bootstrap: SSHConnection) async { events.record("rollback") }
    func close() async {
        events.record("close")
        finishWrite()
    }
}
