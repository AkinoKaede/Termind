import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite
@MainActor
struct CommandHistoryTests {
    @Test
    func memoryStoreKeepsDuplicatesSearchesAndScopesByHost() throws {
        let firstHost = UUID()
        let secondHost = UUID()
        let store = CommandHistoryModel()

        store.record("uptime", for: firstHost, at: Date(timeIntervalSince1970: 1))
        let duplicate = try #require(
            store.record("uptime", for: firstHost, at: Date(timeIntervalSince1970: 2))
        )
        store.record("系统状态", for: firstHost, at: Date(timeIntervalSince1970: 3))
        store.record("other", for: secondHost, at: Date(timeIntervalSince1970: 4))

        #expect(store.entries(for: firstHost).map(\.command) == ["系统状态", "uptime", "uptime"])
        #expect(store.entries(for: firstHost, matching: "TIME").count == 2)
        #expect(store.entries(for: secondHost).map(\.command) == ["other"])

        store.delete(duplicate.id)
        #expect(store.entries(for: firstHost).map(\.command) == ["系统状态", "uptime"])
        store.clear(for: firstHost)
        #expect(store.entries(for: firstHost).isEmpty)
        #expect(store.entries(for: secondHost).count == 1)
    }

    @Test
    func completionEnrichesExistingHistoryWithoutCreatingAnotherRow() throws {
        let hostID = UUID()
        let store = CommandHistoryModel()
        let entry = try #require(store.record("false", for: hostID))

        let completed = store.recordCompletion(
            for: entry.id, hostID: hostID, exitStatus: 1, duration: 0.25
        )

        #expect(completed?.exitStatus == 1)
        #expect(completed?.duration == 0.25)
        #expect(store.entries(for: hostID).count == 1)
    }

    @Test
    func storeRejectsBlankCommandsAndTrimsPerHost() {
        let hostID = UUID()
        let store = CommandHistoryModel()
        #expect(store.record(" \n\t ", for: hostID) == nil)

        for index in 0...CommandHistoryModel.perHostLimit {
            store.record(
                "command-\(index)", for: hostID,
                at: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        let commands = store.entries(for: hostID).map(\.command)
        #expect(commands.count == CommandHistoryModel.perHostLimit)
        #expect(commands.first == "command-1000")
        #expect(commands.last == "command-1")
    }

    @Test
    func swiftDataStorePersistsIncrementally() throws {
        let container = try makeContainer("CommandHistoryPersistence")
        let hostID = UUID()
        let entryID: UUID
        do {
            let store = CommandHistoryModel(modelContext: container.mainContext)
            entryID = try #require(store.record("echo 持久化", for: hostID)).id
            store.recordCompletion(
                for: entryID, hostID: hostID, exitStatus: 7, duration: 1.5
            )
            #expect(store.storageError == nil)
            #expect(
                try container.mainContext.fetch(
                    FetchDescriptor<PersistentCommandHistoryEntry>()
                ).count == 1
            )
        }

        let reloaded = CommandHistoryModel(modelContext: container.mainContext)
        #expect(reloaded.entries(for: hostID).map(\.id) == [entryID])
        #expect(reloaded.entries(for: hostID).map(\.command) == ["echo 持久化"])
        #expect(reloaded.entries(for: hostID).map(\.exitStatus) == [7])
        #expect(reloaded.entries(for: hostID).map(\.duration) == [1.5])
        #expect(reloaded.storageError == nil)
    }

    @Test
    func schemaV9HistoryMigratesWithUnknownCompletion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TermindCommandHistoryV10Migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Termind.store")
        let legacySchema = Schema(versionedSchema: TermindSchemaV9.self)
        let value = CommandHistoryEntry(
            hostID: UUID(), command: "uptime",
            executedAt: Date(timeIntervalSince1970: 123)
        )

        var legacyContainer: ModelContainer? = try ModelContainer(
            for: legacySchema,
            configurations: [
                localModelConfiguration(
                    "CommandHistoryMigration", schema: legacySchema, url: storeURL
                )
            ]
        )
        legacyContainer?.mainContext.insert(
            TermindSchemaV9Models.PersistentCommandHistoryEntry(value)
        )
        try legacyContainer?.mainContext.save()
        legacyContainer = nil

        let migrated = try ModelContainer(
            for: HostPersistence.schema,
            migrationPlan: TermindMigrationPlan.self,
            configurations: [
                localModelConfiguration(
                    "CommandHistoryMigration", schema: HostPersistence.schema,
                    url: storeURL
                )
            ]
        )
        let entries = try migrated.mainContext.fetch(
            FetchDescriptor<PersistentCommandHistoryEntry>()
        ).map(\.value)

        #expect(entries.map(\.command) == ["uptime"])
        #expect(entries.first?.exitStatus == nil)
        #expect(entries.first?.duration == nil)
    }

    @Test
    func sftpStartupDirectoryIsExecutedButExcludedFromHistoryOnce() {
        let command = "cd '/srv/app'"
        let session = SSHSessionModel(
            host: Host(name: "Files", host: "files.example"),
            initialCommand: command,
            recordsInitialCommandInHistory: false
        )
        var submitted = Data()
        session.inputSink = { submitted.append($0) }

        session.submitPendingInitialCommand()
        session.recordExecutedCommand(command)

        #expect(String(decoding: submitted, as: UTF8.self) == "\(command)\r")
        #expect(session.transientCommandHistory.isEmpty)

        session.recordExecutedCommand(command)
        #expect(session.transientCommandHistory.map(\.command) == [command])
    }

    @Test
    func ordinaryStartupCommandStillAppearsInHistory() {
        let session = SSHSessionModel(
            host: Host(name: "Shell", host: "shell.example"),
            initialCommand: "uptime"
        )

        session.submitPendingInitialCommand()
        session.recordExecutedCommand("uptime")

        #expect(session.transientCommandHistory.map(\.command) == ["uptime"])
    }

    @Test
    func shellLifecycleCompletesTheMatchingTransientHistoryRow() throws {
        let session = SSHSessionModel(host: Host(name: "Shell", host: "shell.example"))

        session.receiveShellIntegrationEvent(.commandStarted("false"))
        session.receiveShellIntegrationEvent(.commandFinished(1, duration: 5))

        let entry = try #require(session.transientCommandHistory.first)
        #expect(entry.command == "false")
        #expect(entry.exitStatus == 1)
        #expect(entry.duration == 5)
    }

    private func makeContainer(_ name: String) throws -> ModelContainer {
        let configuration = localModelConfiguration(
            name, schema: HostPersistence.schema, isStoredInMemoryOnly: true
        )
        return try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
    }
}

