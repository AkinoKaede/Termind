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
}
