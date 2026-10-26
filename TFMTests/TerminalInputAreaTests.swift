// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@testable import Termind

@MainActor
private final class InputAreaGenerator: CommandGenerating {
    var contexts: [CommandGeneratorContext] = []
    var pending: CheckedContinuation<String, any Error>?

    func generate(_ context: CommandGeneratorContext) async throws -> String {
        contexts.append(context)
        return try await withCheckedThrowingContinuation { pending = $0 }
    }

    func finish(_ result: Result<String, any Error>) {
        let continuation = pending
        pending = nil
        continuation?.resume(with: result)
    }
}

@Suite @MainActor
struct TerminalInputAreaTests {
    @Test
    func preferencesStartHiddenAndOnlyNewModelsInheritTheLastResize() throws {
        let suite = "TerminalInputAreaTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!defaults.bool(forKey: DesktopSettingsKey.showTerminalInputArea))
        let first = TerminalInputAreaModel(defaults: defaults)
        let existing = TerminalInputAreaModel(defaults: defaults)
        #expect(first.preferredHeight == 96)
        first.resize(to: 240, available: 800)
        #expect(first.preferredHeight == 240)
        #expect(existing.preferredHeight == 96)
        let reopenedDefaults = try #require(UserDefaults(suiteName: suite))
        let new = TerminalInputAreaModel(defaults: reopenedDefaults)
        #expect(new.preferredHeight == 240)
        #expect(new.draft.isEmpty && new.mode == .input)
        #expect(TerminalInputAreaModel.height(first.preferredHeight, available: 200) == 120)
        first.resize(to: 120, available: 200)
        #expect(first.preferredHeight == 240)
        #expect(reopenedDefaults.double(forKey: DesktopSettingsKey.terminalInputAreaDefaultHeight) == 240)
    }

    @Test
    func heightRemainsFiniteAndLeavesTerminalSpaceInTinyPanes() {
        for available in [0.0, 60, 136, 300, 900] {
            for preferred in [-100.0, 0, 160, 2_000, .infinity, .nan] {
                let result = TerminalInputAreaModel.height(preferred, available: available)
                #expect(result.isFinite && result >= 0 && result <= available * 0.6)
            }
        }
    }

    @Test
    func submissionPreservesWhitespaceAndOnlyClearsAnAcceptedDraft() {
        let model = TerminalInputAreaModel()
        let text = "  printf 'a\\nb'\n echo next  \n"
        model.draft = text
        var sent: [String] = []
        #expect(!model.submit { _ in throw TerminalInputAreaError.unavailable })
        #expect(model.draft == text && model.error != nil)
        let focus = model.focusRequest
        #expect(model.submit { sent.append($0) })
        #expect(sent == [text])
        #expect(model.draft.isEmpty && model.error == nil)
        #expect(model.focusRequest > focus)
        model.draft = " \n\t"
        #expect(!model.submit { sent.append($0) })
        #expect(sent.count == 1)
    }

    @Test
    func sendsFromTheOwningPaneAndBroadcastsOnceOnlyAfterExplicitSubmission() throws {
        let (workspace, source, other) = fixture()
        defer { for pane in workspace.panes { pane.disconnectConnection() } }
        var first: [Data] = []
        var second: [Data] = []
        source.sshSession?.inputSink = { first.append($0) }
        other.sshSession?.inputSink = { second.append($0) }
        workspace.focus(other.id)
        try workspace.submitInputArea("  echo first\n echo second ", from: source)
        #expect(first == [Data("  echo first\n echo second \r".utf8)])
        #expect(second.isEmpty)
        workspace.broadcastsInput = true
        try workspace.submitInputArea("hostname", from: source)
        #expect(first.last == Data("hostname\r".utf8))
        #expect(second == [Data("hostname\r".utf8)])
        #expect(first.count == 2)
    }

    @Test
    func broadcastPreflightsEveryTargetBeforeSendingAnyBytes() {
        let (workspace, source, other) = fixture()
        defer { for pane in workspace.panes { pane.disconnectConnection() } }
        var writes: [Data] = []
        source.sshSession?.inputSink = { writes.append($0) }
        other.sshSession?.status = .disconnected
        workspace.broadcastsInput = true
        source.terminalInputArea.draft = "echo once"
        #expect(!source.terminalInputArea.submit { try workspace.submitInputArea($0, from: source) })
        #expect(writes.isEmpty)
        #expect(source.terminalInputArea.draft == "echo once")
        #expect(source.terminalInputArea.error != nil)
    }

