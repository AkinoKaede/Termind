// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import TermindPresentation
import Testing

@testable import TermindRemoteInfrastructure

@Suite @MainActor
struct SessionHistoryTests {
    @Test func returningToAPaneRestoresStableRowsWithoutAnotherRead() async {
        let model = CommandHistoryModel()
        let generation = UUID()
        let first = historyContext(pane: "a", path: "/a/history")
        let second = historyContext(pane: "b", path: "/b/history")
        let firstRead = HistoryReadGate()
        let secondRead = HistoryReadGate()
        model.load(using: firstRead, source: model.selectContext(first, generation: generation))
        await firstRead.waitForRead()
        await firstRead.finish([.init(command: "first file")])
        #expect(await settles { model.hasLoaded })
        let firstIDs = model.entries().map(\.id)
        let sharedFile = historyContext(pane: "shared", path: "/a/history", instance: "another-shell")
        model.load(using: firstRead, source: model.selectContext(sharedFile, generation: generation))
        #expect(model.hasLoaded)
        #expect(!model.isLoading)
        #expect(model.entries().map(\.id) == firstIDs)
        #expect(await firstRead.readCount == 1)
        model.load(using: secondRead, source: model.selectContext(second, generation: generation))
        await secondRead.waitForRead()
        await secondRead.finish([])
        #expect(await settles { model.hasLoaded })

        model.load(using: firstRead, source: model.selectContext(first, generation: generation))
        #expect(model.hasLoaded)
        #expect(!model.isLoading)
        #expect(model.entries().map(\.id) == firstIDs)
        #expect(await firstRead.readCount == 1)
        model.selectContext(nil, generation: generation)
        #expect(model.entries().isEmpty)
        model.selectContext(first, generation: generation)
        #expect(model.entries().map(\.id) == firstIDs)
        model.load(using: secondRead, source: model.selectContext(second, generation: generation))
        #expect(model.hasLoaded)
        #expect(model.entries().isEmpty)
        #expect(await secondRead.readCount == 1)

        model.selectContext(first, generation: UUID())
        #expect(!model.hasLoaded)
        #expect(model.entries().isEmpty)
    }

    @Test func switchingPanesRejectsOldFileReadsAndKeepsObservedCommands() async throws {
        let model = CommandHistoryModel()
        let generation = UUID()
        let first = historyContext(pane: "a", path: "/a/history")
        let second = historyContext(pane: "b", path: "/b/history")
        let stale = HistoryReadGate()
        let current = HistoryReadGate()
        model.record("observed live command")
        model.load(using: stale, source: model.selectContext(first, generation: generation))
        await stale.waitForRead()
        model.load(using: current, source: model.selectContext(second, generation: generation))
        await current.waitForRead()
        await current.finish([.init(command: "pane b history")])
        #expect(await settles { model.hasLoaded })
        await stale.finish([.init(command: "pane a history")])
        for _ in 0..<20 { await Task.yield() }
        #expect(model.entries().map(\.command) == ["observed live command", "pane b history"])
        model.selectContext(nil, generation: generation)
        #expect(model.entries().map(\.command) == ["observed live command"])
        #expect(!model.hasLoaded)
    }

    @Test func historyFileCacheExpiresOnNewConnectionOrFileButNotPromptSequence() async {
        let model = CommandHistoryModel()
        var generation = UUID()
        var context = historyContext(pane: "a", path: "/a/history")
        for change in 0..<3 {
            let gate = HistoryReadGate()
            model.load(using: gate, source: model.selectContext(context, generation: generation))
            await gate.waitForRead()
            await gate.finish([.init(command: "snapshot \(change)")])
            #expect(await settles { model.hasLoaded })
            var typing = context
            typing.sequence += 1
            typing.promptReady = false
            model.selectContext(typing, generation: generation)
            model.load(using: gate, source: typing.historySource)
            #expect(await gate.readCount == 1)
            #expect(model.entries().map(\.command) == ["snapshot \(change)"])
            switch change {
            case 0: context.historyPath = "/a/new history"
            case 1: generation = UUID()
            default: break
            }
        }
    }

    @Test func unverifiedHistoryNeverFallsBackToAnOuterShellFile() {
        var context = historyContext(pane: "a", path: "/a/history")
        context.historyPath = nil
        #expect(context.historySource == nil)
        context.historyPath = "relative"
        #expect(context.historySource == nil)
        context.historyPath = ""
        #expect(context.historySource == .init(shell: .bash, path: ""))
        context.shell = "unknown"
        #expect(context.historySource == nil)
    }

    private func historyContext(pane: String, path: String, instance: String = "shell") -> TerminalShellContext {
        .init(
            identity: .init(backend: "test", server: "server", session: "session", pane: pane, shellInstance: instance),
            shell: "bash", directory: "/", home: "/home/test", promptReady: true, sequence: 1,
            capabilities: [.commandLifecycle], historyPath: path)
    }

