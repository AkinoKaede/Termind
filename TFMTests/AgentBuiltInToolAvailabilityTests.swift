import AgentKit
import AgentKitScrubber
import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind

@Suite
@MainActor
struct AgentBuiltInToolAvailabilityTests {
    @Test
    func terminalSuggestionDefinitionIsStableAcrossSurfaces() {
        let hosts = AgentHostResolver(store: HostLibraryModel())
        let connections = AgentConnectionPool(
            configuration: { _ in throw AgentToolError.invalidHost },
            routeFingerprint: { _ in "" },
            openExec: { _ in throw AgentToolError.invalidHost },
            openSFTP: { _ in throw AgentToolError.invalidHost },
            sweepInterval: nil
        )

        let mainAssistant = TermindAgentTools.tools(
            in: .init(
                hosts: hosts, metrics: TestMetricsReader(), connections: connections
            )
        ).map(\.descriptor)
        let workspaceSidebar = TermindAgentTools.tools(
            in: .init(
                hosts: hosts, metrics: TestMetricsReader(), connections: connections, includesTerminalSuggestion: true
            )
        ).map(\.descriptor)

        #expect(mainAssistant.contains { $0.name == "get_metrics" })
        #expect(workspaceSidebar.contains { $0.name == "get_metrics" })
        #expect(mainAssistant.contains { $0.name == "terminal_suggest" })
        #expect(mainAssistant == workspaceSidebar)
        #expect(workspaceSidebar.contains { $0.name == "terminal_suggest" })

        let registry = AgentToolRegistry(
            TermindAgentTools.tools(
                in: .init(
                    hosts: hosts, metrics: TestMetricsReader(), connections: connections
                )
            )
        )
        let planning = Set(registry.available(in: .planning).descriptors.map(\.name))
        let acting = Set(registry.available(in: .acting).descriptors.map(\.name))
        #expect(registry.available(in: .reviewing).descriptors.isEmpty)
        #expect(planning.contains("ssh_exec"))
        #expect(!planning.contains("sftp_write"))
        #expect(acting.isSuperset(of: ["ssh_exec", "sftp_write"]))
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
            document: { _ in throw AgentWebError.emptyDocument },
            search: { _, _ in [] }
        )
        let descriptors = AgentToolCatalog.registry(
            builtIn: .init(
                workspace: workspace, web: web, search: web,
                tasks: AgentTaskList { _ in }, plans: AgentPlanRecorder { _ in }
            ),
            additional: TermindAgentTools.tools(
                in: .init(
                    hosts: hosts, metrics: TestMetricsReader(), connections: connections,
                    includesTerminalSuggestion: true, workspace: workspace
                ))
        ).descriptors

        for descriptor in descriptors where descriptor.target != .mcp {
            let id = descriptor.presentation?.presenterID
            #expect(id != nil, "Missing presenter for \(descriptor.name)")
            if let id {
                #expect(TermindAgentTools.presenter(id: id) != nil)
            }
        }
    }

    /// The point of `AgentToolGroup`: an adopter with no web client and no
    /// skills gets a registry that never names `fetch` or `load_skill`, rather
    /// than one that offers them and fails on the first call.
    @Test
    func onlyTheSelectedGroupsReachTheRegistry() throws {
        let workspace = AgentScratchWorkspace(
            conversationID: UUID(), base: FileManager.default.temporaryDirectory
        )
        let web = ScrubberWebClient(
            document: { _ in throw AgentWebError.emptyDocument },
            search: { _, _ in [] }
        )
        let everything = AgentBuiltInToolConfiguration(
            workspace: workspace, web: web, search: web,
            tasks: AgentTaskList { _ in }, plans: AgentPlanRecorder { _ in },
            skills: AgentSkillCatalog([
                AgentSkill(name: "deploy", summary: "Deploy the app", body: "Steps")
            ])
        )

        var narrowed = everything
        narrowed.groups = [.scratch, .userInteraction]
        let names = Set(AgentToolCatalog.registry(builtIn: narrowed).descriptors.map(\.name))

        #expect(names.contains("scratch_write"))
        #expect(names.contains("request_user_secret"))
        for absent in [
            "fetch", "web_search", "scratch_fetch", "load_skill", "manage_tasks",
            "present_plan",
        ] {
            #expect(!names.contains(absent), "\(absent) survived group selection")
        }

        // Everything the narrowed set dropped is present when its group is.
        let all = Set(AgentToolCatalog.registry(builtIn: everything).descriptors.map(\.name))
        #expect(names.isSubset(of: all))
        #expect(all.isSuperset(of: ["fetch", "web_search", "load_skill", "present_plan"]))
    }

    /// A selected group whose dependency is missing contributes nothing. The
    /// alternative — registering `fetch` with no fetcher — puts a tool in front
    /// of the model that can only ever fail.
    @Test
    func aSelectedGroupWithoutItsDependencyRegistersNothing() {
        let names = Set(
            AgentToolCatalog.registry(builtIn: .init(groups: [.web, .scratch, .planning]))
                .descriptors.map(\.name)
        )
        #expect(names.isEmpty)
    }
}
