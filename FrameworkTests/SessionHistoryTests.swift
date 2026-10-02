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
