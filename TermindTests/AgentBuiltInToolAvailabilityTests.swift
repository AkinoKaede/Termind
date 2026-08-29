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

        let mainAssistant = AgentToolCatalog.registry(environment: .init(
            hosts: hosts, connections: connections
        )).descriptors
        let workspaceSidebar = AgentToolCatalog.registry(environment: .init(
            hosts: hosts, connections: connections, includesTerminalSuggestion: true
        )).descriptors

        #expect(!mainAssistant.contains { $0.name == "terminal_suggest" })
        #expect(workspaceSidebar.contains { $0.name == "terminal_suggest" })
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
        let workspace = AgentScratchWorkspace(
            conversationID: UUID(), base: FileManager.default.temporaryDirectory
        )
        let web = ScrubberWebClient(
                document: { _ in throw ScrubberWebError.emptyDocument },
                search: { _, _ in [] }
        )
        let descriptors = AgentToolCatalog.registry(environment: .init(
            hosts: hosts, connections: connections, web: web, search: web,
            includesTerminalSuggestion: true, workspace: workspace,
            tasks: AgentTaskList { _ in }, plans: AgentPlanRecorder { _ in }
        )).descriptors

        for descriptor in descriptors where descriptor.target != .mcp {
            let id = descriptor.presentation?.presenterID
            #expect(id != nil, "Missing presenter for \(descriptor.name)")
            if let id {
                #expect(AgentToolCatalog.presenter(id: id) != nil)
            }
        }
    }
}
