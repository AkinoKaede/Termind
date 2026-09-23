import Foundation
import Security
import TermindApplication
import TermindPresentation
import TermindRemoteInfrastructure

@MainActor
@Observable
final class MCPServerController {
    enum Status: Equatable {
        case stopped, starting
        case ready(port: UInt16)
        case failed(String)

        var label: String {
            switch self {
            case .stopped: String(localized: TermindCopy.MCP.off)
            case .starting: String(localized: TermindCopy.MCP.startingProgress)
            case .ready(let port):
                String(localized: TermindCopy.MCP.listeningOnLocalhost(String(port)))
            case .failed(let reason): reason
            }
        }
    }

    private let defaults: UserDefaults
    private let tokenStore: MCPServerTokenStore
    private let metrics: any MetricsSnapshotReading
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
    private(set) var token = ""
    private(set) var tokenStorageError: String?

    init(
        secrets: any SecretStoring, hosts: AgentHostResolver, metrics: any MetricsSnapshotReading,
        connections: AgentConnectionPool,
        authentication: AgentSSHAuthenticationRegistry,
        background: AgentBackgroundCommands,
        externalAuthentication: ExternalAuthCoordinator,
        history: ToolAuditModel,
        canUsePro: @escaping @MainActor () -> Bool = { true },
        requestPro: @escaping @MainActor () -> Bool = { true },
        defaults: UserDefaults = .standard
    ) {
        tokenStore = MCPServerTokenStore(secrets: secrets)
        self.metrics = metrics
        self.hosts = hosts
        self.connections = connections
        self.authentication = authentication
        self.background = background
        self.externalAuthentication = externalAuthentication
        self.defaults = defaults
        self.canUsePro = canUsePro
        self.requestPro = requestPro
        isEnabled =
            defaults.object(forKey: DesktopSettingsKey.mcpServerEnabled) as? Bool
            ?? DesktopSettingsKey.defaultMCPServerEnabled
        port =
            defaults.object(forKey: DesktopSettingsKey.mcpServerPort) as? Int
            ?? DesktopSettingsKey.defaultMCPServerPort
        let initialDisabledTools = Self.readDisabledTools(defaults)
        disabledTools = initialDisabledTools
        tools = MCPServerTools(
            hosts: hosts, metrics: metrics, connections: connections, authentication: authentication,
            background: background, externalAuthentication: externalAuthentication,
            history: history, disabledTools: initialDisabledTools
        )
        protocolServer = MCPServerProtocol(tools: tools)
        reloadToken()
        Task { [weak self, protocolServer] in
            await protocolServer.setClientCountHandler { [weak self] count in
                Task { @MainActor in self?.connectedClients = count }
            }
        }
        if isEnabled, canUsePro() { Task { [weak self] in await self?.start() } }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled, !requestPro() { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: DesktopSettingsKey.mcpServerEnabled)
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
        defaults.set(clamped, forKey: DesktopSettingsKey.mcpServerPort)
        if isEnabled { Task { [weak self] in await self?.restart() } }
    }

    func setToolEnabled(_ enabled: Bool, name: String) {
        guard requestPro() else { return }
        guard MCPServerTools.exportedNames.contains(name) else { return }
        if enabled { disabledTools.remove(name) } else { disabledTools.insert(name) }
        defaults.set(Array(disabledTools).sorted(), forKey: DesktopSettingsKey.mcpServerDisabledTools)
        tools.replaceDisabledTools(
            disabledTools, hosts: hosts, metrics: metrics, connections: connections,
            authentication: authentication, background: background
        )
    }

    func rotateToken() {
        guard requestPro() else { return }
        guard let generated = try? Self.makeToken() else {
            status = .failed(String(localized: TermindCopy.MCP.unableToGenerateASecureToken))
            return
        }
        do {
            try tokenStore.save(generated)
            token = generated
            tokenStorageError = nil
        } catch {
            tokenStorageError = error.localizedDescription
            status = .failed(error.localizedDescription)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await tools.stopTransfers()
            await protocolServer.stop()
            await http.replaceToken(generated)
            if let port = UInt16(exactly: self.port), self.isEnabled {
                tools.configureTransfers(port: port)
            }
        }
    }

    func ensureToken() -> String? {
        if token.isEmpty { reloadToken() }
        guard tokenStorageError == nil else { return nil }
        if !token.isEmpty { return token }
        rotateToken()
        return token.isEmpty ? nil : token
    }

    func stop() async {
        await tools.stopTransfers()
        await protocolServer.stop()
        await http.stop()
        externalAuthentication.cancelExternalRequests()
        connectedClients = 0
        status = .stopped
    }

    private func start() async {
        guard isEnabled, canUsePro() else { return }
        guard let token = ensureToken(), let validPort = UInt16(exactly: port) else {
            isEnabled = false
            defaults.set(false, forKey: DesktopSettingsKey.mcpServerEnabled)
            return
        }
        status = .starting
        tools.configureTransfers(port: validPort)
        do {
            try await http.start(
                port: validPort, token: token,
                stateHandler: { [weak self] state in
                    Task { @MainActor in self?.apply(state) }
                },
                streamingHandler: { [uploads = tools.uploads] request in
                    await uploads.prepare(request)
                },
                downloadHandler: { [downloads = tools.downloads] request, token, cancelTransport in
                    await downloads.prepare(request, cancellation: token, cancelTransport: cancelTransport)
                },
                handler: { [protocolServer] request in
                    await protocolServer.handle(request)
                }
            )
        } catch {
            await tools.stopTransfers()
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
        Set((defaults.array(forKey: DesktopSettingsKey.mcpServerDisabledTools) as? [String]) ?? [])
            .intersection(MCPServerTools.exportedNames)
    }

    private func reloadToken() {
        do {
            token = try tokenStore.load() ?? ""
            tokenStorageError = nil
        } catch {
            tokenStorageError = error.localizedDescription
            status = .failed(error.localizedDescription)
        }
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
