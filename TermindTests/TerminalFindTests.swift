import Testing

@testable import Termind

struct TerminalFindTests {
    @Test
    func presentationRetainsQueryAndRequestsFocusEveryTime() {
        var state = TerminalFindState(query: "deploy")

        state.present()
        #expect(state.isPresented)
        #expect(state.query == "deploy")
        #expect(state.focusRequest == 1)

        state.dismiss()
        #expect(!state.isPresented)
        #expect(state.query == "deploy")

        state.present()
        #expect(state.isPresented)
        #expect(state.query == "deploy")
        #expect(state.focusRequest == 2)
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
        window.focusedSSHSession?.find.query = "deploy"

        window.navigateTerminalFind(.previous)

        #expect(window.focusedSSHSession?.find.isPresented == true)
        #expect(window.focusedSSHSession?.find.query == "deploy")
    }
}
