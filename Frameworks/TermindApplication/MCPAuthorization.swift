import AgentKit
import Foundation
import Observation

/// A device-local secure store. OAuth grants never use the AI secret migration path.
@MainActor
public protocol MCPAuthorizationStoring: AnyObject, Sendable {
    func credentials(for serverID: UUID) throws -> [MCPOAuthCredential]
    func setCredentials(_ credentials: [MCPOAuthCredential], for serverID: UUID) throws
    func clientSecret(for server: MCPServer) throws -> String?
    func setClientSecret(_ value: String?, for server: MCPServer) throws
    func remove(serverID: UUID) throws
}

@MainActor
public final class InMemoryMCPAuthorizationStore: MCPAuthorizationStoring {
    private var grants: [UUID: [MCPOAuthCredential]] = [:]
    private var secrets: [UUID: (String, MCPOAuthConfiguration?, String)] = [:]
    public init() {}
    public func credentials(for serverID: UUID) -> [MCPOAuthCredential] { grants[serverID] ?? [] }
    public func setCredentials(_ credentials: [MCPOAuthCredential], for serverID: UUID) {
        grants[serverID] = credentials
    }
    public func clientSecret(for server: MCPServer) -> String? {
        guard let entry = secrets[server.id], entry.0 == server.url, entry.1 == server.oauth else { return nil }
        return entry.2
    }
    public func setClientSecret(_ value: String?, for server: MCPServer) {
        secrets[server.id] = value.map { (server.url, server.oauth, $0) }
    }
    public func remove(serverID: UUID) {
        grants[serverID] = nil
        secrets[serverID] = nil
    }
}

/// Checks the current configuration again at the persistence boundary, after asynchronous OAuth work.
@MainActor
public final class MCPAuthorizationGrantStore: MCPOAuthCredentialStoring {
    let backing: any MCPAuthorizationStoring
    var servers: [UUID: MCPServer] = [:]
    var changed: (() -> Void)?
    var committingIDs: Set<UUID> = []

    public init(backing: any MCPAuthorizationStoring) { self.backing = backing }

    public func credentials(for serverID: UUID) throws -> [MCPOAuthCredential] {
        guard let server = servers[serverID] else { throw CancellationError() }
        return try backing.credentials(for: serverID).filter { Self.matches($0, server: server) }
    }

    public func save(_ credentials: [MCPOAuthCredential], for serverID: UUID) throws {
        try Task.checkCancellation()
        guard let server = servers[serverID], credentials.allSatisfy({ Self.matches($0, server: server) }) else {
            throw CancellationError()
        }
        try backing.setCredentials(credentials, for: serverID)
        changed?()
    }

    public func clientSecret(for server: MCPServer) throws -> String? {
        guard let current = servers[server.id], Self.sameBinding(current, server) else { throw CancellationError() }
        return try backing.clientSecret(for: server)
    }

    public static func sameBinding(_ lhs: MCPServer, _ rhs: MCPServer) -> Bool {
        lhs.url == rhs.url && lhs.oauth == rhs.oauth && lhs.transport == rhs.transport
            && lhs.credentialRef == rhs.credentialRef && lhs.headers == rhs.headers
    }

    static func matches(_ credential: MCPOAuthCredential, server: MCPServer) -> Bool {
        guard var url = URLComponents(string: server.url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        url.scheme = url.scheme?.lowercased()
        url.host = url.host?.lowercased()
        if url.scheme == "https", url.port == 443 { url.port = nil }
        if url.path == "/" { url.path = "" }
        return credential.resource == url.string && credential.configuration == (server.oauth ?? .init())
    }
}

@MainActor @Observable
public final class MCPAuthorizationModel: MCPAuthorizationProviding {
    public static let redirectURI = URL(string: "https://termind.akinokaede.com/oauth/mcp/callback/")!
    public static let clientMetadataURL = URL(string: "https://termind.akinokaede.com/oauth/mcp-client.json")!
    public let coordinator: MCPOAuthCoordinator
    private let grants: MCPAuthorizationGrantStore
    private var revision = 0
    public private(set) var error: String?

    public init(storage: any MCPAuthorizationStoring) {
        let grants = MCPAuthorizationGrantStore(backing: storage)
        self.grants = grants
        coordinator = MCPOAuthCoordinator(
            store: grants, redirectURI: Self.redirectURI, clientMetadataURL: Self.clientMetadataURL,
            clientName: "Termind")
        grants.changed = { [weak self] in self?.revision += 1 }
    }

