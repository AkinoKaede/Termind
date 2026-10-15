import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@Suite @MainActor
struct SessionPersistenceTests {
    @Test func newHostsDisablePersistenceAndAskEveryTimeWhenEnabled() {
        let host = Host(name: "New", host: "example.invalid")
        let tailscale = TailscaleHostPreferences()
        for preferences in [host.sessionPersistence, tailscale.sessionPersistence] {
            #expect(!preferences.enabled)
            #expect(preferences.backend == .tmux)
            #expect(preferences.onConnect == .ask)
        }
    }

    @Test(arguments: [false, true])
    func preferencesRoundTripWithoutResettingSelections(enabled: Bool) throws {
        var host = Host(name: "Saved", host: "example.invalid")
        host.sessionPersistence = .init(enabled: enabled, backend: .init(rawValue: "future"), onConnect: .createManaged)
        #expect(try JSONDecoder().decode(Host.self, from: JSONEncoder().encode(host)) == host)
        #expect(PersistentHost(host).value.sessionPersistence == host.sessionPersistence)
        let envelope = VaultEnvelope(
            key: .init(kind: .host, id: host.id), version: .baseline(writerID: UUID()), payload: .host(host))
        #expect(try VaultSyncCodec.decode(VaultSyncCodec.encode(envelope)).payload == .host(host))
        var legacy = envelope
        legacy.formatVersion = 2
        #expect(throws: (any Error).self) { try VaultSyncCodec.encode(legacy) }
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as? [String: Any])
        json["sessionPersistence"] = nil
        let old = try JSONDecoder().decode(Host.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.sessionPersistence == .init(enabled: false))
    }

    @Test func legacyTailscalePreferencesStayDisabled() throws {
        let preferences = TailscaleHostPreferences()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        json["sessionPersistence"] = nil
        let old = try JSONDecoder().decode(
            TailscaleHostPreferences.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.sessionPersistence == .init(enabled: false))
    }

    @Test func legacyHostWirePreservesDisabledBehaviorAndRejectsEnabledPreferences() throws {
        var host = Host(name: "Legacy", host: "example.invalid")
        host.sessionPersistence.enabled = true
        for version in [1, 2] {
            let enabled = VaultRecordPayload.host(host)
            let enabledEnvelope = VaultEnvelope(
                key: enabled.key, version: .baseline(writerID: UUID()), payload: enabled, formatVersion: version)
            #expect(throws: (any Error).self) { try VaultSyncCodec.encode(enabledEnvelope) }
            host.sessionPersistence.enabled = false
            let disabled = VaultRecordPayload.host(host)
            let disabledEnvelope = VaultEnvelope(
                key: disabled.key, version: .baseline(writerID: UUID()), payload: disabled, formatVersion: version)
            #expect(try VaultSyncCodec.decode(VaultSyncCodec.encode(disabledEnvelope)).payload == disabled)
            host.sessionPersistence.enabled = true
        }
    }

    @Test(arguments: [false, true])
    func tailscaleWirePreservesSelectionsAndRejectsLossyOlderWrites(enabled: Bool) throws {
        let network = try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "example.ts.net")
        var group = HostGroup(name: "Tailnet")
        group.tailscale = TailscaleGroupConfiguration(network: network)
        let id = UUID()
        var preferences = TailscaleHostPreferences()
        preferences.sessionPersistence = .init(
            enabled: enabled, backend: .init(rawValue: "future"), onConnect: .plainShell)
        group.tailscale?.hostPreferences[id] = preferences
        let payload = VaultRecordPayload.hostGroup(group)
        var envelope = VaultEnvelope(key: payload.key, version: .baseline(writerID: UUID()), payload: payload)
        #expect(try VaultSyncCodec.decode(VaultSyncCodec.encode(envelope)).payload == payload)
        envelope.formatVersion = 3
        #expect(throws: (any Error).self) { try VaultSyncCodec.encode(envelope) }
        preferences.sessionPersistence = .init(enabled: false)
        group.tailscale?.hostPreferences[id] = preferences
        let legacy = VaultRecordPayload.hostGroup(group)
        let legacyEnvelope = VaultEnvelope(
            key: legacy.key, version: .baseline(writerID: UUID()), payload: legacy, formatVersion: 3)
        #expect(try VaultSyncCodec.decode(VaultSyncCodec.encode(legacyEnvelope)).payload == legacy)
    }

    @Test func historicalDiskStoreMigratesAndReopens() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Termind.store")
        let host = Host(
            name: "Historical", host: "example.invalid", startupSnippetID: UUID(),
            sessionPersistence: .init(enabled: false))
        try writeHistorical(host, url: url)
        try checkMigrated(host, url: url)
        try checkMigrated(host, url: url)
    }

    private func writeHistorical(_ host: Host, url: URL) throws {
        let schema = Schema(versionedSchema: TermindSchemaV52.self)
        let container = try ModelContainer(
            for: schema, configurations: [.init("Termind", schema: schema, url: url, cloudKitDatabase: .none)])
        container.mainContext.insert(TermindSchemaV44HostModels.PersistentHost(host))
        try container.mainContext.save()
    }

    private func checkMigrated(_ host: Host, url: URL) throws {
        let container = try TermindPersistence.makeContainer(url: url)
        let stored = try #require(container.mainContext.fetch(FetchDescriptor<PersistentHost>()).first)
        #expect(stored.value == host)
        #expect(!stored.value.sessionPersistence.enabled)
    }

    @Test func plainPolicyNeverProbesAndPersistentExplicitCommandsCreateOnce() async throws {
        let backend = Backend()
        let coordinator = RemoteSessionCoordinator()
        let host = UUID()
        let plain = try await coordinator.prepare(
            service: backend, hostID: host, endpoint: "host:22", username: "u",
            startupCommand: nil, requiresNewSession: false, shellIntegration: false, onConnect: .plainShell)
        #expect(plain == nil)
        #expect(await backend.probeCount == 0)
        let plainCommand = try await coordinator.prepare(
            service: backend, hostID: host, endpoint: "host:22", username: "u",
            startupCommand: "echo normal", requiresNewSession: true, shellIntegration: false, onConnect: .plainShell)
        #expect(plainCommand == nil)
        #expect(await backend.probeCount == 0)
        let created = try await coordinator.prepare(
            service: backend, hostID: host, endpoint: "host:22", username: "u",
            startupCommand: "echo once", requiresNewSession: true, shellIntegration: false, onConnect: .ask)
        #expect(created?.attachment.isManaged == true)
        let restored = try await coordinator.prepare(
            service: backend, hostID: host, endpoint: "host:22", username: "u",
            startupCommand: "must-not-run", requiresNewSession: false, shellIntegration: false,
            onConnect: .createManaged)
        #expect(restored?.created == false)
        #expect(await backend.commands == ["echo once"])
    }

    @Test func lostReferenceAsksInsteadOfApplyingCreatePolicy() async throws {
        let backend = Backend()
        let coordinator = RemoteSessionCoordinator()
        let host = UUID()
        _ = try await coordinator.prepare(
            service: backend, hostID: host, endpoint: "host:22", username: "u",
            startupCommand: nil, requiresNewSession: false, shellIntegration: false, onConnect: .createManaged)
        await backend.removeSessions()
        let task = Task {
            try await coordinator.prepare(
                service: backend, hostID: host, endpoint: "host:22", username: "u",
                startupCommand: nil, requiresNewSession: false, shellIntegration: false, onConnect: .createManaged)
        }
        try await wait { coordinator.prompt != nil }
        #expect(coordinator.prompt?.failure == .sessionMissing)
        coordinator.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled selection must not launch")
        } catch is CancellationError {} catch { throw error }
        #expect(await backend.commands.count == 1)
        #expect(coordinator.requiresSelection)
    }

    @Test func manualAttachNeverTakesManagedOwnershipAndStaleChoicesAreIgnored() async throws {
        let backend = Backend()
        _ = try await backend.create(token: UUID(), startupCommand: nil, shellIntegration: false)
        let coordinator = RemoteSessionCoordinator()
        let task = Task {
            try await coordinator.prepare(
                service: backend, hostID: UUID(), endpoint: "host:22", username: "u",
                startupCommand: nil, requiresNewSession: false, shellIntegration: false)
        }
        try await wait { coordinator.prompt != nil }
        let prompt = try #require(coordinator.prompt)
        coordinator.choose(.plainShell, for: UUID())
        #expect(coordinator.prompt?.id == prompt.id)
        coordinator.choose(.attach(try #require(prompt.sessions.first)), for: prompt.id)
        let attached = try await task.value
        #expect(attached?.attachment.isManaged == false)
    }

    @Test func unknownBackendPromptsWithoutRunningCommands() async throws {
        let coordinator = RemoteSessionCoordinator()
        let task = Task {
            try await coordinator.prepare(
                preferences: .init(enabled: true, backend: .init(rawValue: "other")),
                registry: .init([:]),
                execute: { _ in
                    Issue.record("Must not execute")
                    throw CancellationError()
                },
                hostID: UUID(), endpoint: "host:22", username: "u", startupCommand: nil, requiresNewSession: false,
                shellIntegration: false)
        }
        try await wait { coordinator.prompt != nil }
        let prompt = try #require(coordinator.prompt)
        #expect(prompt.failure == .unsupported)
        coordinator.choose(.plainShell, for: prompt.id)
        #expect(try await task.value == nil)
    }

    @Test func unsupportedReferenceVersionsDoNotProbeOrReplaceTheSession() async throws {
        let backend = Backend()
        let coordinator = RemoteSessionCoordinator()
        _ = try await coordinator.prepare(
            service: backend, hostID: UUID(), endpoint: "host:22", username: "u",
            startupCommand: nil, requiresNewSession: false, shellIntegration: false, onConnect: .createManaged)
        coordinator.attachment?.version = 2
        let probes = await backend.probeCount
        let task = Task {
            try await coordinator.prepare(
                service: backend, hostID: UUID(), endpoint: "host:22", username: "u",
                startupCommand: nil, requiresNewSession: false, shellIntegration: false, onConnect: .createManaged)
        }
        try await wait { coordinator.prompt != nil }
        #expect(coordinator.prompt?.failure == .unsupported)
        #expect(await backend.probeCount == probes)
        #expect(await backend.commands.count == 1)
        coordinator.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func endedSessionsRequireAChoiceInsteadOfAutomaticReplacement() async throws {
        let backend = Backend()
        let coordinator = RemoteSessionCoordinator()
        coordinator.markEnded()
        let task = Task {
            try await coordinator.prepare(
                service: backend, hostID: UUID(), endpoint: "host:22", username: "u",
                startupCommand: nil, requiresNewSession: false, shellIntegration: false, onConnect: .createManaged)
        }
        try await wait { coordinator.prompt != nil }
        #expect(await backend.commands.isEmpty)
        #expect(coordinator.attachment == nil)
        #expect(!coordinator.detached)
        coordinator.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(arguments: [Int32(0), Int32(1)], [Optional(true), Optional(false), nil])
    func exitClosesOnlyConfirmedSuccessfulEnds(exitCode: Int32, sessionExists: Bool?) {
        let coordinator = RemoteSessionCoordinator()
        let saved = reference()
        coordinator.attachment = saved
        var cleared = false
        coordinator.didChangeAttachment = { cleared = $0 == nil }

        let shouldClose = coordinator.finishExit(exitCode: exitCode, sessionExists: sessionExists)

        #expect(shouldClose == (exitCode == 0 && sessionExists == false))
        if sessionExists == false {
            #expect(coordinator.attachment == nil)
            #expect(cleared)
            #expect(coordinator.requiresSelection)
            #expect(!coordinator.detached)
        } else {
            #expect(coordinator.attachment == saved)
            #expect(!cleared)
            #expect(coordinator.detached)
        }
    }

    @Test func selectionPausesJourneyAndCancelResumesWithoutLaunching() async throws {
        let coordinator = RemoteSessionCoordinator()
        let backend = Backend()
        let host = Host(name: "Server", host: "server.invalid")
        let journey = ConnectionJourney()
        journey.begin(host: host, route: [host], purpose: .sshSession, username: "u")
        coordinator.didChangePrompt = { pending in
            if pending { journey.waitForSessionSelection() } else { journey.resume() }
        }
        let task = Task {
            try await coordinator.prepare(
                service: backend, hostID: host.id, endpoint: "host:22", username: "u",
                startupCommand: nil, requiresNewSession: false, shellIntegration: false, onConnect: .ask)
        }
        try await wait { coordinator.prompt != nil }
        #expect(journey.phase == .waiting)
        #expect(journey.activeEndpointIndex == journey.endpoints.count - 1)
        #expect(journey.checkpoint == nil)
        #expect(journey.localRequirement == nil)
        coordinator.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(journey.phase == .connecting)
        #expect(coordinator.prompt == nil)
        #expect(await backend.commands.isEmpty)
    }

    @Test func cancellingSelectionClosesBeforePreparationReportsCancellation() async throws {
        let coordinator = RemoteSessionCoordinator()
        var closed = false
        let task = Task {
            do {
                try await coordinator.confirmPlainConnection()
                Issue.record("Cancelled selection must not launch a connection")
            } catch is CancellationError {
                #expect(closed)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
        try await wait { coordinator.prompt != nil }
        let id = try #require(coordinator.prompt?.id)
        coordinator.cancelSelection(for: id) { closed = true }
        #expect(closed)
        #expect(coordinator.prompt == nil)
        await task.value
    }

    @Test func staleSelectionCancellationDoesNotCloseCurrentConnection() async throws {
        let coordinator = RemoteSessionCoordinator()
        let task = Task { try await coordinator.confirmPlainConnection() }
        try await wait { coordinator.prompt != nil }
        let id = try #require(coordinator.prompt?.id)
        coordinator.cancelSelection(for: UUID()) { Issue.record("Stale selection closed the connection") }
        #expect(coordinator.prompt?.id == id)
        coordinator.choose(.plainShell, for: id)
        try await task.value
    }

    @Test func creationRequiresMatchingRemoteOwnershipConfirmation() async throws {
        let name = Array("session\n".utf8).map { String(format: "%02x", $0) }.joined()
        let service = RemoteTmuxService { _ in
            .init(stdout: "TERMIND_TMUX_1\nS $1 123 456 1 0 \(name) -\n", stderr: "", exitCode: 0)
        }
        await #expect(throws: RemoteSessionFailure.ownershipMismatch) {
            try await service.create(token: UUID(), startupCommand: nil, shellIntegration: false)
        }
    }

    @Test func probeSeparatesMissingUnsupportedTimeoutAndMalformedResponses() async throws {
        for (result, failure) in [
            (RemoteSessionCommandResult(stdout: "", stderr: "", exitCode: 77), RemoteSessionFailure.missing),
            (.init(stdout: "tmux 3.2a\n", stderr: "", exitCode: 0), .unsupported),
            (.init(stdout: "unrecognized\n", stderr: "", exitCode: 0), .invalidResponse),
            (.init(stdout: "tmux 3.3a\n", stderr: "", exitCode: 0, truncated: true), .invalidResponse),
        ] {
            let backend = RemoteTmuxService { _ in result }
            await #expect(throws: failure) { try await backend.probe() }
        }
        let timeout = RemoteTmuxService { _ in throw RemoteSessionFailure.timedOut }
        await #expect(throws: RemoteSessionFailure.timedOut) { try await timeout.probe() }
        let empty = RemoteTmuxService { _ in .init(stdout: "TERMIND_TMUX_1\n", stderr: "", exitCode: 0) }
        #expect(try await empty.sessions().isEmpty)
    }

    @Test func closeFailureRetainsRemainingWorkAndQuitDoesNotTerminate() async throws {
        let backend = Backend()
        let coordinator = RemoteSessionCoordinator()
        let launch = try #require(
            try await coordinator.prepare(
                service: backend, hostID: UUID(), endpoint: "host:22", username: "u",
                startupCommand: nil, requiresNewSession: false, shellIntegration: false, onConnect: .createManaged))
        let close = RemoteSessionCloseCoordinator()
        #expect(
            await close.close(attachments: [launch.attachment], intent: .applicationTermination) { _ in
                Issue.record("Quit must preserve")
            })
        var attempts = 0
        let task = Task {
            await close.close(attachments: [launch.attachment]) { _ in
                attempts += 1
                throw RemoteSessionFailure.ownershipMismatch
            }
        }
        try await wait { close.prompt?.failure != nil }
        #expect(attempts == 1)
        close.choose(.cancel, for: try #require(close.prompt?.id))
        #expect(await task.value == false)
    }

    @Test func explicitCloseEndsManagedSessionsWithoutAConfirmation() async {
        let close = RemoteSessionCloseCoordinator()
        let managed = reference()
        let external = RemoteSessionReference(
            backend: managed.backend, session: managed.session, hostID: managed.hostID,
            endpoint: managed.endpoint, username: managed.username, ownershipToken: nil)
        var ended: [RemoteSessionReference] = []

        let allowed = await close.close(attachments: [managed, external]) { session in
            #expect(close.prompt == nil)
            ended.append(session)
        }

        #expect(allowed)
        #expect(ended == [managed])
        #expect(close.prompt == nil)
        #expect(!close.isClosing)
    }

    @Test(arguments: [
        TerminalTeardownIntent.applicationTermination, .suspension, .remoteExit, .detach,
    ])
    func passiveTeardownPreservesManagedSessions(intent: TerminalTeardownIntent) async {
        let close = RemoteSessionCloseCoordinator()
        #expect(
            await close.close(attachments: [reference()], intent: intent) { _ in
                Issue.record("Passive teardown must not terminate a remote session")
            })
        #expect(close.prompt == nil)
    }

    @Test func tmuxParsingKeepsNamesAsDataAndRejectsUnsupportedVersions() throws {
        let name = "odd ' $() ; \\ name"
        let hex = (name + "\n").utf8.map { String(format: "%02x", $0) }.joined()
        let result = try RemoteTmuxCommands.parseSessions("TERMIND_TMUX_1\nS $7 123 456 2 3 \(hex) -\n")
        #expect(result.first?.name == name)
        #expect(result.first?.windows == 2)
        #expect(try RemoteTmuxCommands.quote("a'b") == "'a'\\''b'")
        #expect(throws: RemoteSessionFailure.unsupported) { try RemoteTmuxCommands.validateVersion("tmux 3.2a\n") }
        try RemoteTmuxCommands.validateVersion("tmux 3.3a\n")
        #expect(throws: (any Error).self) { try RemoteTmuxCommands.parseSessions("TERMIND_TMUX_1\nS $bad\n") }
    }

    @Test func uncertainCreatesReuseTheirTokenOnlyForTheSameLaunchIntent() async throws {
        let backend = Backend()
        let coordinator = RemoteSessionCoordinator()
        let host = UUID()
        await backend.failNextCreate()
        let first = Task {
            try await coordinator.prepare(
                service: backend, hostID: host, endpoint: "host:22", username: "u",
                startupCommand: "first", requiresNewSession: true, shellIntegration: false)
        }
        try await wait { coordinator.prompt != nil }
        coordinator.choose(.retry, for: try #require(coordinator.prompt?.id))
        _ = try await first.value
        let retriedTokens = await backend.tokens
        #expect(retriedTokens.count == 2)
        #expect(retriedTokens.first == retriedTokens.last)
        coordinator.clearAttachment()

        await backend.failNextCreate()
        let cancelled = Task {
            try await coordinator.prepare(
                service: backend, hostID: host, endpoint: "host:22", username: "u",
                startupCommand: "second", requiresNewSession: true, shellIntegration: false)
        }
        try await wait { coordinator.prompt != nil }
        coordinator.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        _ = try await coordinator.prepare(
            service: backend, hostID: host, endpoint: "host:22", username: "u",
            startupCommand: "different", requiresNewSession: true, shellIntegration: false)
        let tokens = await backend.tokens
        #expect(tokens.count == 4)
        #expect(tokens[2] != tokens[3])
    }

    @Test func staleCreationCannotPublishOwnershipOverANewerConnection() async throws {
        let oldBackend = Backend()
        await oldBackend.pauseNextCreate()
        let coordinator = RemoteSessionCoordinator()
        let old = Task {
            try await coordinator.prepare(
                service: oldBackend, hostID: UUID(), endpoint: "old:22", username: "u",
                startupCommand: nil, requiresNewSession: true, shellIntegration: false)
        }
        for _ in 0..<200 {
            if await oldBackend.isCreatePaused { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await oldBackend.isCreatePaused)
        let current = try await coordinator.prepare(
            service: Backend(), hostID: UUID(), endpoint: "new:22", username: "u",
            startupCommand: nil, requiresNewSession: true, shellIntegration: true)
        await oldBackend.resumeCreate()
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(coordinator.attachment == current?.attachment)
    }

    @Test func unavailableShellCapabilityDoesNotReceiveIntegrationRequests() async throws {
        let backend = Backend()
        let coordinator = RemoteSessionCoordinator()
        _ = try await coordinator.prepare(
            service: backend, hostID: UUID(), endpoint: "host:22", username: "u",
            startupCommand: nil, requiresNewSession: true, shellIntegration: true)
        #expect(await backend.integrationRequests == [false])
    }

    @Test func duplicateCloseReferencesAreEndedOnceAndRetryKeepsPartialProgress() async throws {
        let first = reference()
        var duplicate = first
        duplicate.session = .init(
            id: first.session.id, name: "Renamed", identity: first.session.identity, windows: 2, clients: 3)
        let second = reference()
        let close = RemoteSessionCloseCoordinator()
        var terminated: [RemoteSessionReference] = []
        var fail = true
        let task = Task {
            await close.close(attachments: [first, duplicate, second]) { reference in
                if reference == second, fail {
                    fail = false
                    throw RemoteSessionFailure.timedOut
                }
                terminated.append(reference)
            }
        }
        try await wait { close.prompt?.failure != nil }
        #expect(terminated == [first])
        #expect(close.prompt?.names == [second.session.name])
        close.choose(.endSessions, for: try #require(close.prompt?.id))
        #expect(await task.value)
        #expect(terminated == [first, second])
    }

    @Test func cancellationDuringBatchCloseDoesNotEndAdditionalSessions() async throws {
        let close = RemoteSessionCloseCoordinator()
        var ended = 0
        let task = Task {
            await close.close(attachments: [reference(), reference()]) { _ in
                ended += 1
                close.cancel()
            }
        }
        #expect(await task.value == false)
        #expect(ended == 1)
    }

    private func reference() -> RemoteSessionReference {
        .init(
            backend: .init(rawValue: "test"), session: .init(id: UUID().uuidString, name: "Session", identity: Data()),
            hostID: UUID(), endpoint: "host:22", username: "u", ownershipToken: UUID())
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }

    private actor Backend: RemoteSessionBackend {
        nonisolated let id = SessionPersistenceBackendID(rawValue: "test-backend")
        nonisolated let capabilities = RemoteSessionCapabilities()
        var probeCount = 0
        var commands: [String?] = []
        var tokens: [UUID] = []
        var integrationRequests: [Bool] = []
        private var shouldFailCreate = false
        private var shouldPauseCreate = false
        private var createContinuation: CheckedContinuation<Void, Never>?
        var isCreatePaused: Bool { createContinuation != nil }
        var current: [RemoteSessionDescriptor] = []
        func failNextCreate() { shouldFailCreate = true }
        func pauseNextCreate() { shouldPauseCreate = true }
        func resumeCreate() {
            createContinuation?.resume()
            createContinuation = nil
        }
        func sessions() async throws -> [RemoteSessionDescriptor] {
            probeCount += 1
            return current
        }
        func removeSessions() { current = [] }
        nonisolated func matches(_ reference: RemoteSessionReference, session: RemoteSessionDescriptor) -> Bool {
            reference.session.identity == session.identity
        }
        func create(
            token: UUID, startupCommand: String?, shellIntegration: Bool, environment: [HostEnvironmentVariable] = []
        ) async throws
            -> RemoteSessionDescriptor
        {
            tokens.append(token)
            integrationRequests.append(shellIntegration)
            if shouldFailCreate {
                shouldFailCreate = false
                throw RemoteSessionFailure.timedOut
            }
            if shouldPauseCreate {
                shouldPauseCreate = false
                await withCheckedContinuation { createContinuation = $0 }
            }
            commands.append(startupCommand)
            let session = RemoteSessionDescriptor(
                id: UUID().uuidString, name: "A test session", identity: Data(token.uuidString.utf8))
            current.append(session)
            return session
        }
        nonisolated func launch(_ attachment: RemoteSessionReference, created: Bool) throws -> RemoteSessionLaunch {
            .init(command: "attach-test", attachment: attachment, created: created)
        }
        func terminate(_ attachment: RemoteSessionReference) async throws {
            current.removeAll { $0.id == attachment.session.id }
        }
    }
}