    @Test func snapshotDoesNotReplaceLiveCommandsAndLoadsOnlyOnce() async throws {
        let gate = HistoryReadGate()
        let model = CommandHistoryModel()
        model.load(using: gate, source: nil)
        await gate.waitForRead()
        let live = try #require(model.record("pwd", at: Date(timeIntervalSince1970: 12.5)))
        model.recordCompletion(for: live.id, exitStatus: 0, duration: 0.25)
        await gate.finish([
            .init(command: "pwd", executedAt: Date(timeIntervalSince1970: 10)),
            .init(command: "old without time"),
            .init(command: "pwd", executedAt: Date(timeIntervalSince1970: 12)),
        ])
        #expect(await settles { model.hasLoaded })
        let entries = model.entries()
        #expect(entries.map(\.command) == ["pwd", "old without time", "pwd"])
        #expect(entries.first?.id == live.id)
        #expect(entries.first?.exitStatus == 0)
        #expect(entries.first?.duration == 0.25)
        model.cancelLoading()
        model.load(using: gate, source: nil)
        #expect(await gate.readCount == 1)
    }

    @Test func cancelledOrClosedReadsCannotPublishAndReconnectCanRetry() async {
        let stale = HistoryReadGate()
        let current = HistoryReadGate()
        let model = CommandHistoryModel()
        model.record("live")
        model.load(using: stale, source: nil)
        await stale.waitForRead()
        model.cancelLoading()
        model.load(using: current, source: nil)
        await current.waitForRead()
        await stale.finish([.init(command: "stale")])
        await current.finish([.init(command: "current")])
        #expect(await settles { model.hasLoaded })
        #expect(model.entries().map(\.command) == ["live", "current"])

        let closing = HistoryReadGate()
        let closed = CommandHistoryModel()
        closed.load(using: closing, source: nil)
        await closing.waitForRead()
        closed.close()
        await closing.finish([.init(command: "too late")])
        for _ in 0..<20 { await Task.yield() }
        #expect(closed.entries().isEmpty)
        #expect(closed.record("callback") == nil)
        #expect(!closed.hasLoaded)
    }

    @Test func failureKeepsLiveRecordsAndAnEmptySuccessfulReadStopsRetries() async {
        let model = CommandHistoryModel()
        model.record("retained")
        model.load(using: FailedHistoryRead(), source: nil)
        #expect(await settles { model.loadError != nil })
        #expect(model.entries().map(\.command) == ["retained"])
        let empty = HistoryReadGate()
        model.load(using: empty, source: nil)
        await empty.waitForRead()
        await empty.finish([])
        #expect(await settles { model.hasLoaded })
        #expect(model.loadError == nil)
    }

    @Test func unknownTimeHasNoSubtitleButKnownDurationStillDisplays() {
        var entry = CommandHistoryEntry(sessionID: UUID(), command: "pwd")
        #expect(CommandHistoryPresentation.subtitle(for: entry, locale: Locale(identifier: "en")).isEmpty)
        entry.duration = 2
        #expect(!CommandHistoryPresentation.subtitle(for: entry, locale: Locale(identifier: "en")).isEmpty)
    }

