import AgentKit
import AgentKitScrubber
import Foundation
import TermindApplication
import TermindDomain

@MainActor
public enum AssistantToolRegistry {
    public static func make(
        conversation: ConversationModel, model: AIModel, provider: ModelProvider,
        skills skillCatalog: AgentSkillCatalog, channel: AgentEventChannel,
        ai: AIConfigurationModel, hosts: AgentHostResolver,
        metrics: any MetricsSnapshotReading, connections: AgentConnectionPool,
        authentication: AgentSSHAuthenticationRegistry, background: AgentBackgroundCommands,
        includesTerminalSuggestion: Bool = false
    ) -> AgentToolRegistry {
        let native =
            ai.webSearch.isEnabled && ai.webSearch.prefersBuiltIn && provider.supportsNativeWebSearch(model: model)
        let localSearch: ScrubberWebClient? = ai.webSearch.isEnabled && !native ? ScrubberWebClient() : nil
        var registry = AgentToolRegistry([AnyAgentTool]())
        if model.abilities.contains(.toolCall) {
            // One workspace per conversation, not per run: a file staged before the
            // user interrupted, or before they typed a follow-up, is still there for
            // the run that answers them. Isolation comes from the scope directory
            // being keyed by conversation, so one chat can never read what another
            // pulled off a host.
            let scratch = AgentScratchWorkspace(
                conversationID: conversation.id,
                applicationName: TermindAgentPolicy.scratchDirectoryName
            )
            // One client for both, rather than two default-constructed ones: `fetch`
            // and `scratch_fetch` read the same web the same way and differ only in
            // where the page ends up.
            let web = ScrubberWebClient()
            // Both write through the one ordered channel the rest of the run
            // uses, rather than reaching into the conversation directly: a tool
            // that touched `@Observable` state from a task group would be
            // mutating the UI from off the main actor.
            let servers = ai.usableMCPServers.map { server in
                (server: server, bearerToken: ai.secret(for: server.credentialRef))
            }
            // Local definitions are registered once per catalog — the runtime's
            // built-in groups, then ours; discovered MCP definitions join the
            // same resolved registry after both, so neither a Termind name nor a
            // remote name can shadow a built-in.
            registry = AgentToolCatalog.registry(
                builtIn: AgentBuiltInToolConfiguration(
                    workspace: scratch,
                    web: web,
                    search: localSearch,
                    secretConsumerTools: [TermindAgentPolicy.sshExecToolName],
                    tasks: AgentTaskList { channel.emit(.tasksUpdated($0)) },
                    plans: AgentPlanRecorder { channel.emit(.planPresented($0)) },
                    skills: skillCatalog,
                    mcpServers: servers,
                    mcpClient: MCPClient(clientInfo: TermindAgentPolicy.mcpClientInfo)
                ),
                additional: TermindAgentTools.tools(
                    in: TermindAgentToolEnvironment(
                        hosts: hosts, metrics: metrics, connections: connections,
                        authentication: authentication,
                        background: background,
                        includesTerminalSuggestion: includesTerminalSuggestion,
                        workspace: scratch
                    ))
            )
        }
        return registry
    }
}