    @Test
    func revokedHostAccessRejectsSubmissionWithoutLosingTheDraft() {
        let hosts = (0..<4).map {
            Host(
                name: "Host\($0)", host: "host\($0).invalid",
                createdAt: Date(timeIntervalSince1970: Double($0)))
        }
        let library = HostLibraryModel(hosts: hosts)
        library.hostAccess.entitlement = .free
        let pane = Pane.sshSession(host: hosts[3])
        let workspace = Workspace(pane: pane)
        defer { pane.disconnectConnection() }
        guard let session = pane.sshSession else {
            Issue.record("Expected an SSH pane")
            return
        }
        // Without an identity this stops at authentication, before any network I/O.
        session.connect(using: library)
        session.status = .connected
        var writes: [Data] = []
        session.inputSink = { writes.append($0) }
        pane.terminalInputArea.draft = "echo restricted"
        #expect(!pane.terminalInputArea.submit { try workspace.submitInputArea($0, from: pane) })
        #expect(writes.isEmpty)
        #expect(pane.terminalInputArea.draft == "echo restricted")
        #expect(pane.terminalInputArea.error != nil)
        let permissionError = pane.terminalInputArea.error
        session.connectionJourney.hide()
        let generator = InputAreaGenerator()
        workspace.generateInputAreaCommand(from: pane, using: generator)
        #expect(pane.terminalInputArea.error == permissionError)
        #expect(!pane.terminalInputArea.isGenerating && generator.contexts.isEmpty)
    }

