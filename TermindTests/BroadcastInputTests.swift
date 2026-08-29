import Foundation
import Testing

@testable import Termind

#if canImport(AppKit)
    import AppKit

    private nonisolated let ghosttyHasActiveDisplay: Bool = {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return false }
        return count > 0
    }()
#endif

@MainActor
private final class WorkspaceCommandGeneratorStub: CommandGenerating {
    var command: String
    var delay: Duration?
    private(set) var contexts: [CommandGeneratorContext] = []

    init(command: String, delay: Duration? = nil) {
        self.command = command
        self.delay = delay
    }

    func generate(_ context: CommandGeneratorContext) async throws -> String {
        contexts.append(context)
        if let delay { try await Task.sleep(for: delay) }
        return command
    }
}

@MainActor
struct BroadcastInputTests {
    @Test
    func routesInteractiveBytesOnlyWhenBroadcastIsEnabled() {
        let (workspace, firstSSHSession, secondSSHSession) = makeTwoSSHSessionWorkspace()
        var firstWrites: [Data] = []
        var secondWrites: [Data] = []
        firstSSHSession.inputSink = { firstWrites.append($0) }
        secondSSHSession.inputSink = { secondWrites.append($0) }
        let input = Data("echo hello\r".utf8)

        workspace.routeInteractiveInput(input, from: firstSSHSession)
        #expect(firstWrites == [input])
        #expect(secondWrites.isEmpty)

        workspace.broadcastsInput = true
        workspace.routeInteractiveInput(input, from: firstSSHSession)
        #expect(firstWrites == [input, input])
        #expect(secondWrites == [input])
    }

    @Test
    func nonInteractiveTerminalWritesNeverBroadcast() {
        let (workspace, firstSSHSession, secondSSHSession) = makeTwoSSHSessionWorkspace()
        var firstWrites: [Data] = []
        var secondWrites: [Data] = []
        firstSSHSession.inputSink = { firstWrites.append($0) }
        secondSSHSession.inputSink = { secondWrites.append($0) }
        workspace.broadcastsInput = true
        let protocolReply = Data("\u{1B}[?1;2c".utf8)

        firstSSHSession.handleTerminalWrite(protocolReply, isInteractiveInput: false)

        #expect(firstWrites == [protocolReply])
        #expect(secondWrites.isEmpty)
    }

    @Test
    func ignoresNonSSHSessionPanesAndResetsAfterLastPeerCloses() {
        let firstHost = Host(name: "first", host: "first.example")
        let secondHost = Host(name: "second", host: "second.example")
        let workspace = Workspace.sshSession(host: firstHost)
        let sftpPane = Pane.sftpSession(host: firstHost)
        workspace.splitFocusedPane(axis: .horizontal, with: sftpPane)
        let secondPane = Pane.sshSession(host: secondHost)
        workspace.splitFocusedPane(axis: .vertical, with: secondPane)
        let firstSSHSession = workspace.broadcastTargets[0]
        let secondSSHSession = workspace.broadcastTargets[1]
        var firstWrites: [Data] = []
        var secondWrites: [Data] = []
        firstSSHSession.inputSink = { firstWrites.append($0) }
        secondSSHSession.inputSink = { secondWrites.append($0) }
        workspace.broadcastsInput = true
        let input = Data([0x03])

        workspace.routeInteractiveInput(input, from: firstSSHSession)
        #expect(firstWrites == [input])
        #expect(secondWrites == [input])

        #expect(workspace.closePane(secondPane.id))
        #expect(!workspace.broadcastsInput)
        #expect(!workspace.canBroadcast)
        #expect(secondSSHSession.inputRouter == nil)
    }

    @Test
    func layoutChangesRebindSessionsToTheirCurrentWorkspace() {
        let host = Host(name: "host", host: "host.example")
        let source = Workspace.sshSession(host: host)
        let sshSession = source.focusedPane.sshSession!
        let destination = Workspace.sftpSession(host: host)

        destination.replacePane(destination.focusedPaneID, with: source.layout)

        #expect(sshSession.inputRouter === destination)
    }

