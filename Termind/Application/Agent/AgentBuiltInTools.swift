import Foundation

nonisolated enum AgentBuiltInTools: AgentToolSchemaBuilding {
    /// `search` is nil whenever Web Search is disabled or the model uses its
    /// provider's native search. `web` always powers the standalone `fetch`.
    static func make(
        hosts: AgentHostResolver,
        connections: AgentConnectionPool,
        authentication suppliedAuthentication: AgentSSHAuthenticationRegistry? = nil,
        background: AgentBackgroundCommands = AgentBackgroundCommands(),
        web: ScrubberWebClient = ScrubberWebClient(),
        search: ScrubberWebClient? = nil,
        includesTerminalSuggestion: Bool = false
    ) -> [AnyAgentTool] {
        let authentication = suppliedAuthentication
            ?? AgentSSHAuthenticationRegistry(resolver: hosts)
        let terminalTools = includesTerminalSuggestion ? [terminalSuggest()] : []
        return [
            listHosts(hosts), sshExec(authentication, connections, background),
            sshWait(background),
        ] + terminalTools + [
            sftpList(authentication, connections), sftpStat(authentication, connections),
            sftpRead(authentication, connections), sftpWrite(authentication, connections),
            sftpMkdir(authentication, connections), sftpMove(authentication, connections),
            sftpChmod(authentication, connections), sftpDelete(authentication, connections),
            fetch(web),
            requestUserInput(), requestUserSecret(),
        ] + (search.map { [webSearch($0)] } ?? [])
    }
}
