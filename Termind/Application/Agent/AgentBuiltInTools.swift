import Foundation

nonisolated enum AgentBuiltInTools: AgentToolSchemaBuilding {
    /// `search` is optional, and nil means the tool is not registered at all
    /// rather than registered and always failing. A model shown a `web_search`
    /// it cannot use spends a turn discovering that; a model not shown one
    /// reaches for `fetch` or asks, which is the behaviour we want when no
    /// backend is configured. It is also nil whenever the model has provider
    /// search of its own — see `AppModel.webSearchPlan`.
    static func make(
        hosts: AgentHostResolver,
        connections: AgentConnectionPool,
        authentication suppliedAuthentication: AgentSSHAuthenticationRegistry? = nil,
        background: AgentBackgroundCommands = AgentBackgroundCommands(),
        fetcher: RestrictedHTTPFetcher = RestrictedHTTPFetcher(),
        search: WebSearchClient? = nil,
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
            fetch(fetcher),
            requestUserInput(), requestUserSecret(),
        ] + (search.map { [webSearch($0)] } ?? [])
    }
}
