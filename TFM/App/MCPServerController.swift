// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

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
            case .stopped: String(localized: AppStrings.MCP.off)
            case .starting: String(localized: AppStrings.MCP.startingProgress)
            case .ready(let port):
                String(localized: AppStrings.MCP.listeningOnLocalhost(String(port)))
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
    private var lifecycleTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var wasReady = false
    private var consecutiveRecoveryAttempts = 0
    private static let maximumRecoveryAttempts = 3

    let tools: MCPServerTools

    private(set) var status: Status = .stopped
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
        management: AgentResourceManager? = nil,

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
            history: history, disabledTools: initialDisabledTools, management: management
        )
        protocolServer = MCPServerProtocol(tools: tools)
        reloadToken()
        if isEnabled { enqueueLifecycle { await $0.start() } }
    }

    func setEnabled(_ enabled: Bool) {

        isEnabled = enabled
        defaults.set(enabled, forKey: DesktopSettingsKey.mcpServerEnabled)
        recoveryTask?.cancel()
        recoveryTask = nil
        consecutiveRecoveryAttempts = 0
        enqueueLifecycle { controller in
            if enabled { await controller.start() } else { await controller.stopInternal() }
        }
    }

    func setPort(_ value: Int) {

        let clamped = min(max(value, 1_024), 65_535)
        guard clamped != port else { return }
        port = clamped
        defaults.set(clamped, forKey: DesktopSettingsKey.mcpServerPort)
        recoveryTask?.cancel()
        recoveryTask = nil
        consecutiveRecoveryAttempts = 0
        if isEnabled { enqueueLifecycle { await $0.restart() } }
    }

    func isToolEnabled(_ name: String) -> Bool {
        !disabledTools.contains(name)
            && !(name == TermindToolName.runSnippet && disabledTools.contains(TermindToolName.sshExecRun))
    }

    func setToolEnabled(_ enabled: Bool, name: String) {

        guard MCPServerTools.exportedNames.contains(name) else { return }
        if enabled { disabledTools.remove(name) } else { disabledTools.insert(name) }
        defaults.set(Array(disabledTools).sorted(), forKey: DesktopSettingsKey.mcpServerDisabledTools)
        tools.replaceDisabledTools(
            disabledTools, hosts: hosts, metrics: metrics, connections: connections,
            authentication: authentication, background: background
        )
        if !enabled {
            Task { [protocolServer] in await protocolServer.revokeModernOperations() }
        }
    }

    func rotateToken() {

        guard let generated = try? Self.makeToken() else {
            status = .failed(String(localized: AppStrings.MCP.unableToGenerateASecureToken))
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
        enqueueLifecycle { controller in
            await controller.tools.stopTransfers()
            await controller.protocolServer.stop()
            await controller.http.replaceToken(generated)
            if let port = UInt16(exactly: controller.port), controller.isEnabled {
                controller.tools.configureTransfers(port: port)
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
        recoveryTask?.cancel()
        recoveryTask = nil
        consecutiveRecoveryAttempts = 0
        let task = enqueueLifecycle { await $0.stopInternal() }
        await task.value
    }

    private func stopInternal() async {
        wasReady = false
        await tools.stopTransfers()
        await protocolServer.stop()
        await http.stop()
        externalAuthentication.cancelExternalRequests()
        status = .stopped
    }

    @discardableResult
    private func enqueueLifecycle(_ operation: @escaping @MainActor (MCPServerController) async -> Void) -> Task<
        Void, Never
    > {
        let previous = lifecycleTask
        let next = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await operation(self)
        }
        lifecycleTask = next
        return next
    }

    private func start() async {
        guard isEnabled else { return }
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
        await stopInternal()
        guard isEnabled else { return }
        await start()
    }

    private func apply(_ state: LoopbackHTTPServer.State) {
        switch state {
        case .stopped:
            wasReady = false
            status = .stopped
        case .starting:
            status = .starting
        case .ready(let port):
            wasReady = true
            consecutiveRecoveryAttempts = 0
            recoveryTask?.cancel()
            recoveryTask = nil
            status = .ready(port: port)
        case .failed(let reason):
            let shouldRecover = wasReady && isEnabled && consecutiveRecoveryAttempts < Self.maximumRecoveryAttempts
            wasReady = false
            status = .failed(reason)
            if shouldRecover {
                consecutiveRecoveryAttempts += 1
                let delaySeconds = consecutiveRecoveryAttempts
                recoveryTask?.cancel()
                recoveryTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(delaySeconds)) } catch { return }
                    guard let self, self.isEnabled else { return }
                    self.enqueueLifecycle { await $0.restart() }
                }
            }
        }
    }

    private static func readDisabledTools(_ defaults: UserDefaults) -> Set<String> {
        var names = Set((defaults.array(forKey: DesktopSettingsKey.mcpServerDisabledTools) as? [String]) ?? [])
        if names.remove("ssh_exec") != nil {
            names.formUnion([TermindToolName.sshExecRun, TermindToolName.sshExecStdin])
        }
        if names.remove("ssh_wait") != nil { names.insert(TermindToolName.sshExecOutput) }
        names.formIntersection(MCPServerTools.exportedNames)
        defaults.set(Array(names).sorted(), forKey: DesktopSettingsKey.mcpServerDisabledTools)
        return names
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
