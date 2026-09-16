import TermindApplication
import TermindPresentation
import Testing

@Suite("Workspace upload policy")
struct WorkspaceUploadNoticeTests {
    @Test func terminalUploadRequiresAConnectedTransferAndResolvedDirectory() {
        #expect(
            TerminalUploadAvailability.problem(
                isConnected: false,
                hasTransferConfiguration: false,
                isWorkingDirectoryPending: true,
                workingDirectory: nil
            ) != nil
        )
        #expect(
            TerminalUploadAvailability.problem(
                isConnected: true,
                hasTransferConfiguration: true,
                isWorkingDirectoryPending: true,
                workingDirectory: nil
            ) != nil
        )
        #expect(
            TerminalUploadAvailability.problem(
                isConnected: true,
                hasTransferConfiguration: true,
                isWorkingDirectoryPending: false,
                workingDirectory: "/srv/project"
            ) == nil
        )
    }

    @Test func uploadNoticeRetainsItsDestinationAndRejectionState() {
        let queued = WorkspaceUploadNotice.queued(2, "/srv/project")
        #expect(queued.detail == "/srv/project")
        #expect(!queued.isRejected)
        #expect(WorkspaceUploadNotice.rejected("Denied").isRejected)
    }
}