    @Test
    func interactionCaptureIsScopedAndNestable() {
        let capture = TerminalInteractiveInputCapture()
        #expect(!capture.isActive)

        capture.withInteraction {
            #expect(capture.isActive)
            capture.withInteraction {
                #expect(capture.isActive)
            }
            #expect(capture.isActive)
        }

        #expect(!capture.isActive)
    }

    @Test
    func deferredGhosttyWriteConsumesOneInteractiveTicket() {
        let capture = TerminalInteractiveInputCapture()

        capture.withInteraction {}

        #expect(capture.classifyWrite())
        #expect(!capture.classifyWrite())
    }

    @Test
    func releaseAndModifierScopesDoNotLeaveDeferredTickets() {
        let capture = TerminalInteractiveInputCapture()

        capture.withInteraction(allowsDeferredWrite: false) {}

        #expect(!capture.classifyWrite())
    }

    @Test
    func commandGeneratorReadsAndReplacesOnlyFocusedSessionWithoutBroadcast() async throws {
        let (workspace, firstSSHSession, secondSSHSession) = makeTwoSSHSessionWorkspace()
        focus(firstSSHSession, in: workspace)
        try await Task.sleep(for: .milliseconds(20))
        let systemInfo = RemoteSystemInfo(
            distributionID: "debian", distributionVersion: "13",
            kernelName: "Linux", kernelRelease: "6.12.0", architecture: "x86_64"
        )
        prepareForCommandGenerator(
            firstSSHSession, cwd: "/srv/app", shell: "zsh", systemInfo: systemInfo
        )
        var firstWrites: [Data] = []
        var secondWrites: [Data] = []
        firstSSHSession.inputSink = { data in
            firstWrites.append(data)
            if data == Data("\u{1B}[777;1~".utf8) {
                DispatchQueue.main.async {
                    firstSSHSession.receiveShellIntegrationEvent(.draft("show hidden files"))
                }
            }
        }
        secondSSHSession.inputSink = { secondWrites.append($0) }
        let generator = WorkspaceCommandGeneratorStub(command: "ls -la")

        workspace.generateFocusedCommand(using: generator)
        try await waitUntil { workspace.commandGeneratorState == .inserted(targetCount: 1) }

        #expect(generator.contexts == [
            .init(
                draft: "show hidden files", shell: "zsh", cwd: "/srv/app",
                remoteSystemInfo: systemInfo
            )
        ])
        #expect(firstWrites.first == Data("\u{1B}[777;1~".utf8))
        let replacement = try #require(firstWrites.last)
        #expect(replacement == replacementPayload(command: "ls -la"))
        #expect(!replacement.contains(0x0A))
        #expect(!replacement.contains(0x0D))
        #expect(secondWrites.isEmpty)
    }

    @Test
    func commandGeneratorBroadcastsOneModelResultWithoutRoutingItTwice() async throws {
        let (workspace, firstSSHSession, secondSSHSession) = makeTwoSSHSessionWorkspace()
        focus(firstSSHSession, in: workspace)
        try await Task.sleep(for: .milliseconds(20))
        prepareForCommandGenerator(firstSSHSession, cwd: "/tmp", shell: "bash")
        prepareForCommandGenerator(secondSSHSession, cwd: "/elsewhere", shell: "fish")
        workspace.broadcastsInput = true
        var firstWrites: [Data] = []
        var secondWrites: [Data] = []
        firstSSHSession.inputSink = { data in
            firstWrites.append(data)
            if data == Data("\u{1B}[777;1~".utf8) {
                DispatchQueue.main.async {
                    firstSSHSession.receiveShellIntegrationEvent(.draft("find large files"))
                }
            }
        }
        secondSSHSession.inputSink = { secondWrites.append($0) }
        let generator = WorkspaceCommandGeneratorStub(command: "find . -type f -size +1M")

        workspace.generateFocusedCommand(using: generator)
        try await waitUntil { workspace.commandGeneratorState == .inserted(targetCount: 2) }

        #expect(generator.contexts.count == 1)
        #expect(generator.contexts.first?.shell == "bash")
        #expect(generator.contexts.first?.cwd == "/tmp")
        #expect(firstWrites.count == 2)
        #expect(secondWrites == [replacementPayload(command: generator.command)])
        #expect(firstWrites.last == secondWrites.last)
    }

    @Test
    func commandGeneratorPreflightFailureLeavesEveryBroadcastDraftUntouched() {
        let (workspace, firstSSHSession, secondSSHSession) = makeTwoSSHSessionWorkspace()
        focus(firstSSHSession, in: workspace)
        prepareForCommandGenerator(firstSSHSession, cwd: "/tmp", shell: "bash")
        workspace.broadcastsInput = true
        var firstWrites: [Data] = []
        var secondWrites: [Data] = []
        firstSSHSession.inputSink = { firstWrites.append($0) }
        secondSSHSession.inputSink = { secondWrites.append($0) }
        let generator = WorkspaceCommandGeneratorStub(command: "ls")

        workspace.generateFocusedCommand(using: generator)

        #expect(generator.contexts.isEmpty)
        #expect(firstWrites.isEmpty)
        #expect(secondWrites.isEmpty)
        guard case .failed = workspace.commandGeneratorState else {
            Issue.record("Expected preflight failure overlay")
            return
        }
    }

    @Test
    func programmaticInputCancelsGenerationWithoutReplacingTheDraft() async throws {
        let workspace = Workspace.sshSession(
            host: Host(name: "host", host: "host.example")
        )
        let sshSession = workspace.focusedPane.sshSession!
        try await Task.sleep(for: .milliseconds(20))
        prepareForCommandGenerator(sshSession, cwd: "/tmp", shell: "bash")
        var writes: [Data] = []
        sshSession.inputSink = { data in
            writes.append(data)
            if data == Data("\u{1B}[777;1~".utf8) {
                DispatchQueue.main.async {
                    sshSession.receiveShellIntegrationEvent(.draft("list files"))
                }
            }
        }
        let generator = WorkspaceCommandGeneratorStub(
            command: "ls", delay: .seconds(30)
        )

        workspace.generateFocusedCommand(using: generator)
        try await waitUntil { workspace.commandGeneratorState == .generating }
        sshSession.insert("new draft")
        try await Task.sleep(for: .milliseconds(20))

        #expect(workspace.commandGeneratorState == .idle)
        #expect(writes == [
            Data("\u{1B}[777;1~".utf8), Data("new draft".utf8),
        ])
    }

    #if canImport(AppKit)
        @Test(.disabled(
            if: !ghosttyHasActiveDisplay,
            "Ghostty's Metal surface requires an active display"
        ))
        func nativeGhosttyKeyPathBroadcastsGeneratedBytes() async throws {
            let (workspace, firstSSHSession, secondSSHSession) = makeTwoSSHSessionWorkspace()
            var firstWrites: [Data] = []
            var secondWrites: [Data] = []
            firstSSHSession.inputSink = { firstWrites.append($0) }
            secondSSHSession.inputSink = { secondWrites.append($0) }
            workspace.broadcastsInput = true

            let mount = TerminalMountView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
            let window = NSWindow(
                contentRect: mount.frame,
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = mount
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            firstSSHSession.terminalViewOwner.mount(
                in: mount,
                state: firstSSHSession.terminalState,
                isVisible: true,
                requestsFocus: true
            )
            mount.layoutSubtreeIfNeeded()
            for _ in 0..<100 where !firstSSHSession.terminalViewOwner.hasKeyboardFocusForTesting {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(firstSSHSession.terminalViewOwner.hasKeyboardFocusForTesting)

            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    characters: "x",
                    charactersIgnoringModifiers: "x",
                    isARepeat: false,
                    keyCode: 7
                ))
            // Dispatch through AppKit rather than invoking `keyDown` directly.
            // Ghostty's native translator consults the application's current
            // event while interpreting keys, exactly as it does in production.
            NSApp.sendEvent(event)

            for _ in 0..<100 where firstWrites.isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }

            #expect(firstWrites == [Data("x".utf8)])
            #expect(secondWrites == [Data("x".utf8)])
        }

        @Test(.disabled(
            if: !ghosttyHasActiveDisplay,
            "Ghostty's Metal surface requires an active display"
        ))
        func commandDigitsFallThroughToAppKitWorkspaceCommands() async throws {
            let host = Host(name: "host", host: "host.example")
            let sshSession = Workspace.sshSession(host: host).focusedPane.sshSession!
            let mount = TerminalMountView(
                frame: NSRect(x: 0, y: 0, width: 640, height: 400)
            )
            let window = NSWindow(
                contentRect: mount.frame,
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = mount
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            NSApp.activate(ignoringOtherApps: true)
            sshSession.terminalViewOwner.mount(
                in: mount,
                state: sshSession.terminalState,
                isVisible: true,
                requestsFocus: true
            )
            mount.layoutSubtreeIfNeeded()
            for _ in 0..<100 where !sshSession.terminalViewOwner.hasKeyboardFocusForTesting {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(sshSession.terminalViewOwner.hasKeyboardFocusForTesting)

            let numberRowKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
            for (offset, keyCode) in numberRowKeyCodes.enumerated() {
                let digit = String(offset + 1)
                let event = try #require(
                    NSEvent.keyEvent(
                        with: .keyDown,
                        location: .zero,
                        modifierFlags: .command,
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber,
                        context: nil,
                        characters: digit,
                        charactersIgnoringModifiers: digit,
                        isARepeat: false,
                        keyCode: keyCode
                    ))

                #expect(!sshSession.terminalViewOwner.performKeyEquivalentForTesting(event))
            }
        }

        @Test
        func commandQFallsThroughToAppKitQuitCommand() throws {
            let host = Host(name: "host", host: "host.example")
            let sshSession = Workspace.sshSession(host: host).focusedPane.sshSession!
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: .command,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: 0,
                    context: nil,
                    characters: "q",
                    charactersIgnoringModifiers: "q",
                    isARepeat: false,
                    keyCode: 12
                ))

            #expect(!sshSession.terminalViewOwner.performKeyEquivalentForTesting(event))
        }

        @Test
        func commandIFallsThroughToAppKitGenerateCommand() throws {
            let host = Host(name: "host", host: "host.example")
            let sshSession = Workspace.sshSession(host: host).focusedPane.sshSession!
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: .command,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: 0,
                    context: nil,
                    characters: "i",
                    charactersIgnoringModifiers: "i",
                    isARepeat: false,
                    keyCode: 34
                ))

            #expect(!sshSession.terminalViewOwner.performKeyEquivalentForTesting(event))
        }
    #endif

    private func prepareForCommandGenerator(
        _ sshSession: SSHSessionModel, cwd: String, shell: String,
        systemInfo: RemoteSystemInfo? = nil
    ) {
        sshSession.status = .connected
        sshSession.workingDirectory = cwd
        sshSession.receiveShellIntegrationEvent(
            .available(shell: shell, systemInfo: systemInfo, homeDirectory: "/home/test")
        )
        sshSession.receiveShellIntegrationEvent(.promptReady)
    }

    private func focus(_ sshSession: SSHSessionModel, in workspace: Workspace) {
        workspace.focusedPaneID = workspace.panes.first(where: {
            $0.sshSession === sshSession
        })!.id
    }

    private func replacementPayload(command: String) -> Data {
        Data("\u{1B}[777;2~\u{1B}[200~\(command)\u{1B}[201~".utf8)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition")
    }

    private func makeTwoSSHSessionWorkspace() -> (
        Workspace, SSHSessionModel, SSHSessionModel
    ) {
        let firstHost = Host(name: "first", host: "first.example")
        let secondHost = Host(name: "second", host: "second.example")
        let workspace = Workspace.sshSession(host: firstHost)
        workspace.splitFocusedPane(axis: .horizontal, with: .sshSession(host: secondHost))
        return (workspace, workspace.broadcastTargets[0], workspace.broadcastTargets[1])
    }
}