    private func settles(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<1000 {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }
}

private actor HistoryReadGate: ShellHistoryLoading {
    private var continuation: CheckedContinuation<[ShellHistoryRecord], Never>?
    private(set) var readCount = 0
    func load(source: ShellHistorySource?) async throws -> [ShellHistoryRecord] {
        readCount += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func waitForRead() async {
        while continuation == nil { await Task.yield() }
    }
    func finish(_ records: [ShellHistoryRecord]) {
        continuation?.resume(returning: records)
        continuation = nil
    }
}

private struct FailedHistoryRead: ShellHistoryLoading {
    func load(source: ShellHistorySource?) async throws -> [ShellHistoryRecord] {
        throw CocoaError(.fileReadNoPermission)
    }
}

@Suite
struct ShellHistoryParsingTests {
    @Test func bashPreservesRepeatedCommandsAndTimestampedMultilineRecords() {
        let records = ShellHistoryParser.parse("#100\nprintf 'one\ntwo'\n#101\npwd\n#102\npwd\n", shell: .bash)
        #expect(records.map(\.command) == ["printf 'one\ntwo'", "pwd", "pwd"])
        #expect(records.map { $0.executedAt?.timeIntervalSince1970 } == [100, 101, 102])
        let plain = ShellHistoryParser.parse("pwd\npwd\npartial", shell: .bash)
        #expect(plain.map(\.command) == ["pwd", "pwd"])
        #expect(plain.allSatisfy { $0.executedAt == nil })
    }

    @Test func zshAndFishDecodeTheirOwnMultilineFormats() {
        let zsh = ShellHistoryParser.parse(": 100:2;printf 'one\\\ntwo'\n: 103:0;pwd\n", shell: .zsh)
        #expect(zsh.map(\.command) == ["printf 'one\ntwo'", "pwd"])
        #expect(zsh.first?.duration == 2)
        let fish = ShellHistoryParser.parse(
            "- cmd: printf one\\ntwo\\\\three\n  when: 100\n  paths:\n    - /tmp\n- cmd: pwd\n", shell: .fish)
        #expect(fish.map(\.command) == ["printf one\ntwo\\three", "pwd"])
        #expect(fish.first?.executedAt?.timeIntervalSince1970 == 100)
        #expect(fish.last?.executedAt == nil)
    }

    @Test func truncatedRecordsDoNotTurnIntoCommands() {
        #expect(
            ShellHistoryParser.parse("broken\nremaining\n#123\npwd\n", shell: .bash, truncatedStart: true)
                .map(\.command) == ["pwd"])
        #expect(
            ShellHistoryParser.parse("broken\nremaining\n: 123:0;pwd\n", shell: .zsh, truncatedStart: true)
                .map(\.command) == ["pwd"])
        #expect(
            ShellHistoryParser.parse("broken\n  when: 123\n- cmd: pwd\n", shell: .fish, truncatedStart: true)
                .map(\.command) == ["pwd"])
    }

    @Test(arguments: ["bash", "zsh", "fish"])
    func realInjectedScriptsAreFilteredWithoutHidingUserText(shell: String) throws {
        var bootstrap = RemoteShellIntegrationBootstrap(token: "OLD123")
        #expect(ShellHistoryFilter.isIntegrationCommand(String(decoding: bootstrap.startCommand, as: UTF8.self)))
        let update = bootstrap.receive(Data("__TRMD_OLD123_SHELL__/bin/\(shell)__\n".utf8))
        let install = String(decoding: try #require(update.command), as: UTF8.self)
        #expect(ShellHistoryFilter.isIntegrationCommand(install))
        #expect(ShellHistoryFilter.isIntegrationCommand("__termind_report_prompt"))
        #expect(!ShellHistoryFilter.isIntegrationCommand("echo __termind_report_prompt"))
        #expect(!ShellHistoryFilter.isIntegrationCommand("grep '__TRMD_OLD123_PROBE__' log"))
        #expect(!ShellHistoryFilter.isIntegrationCommand("npm run integration"))
    }

    @Test func bootstrapCarriesExplicitCustomOrDisabledHistoryPaths() throws {
        for path in ["%2Fhome%2Fuser%2Fcustom%20history", ""] {
            var bootstrap = RemoteShellIntegrationBootstrap(token: "SOURCE")
            _ = bootstrap.receive(Data("__TRMD_SOURCE_SHELL__/bin/bash__\n".utf8))
            let result = bootstrap.receive(Data("__TRMD_SOURCE_HISTORY__\(path)\n__TRMD_SOURCE_DONE__\n".utf8))
            #expect(result.historySource?.shell == .bash)
            #expect(result.historySource?.path == (path.isEmpty ? "" : "/home/user/custom history"))
        }
    }
}

