import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

import struct TermindDomain.Host

@testable import TermindRemoteInfrastructure

@Suite @MainActor
struct SessionPersistenceTests {
    @Test(arguments: SessionPersistenceBackendID.supported)
    func sshReconnectKeepsAttachmentAndDoesNotReplayTheSelectedSnippet(backendID: SessionPersistenceBackendID)
        async throws
    {
        let backend = Backend(id: backendID)
        let coordinator = RemoteSessionCoordinator()
        let hostID = UUID()
        let registry = RemoteSessionBackendRegistry([backendID: { _ in backend }])
        let execute: RemoteSessionCommandExecutor = { _ in throw CancellationError() }
        let first = try await coordinator.prepare(
            preferences: .init(enabled: true, backend: backendID, onConnect: .createManaged),
            registry: registry, execute: execute, hostID: hostID, endpoint: "server:22", username: "user",
            startupCommand: "cd /tmp; export ONCE=yes", requiresNewSession: false, shellIntegration: true)
        let reference = try #require(first?.runtimeAttachment)
        let restored = try await coordinator.prepare(
            preferences: .init(enabled: true, backend: backendID, onConnect: .createManaged),
            registry: registry, execute: execute, hostID: hostID, endpoint: "server:22", username: "user",
            startupCommand: "must-not-replay", requiresNewSession: false, shellIntegration: true)
        #expect(restored?.runtimeAttachment == reference)
        #expect(await backend.commands == ["cd /tmp; export ONCE=yes"])
    }

    @Test(arguments: [HostTerminalProtocol.mosh, .eternalTerminal], SessionPersistenceBackendID.supported)
    func resumableTransportAttachesAndRestoresWithoutReplayingStartup(
        _ transport: HostTerminalProtocol, backendID: SessionPersistenceBackendID
    )
        async throws
    {
        let backend = Backend(id: backendID)
        let coordinator = RemoteSessionCoordinator()
        let hostID = UUID()
        let preparation: SSHPTYChannel.StartupPreparation = { execute in
            try await coordinator.prepare(
                preferences: .init(enabled: true, backend: backend.id, onConnect: .createManaged),
                registry: .init([backend.id: { _ in backend }]), execute: execute,
                hostID: hostID, endpoint: "server:22", username: "user", startupCommand: "uptime",
                requiresNewSession: false, shellIntegration: transport != .mosh)
        }
        let execute: RemoteSessionCommandExecutor = { _ in
            Issue.record("The fake backend should not need a remote command")
            throw CancellationError()
        }
        let startup = try await ResumableTerminalStartup.prepare(
            restoring: false, preparation: preparation, execute: execute)
        #expect(coordinator.attachment != nil)
        #expect(startup.plan?.runtimeAttachment?.backend == backendID)
        #expect(await backend.commands == ["uptime"])
        if transport == .mosh {
            #expect(try startup.moshArguments == " -- /bin/sh -c 'attach-test'")
        } else {
            #expect(try startup.eternalInput == Data(" exec /bin/sh -c 'attach-test'\r".utf8))
        }
        let originalAttachment = coordinator.attachment
        let resumed = try await ResumableTerminalStartup.prepare(
            restoring: true, preparation: preparation, execute: execute)
        #expect(resumed.plan == nil)
        #expect(try resumed.moshArguments.isEmpty)
        #expect(try resumed.eternalInput == nil)
        #expect(coordinator.attachment == originalAttachment)
        #expect(await backend.probeCount == 1)
        #expect(await backend.commands == ["uptime"])

        _ = try await ResumableTerminalStartup.prepare(restoring: false, preparation: preparation, execute: execute)
        #expect(await backend.commands == ["uptime"])
        #expect(coordinator.attachment == originalAttachment)
    }

    @Test func newHostsDisablePersistenceAndAskEveryTimeWhenEnabled() {
        let host = Host(name: "New", host: "example.invalid")
        let tailscale = TailscaleHostPreferences()
        for preferences in [host.sessionPersistence, tailscale.sessionPersistence] {
            #expect(!preferences.enabled)
            #expect(preferences.backend == .tmux)
            #expect(preferences.onConnect == .ask)
        }
    }

