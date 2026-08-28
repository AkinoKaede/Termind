import Foundation
import Testing

@testable import Termind

struct TerminalFindTests {
    /// Closing the bar ends Ghostty's highlights but keeps the query, so ⌘F in
    /// the same terminal resumes the search instead of starting over.
    @MainActor
    @Test
    func presentationRetainsTheQueryAcrossClosingAndReopening() {
        let sshSession = SSHSessionModel(hostID: UUID(), title: "web-01")

        sshSession.updateFindQuery("deploy")
        sshSession.presentFind()
        #expect(sshSession.isFindPresented)
        #expect(sshSession.findQuery == "deploy")

        sshSession.dismissFind()
        #expect(!sshSession.isFindPresented)
        #expect(sshSession.findQuery == "deploy")

        sshSession.presentFind()
        #expect(sshSession.isFindPresented)
        #expect(sshSession.findQuery == "deploy")
    }

    /// Typing narrows the search; it does not open or close the bar. The two are
    /// separate stored properties precisely so a keystroke cannot invalidate
    /// every view that only watches whether the bar is open.
    @MainActor
    @Test
    func typingDoesNotChangeWhetherTheBarIsOpen() {
        let sshSession = SSHSessionModel(hostID: UUID(), title: "web-01")

        sshSession.updateFindQuery("error")
        #expect(!sshSession.isFindPresented)

        sshSession.presentFind()
        sshSession.updateFindQuery("errors")
        #expect(sshSession.isFindPresented)
        #expect(sshSession.findQuery == "errors")
    }

    @Test
    func bindingActionsMatchGhosttySearchSyntax() {
        #expect(TerminalFindBinding.search("") == "search:")
        #expect(TerminalFindBinding.search("错误:error") == "search:错误:error")
        #expect(TerminalFindBinding.navigate(.previous) == "navigate_search:previous")
        #expect(TerminalFindBinding.navigate(.next) == "navigate_search:next")
        #expect(TerminalFindBinding.end == "end_search")
    }

    /// A terminal search starts at the bottom of the buffer, so the direction
    /// that reaches the first match is Ghostty's `.previous` — which is what a
    /// reader means by "next". Return in the Find field, ⌘G and F3 all have to
    /// agree on that; ⌘G used to be wired the other way round.
    @Test
    func findNextWalksTowardOlderOutput() {
        #expect(TerminalFindDirection.previous.bindingAction == "navigate_search:previous")
        #expect(TerminalFindDirection.next.bindingAction == "navigate_search:next")
    }

    @MainActor
    @Test
    func navigatingRevealsTheFindStateAndRetainsTheQuery() {
        let host = Host(name: "web-01", host: "web-01.example")
        let window = WindowModel(workspaces: [Workspace.sshSession(host: host)])
        window.focusedSSHSession?.updateFindQuery("deploy")

        window.navigateTerminalFind(.previous)

        #expect(window.focusedSSHSession?.isFindPresented == true)
        #expect(window.focusedSSHSession?.findQuery == "deploy")
    }
}
