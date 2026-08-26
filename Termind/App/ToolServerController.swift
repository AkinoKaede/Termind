import Foundation
import Security

@MainActor
@Observable
final class ToolServerController {
    static let tokenReference = "termind.ai.toolserver.token"

    enum Status: Equatable {
        case stopped, starting, ready(port: UInt16), failed(String)

        var label: String {
            switch self {
            case .stopped: String(localized: "Off")
            case .starting: String(localized: "Starting…")
            case .ready(let port): String(localized: "Listening on localhost:\(port)")
            case .failed(let reason): reason
            }
        }
    }

    private let defaults: UserDefaults
    private let ai: AIConfigurationModel
    private let hosts: AgentHostResolver
    private let connections: AgentConnectionPool
    private let authentication: AgentSSHAuthenticationRegistry
    private let background: AgentBackgroundCommands
    private let externalAuthentication: ExternalAuthCoordinator
    private let http = LoopbackHTTPServer()
    private let protocolServer: MCPServerProtocol
    let tools: MCPToolServer

    private(set) var status: Status = .stopped
    private(set) var connectedClients = 0
    private(set) var isEnabled: Bool
    private(set) var port: Int
    private(set) var disabledTools: Set<String>

    init(
        ai: AIConfigurationModel, hosts: AgentHostResolver, connections: AgentConnectionPool,
        authentication: AgentSSHAuthenticationRegistry,
        background: AgentBackgroundCommands,
        externalAuthentication: ExternalAuthCoordinator,
        history: ToolAuditModel,
        defaults: UserDefaults = .standard
    ) {
        self.ai = ai
        self.hosts = hosts
        self.connections = connections
        self.authentication = authentication
        self.background = background
        self.externalAuthentication = externalAuthentication
        self.defaults = defaults
        isEnabled = defaults.object(forKey: SettingsKey.toolServerEnabled) as? Bool
            ?? SettingsKey.defaultToolServerEnabled
        port = defaults.object(forKey: SettingsKey.toolServerPort) as? Int
            ?? SettingsKey.defaultToolServerPort
        let initialDisabledTools = Self.readDisabledTools(defaults)
        disabledTools = initialDisabledTools
        tools = MCPToolServer(
            hosts: hosts, connections: connections, authentication: authentication,
            background: background, externalAuthentication: externalAuthentication,
            history: history, disabledTools: initialDisabledTools
        )
        protocolServer = MCPServerProtocol(tools: tools)
        Task { [weak self, protocolServer] in
            await protocolServer.setClientCountHandler { [weak self] count in
                Task { @MainActor in self?.connectedClients = count }
            }
        }
        if isEnabled { Task { [weak self] in await self?.start() } }
    }

    var token: String { ai.secret(for: Self.tokenReference) ?? "" }

    var enabledToolNames: [String] {
        MCPToolServer.exportedNames.subtracting(disabledTools).sorted()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: SettingsKey.toolServerEnabled)
        Task { [weak self] in
            if enabled { await self?.start() } else { await self?.stop() }
        }
    }

    func setPort(_ value: Int) {
        let clamped = min(max(value, 1_024), 65_535)
        guard clamped != port else { return }
        port = clamped
        defaults.set(clamped, forKey: SettingsKey.toolServerPort)
        if isEnabled { Task { [weak self] in await self?.restart() } }
    }

    func setToolEnabled(_ enabled: Bool, name: String) {
        guard MCPToolServer.exportedNames.contains(name) else { return }
        if enabled { disabledTools.remove(name) } else { disabledTools.insert(name) }
        defaults.set(Array(disabledTools).sorted(), forKey: SettingsKey.toolServerDisabledTools)
        tools.replaceDisabledTools(
            disabledTools, hosts: hosts, connections: connections,
            authentication: authentication, background: background
        )
    }

    func rotateToken() {
        guard let generated = try? Self.makeToken() else {
            status = .failed(String(localized: "Unable to generate a secure token."))
            return
        }
        ai.setSecret(generated, for: Self.tokenReference)
        guard ai.secretStorageError == nil else {
            status = .failed(ai.secretStorageError ?? String(localized: "Unable to store the token."))
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await protocolServer.stop()
            await http.replaceToken(generated)
        }
    }

    func ensureToken() -> String? {
        if !token.isEmpty { return token }
        rotateToken()
        return token.isEmpty ? nil : token
    }

    func stop() async {
        await protocolServer.stop()
        await http.stop()
        externalAuthentication.cancelAll()
        connectedClients = 0
        status = .stopped
    }

    private func start() async {
        guard isEnabled else { return }
        guard let token = ensureToken(), let validPort = UInt16(exactly: port) else {
            isEnabled = false
            defaults.set(false, forKey: SettingsKey.toolServerEnabled)
            return
        }
        status = .starting
        do {
            try await http.start(
                port: validPort, token: token,
                stateHandler: { [weak self] state in
                    Task { @MainActor in self?.apply(state) }
                },
                handler: { [protocolServer] request in
                    await protocolServer.handle(request)
                }
            )
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func restart() async {
        await stop()
        guard isEnabled else { return }
        await start()
    }

    private func apply(_ state: LoopbackHTTPServer.State) {
        switch state {
        case .stopped: status = .stopped
        case .starting: status = .starting
        case .ready(let port): status = .ready(port: port)
        case .failed(let reason): status = .failed(reason)
        }
    }

    private static func readDisabledTools(_ defaults: UserDefaults) -> Set<String> {
        Set((defaults.array(forKey: SettingsKey.toolServerDisabledTools) as? [String]) ?? [])
            .intersection(MCPToolServer.exportedNames)
    }

    private static func makeToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ToolServerTokenError.generationFailed
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private enum ToolServerTokenError: Error { case generationFailed }
