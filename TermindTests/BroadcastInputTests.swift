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
    #endif

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
