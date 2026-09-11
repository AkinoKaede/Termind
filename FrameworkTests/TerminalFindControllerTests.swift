import TermindApplication
import TermindDomain
import Testing

@Suite("Terminal Find controller")
@MainActor
struct TerminalFindControllerTests {
    @Test func retainedQueryRestartsWhenPresentedAndDismissReturnsFocus() {
        var bindings: [String] = []
        var focusCount = 0
        let find = TerminalFindController(
            perform: { bindings.append($0) },
            focus: { focusCount += 1 }
        )

        find.updateQuery("deploy")
        find.present()
        find.navigate(.next)
        find.dismiss()
        find.present()

        #expect(
            bindings == [
                TerminalFindBinding.search("deploy"),
                TerminalFindBinding.search("deploy"),
                TerminalFindBinding.navigate(.next),
                TerminalFindBinding.end,
                TerminalFindBinding.search("deploy"),
            ]
        )
        #expect(focusCount == 1)
        #expect(find.query == "deploy")
        #expect(find.isPresented)
    }

    @Test func navigationOpensTheBarButRequiresAQuery() {
        var bindings: [String] = []
        let find = TerminalFindController(perform: { bindings.append($0) }, focus: {})

        find.presentAndNavigate(.previous)

        #expect(find.isPresented)
        #expect(bindings.isEmpty)
    }
}
