import Foundation
import Security

@MainActor
@Observable
final class MCPServerController {
    static let tokenReference = "termind.ai.mcpserver.token"

    enum Status: Equatable {
        case stopped, starting
        case ready(port: UInt16)
        case failed(String)

        var label: String {
            switch self {
            case .stopped: String(localized: "Off")
            case .starting: String(localized: "Starting…")
            case .ready(let port):
                String(localized: "Listening on localhost:\(String(port))")
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
    private let canUsePro: @MainActor () -> Bool
    private let requestPro: @MainActor () -> Bool
    let tools: MCPServerTools

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
        canUsePro: @escaping @MainActor () -> Bool = { true },
        requestPro: @escaping @MainActor () -> Bool = { true },
        defaults: UserDefaults = .standard
    ) {
        self.ai = ai
        self.hosts = hosts
        self.connections = connections
        self.authentication = authentication
        self.background = background
        self.externalAuthentication = externalAuthentication
        self.defaults = defaults
        self.canUsePro = canUsePro
        self.requestPro = requestPro
        isEnabled =
            defaults.object(forKey: SettingsKey.mcpServerEnabled) as? Bool
            ?? SettingsKey.defaultMCPServerEnabled
        port =
            defaults.object(forKey: SettingsKey.mcpServerPort) as? Int
            ?? SettingsKey.defaultMCPServerPort
        let initialDisabledTools = Self.readDisabledTools(defaults)
        disabledTools = initialDisabledTools
        tools = MCPServerTools(
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
        if isEnabled, canUsePro() { Task { [weak self] in await self?.start() } }
    }

    var token: String {
        ai.secret(for: Self.tokenReference) ?? ""
    }

    func setEnabled(_ enabled: Bool) {
        if enabled, !requestPro() { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: SettingsKey.mcpServerEnabled)
        Task { [weak self] in
            if enabled { await self?.start() } else { await self?.stop() }
        }
    }

    func suspendForProAccess() {
        Task { [weak self] in await self?.stop() }
    }

    func resumeForProAccess() {
        guard isEnabled, canUsePro() else { return }
        Task { [weak self] in await self?.start() }
    }

    func setPort(_ value: Int) {
        guard requestPro() else { return }
        let clamped = min(max(value, 1_024), 65_535)
        guard clamped != port else { return }
        port = clamped
        defaults.set(clamped, forKey: SettingsKey.mcpServerPort)
        if isEnabled { Task { [weak self] in await self?.restart() } }
    }

    func setToolEnabled(_ enabled: Bool, name: String) {
        guard requestPro() else { return }
        guard MCPServerTools.exportedNames.contains(name) else { return }
        if enabled { disabledTools.remove(name) } else { disabledTools.insert(name) }
        defaults.set(Array(disabledTools).sorted(), forKey: SettingsKey.mcpServerDisabledTools)
        tools.replaceDisabledTools(
            disabledTools, hosts: hosts, connections: connections,
            authentication: authentication, background: background
        )
    }

    func rotateToken() {
        guard requestPro() else { return }
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
        guard isEnabled, canUsePro() else { return }
        guard let token = ensureToken(), let validPort = UInt16(exactly: port) else {
            isEnabled = false
            defaults.set(false, forKey: SettingsKey.mcpServerEnabled)
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
        Set((defaults.array(forKey: SettingsKey.mcpServerDisabledTools) as? [String]) ?? [])
            .intersection(MCPServerTools.exportedNames)
    }

    private static func makeToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MCPServerTokenError.generationFailed
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private enum MCPServerTokenError: Error { case generationFailed }