    @Test
    func foreignAndDisconnectedPanesCannotSubmit() {
        let (workspace, source, _) = fixture()
        defer { for pane in workspace.panes { pane.disconnectConnection() } }
        let foreign = Pane.sshSession(host: Host(name: "foreign", host: "foreign.invalid"))
        #expect(throws: TerminalInputAreaError.self) {
            try workspace.submitInputArea("wrong target", from: foreign)
        }
        source.sshSession?.status = .disconnected
        #expect(throws: TerminalInputAreaError.self) {
            try workspace.submitInputArea("disconnected", from: source)
        }
    }

    @Test
    func disconnectedTelnetRejectsInputWithoutClearingTheDraft() {
        let pane = Pane(.telnetSession(TelnetSessionModel(host: Host(name: "telnet", host: "telnet.invalid"))))
        let workspace = Workspace(pane: pane)
        defer { pane.disconnectConnection() }
        pane.terminalInputArea.draft = "retained telnet draft"
        #expect(!pane.terminalInputArea.submit { try workspace.submitInputArea($0, from: pane) })
        #expect(pane.terminalInputArea.draft == "retained telnet draft")
        #expect(pane.terminalInputArea.error != nil)
    }

    @Test
    func generationReadsTheLocalDraftAndNeverWritesUntilReviewed() async throws {
        let (workspace, source, other) = fixture()
        defer { for pane in workspace.panes { pane.disconnectConnection() } }
        let session = try #require(source.sshSession)
        var first: [Data] = []
        var second: [Data] = []
        session.inputSink = { first.append($0) }
        other.sshSession?.inputSink = { second.append($0) }
        workspace.broadcastsInput = true
        // Drain Ghostty's initial nil-directory observation before supplying
        // the shell context, as the live session does after connecting.
        try await Task.sleep(for: .milliseconds(20))
        prepareGenerator(session)
        let input = source.terminalInputArea
        input.mode = .commandGenerator
        input.draft = "list hidden files"
        let generator = InputAreaGenerator()
        workspace.generateInputAreaCommand(from: source, using: generator) { _ in "visible terminal output" }
        try await wait { generator.pending != nil }
        #expect(generator.contexts.first?.draft == "list hidden files")
        #expect(generator.contexts.first?.shell == "zsh")
        #expect(generator.contexts.first?.cwd == "/srv/project")
        #expect(generator.contexts.first?.viewport?.text == "visible terminal output")
        #expect(first.isEmpty && second.isEmpty)
        workspace.generateInputAreaCommand(from: source, using: generator)
        #expect(generator.contexts.count == 1)
        generator.finish(.success("ls -la"))
        try await wait { input.mode == .input }
        #expect(input.draft == "ls -la" && !input.isGenerating)
        #expect(first.isEmpty && second.isEmpty)
        #expect(input.submit { try workspace.submitInputArea($0, from: source) })
        #expect(first == [Data("ls -la\r".utf8)] && second == first)
        #expect(input.draft.isEmpty)
    }

    @Test(arguments: ["edit", "mode", "hide", "disconnect", "context", "broadcast", "close"])
    func cancelledGenerationCannotOverwriteNewInput(reason: String) async throws {
        let (workspace, source, other) = fixture()
        defer { for pane in workspace.panes { pane.disconnectConnection() } }
        let session = try #require(source.sshSession)
        try await Task.sleep(for: .milliseconds(20))
        prepareGenerator(session)
        let input = source.terminalInputArea
        input.mode = .commandGenerator
        input.draft = "old request"
        let generator = InputAreaGenerator()
        workspace.generateInputAreaCommand(from: source, using: generator) { _ in nil }
        try await wait { generator.pending != nil }
        switch reason {
        case "edit": input.draft = "new request"
        case "mode": input.mode = .input
        case "hide": input.cancelGeneration()
        case "disconnect": session.status = .disconnected
        case "context": session.workingDirectory = "/elsewhere"
        case "broadcast":
            workspace.broadcastsInput = true
            workspace.routeInteractiveInput(Data("other pane input".utf8), from: try #require(other.sshSession))
        case "close": source.disconnectConnection()
        default: break
        }
        let expected = input.draft
        #expect(!input.isGenerating)
        generator.finish(.success("must not appear"))
        try await Task.sleep(for: .milliseconds(30))
        #expect(input.draft == expected)
    }

    @Test(arguments: [CommandGeneratorError.missingModel, .missingCredential, .timedOut, .invalidResponse])
    func generationFailureKeepsTheRequestAndAllowsRetry(error: CommandGeneratorError) async throws {
        let input = TerminalInputAreaModel()
        input.mode = .commandGenerator
        input.draft = "keep this request"
        let context = CommandGeneratorContext(draft: input.draft, shell: "bash", cwd: "/tmp")
        let generator = InputAreaGenerator()
        input.generate(context: context, using: generator, isCurrent: { true })
        try await wait { generator.pending != nil }
        generator.finish(.failure(error))
        try await wait { input.error != nil }
        #expect(input.draft == context.draft && input.mode == .commandGenerator)
        input.generate(context: context, using: generator, isCurrent: { true })
        try await wait { generator.pending != nil }
        generator.finish(.success("pwd"))
        try await wait { input.mode == .input }
        #expect(input.draft == "pwd" && input.error == nil)
    }

    @Test(arguments: ["unknown", "unsupported", "busy"])
    func inputGenerationDoesNotRequireShellDraftIntegration(context: String) async throws {
        let (workspace, source, _) = fixture()
        defer { for pane in workspace.panes { pane.disconnectConnection() } }
        let session = try #require(source.sshSession)
        try await Task.sleep(for: .milliseconds(20))
        if context != "unknown" {
            session.receiveShellIntegrationEvent(
                .available(shell: context == "unsupported" ? "fish" : "bash", systemInfo: nil, homeDirectory: nil))
        }
        let input = source.terminalInputArea
        input.draft = "show files"
        let generator = InputAreaGenerator()
        workspace.generateInputAreaCommand(from: source, using: generator) { _ in nil }
        try await wait { generator.pending != nil }
        #expect(input.mode == .commandGenerator)
        #expect(generator.contexts.first?.draft == "show files")
        #expect(
            generator.contexts.first?.shell == (context == "unknown" ? "" : context == "unsupported" ? "fish" : "bash"))
        #expect(generator.contexts.first?.cwd == "")
        #expect(!session.canGenerateFromCurrentDraft)
        generator.finish(.success("ls"))
        try await wait { input.mode == .input }
        #expect(input.draft == "ls")
        #expect(input.submit { try workspace.submitInputArea($0, from: source) })
    }

    @Test
    func explicitlyDisabledShellIntegrationStillAllowsInputAreaGeneration() async throws {
        let host = Host(name: "disabled", host: "disabled.invalid", shellIntegrationMode: .disabled)
        let library = HostLibraryModel(hosts: [host])
        let session = SSHSessionModel(host: host)
        let source = Pane(.sshSession(session))
        let workspace = Workspace(pane: source)
        defer { source.disconnectConnection() }
        session.connect(using: library)
        session.status = .connected
        session.inputSink = { _ in Issue.record("Generation must not write to the terminal") }
        session.connectionJourney.hide()
        try await Task.sleep(for: .milliseconds(20))
        #expect(!session.isShellIntegrationEnabled)
        let input = source.terminalInputArea
        input.draft = "show files"
        let generator = InputAreaGenerator()
        workspace.generateInputAreaCommand(from: source, using: generator) { _ in "available output" }
        try await wait { generator.pending != nil }
        #expect(generator.contexts.first?.shell == "")
        #expect(generator.contexts.first?.viewport?.text == "available output")
        generator.finish(.success("ls"))
        try await wait { input.mode == .input }
        #expect(input.draft == "ls")
        #expect(!session.canGenerateFromCurrentDraft)
        workspace.generateFocusedCommand(using: generator)
        guard case .failed = workspace.commandGeneratorState else {
            Issue.record("The original terminal generation path must still require shell integration")
            return
        }
        #expect(generator.contexts.count == 1)
    }

    @Test(arguments: ["disconnected", "journey", "foreign"])
    func unavailableInputGenerationNeverCallsTheModel(reason: String) {
        let (workspace, source, _) = fixture()
        defer { for pane in workspace.panes { pane.disconnectConnection() } }
        if reason == "disconnected" { source.sshSession?.status = .disconnected }
        if reason == "journey" { source.sshSession?.connectionJourney.fail("Connection failed") }
        let input = source.terminalInputArea
        input.draft = "keep my request"
        let generator = InputAreaGenerator()
        let target = reason == "foreign" ? Workspace(pane: Pane(.empty)) : workspace
        target.generateInputAreaCommand(from: source, using: generator)
        #expect(!input.isGenerating && generator.contexts.isEmpty)
        #expect(input.draft == "keep my request")
        if reason != "foreign" { #expect(input.error != nil) }
    }

    @Test
    func movingThePanePreservesItsInputModelAndCloseDiscardsTheDraft() {
        let (source, pane, _) = fixture()
        defer { for pane in source.panes { pane.disconnectConnection() } }
        let input = pane.terminalInputArea
        input.draft = "unsubmitted"
        input.mode = .commandGenerator
        let destination = Workspace(pane: pane)
        defer { pane.disconnectConnection() }
        #expect(destination.focusedPane.terminalInputArea === input)
        #expect(destination.focusedPane.terminalInputArea.draft == "unsubmitted")
        #expect(destination.focusedPane.terminalInputArea.mode == .commandGenerator)
        pane.disconnectConnection()
        #expect(input.draft.isEmpty && input.mode == .input && !input.isGenerating)
    }

    @Test
    func lateFocusTeardownFromTheOldMountCannotClearTheNewEditor() {
        let input = TerminalInputAreaModel()
        let old = UUID()
        let new = UUID()
        input.setEditorFocused(true, editorID: old)
        input.setEditorFocused(true, editorID: new)
        input.setEditorFocused(false, editorID: old)
        #expect(input.isEditorFocused)
        input.setEditorFocused(false, editorID: new)
        #expect(!input.isEditorFocused)
    }

    @Test(arguments: InputSendShortcut.allCases)
    func submitAndNewlineGesturesFollowTheSelectedShortcut(shortcut: InputSendShortcut) throws {
        for keyCode: UInt16 in [36, 76] {
            for modifiers: NSEvent.ModifierFlags in [[], .command, [.command, .shift], .shift, .option, .control] {
                let event = try #require(
                    NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                        windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                        isARepeat: false, keyCode: keyCode))
                let expectedSubmit = modifiers == (shortcut == .returnKey ? [] : .command)
                #expect((shortcut.action(for: event, hasMarkedText: false) == .submit) == expectedSubmit)
                #expect(shortcut.action(for: event, hasMarkedText: true) == .system)
            }
        }
    }

    private func fixture() -> (Workspace, Pane, Pane) {
        let first = Pane.sshSession(host: Host(name: "first", host: "first.invalid"))
        let second = Pane.sshSession(host: Host(name: "second", host: "second.invalid"))
        let workspace = Workspace(pane: first)
        workspace.splitFocusedPane(axis: .horizontal, with: second)
        for session in workspace.broadcastTargets {
            session.status = .connected
            session.connectionJourney.hide()
            session.inputSink = { _ in }
        }
        return (workspace, first, second)
    }

    private func prepareGenerator(_ session: SSHSessionModel) {
        session.workingDirectory = "/srv/project"
        session.receiveShellIntegrationEvent(.available(shell: "zsh", systemInfo: nil, homeDirectory: "/home/test"))
        session.receiveShellIntegrationEvent(.promptReady)
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for input area state")
    }
}
