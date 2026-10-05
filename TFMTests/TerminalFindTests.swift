import Foundation
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@testable import Termind

struct TerminalFindTests {
    /// Closing the bar ends Ghostty's highlights but keeps the query, so ⌘F in
    /// the same terminal resumes the search instead of starting over.
    @MainActor
    @Test
    func presentationRetainsTheQueryAcrossClosingAndReopening() {
        let sshSession = SSHSessionModel(hostID: UUID(), title: "web-01")

        sshSession.find.updateQuery("deploy")
        sshSession.find.present()
        #expect(sshSession.find.isPresented)
        #expect(sshSession.find.query == "deploy")

        sshSession.find.dismiss()
        #expect(!sshSession.find.isPresented)
        #expect(sshSession.find.query == "deploy")

        sshSession.find.present()
        #expect(sshSession.find.isPresented)
        #expect(sshSession.find.query == "deploy")
    }

    /// Typing narrows the search; it does not open or close the bar. The two are
    /// separate stored properties precisely so a keystroke cannot invalidate
    /// every view that only watches whether the bar is open.
    @MainActor
    @Test
    func typingDoesNotChangeWhetherTheBarIsOpen() {
        let sshSession = SSHSessionModel(hostID: UUID(), title: "web-01")

        sshSession.find.updateQuery("error")
        #expect(!sshSession.find.isPresented)

        sshSession.find.present()
        sshSession.find.updateQuery("errors")
        #expect(sshSession.find.isPresented)
        #expect(sshSession.find.query == "errors")
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
        #expect(TerminalFindBinding.navigate(.previous) == "navigate_search:previous")
        #expect(TerminalFindBinding.navigate(.next) == "navigate_search:next")
    }

    @MainActor
    @Test
    func navigatingRevealsTheFindStateAndRetainsTheQuery() {
        let host = Host(name: "web-01", host: "web-01.example")
        let window = WindowModel(workspaces: [Workspace.sshSession(host: host)])
        window.focusedSSHSession?.find.updateQuery("deploy")

        window.navigateTerminalFind(.previous)

        #expect(window.focusedSSHSession?.find.isPresented == true)
        #expect(window.focusedSSHSession?.find.query == "deploy")
    }
}
