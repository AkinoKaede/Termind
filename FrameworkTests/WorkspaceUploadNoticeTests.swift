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
            ) == String(localized: "The SSH session is not ready for file transfer.")
        )
        #expect(
            TerminalUploadAvailability.problem(
                isConnected: true,
                hasTransferConfiguration: true,
                isWorkingDirectoryPending: true,
                workingDirectory: nil
            ) == String(localized: "Wait for the shell prompt to report its current directory.")
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

    @Test func uploadNoticePresentationUsesOneCrossPlatformMapping() {
        let queued = WorkspaceUploadNotice.queued(2, "/srv/project")
        #expect(queued.symbol == "checkmark.circle.fill")
        #expect(queued.title == String(localized: "Added 2 items to Transfers"))
        #expect(queued.detail == "/srv/project")
        #expect(!queued.isRejected)
        #expect(WorkspaceUploadNotice.rejected("Denied").isRejected)
    }
}
