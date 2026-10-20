// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

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
        panes: AgentPaneAccess? = nil,
        chatModels: (any AgentChatModelCatalog)? = nil,
        chats: (any AgentChatCoordinating)? = nil,
        chatSource: AgentChatSourceContext? = nil
    ) -> AgentToolRegistry {
        let native =
            ai.webSearch.isEnabled && ai.webSearch.prefersBuiltIn && provider.supportsNativeWebSearch(model: model)
        let localSearch: ScrubberWebClient? = ai.webSearch.isEnabled && !native ? ScrubberWebClient() : nil
        var registry = AgentToolRegistry([AnyAgentTool]())
        if model.abilities.contains(.toolCall) {
            let scratch = AgentScratchWorkspace.shared(applicationName: TermindAgentPolicy.scratchDirectoryName)
            // One client for both, rather than two default-constructed ones: `fetch`
            // and `scratch_fetch` read the same web the same way and differ only in
            // where the page ends up.
            let web = ScrubberWebClient()
            // Plans write through the ordered channel the rest of the run
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
                    plans: AgentPlanRecorder { channel.emit(.planPresented($0)) },
                    skills: skillCatalog,
                    chatModels: chatModels, chats: chats, chatSource: chatSource,
                    mcpServers: servers,
                    mcpClient: ai.mcpAuthorization.client
                ),
                additional: TermindAgentTools.tools(
                    in: TermindAgentToolEnvironment(
                        hosts: hosts, metrics: metrics, connections: connections,
                        authentication: authentication,
                        background: background, scope: conversation.id,
                        workspace: scratch, panes: panes
                    ))
            )
        }
        return registry
    }
}
