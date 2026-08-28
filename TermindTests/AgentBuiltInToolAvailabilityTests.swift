import Foundation
import Testing

@testable import Termind

@Suite
@MainActor
struct AgentBuiltInToolAvailabilityTests {
    @Test
    func terminalSuggestionIsRegisteredOnlyWhenTheSurfaceOptsIn() {
        let hosts = AgentHostResolver(store: HostLibraryModel())
        let connections = AgentConnectionPool(
            configuration: { _ in throw AgentToolError.invalidHost },
            routeFingerprint: { _ in "" },
            openExec: { _ in throw AgentToolError.invalidHost },
            openSFTP: { _ in throw AgentToolError.invalidHost },
            sweepInterval: nil
        )

        let mainAssistant = AgentBuiltInTools.make(
            hosts: hosts, connections: connections
        )
        let workspaceSidebar = AgentBuiltInTools.make(
            hosts: hosts, connections: connections,
            includesTerminalSuggestion: true
        )

        #expect(!mainAssistant.contains { $0.descriptor.name == "terminal_suggest" })
        #expect(workspaceSidebar.contains { $0.descriptor.name == "terminal_suggest" })
    }

    @Test
    func everyBuiltInToolDeclaresARegisteredDetailPresenter() {
        let hosts = AgentHostResolver(store: HostLibraryModel())
        let connections = AgentConnectionPool(
            configuration: { _ in throw AgentToolError.invalidHost },
            routeFingerprint: { _ in "" },
            openExec: { _ in throw AgentToolError.invalidHost },
            openSFTP: { _ in throw AgentToolError.invalidHost },
            sweepInterval: nil
        )
        let builtIns = AgentBuiltInTools.make(
            hosts: hosts, connections: connections,
            search: ScrubberWebClient(
                document: { _ in throw ScrubberWebError.emptyDocument },
                search: { _, _ in [] }
            ),
            includesTerminalSuggestion: true
        )
        let workspace = AgentScratchWorkspace(
            conversationID: UUID(), base: FileManager.default.temporaryDirectory
        )
        let scratch = AgentScratchTools.make(
            workspace: workspace,
            web: ScrubberWebClient(
                document: { _ in throw ScrubberWebError.emptyDocument },
                search: { _, _ in [] }
            )
        )
        let planning = AgentPlanTools.make(
            workspace: workspace, tasks: AgentTaskList { _ in },
            plans: AgentPlanRecorder { _ in }
        )

        for tool in builtIns + scratch + planning {
            let id = tool.descriptor.presentation?.detailPresenterID
            #expect(id != nil)
            if let id {
                #expect(AgentBuiltInToolDetailPresenters.presenter(id: id) != nil)
            }
        }
    }
}