    public var client: MCPClient {
        MCPClient(
            clientInfo: .init(
                name: "Termind", version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"),
            authorization: self)
    }

    public func token(
        for server: MCPServer, challenge: MCPAuthorizationChallenge?, rejectedToken: String?,
        interaction: MCPAuthorizationInteraction?
    ) async throws -> String? {
        guard grants.servers[server.id].map({ MCPAuthorizationGrantStore.sameBinding($0, server) }) == true else {
            throw CancellationError()
        }
        let token = try await coordinator.token(
            for: server, challenge: challenge, rejectedToken: rejectedToken, interaction: interaction)
        guard grants.servers[server.id].map({ MCPAuthorizationGrantStore.sameBinding($0, server) }) == true else {
            throw CancellationError()
        }
        return token
    }

    public func synchronize(_ servers: [MCPServer]) {
        let updated = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        let retired = grants.servers.values.filter { previous in
            updated[previous.id].map { !MCPAuthorizationGrantStore.sameBinding(previous, $0) } ?? true
        }
        grants.servers = updated
        for server in retired {
            let retiredCredentials =
                grants.committingIDs.contains(server.id)
                ? [] : ((try? grants.backing.credentials(for: server.id)) ?? [])
            do { if !grants.committingIDs.contains(server.id) { try grants.backing.remove(serverID: server.id) } } catch
            { self.error = error.localizedDescription }
            Task {
                await coordinator.cancel(serverID: server.id)
                await coordinator.revoke(
                    retiredCredentials.filter { MCPAuthorizationGrantStore.matches($0, server: server) })
            }
        }
        revision += 1
    }

    public func isSignedIn(_ server: MCPServer) -> Bool {
        _ = revision
        guard grants.servers[server.id].map({ MCPAuthorizationGrantStore.sameBinding($0, server) }) == true else {
            return false
        }
        return (try? grants.credentials(for: server.id).contains { $0.accessToken != nil || $0.refreshToken != nil })
            ?? false
    }

    public func clientSecret(for server: MCPServer) throws -> String {
        try grants.backing.clientSecret(for: server) ?? ""
    }

    public func setClientSecret(_ secret: String, for server: MCPServer) throws {
        guard (try grants.backing.clientSecret(for: server) ?? "") != secret else { return }
        try grants.backing.setClientSecret(secret.isEmpty ? nil : secret, for: server)
        try grants.backing.setCredentials([], for: server.id)
        revision += 1
        Task { await coordinator.cancel(serverID: server.id) }
    }

    public func signOut(_ server: MCPServer) async {
        do {
            try await coordinator.signOut(serverID: server.id)
            try grants.backing.setClientSecret(nil, for: server)
            error = nil
        } catch { self.error = error.localizedDescription }
        revision += 1
    }

    public func prepareReauthorization(_ server: MCPServer) async {
        do {
            try await coordinator.signOut(serverID: server.id)
            error = nil
        } catch { self.error = error.localizedDescription }
        revision += 1
    }

    public func draft(for server: MCPServer) throws -> MCPAuthorizationDraft {
        try MCPAuthorizationDraft(server: server, live: grants, liveCoordinator: coordinator)
    }
}

/// Unsaved mobile grants stay in memory; cancelling an editor cannot replace a saved login.
@MainActor @Observable
public final class MCPAuthorizationDraft: MCPOAuthCredentialStoring, MCPAuthorizationProviding {
    private let live: MCPAuthorizationGrantStore
    private let liveCoordinator: MCPOAuthCoordinator
    private let original: MCPServer
    private var current: MCPServer
    private var values: [MCPOAuthCredential]
    private var baseline: [MCPOAuthCredential]
    public var secret: String {
        didSet {
            if secret != oldValue {
                values = []
                let service = coordinatorStorage
                let id = current.id
                Task { await service?.cancel(serverID: id) }
            }
        }
    }
    private let originalSecret: String
    private var discarded = false
    private var coordinatorStorage: MCPOAuthCoordinator?
    public var coordinator: MCPOAuthCoordinator {
        if let coordinatorStorage { return coordinatorStorage }
        let value = MCPOAuthCoordinator(
            store: self, redirectURI: MCPAuthorizationModel.redirectURI,
            clientMetadataURL: MCPAuthorizationModel.clientMetadataURL, clientName: "Termind")
        coordinatorStorage = value
        return value
    }

    init(server: MCPServer, live: MCPAuthorizationGrantStore, liveCoordinator: MCPOAuthCoordinator) throws {
        self.original = server
        self.current = server
        self.live = live
        self.liveCoordinator = liveCoordinator
        let saved = live.servers[server.id] == nil ? [] : try live.credentials(for: server.id)
        baseline = saved
        values = saved
        originalSecret = try live.backing.clientSecret(for: server) ?? ""
        secret = originalSecret
    }

