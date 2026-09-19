import TermindApplication
import TermindDomain
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

    @Test func uploadNoticeAbbreviatesResolvedHomePaths() {
        let home: RemoteHomeResolutionState = .resolved("/home/user")

        #expect(WorkspaceUploadNotice.preparing("/home/user").detail(home: home) == "~")
        #expect(WorkspaceUploadNotice.preparing("/home/user/project").detail(home: home) == "~/project")
        #expect(WorkspaceUploadNotice.queued(2, "/home/user/project").detail(home: home) == "~/project")
    }

    @Test func uploadNoticePreservesPathsOutsideOrWithoutAResolvedHome() {
        let preparing = WorkspaceUploadNotice.preparing("/srv/project")
        let rejected = WorkspaceUploadNotice.rejected("Denied")

        #expect(preparing.detail(home: .resolved("/home/user")) == "/srv/project")
        #expect(preparing.detail(home: .unavailable) == "/srv/project")
        #expect(rejected.detail(home: .resolved("/home/user")) == "Denied")
    }
}
