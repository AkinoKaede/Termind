import TermindDomain
import Testing

@Suite
struct RemoteShellCommandTests {
    @Test
    func directoryChangesQuoteRemotePaths() {
        #expect(
            RemoteShellCommand.changeDirectory(to: "/srv/it's live")
                == "cd '/srv/it'\"'\"'s live'"
        )
        #expect(RemoteShellCommand.changeDirectory(to: "") == nil)
    }
}