@Suite @MainActor
struct RetiredSessionHistoryMigrationTests {
    @Test func version48RetainsCloudHistoryJournalsAndDeviceStateAfterMigrationAndReopening() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("CloudHistory.store")
        let device = DeviceRecord(id: UUID(), displayName: "Original device")
        let event = ConnectionHistoryEntry(
            hostID: UUID(), kind: .sftp, connectedAt: Date(timeIntervalSince1970: 100),
            sourceDeviceID: device.id, endedAt: Date(timeIntervalSince1970: 200))
        let deletedEvent = ConnectionHistoryEntry(hostID: event.hostID, kind: .ssh)
        let version = VaultVersion(modifiedAt: Date(timeIntervalSince1970: 300), counter: 4, writerID: device.id)
        let eventPayload = HistoryRecordPayload.connectionHistory(event)
        let devicePayload = HistoryRecordPayload.device(device)
        let envelopes = [
            HistoryEnvelope(key: eventPayload.key, version: version, payload: eventPayload),
            HistoryEnvelope(key: devicePayload.key, version: version, payload: devicePayload),
            HistoryEnvelope(
                key: .init(kind: .connectionHistory, id: deletedEvent.id), version: version, isDeleted: true),
            HistoryEnvelope(key: .init(kind: .device, id: UUID()), version: version, isDeleted: true),
        ]
        try writeCloudHistoryStore(url, event: event, device: device, envelopes: envelopes)
        for _ in 0..<2 {
            let container = try TermindPersistence.makeContainer(url: url)
            let context = container.mainContext
            let persistence = HistorySyncPersistence(context: context)
            try persistence.prepare()
            #expect(try context.fetch(FetchDescriptor<PersistentConnectionHistoryEntry>()).map(\.value) == [event])
            let devices = try context.fetch(FetchDescriptor<PersistentDeviceRecord>())
            #expect(
                devices.count == 1 && devices.first?.id == device.id && devices.first?.displayName == device.displayName
            )
            let rows = try context.fetch(FetchDescriptor<PersistentHistorySyncEntry>())
            #expect(Set(rows.compactMap(\.envelope)) == Set(envelopes))
            for (index, envelope) in envelopes.enumerated() {
                let row = try #require(rows.first { $0.recordName == envelope.key.recordName })
                #expect(row.systemFieldsData == Data([UInt8(index), 42]))
                #expect(row.needsUpload == (index != 1))
            }
            for kind in HistoryRecordKind.allCases {
                let state = try HistorySyncJournal(context: context, kind: kind).state()
                #expect(state.bootstrapCompleted)
                #expect(state.installationID == device.id)
                #expect(state.boundUserRecordName == "account-\(kind.rawValue)")
                #expect(state.pendingUserRecordName == "pending-\(kind.rawValue)")
                #expect(state.engineStateData == Data(kind.rawValue.utf8))
                #expect(state.lastSuccessfulSync == version.modifiedAt)
            }
            let late = HistoryRecordPayload.connectionHistory(deletedEvent)
            _ = try persistence.applyRemote([
                HistoryEnvelope(
                    key: late.key, version: .next(after: version, writerID: UUID()), payload: late)
            ])
            #expect(try persistence.journal.envelope(for: late.key)?.isDeleted == true)
            #expect(try context.fetch(FetchDescriptor<PersistentConnectionHistoryEntry>()).map(\.value) == [event])
        }
    }

    private func writeCloudHistoryStore(
        _ url: URL, event: ConnectionHistoryEntry, device: DeviceRecord, envelopes: [HistoryEnvelope]
    ) throws {
        let schema = Schema(versionedSchema: TermindSchemaV48.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration("Termind", schema: schema, url: url, cloudKitDatabase: .none)])
        let context = container.mainContext
        context.insert(PersistentConnectionHistoryEntry(event))
        context.insert(PersistentDeviceRecord(device))
        context.insert(PersistentCommandHistoryEntry(hostID: event.hostID, command: "retired", executedAt: .now))
        context.insert(
            PersistentSFTPHistoryEntry(hostID: event.hostID, kind: "file", path: "/retired", visitedAt: .now))
        for (index, envelope) in envelopes.enumerated() {
            let row = try PersistentHistorySyncEntry(envelope: envelope, needsUpload: index != 1)
            row.systemFieldsData = Data([UInt8(index), 42])
            context.insert(row)
        }
        for kind in HistoryRecordKind.allCases {
            let state = try HistorySyncJournal(context: context, kind: kind).state()
            state.bootstrapCompleted = true
            state.installationID = device.id
            state.boundUserRecordName = "account-\(kind.rawValue)"
            state.pendingUserRecordName = "pending-\(kind.rawValue)"
            state.engineStateData = Data(kind.rawValue.utf8)
            state.lastSuccessfulSync = envelopes[0].version.modifiedAt
        }
        try context.save()
    }

    @Test(arguments: [9, 48])
    func oldStoresDropSessionHistoryAndRetainOtherDataAfterReopening(version: Int) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.store")
        let group = HostGroup(name: "Keep this group")
        try writeLegacyStore(version: version, url: url, group: group)
        for _ in 0..<2 {
            let container = try TermindPersistence.makeContainer(url: url)
            let names = container.schema.entities.map(\.name)
            #expect(!names.contains("PersistentCommandHistoryEntry"))
            #expect(!names.contains("PersistentSFTPHistoryEntry"))
            #expect(try container.mainContext.fetch(FetchDescriptor<PersistentHostGroup>()).map(\.value) == [group])
        }
    }

    private func writeLegacyStore(version: Int, url: URL, group: HostGroup) throws {
        let schema =
            version == 9
            ? Schema(versionedSchema: TermindSchemaV9.self) : Schema(versionedSchema: TermindSchemaV48.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration("Termind", schema: schema, url: url, cloudKitDatabase: .none)
            ])
        container.mainContext.insert(PersistentHostGroup(group))
        if version == 9 {
            container.mainContext.insert(
                TermindSchemaV9Models.PersistentCommandHistoryEntry(
                    hostID: UUID(), command: "old", executedAt: Date()))
        } else {
            container.mainContext.insert(
                PersistentCommandHistoryEntry(hostID: UUID(), command: "old", executedAt: Date()))
        }
        container.mainContext.insert(
            PersistentSFTPHistoryEntry(hostID: UUID(), kind: "directory", path: "/old", visitedAt: Date()))
        try container.mainContext.save()
    }
}