    public var isSignedIn: Bool { values.contains { $0.accessToken != nil || $0.refreshToken != nil } }

    public func update(_ server: MCPServer) {
        if !MCPAuthorizationGrantStore.sameBinding(current, server) {
            values = []
            if current.url != server.url || current.oauth != server.oauth { secret = "" }
            let service = coordinatorStorage
            Task { await service?.cancel(serverID: server.id) }
        }
        current = server
    }

    /// Saved grants share the runtime's refresh flight. Only newly authorized grants belong to the draft.
    public func token(
        for server: MCPServer, challenge: MCPAuthorizationChallenge?, rejectedToken: String?,
        interaction: MCPAuthorizationInteraction?
    ) async throws -> String? {
        guard !discarded, MCPAuthorizationGrantStore.sameBinding(current, server) else { throw CancellationError() }
        if values == baseline, secret == originalSecret,
            MCPAuthorizationGrantStore.sameBinding(original, current),
            live.servers[server.id].map({ MCPAuthorizationGrantStore.sameBinding($0, current) }) == true
        {
            do {
                let token = try await liveCoordinator.token(
                    for: server, challenge: challenge, rejectedToken: rejectedToken, interaction: nil)
                baseline = try live.credentials(for: server.id)
                values = baseline
                return token
            } catch MCPOAuthError.authorizationRequired {
                baseline = try live.credentials(for: server.id)
                values = baseline
            }
        }
        return try await coordinator.token(
            for: server, challenge: challenge, rejectedToken: rejectedToken, interaction: interaction)
    }

    public func credentials(for serverID: UUID) throws -> [MCPOAuthCredential] {
        guard !discarded, serverID == current.id else { throw CancellationError() }
        return values.filter { MCPAuthorizationGrantStore.matches($0, server: current) }
    }
    public func save(_ credentials: [MCPOAuthCredential], for serverID: UUID) throws {
        try Task.checkCancellation()
        guard !discarded, serverID == current.id,
            credentials.allSatisfy({ MCPAuthorizationGrantStore.matches($0, server: current) })
        else {
            throw CancellationError()
        }
        values = credentials
    }
    public func saveRefreshed(_ credentials: [MCPOAuthCredential], for serverID: UUID) throws {
        if values != baseline {
            try save(credentials, for: serverID)
            return
        }
        guard !discarded, MCPAuthorizationGrantStore.sameBinding(original, current),
            live.servers[serverID].map({ MCPAuthorizationGrantStore.sameBinding($0, original) }) == true
        else {
            throw CancellationError()
        }
        try live.save(credentials, for: serverID)
        values = credentials
        baseline = credentials
    }

    public func clientSecret(for server: MCPServer) throws -> String? {
        guard !discarded, MCPAuthorizationGrantStore.sameBinding(current, server) else { throw CancellationError() }
        return secret.isEmpty ? nil : secret
    }

    /// Commit the secure half before the configuration transaction, and restore it if that transaction fails.
    public func commit(server: MCPServer, persist: () throws -> Void) throws {
        guard !discarded else { throw CancellationError() }
        let previous = try live.backing.credentials(for: server.id)
        let unchanged = values == baseline && secret == originalSecret
        guard unchanged || previous == baseline || !MCPAuthorizationGrantStore.sameBinding(original, server) else {
            throw SettingsDraftMerge.Conflict.changed
        }
        let committed = unchanged && MCPAuthorizationGrantStore.sameBinding(original, server) ? previous : values
        let previousSecret = try live.backing.clientSecret(for: original)
        live.committingIDs.insert(server.id)
        defer { live.committingIDs.remove(server.id) }
        do {
            try live.backing.setCredentials(
                committed.filter { MCPAuthorizationGrantStore.matches($0, server: server) }, for: server.id)
            try live.backing.setClientSecret(secret.isEmpty ? nil : secret, for: server)
            try persist()
            live.changed?()
            if !MCPAuthorizationGrantStore.sameBinding(original, server) {
                Task { await liveCoordinator.revoke(previous.filter { !committed.contains($0) }) }
            }
        } catch {
            try? live.backing.setCredentials(previous, for: server.id)
            try? live.backing.setClientSecret(previousSecret, for: original)
            throw error
        }
    }

    public func resetAfterSignOut() {
        values = []
        baseline = []
        secret = ""
    }

    public func requireAuthorization() {
        for index in values.indices {
            values[index].accessToken = nil
            values[index].refreshToken = nil
            values[index].expiresAt = nil
        }
    }

    public func discard() {
        discarded = true
        values = []
        secret = ""
        let service = coordinatorStorage
        let serverID = current.id
        coordinatorStorage = nil
        Task { await service?.cancel(serverID: serverID) }
    }
}