@Suite
struct RemoteCommandEventFilterTests {
    @Test
    func ordinaryOSCWindowTitlesRemainVisibleToGhostty() {
        var filter = RemoteCommandEventFilter(token: "TOKEN")
        let data = Data(
            "\u{1B}]0;kaede@host:/srv\u{7}\u{1B}]2;host: command\u{7}".utf8
        )

        let update = filter.receive(data)

        #expect(update.visibleOutput == data)
        #expect(update.events.isEmpty)
    }

    @Test
    func filtersChunkedEventsAndPreservesSurroundingOutput() {
        var filter = RemoteCommandEventFilter(token: "TOKEN")
        let first = filter.receive(Data("before\u{1B}]777;TermindCom".utf8))
        #expect(String(decoding: first.visibleOutput, as: UTF8.self) == "before")
        #expect(first.events.isEmpty)

        let second = filter.receive(
            Data("mand=TOKEN;echo%20%E4%BD%A0%E5%A5%BD%0Asecond\u{7}after".utf8)
        )
        #expect(second.events == [.commandStarted("echo 你好\nsecond")])
        #expect(String(decoding: second.visibleOutput, as: UTF8.self) == "after")
    }

    @Test
    func wrongTokenAndOrdinaryOutputRemainVisible() {
        var filter = RemoteCommandEventFilter(token: "RIGHT")
        let data = Data("x\u{1B}]777;TermindCommand=WRONG;rm%20-rf%20/%07y".utf8)
        let update = filter.receive(data)

        #expect(update.events.isEmpty)
        #expect(update.visibleOutput == data)
    }

    @Test
    func filtersChunkedPromptAndUnicodeDraftEvents() {
        var filter = RemoteCommandEventFilter(token: "TOKEN")
        let first = filter.receive(Data("before\u{1B}]777;TermindPrompt=TO".utf8))
        #expect(first.visibleOutput == Data("before".utf8))
        #expect(first.events.isEmpty)

        let second = filter.receive(
            Data("KEN\u{7}\u{1B}]777;TermindDraft=TOKEN;echo%20%E4%BD%A0".utf8)
        )
        #expect(second.visibleOutput.isEmpty)
        #expect(second.events == [.promptReady])

        let third = filter.receive(Data("%E5%A5%BD\u{7}after".utf8))
        #expect(third.events == [.draft("echo 你好")])
        #expect(third.visibleOutput == Data("after".utf8))
    }

    @Test
    func acceptsAuthenticatedEmptyDraft() {
        var filter = RemoteCommandEventFilter(token: "TOKEN")
        let update = filter.receive(
            Data("\u{1B}]777;TermindDraft=TOKEN;\u{7}".utf8)
        )

        #expect(update.events == [.draft("")])
        #expect(update.visibleOutput.isEmpty)
    }

    @Test
    func preservesLifecycleEventOrderWithinOneRead() {
        var filter = RemoteCommandEventFilter(token: "TOKEN")
        let update = filter.receive(
            Data(
                ("\u{1B}]777;TermindCommand=TOKEN;first\u{7}"
                    + "\u{1B}]777;TermindCommandFinished=TOKEN;3;5000\u{7}"
                    + "\u{1B}]777;TermindPrompt=TOKEN\u{7}"
                    + "\u{1B}]777;TermindCommand=TOKEN;second\u{7}").utf8
            )
        )

        #expect(
            update.events == [
                .commandStarted("first"), .commandFinished(3, duration: 5),
                .promptReady,
                .commandStarted("second"),
            ]
        )
    }

    @Test
    func oversizedUnterminatedAuthenticatedFrameIsDroppedAndParsingRecovers() {
        var filter = RemoteCommandEventFilter(token: "TOKEN")
        let malformed =
            "before\u{1B}]777;TermindCommand=TOKEN;"
            + String(
                repeating: "x",
                count: RemoteCommandEventFilter.maximumPayloadBytes + 1
            )

        let first = filter.receive(Data(malformed.utf8))
        let second = filter.receive(Data("after".utf8))

        #expect(first.visibleOutput == Data("before".utf8))
        #expect(first.events.isEmpty)
        #expect(second.visibleOutput == Data("after".utf8))
    }

    @Test
    func invalidExitStatusIsIgnored() {
        var filter = RemoteCommandEventFilter(token: "TOKEN")
        let update = filter.receive(
            Data("\u{1B}]777;TermindCommandFinished=TOKEN;999\u{7}".utf8)
        )

        #expect(update.events.isEmpty)
    }
}
