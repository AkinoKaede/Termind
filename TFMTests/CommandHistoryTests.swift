// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite
@MainActor
struct CommandHistoryTests {
    @Test
    func historyNormalizesExplicitContinuationsAndPreservesRealLineBreaks() throws {
        let hostID = UUID()
        let legacy = CommandHistoryEntry(
            sessionID: hostID,
            command: "printf legacy \\\r\n\t value\nprintf retained"
        )
        let store = CommandHistoryModel(sessionID: hostID, entries: [legacy])

        let newCommand =
            "printf new \\\n                value \\\n                  again\nprintf retained"
        let recorded = try #require(store.record(newCommand))

        #expect(recorded.command == "printf new value again\nprintf retained")
        #expect(
            store.entries().map(\.command) == [
                "printf new value again\nprintf retained",
                "printf legacy value\nprintf retained",
            ]
        )
        #expect(
            CommandHistoryEntry.normalizingLineContinuations(
                in: "printf escaped \\\\\nnext"
            ) == "printf escaped \\\\\nnext"
        )
    }

    @Test
    func historyTitleShowsOneLogicalLineWithoutChangingTheCommand() {
        let single = CommandHistoryEntry(sessionID: UUID(), command: "uptime")
        let multiline = CommandHistoryEntry(
            sessionID: UUID(), command: "printf first\nprintf second"
        )
        let windowsMultiline = CommandHistoryEntry(
            sessionID: UUID(), command: "printf first\r\nprintf second"
        )

        #expect(CommandHistoryPresentation.title(for: single) == "uptime")
        #expect(CommandHistoryPresentation.title(for: multiline) == "printf first…")
        #expect(CommandHistoryPresentation.title(for: windowsMultiline) == "printf first…")
        #expect(multiline.command == "printf first\nprintf second")
    }

    @Test func memoryStoresKeepDuplicatesAndIsolateSessions() {
        let first = CommandHistoryModel()
        let second = CommandHistoryModel()
        first.record("uptime")
        first.record("uptime")
        second.record("other")
        #expect(first.entries(matching: "TIME").map(\.command) == ["uptime", "uptime"])
        #expect(second.entries().map(\.command) == ["other"])
        first.close()
        #expect(first.entries().isEmpty)
        #expect(second.entries().count == 1)
    }

    @Test
    func completionEnrichesExistingHistoryWithoutCreatingAnotherRow() throws {
        let store = CommandHistoryModel()
        let entry = try #require(store.record("false"))

        let completed = store.recordCompletion(
            for: entry.id, exitStatus: 1, duration: 0.25
        )

        #expect(completed?.exitStatus == 1)
        #expect(completed?.duration == 0.25)
        #expect(store.entries().count == 1)
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
        #expect(session.commandHistory.entries().isEmpty)

        session.recordExecutedCommand(command)
        #expect(session.commandHistory.entries().map(\.command) == [command])
    }

    @Test
    func continuedStartupCommandIsExcludedAfterHistoryNormalization() {
        let submittedCommand = "printf '%s' one \\\n            two"
        let reportedCommand = "printf '%s' one \\\n                two"
        let session = SSHSessionModel(
            host: Host(name: "Files", host: "files.example"),
            initialCommand: submittedCommand,
            recordsInitialCommandInHistory: false
        )

        session.submitPendingInitialCommand()
        session.recordExecutedCommand(reportedCommand)

        #expect(session.commandHistory.entries().isEmpty)
    }

    @Test
    func ordinaryStartupCommandStillAppearsInHistory() {
        let session = SSHSessionModel(
            host: Host(name: "Shell", host: "shell.example"),
            initialCommand: "uptime"
        )

        session.submitPendingInitialCommand()
        session.recordExecutedCommand("uptime")

        #expect(session.commandHistory.entries().map(\.command) == ["uptime"])
    }

    @Test
    func startupCommandWaitsForTheShellBootstrapBeforeSubmitting() {
        let session = SSHSessionModel(
            host: Host(name: "Shell", host: "shell.example"),
            initialCommand: "uptime"
        )
        var submitted = Data()
        session.inputSink = { submitted.append($0) }
        session.status = .connected

        #expect(submitted.isEmpty)
        session.receiveShellIntegrationEvent(
            .available(shell: "zsh", systemInfo: nil, homeDirectory: "/home/test")
        )

        #expect(String(decoding: submitted, as: UTF8.self) == "uptime\r")
    }

    @Test
    func shellLifecycleCompletesTheMatchingTransientHistoryRow() throws {
        let session = SSHSessionModel(host: Host(name: "Shell", host: "shell.example"))

        session.receiveShellIntegrationEvent(.commandStarted("false"))
        session.receiveShellIntegrationEvent(.commandFinished(1, duration: 5))

        let entry = try #require(session.commandHistory.entries().first)
        #expect(entry.command == "false")
        #expect(entry.exitStatus == 1)
        #expect(entry.duration == 5)
    }

    @Test
    func shellLifecycleStoresContinuedCommandsWithOneSpacePerBoundary() throws {
        let session = SSHSessionModel(host: Host(name: "Shell", host: "shell.example"))

        session.receiveShellIntegrationEvent(
            .commandStarted("printf first \\\n                second\nprintf retained")
        )

        let entry = try #require(session.commandHistory.entries().first)
        #expect(entry.command == "printf first second\nprintf retained")
    }

    @Test func sessionsOnTheSameHostAreIndependentAndClosingPreventsLateCommands() {
        let host = Host(name: "Shared", host: "example.invalid")
        let first = SSHSessionModel(host: host)
        let second = SSHSessionModel(host: host)
        first.recordExecutedCommand("first")
        second.recordExecutedCommand("second")
        first.disconnect()
        #expect(first.commandHistory.entries().map(\.command) == ["first"])
        let clone = first.copyForReconnect()
        #expect(clone.commandHistory.entries().isEmpty)
        let pane = Pane(.sshSession(first))
        pane.disconnectConnection()
        first.recordExecutedCommand("late")
        #expect(first.commandHistory.entries().isEmpty)
        #expect(second.commandHistory.entries().map(\.command) == ["second"])
        pane.prepareForReopen()
        #expect(pane.sshSession?.commandHistory.entries().isEmpty == true)
        #expect(pane.sshSession?.id != first.id)
    }

    @Test func reopenedSFTPPaneCannotReceiveOldTransferHistory() {
        let channel = SFTPChannelModel(hostID: UUID())
        let pane = Pane(.sftpChannel(channel))
        let oldHistory = channel.history
        oldHistory.record(kind: .file, path: "/before")
        pane.disconnectConnection()
        pane.prepareForReopen()
        oldHistory.record(kind: .file, path: "/late")
        #expect(oldHistory.entries().isEmpty)
        #expect(channel.history.entries().isEmpty)
        #expect(channel.history.sessionID != oldHistory.sessionID)
        channel.recordOpenedFile(at: "/current")
        #expect(channel.history.entries().map(\.path) == ["/current"])
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
    func transportsAChunkedBackslashContinuationAsOneCommandEvent() {
        var filter = RemoteCommandEventFilter(token: "TOKEN")
        let first = filter.receive(
            Data("\u{1B}]777;TermindCommand=TOKEN;printf%20one%20%5C%0A".utf8)
        )
        let second = filter.receive(Data("%20%20two\u{7}".utf8))

        #expect(first.events.isEmpty)
        #expect(second.events == [.commandStarted("printf one \\\n  two")])
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
