import AppKit
import Foundation
import GhosttyTerminal
import Testing

@testable import Termind

@Suite(.serialized)
@MainActor
struct RemoteWindowTitleTests {
    @Test
    func sshSessionMirrorsSanitizedGhosttyTitleOnlyWhileConnected() async {
        let session = SSHSessionModel(hostID: UUID(), title: "Host")

        session.terminalState.terminalDidChangeTitle(
            "\u{1B}[31mkaede@lima-default:/Users/kaede\u{1B}[0m\nignored"
        )
        #expect(session.remoteWindowTitle == "kaede@lima-default:/Users/kaede ignored")
        #expect(session.menuBarWindowTitle == nil)

        session.status = .connected
        #expect(session.menuBarWindowTitle == "kaede@lima-default:/Users/kaede ignored")

        session.disconnect()
        #expect(session.remoteWindowTitle == nil)
        #expect(session.menuBarWindowTitle == nil)
    }

    @Test
    func sanitizerKeepsOnePrintableLineAndRejectsEmptyTitles() {
        #expect(RemoteWindowTitle.sanitized("  host: /srv  ") == "host: /srv")
        #expect(RemoteWindowTitle.sanitized("host\r\n/srv\u{7}") == "host /srv")
        #expect(RemoteWindowTitle.sanitized("\u{1B}[1;32mgreen\u{1B}[0m") == "green")
        #expect(RemoteWindowTitle.sanitized("\n\u{7}\u{1B}[31m") == nil)
    }

    @Test
    func menuFollowsOnlyTheKeyWindowAndUsesKittyTitleFormat() throws {
        let mainMenu = NSMenu()
        let help = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        help.submenu = NSMenu(title: "Help")
        mainMenu.addItem(help)
        let firstWindow = NSWindow()
        let secondWindow = NSWindow()
        var keyWindow: NSWindow? = firstWindow
        let coordinator = RemoteWindowTitleMenuCoordinator(
            mainMenuProvider: { mainMenu }, keyWindowProvider: { keyWindow },
            observesKeyWindowChanges: false
        )
        let firstToken = UUID()
        let secondToken = UUID()

        coordinator.report(
            title: "kaede@lima-default:/Users/kaede",
            for: firstWindow, token: firstToken
        )
        #expect(mainMenu.items.count == 2)
        #expect(mainMenu.items[0] === help)
        #expect(mainMenu.items[1].title.isEmpty)
        #expect(
            try #require(mainMenu.items[1].submenu).title
                == " :: kaede@lima-default:/Users/kaede"
        )
        #expect(mainMenu.items[1].submenu?.items.isEmpty == true)

        coordinator.report(title: "second:/tmp", for: secondWindow, token: secondToken)
        #expect(mainMenu.items[1].submenu?.title == " :: kaede@lima-default:/Users/kaede")

        keyWindow = secondWindow
        coordinator.refresh()
        #expect(mainMenu.items[1].submenu?.title == " :: second:/tmp")

        coordinator.withdraw(token: secondToken)
        #expect(mainMenu.items == [help])
    }

    @Test(
        .disabled(
            if: !ghosttyHasActiveDisplay,
            "Ghostty's Metal surface requires an active display"
        ))
    func hostManagedGhosttySurfaceParsesOSCZeroAndTwo() async throws {
        let backend = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let state = TerminalViewState(configSource: .none)
        state.configuration = TerminalSurfaceOptions(backend: .inMemory(backend))
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        terminal.delegate = state
        terminal.configuration = state.configuration
        terminal.controller = state.controller
        let window = NSWindow(
            contentRect: terminal.frame, styleMask: [.titled],
            backing: .buffered, defer: false
        )
        window.contentView = terminal
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        backend.receive(Data("\u{1B}]0;zero-title\u{7}".utf8))
        try await waitUntil { state.title == "zero-title" }

        backend.receive(Data("\u{1B}]2;two-title\u{7}".utf8))
        try await waitUntil { state.title == "two-title" }
    }

    private func waitUntil(
        timeout: Duration = .seconds(2), condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for terminal state")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private nonisolated let ghosttyHasActiveDisplay: Bool = {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success else { return false }
    return count > 0
}()