    @Test(arguments: [false, true], SessionPersistenceBackendID.supported + [.init(rawValue: "future")])
    func preferencesRoundTripWithoutResettingSelections(enabled: Bool, backend: SessionPersistenceBackendID) throws {
        var host = Host(name: "Saved", host: "example.invalid")
        host.sessionPersistence = .init(enabled: enabled, backend: backend, onConnect: .createManaged)
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
        let service = try RemoteSessionBackendRegistry.live.backend(.tmux) { _ in
            .init(stdout: "TERMIND_TMUX_1\nS $1 123 456 1 0 \(name) -\n", stderr: "", exitCode: 0)
        }
        await #expect(throws: RemoteSessionFailure.ownershipMismatch) {
            try await service.create(token: UUID(), startupCommand: nil, shellIntegration: false, environment: [])
        }
    }

    @Test func probeSeparatesMissingUnsupportedTimeoutAndMalformedResponses() async throws {
        for (result, failure) in [
            (RemoteSessionCommandResult(stdout: "", stderr: "", exitCode: 77), RemoteSessionFailure.missing),
            (.init(stdout: "tmux 3.2a\n", stderr: "", exitCode: 0), .unsupported),
            (.init(stdout: "unrecognized\n", stderr: "", exitCode: 0), .invalidResponse),
            (.init(stdout: "tmux 3.3a\n", stderr: "", exitCode: 0, truncated: true), .invalidResponse),
        ] {
            let backend = try RemoteSessionBackendRegistry.live.backend(.tmux) { _ in result }
            await #expect(throws: failure) { try await backend.probe() }
        }
        let timeout = try RemoteSessionBackendRegistry.live.backend(.tmux) { _ in throw RemoteSessionFailure.timedOut }
        await #expect(throws: RemoteSessionFailure.timedOut) { try await timeout.probe() }
        let empty = try RemoteSessionBackendRegistry.live.backend(.tmux) { _ in
            .init(stdout: "TERMIND_TMUX_1\n", stderr: "", exitCode: 0)
        }
        #expect(try await empty.sessions().isEmpty)
    }

    @Test func closeFailureIsBestEffortAndDoesNotRetry() async {
        var attempts = 0
        let close = RemoteSessionCloseCoordinator { _ in
            attempts += 1
            throw RemoteSessionFailure.ownershipMismatch
        }
        #expect(close.enqueue(closeRequest(reference())))
        #expect(attempts == 0)
        await close.waitUntilIdle()
        #expect(attempts == 1)
        #expect(!close.isClosing)
    }

    @Test func explicitCloseQueuesOnlyManagedSessionsWithoutWaiting() async {
        let managed = reference()
        let external = RemoteSessionReference(
            backend: managed.backend, session: managed.session, hostID: managed.hostID,
            endpoint: managed.endpoint, username: managed.username, ownershipToken: nil)
        var ended: [RemoteSessionReference] = []
        let close = RemoteSessionCloseCoordinator { ended.append($0.reference) }
        #expect(close.enqueue(closeRequest(managed)))
        #expect(!close.enqueue(closeRequest(external)))
        #expect(ended.isEmpty)
        await close.waitUntilIdle()
        #expect(ended == [managed])
        #expect(!close.isClosing)
    }

    @Test(arguments: [
        TerminalTeardownIntent.applicationTermination, .suspension, .remoteExit, .detach,
    ])
    func passiveTeardownPreservesManagedSessions(intent: TerminalTeardownIntent) async {
        let close = RemoteSessionCloseCoordinator { _ in
            Issue.record("Passive teardown must not terminate a remote session")
        }
        #expect(!close.enqueue(closeRequest(reference()), intent: intent))
        await close.waitUntilIdle()
        #expect(!close.isClosing)
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

    @Test func batchCloseAttemptsEachOwnedIdentityOnceAndContinuesAfterFailure() async {
        let first = reference()
        var duplicate = first
        duplicate.session = .init(
            id: first.session.id, name: "Renamed", identity: first.session.identity, windows: 2, clients: 3)
        let second = reference()
        let third = reference()
        var terminated: [RemoteSessionReference] = []
        var attempted: [RemoteSessionReference] = []
        let close = RemoteSessionCloseCoordinator { request in
            attempted.append(request.reference)
            if request.reference == second { throw RemoteSessionFailure.timedOut }
            terminated.append(request.reference)
        }
        for reference in [first, duplicate, second, third] { close.enqueue(closeRequest(reference)) }
        await close.waitUntilIdle()
        #expect(Set(attempted) == Set([first, second, third]))
        #expect(attempted.count == 3)
        #expect(Set(terminated) == Set([first, third]))
    }

    @Test func cancellationBeforeBackgroundCloseStartsDoesNotOpenConnections() async {
        var attempts = 0
        let close = RemoteSessionCloseCoordinator { _ in attempts += 1 }
        close.enqueue(closeRequest(reference()))
        close.enqueue(closeRequest(reference()))
        close.cancelAll()
        await close.waitUntilIdle()
        #expect(attempts == 0)
        #expect(!close.isClosing)
    }

    @Test func timeoutCancelsCleanupWithoutRetrying() async {
        var attempts = 0
        var cancelled = false
        let close = RemoteSessionCloseCoordinator(timeout: .milliseconds(30)) { _ in
            attempts += 1
            do { try await Task.sleep(for: .seconds(60)) } catch {
                cancelled = true
                throw error
            }
        }
        close.enqueue(closeRequest(reference()))
        await close.waitUntilIdle()
        #expect(attempts == 1)
        #expect(cancelled)
        #expect(!close.isClosing)
    }

    private func closeRequest(_ reference: RemoteSessionReference) -> RemoteSessionCloseRequest {
        .init(
            reference: reference,
            snapshot: .init(
                target: .init(
                    id: reference.hostID, name: "Host", host: "host", port: 22,
                    authentication: .init(username: "u", permitsNone: true), expectedHostKeys: [], proxy: nil)))
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
        nonisolated let id: SessionPersistenceBackendID
        init(id: SessionPersistenceBackendID = .init(rawValue: "test-backend")) { self.id = id }
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
