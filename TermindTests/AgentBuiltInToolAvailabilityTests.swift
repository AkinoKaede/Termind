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
}
